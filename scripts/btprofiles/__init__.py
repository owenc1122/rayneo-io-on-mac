"""Phone-side classic Bluetooth profiles for the virtual phone (pure Python, no dependencies).

Each profile is a class built around a `send(bytes)` callback (bytes to the glasses on its channel)
and an `on_data(bytes)` method (bytes from the glasses on that channel), so it can be plugged into
any transport (scripts/bredr.py's L2CAP channels / RFCOMM DLCs, or a unit test):

    hfp.HfpAudioGateway   HFP 1.8 Audio Gateway: AT commands over one RFCOMM DLC
    avdtp.A2dpSource      AVDTP signaling (L2CAP PSM 0x19) + A2DP SBC media (second L2CAP channel)
    avrcp.AvrcpTarget     AVRCP 1.6 target over AVCTP (L2CAP PSM 0x17)
    sbc                   SBC encoder/decoder (A2DP spec appendix B); python3 -m btprofiles.sbc in.wav out.sbc

Unit tests: python3 -m unittest discover -s Tests/btprofiles
"""
