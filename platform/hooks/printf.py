# Minimal printf formatter for Renode hooks (IronPython 2.7). Reads a format
# string and a va_list argument area from emulated memory. Used for trace only.
import struct as _st
_ctx = [None]  # CPU whose address map is used (cores with private windows, e.g. M55C1)
def _rd32(bus, a):
    return bus.ReadDoubleWord(a, _ctx[0]) & 0xffffffff
def _cstr(bus, a, limit=256):
    if a == 0 or a < 0x100000:
        return '(null)'
    out = []
    for i in range(limit):
        c = bus.ReadByte(a + i, _ctx[0])
        if c == 0:
            break
        out.append(chr(c) if (c == 10 or 32 <= c < 127) else '.')
    return ''.join(out)
def fw_format(bus, fmt_addr, ap, ctx=None):
    _ctx[0] = ctx
    fmt = _cstr(bus, fmt_addr, 512)
    res = []
    i = 0
    n = len(fmt)
    while i < n:
        ch = fmt[i]
        if ch != '%':
            res.append(ch); i += 1; continue
        i += 1
        if i < n and fmt[i] == '%':
            res.append('%'); i += 1; continue
        flags = ''
        while i < n and fmt[i] in '-+ #0':
            flags += fmt[i]; i += 1
        width = ''
        if i < n and fmt[i] == '*':
            width = str(_rd32(bus, ap)); ap += 4; i += 1
        while i < n and fmt[i].isdigit():
            width += fmt[i]; i += 1
        prec = ''
        if i < n and fmt[i] == '.':
            i += 1; prec = '.'
            if i < n and fmt[i] == '*':
                prec += str(_rd32(bus, ap)); ap += 4; i += 1
            while i < n and fmt[i].isdigit():
                prec += fmt[i]; i += 1
        length = ''
        while i < n and fmt[i] in 'hlqjzt':
            length += fmt[i]; i += 1
        if i >= n:
            break
        conv = fmt[i]; i += 1
        spec = '%' + flags + width + prec
        try:
            if conv in 'diuxXoc':
                if length in ('ll', 'q', 'j'):
                    ap = (ap + 7) & ~7
                    v = _rd32(bus, ap) | (_rd32(bus, ap + 4) << 32); ap += 8
                    if conv in 'di' and v >= (1 << 63): v -= (1 << 64)
                else:
                    v = _rd32(bus, ap); ap += 4
                    if length == 'hh': v &= 0xff
                    elif length == 'h': v &= 0xffff
                    if conv in 'di' and v >= (1 << 31): v -= (1 << 32)
                if conv == 'u': conv = 'd'
                if conv == 'c':
                    res.append(chr(v & 0xff) if 32 <= (v & 0xff) < 127 else '.')
                else:
                    res.append((spec + conv) % v)
            elif conv == 's':
                a = _rd32(bus, ap); ap += 4
                res.append((spec + 's') % _cstr(bus, a))
            elif conv == 'p':
                a = _rd32(bus, ap); ap += 4
                res.append('0x%x' % a)
            elif conv in 'fFeEgG':
                ap = (ap + 7) & ~7
                raw = _rd32(bus, ap) | (_rd32(bus, ap + 4) << 32); ap += 8
                res.append((spec + conv) % _st.unpack('<d', _st.pack('<Q', raw))[0])
            else:
                res.append('%' + conv)
        except Exception:
            res.append('<?' + conv + '>')
    return ''.join(res)
