"""HFP 1.8 Audio Gateway (the phone) over one RFCOMM DLC; the glasses are the Hands-Free unit.

    ag = HfpAudioGateway(send=dlc_write, on_audio=open_sco)
    ag.on_data(bytes)              # RFCOMM payload from the HF (AT commands, CR-terminated)
    ag.incoming_call('+15550123')  # callsetup=1, RING + CLIP (call ring() every ~3 s while ringing)
    ag.remote_answer() / ag.remote_hangup() / ag.dial_out('10086') / ag.set_indicator('battchg', 3)

Service level connection (HFP 4.2): AT+BRSF -> +BRSF, [AT+BAC], AT+CIND=? / AT+CIND?, AT+CMER,
[AT+CHLD=?], [AT+BIND=, AT+BIND=?, AT+BIND?] -> `slc` is True. Call control: ATA, AT+CHUP, ATD,
AT+BLDN, AT+CHLD, AT+CLCC, AT+CLIP/CCWA/CMEE/NREC/VGS/VGM/BIA/BCC/BCS (codec connection, then
`on_audio(codec)` asks the host for the SCO/eSCO link: 1 CVSD, 2 mSBC).
"""

# AG supported features (+BRSF bit map, HFP 4.34.1)
AG_THREE_WAY, AG_EC_NR, AG_VOICE_RECOGNITION, AG_INBAND_RING, AG_VOICE_TAG, AG_REJECT_CALL, \
    AG_ENHANCED_STATUS, AG_ENHANCED_CONTROL, AG_EXTENDED_ERRORS, AG_CODEC_NEGOTIATION, \
    AG_HF_INDICATORS, AG_ESCO_S4 = (1 << i for i in range(12))
# HF supported features (AT+BRSF bit map)
HF_EC_NR, HF_THREE_WAY, HF_CLI, HF_VOICE_RECOGNITION, HF_REMOTE_VOLUME, HF_ENHANCED_STATUS, \
    HF_ENHANCED_CONTROL, HF_CODEC_NEGOTIATION, HF_HF_INDICATORS, HF_ESCO_S4 = (1 << i for i in range(10))

CVSD, MSBC = 1, 2
# Indicators in +CIND order (index = position + 1).
INDICATORS = (('service', (0, 1)), ('call', (0, 1)), ('callsetup', (0, 3)), ('callheld', (0, 2)),
              ('signal', (0, 5)), ('roam', (0, 1)), ('battchg', (0, 5)))
# Call states (+CLCC stat)
ACTIVE, HELD, DIALING, ALERTING, INCOMING, WAITING = 0, 1, 2, 3, 4, 5


class HfpAudioGateway:
    FEATURES = (AG_THREE_WAY | AG_EC_NR | AG_REJECT_CALL | AG_ENHANCED_STATUS | AG_ENHANCED_CONTROL |
                AG_EXTENDED_ERRORS | AG_CODEC_NEGOTIATION | AG_HF_INDICATORS)

    def __init__(self, send, on_audio=None, say=None, operator='Virtual Carrier',
                 own_number='+15550100'):
        self.send, self.on_audio = send, on_audio
        self.say = say or (lambda *_: None)
        self.operator, self.own_number = operator, own_number
        self.rx = b''
        self.hf_features = 0
        self.hf_codecs = [CVSD]
        self.codec = CVSD
        self.slc = False
        self.cmer = False                 # indicator events reporting enabled (AT+CMER=3,0,0,1)
        self.clip = self.ccwa = self.cmee = False
        self.ind = dict(service=1, call=0, callsetup=0, callheld=0, signal=5, roam=0, battchg=5)
        self.ind_active = {name: True for name, _ in INDICATORS}
        self.hf_indicators = {}           # HF indicator id -> enabled
        self.calls = []                   # dicts: idx, dir (0 out, 1 in), stat, number
        self.last_dialed = None
        self.speaker_gain = self.mic_gain = 8
        self.nrec = True
        self.pending_codec = None

    # ---- output ----
    def _out(self, text):
        self.say('HFP -> %s' % text)
        self.send(b'\r\n' + text.encode() + b'\r\n')

    def _ok(self):
        self._out('OK')

    def _error(self, cme=None):
        self._out('+CME ERROR: %d' % cme if (cme is not None and self.cmee) else 'ERROR')

    def _ciev(self, name, value):
        if self.ind.get(name) == value:
            return
        self.ind[name] = value
        if self.cmer and self.ind_active.get(name, True):
            idx = [n for n, _ in INDICATORS].index(name) + 1
            self._out('+CIEV: %d,%d' % (idx, value))

    # ---- input ----
    def on_data(self, data):
        self.rx += data
        while b'\r' in self.rx:
            line, self.rx = self.rx.split(b'\r', 1)
            line = line.strip(b'\n ').decode(errors='replace')
            if line:
                self.say('HFP <- %s' % line)
                self.on_command(line)

    def on_command(self, line):
        up = line.upper()
        if up.startswith('AT+BRSF='):
            self.hf_features = int(line[8:])
            self._out('+BRSF: %d' % self.FEATURES)
            self._ok()
        elif up.startswith('AT+BAC='):
            self.hf_codecs = [int(c) for c in line[7:].split(',') if c.strip().isdigit()]
            self._ok()
        elif up == 'AT+CIND=?':
            self._out('+CIND: ' + ','.join('("%s",(%d-%d))' % (n, lo, hi) for n, (lo, hi) in INDICATORS))
            self._ok()
        elif up == 'AT+CIND?':
            self._out('+CIND: ' + ','.join(str(self.ind[n]) for n, _ in INDICATORS))
            self._ok()
        elif up.startswith('AT+CMER='):
            fields = line[8:].split(',')
            self.cmer = len(fields) >= 4 and fields[0].strip() == '3' and fields[3].strip() == '1'
            self._ok()
            if not self._both(AG_THREE_WAY, HF_THREE_WAY) and not self._both(AG_HF_INDICATORS, HF_HF_INDICATORS):
                self._slc_up()
        elif up == 'AT+CHLD=?':
            self._out('+CHLD: (0,1,1x,2,2x,3)')
            self._ok()
            if not self._both(AG_HF_INDICATORS, HF_HF_INDICATORS):
                self._slc_up()
        elif up.startswith('AT+BIND='):
            if line[8:] == '?':
                self._out('+BIND: (1,2)')
            else:
                for i in line[8:].split(','):
                    if i.strip().isdigit():
                        self.hf_indicators[int(i)] = False
            self._ok()
        elif up == 'AT+BIND?':
            for i in (1, 2):                              # 1 enhanced safety, 2 battery level
                self._out('+BIND: %d,1' % i)
                self.hf_indicators[i] = True
            self._ok()
            self._slc_up()
        elif up.startswith('AT+BIEV='):
            ind, val = (int(v) for v in line[8:].split(',')[:2])
            self.say('HFP HF indicator %d = %d' % (ind, val))
            self.hf_indicator_values = getattr(self, 'hf_indicator_values', {})
            self.hf_indicator_values[ind] = val
            self._ok()
        elif up.startswith('AT+BIA='):
            for (name, _), flag in zip(INDICATORS, line[7:].split(',')):
                if flag.strip() in ('0', '1') and name not in ('call', 'callsetup', 'callheld'):
                    self.ind_active[name] = flag.strip() == '1'
            self._ok()
        elif up.startswith('AT+CLIP='):
            self.clip = line[8:].strip() == '1'
            self._ok()
        elif up.startswith('AT+CCWA='):
            self.ccwa = line[8:].strip() == '1'
            self._ok()
        elif up.startswith('AT+CMEE='):
            self.cmee = line[8:].strip() == '1'
            self._ok()
        elif up.startswith('AT+NREC='):
            self.nrec = line[8:].strip() == '1'
            self._ok()
        elif up.startswith('AT+VGS='):
            self.speaker_gain = int(line[7:])
            self._ok()
        elif up.startswith('AT+VGM='):
            self.mic_gain = int(line[7:])
            self._ok()
        elif up == 'AT+CLCC':
            for c in self.calls:
                self._out('+CLCC: %d,%d,%d,0,0,"%s",%d' % (c['idx'], c['dir'], c['stat'], c['number'],
                                                         145 if c['number'].startswith('+') else 129))
            self._ok()
        elif up == 'AT+COPS=3,0':
            self._ok()
        elif up == 'AT+COPS?':
            self._out('+COPS: 0,0,"%s"' % self.operator)
            self._ok()
        elif up == 'AT+CNUM':
            self._out('+CNUM: ,"%s",145,,4' % self.own_number)
            self._ok()
        elif up == 'AT+BTRH?':
            self._ok()
        elif up == 'ATA':
            call = self._call(INCOMING)
            if not call:
                return self._error(3)
            self._ok()
            call['stat'] = ACTIVE
            self._ciev('call', 1)
            self._ciev('callsetup', 0)
            self.connect_audio()
        elif up == 'AT+CHUP':
            if not self.calls:
                return self._error(3)
            self._ok()
            self._end_call(self.calls[0])
        elif up.startswith('ATD'):
            number = line[3:].rstrip(';')
            if number.startswith('>'):
                return self._error(21)                    # memory dialing not supported
            self._ok()
            self.dial_out(number)
        elif up == 'AT+BLDN':
            if not self.last_dialed:
                return self._error(21)
            self._ok()
            self.dial_out(self.last_dialed)
        elif up.startswith('AT+CHLD='):
            self._chld(line[8:].strip())
        elif up.startswith('AT+BCC'):
            self._ok()
            self.connect_audio()
        elif up.startswith('AT+BCS='):
            codec = int(line[7:])
            if codec != self.pending_codec:
                return self._error()
            self._ok()
            self.codec, self.pending_codec = codec, None
            self._audio_up()
        elif up.startswith('AT+BVRA='):
            self._error()                                 # voice recognition not offered
        elif up.startswith(('AT+XAPL=', 'AT+IPHONEACCEV=', 'AT+XEVENT=', 'AT+APLSIRI', 'AT+ANDROID')):
            self._ok()                                    # vendor extensions: accept quietly
        else:
            self._error(4)

    def _both(self, ag_bit, hf_bit):
        return bool(self.FEATURES & ag_bit) and bool(self.hf_features & hf_bit)

    def _slc_up(self):
        if not self.slc:
            self.slc = True
            self.say('HFP service level connection established')

    # ---- calls ----
    def _call(self, stat):
        return next((c for c in self.calls if c['stat'] == stat), None)

    def _new_call(self, number, direction, stat):
        call = dict(idx=len(self.calls) + 1, dir=direction, stat=stat, number=number)
        self.calls.append(call)
        return call

    def incoming_call(self, number, ring=True):
        if self._call(ACTIVE):                            # call waiting
            self._new_call(number, 1, WAITING)
            if self.ccwa:
                self._out('+CCWA: "%s",%d,1' % (number, 145 if number.startswith('+') else 129))
            self._ciev('callsetup', 1)
            return
        self._new_call(number, 1, INCOMING)
        self._ciev('callsetup', 1)
        if ring:
            self.ring()

    def ring(self):
        """RING (+CLIP) for the ringing call; the host repeats this every few seconds."""
        call = self._call(INCOMING)
        if call:
            self._out('RING')
            if self.clip:
                self._out('+CLIP: "%s",%d' % (call['number'], 145 if call['number'].startswith('+') else 129))

    def dial_out(self, number):
        self.last_dialed = number
        self._new_call(number, 0, DIALING)
        self._ciev('callsetup', 2)

    def remote_alerting(self):
        call = self._call(DIALING)
        if call:
            call['stat'] = ALERTING
            self._ciev('callsetup', 3)

    def remote_answer(self):
        call = self._call(ALERTING) or self._call(DIALING)
        if call:
            call['stat'] = ACTIVE
            self._ciev('call', 1)
            self._ciev('callsetup', 0)
            self.connect_audio()

    def phone_answer(self):
        """The user answered on the phone itself."""
        call = self._call(INCOMING)
        if call:
            call['stat'] = ACTIVE
            self._ciev('call', 1)
            self._ciev('callsetup', 0)
            self.connect_audio()

    def remote_hangup(self):
        if self.calls:
            self._end_call(self.calls[0])

    def _end_call(self, call, update_held=True):
        was = call['stat']
        self.calls.remove(call)
        for i, c in enumerate(self.calls):
            c['idx'] = i + 1
        if was in (INCOMING, DIALING, ALERTING, WAITING):
            self._ciev('callsetup', 0)
        if was in (ACTIVE, HELD) and not any(c['stat'] in (ACTIVE, HELD) for c in self.calls):
            self._ciev('call', 0)
        if update_held:
            self._ciev('callheld', 0 if not self._call(HELD) else (1 if self._call(ACTIVE) else 2))

    def _chld(self, arg):
        active, held, waiting = self._call(ACTIVE), self._call(HELD), self._call(WAITING)
        if arg == '0':                                    # release held / reject waiting
            target = waiting or held
            if not target:
                return self._error(3)
            self._ok()
            self._end_call(target)
        elif arg == '1':                                  # release active, accept other
            self._ok()
            if active:
                self._end_call(active, update_held=False)    # the swap below reports the final state
            other = waiting or held
            if other:
                other['stat'] = ACTIVE
                self._ciev('call', 1)
                self._ciev('callsetup', 0)
                self._ciev('callheld', 0)
        elif arg == '2':                                  # hold active, accept other
            self._ok()
            other = waiting or held
            if active:
                active['stat'] = HELD
            if other:
                other['stat'] = ACTIVE
                self._ciev('callsetup', 0)
            self._ciev('callheld', 1 if self._call(ACTIVE) and self._call(HELD) else 2)
        elif arg == '3':                                  # conference
            if not (active and held):
                return self._error(3)
            self._ok()
            held['stat'] = ACTIVE
            self._ciev('callheld', 0)
        elif arg[:1] == '1' and arg[1:].isdigit():
            call = next((c for c in self.calls if c['idx'] == int(arg[1:])), None)
            if not call:
                return self._error(3)
            self._ok()
            self._end_call(call)
        else:
            self._error(4)

    # ---- audio / volume / indicators ----
    def connect_audio(self):
        """Codec connection (HFP 4.11.3) when both support negotiation, else straight to SCO."""
        if self._both(AG_CODEC_NEGOTIATION, HF_CODEC_NEGOTIATION):
            self.pending_codec = MSBC if MSBC in self.hf_codecs else CVSD
            self._out('+BCS: %d' % self.pending_codec)
        else:
            self.codec = CVSD
            self._audio_up()

    def _audio_up(self):
        self.say('HFP audio connection, codec %s' % ('mSBC' if self.codec == MSBC else 'CVSD'))
        if self.on_audio:
            self.on_audio(self.codec)

    def set_speaker_volume(self, gain):
        self.speaker_gain = gain
        self._out('+VGS: %d' % gain)

    def set_mic_volume(self, gain):
        self.mic_gain = gain
        self._out('+VGM: %d' % gain)

    def set_indicator(self, name, value):
        self._ciev(name, value)
