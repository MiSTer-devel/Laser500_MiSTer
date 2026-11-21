#!/usr/bin/env python3
"""Laser 350/500/700 tape decoder (a model of the BASIC ROM's tape reader).

Reads .wav (PCM 8/16-bit, float 32, mono or the left channel) or .cas (the
raw byte stream, played as MAME's vtech2 format: 10800 samples/s, 18 per
bit) and decodes it with the ROM's own algorithm (27-0401-00-00.u6,
RDBYET 1865h, bit reader 18A6h, leader sync 182Dh, header 17C2h, block
19BCh), timed in the core's CPU T-states: one T-state per 4 F14M clocks
plus one 4-clock beat at the start of every memory cycle (rtl/VTL_chip.sv),
which is how the ROM's loops measure the pulses.

    python3 -I tools/laser500_tape.py TAPE...     one line per file on the tape
    --invert     flip the signal (Tape polarity Inverted)
    --speed F    play the tape F times faster (pitch check)

A tape loads in the core if every file prints "ok". Used for the corpus
statistics in docs/CASSETTE_STATUS.md; nothing here runs in the core.
"""
import struct
import sys

F14M = 14697802.0             # rtl/pll: outclk_2


def wav_levels(path, invert=False):
    data = open(path, 'rb').read()
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise ValueError('not a WAV')
    p, fmt, pcm = 12, None, None
    while p + 8 <= len(data):
        cid, ln = data[p:p + 4], struct.unpack('<I', data[p + 4:p + 8])[0]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', data[p + 8:p + 24])
        elif cid == b'data':
            pcm = data[p + 8:p + 8 + ln]
            break
        p += 8 + ln + (ln & 1)
    tag, ch, rate, _, _, bits = fmt
    step = ch * bits // 8
    out = bytearray(len(pcm) // step)
    for i in range(len(out)):
        o = i * step
        if tag == 3:
            v = struct.unpack('<f', pcm[o:o + 4])[0] > 0.04
        elif bits == 16:
            v = struct.unpack('<h', pcm[o:o + 2])[0] > 1310
        else:
            v = pcm[o] > 133
        out[i] = v ^ invert
    return out, rate


def cas_levels(path, invert=False):
    # MAME vt_cas.cpp vtech2: 1 s silence, bits MSB first, 1 = HHHLLL x3,
    # 0 = HHHLLL HHHHHH LLLLLL; 36 low samples after the first 00h byte
    b1 = [1, 1, 1, 0, 0, 0] * 3
    b0 = [1, 1, 1, 0, 0, 0] + [1] * 6 + [0] * 6
    out = [0] * 10800
    nul = False
    for c in open(path, 'rb').read():
        for k in range(7, -1, -1):
            out += b1 if (c >> k) & 1 else b0
        if c == 0 and not nul:
            nul = True
            out += [0] * 36
    out += [0] * 10800
    return bytearray(v ^ invert for v in out), 10800


class Rom:
    """The ROM's tape loops on a level stream. Time in F14M clocks, with
    each instruction's length measured in the core (verilator --m1-trace:
    4 clocks per T-state plus one 4-clock wait beat per memory cycle) and
    the tape read at the clock the core's CPU reads it."""

    def __init__(self, lv, rate, speed=1.0):
        self.lv, self.k = lv, rate * speed / F14M    # samples per clock
        self.t = 0.0

    def rd(self, at):  # bit 7 of 6800h, read `at` clocks from now
        self.t += at
        i = int(self.t * self.k)
        if i >= len(self.lv):
            raise EOFError
        return self.lv[i]

    def bit(self, at_18c4=False):
        """18A6h: 1, 0, or None (timeout, carry set). at_18c4: enter at
        18C4h as the leader sync does (183Fh), at the current level, without
        waiting for an edge."""
        LOOP = 56 + 36 + 20 + 20 + 52 + 52 + 20 + 56   # 18ADh-18B6h, 312 clocks
        t_out = self.t + 0x5DC * LOOP
        if not at_18c4:
            self.t += 52 + 52                           # 18A6h ld hl, 18A9h ld bc
            a = self.rd(20)                             # 18ACh ld a,(hl)
            self.t += 16
        first = at_18c4
        while True:
            while not first:
                b = self.rd(56 + 20)                    # push bc; ld b,(hl)
                self.t += LOOP - 76
                if a != b:
                    break
                if self.t > t_out:
                    return None
            if not first:
                # jp m taken (18B2h): 18BCh, 18C0h: low twice, else back to 18ADh
                if self.rd(40) or self.rd(20 + 36 + 40):
                    self.t += 20
                    a = 1
                    continue
                self.t += 20 + 36
            first = False
            # 18C4h: ld b,45h; djnz x68; then 18C8h: still low = a long half
            self.t += 36 + 68 * 60 + 40
            if not self.rd(40):
                self.t += 20 + 36
                while not self.rd(40):                  # 18CCh: wait for high
                    self.t += 20 + 36
                self.t += 20 + 56 + 52                  # jr 18A9h, ld bc
                t_out = self.t + 0x5DC * LOOP
                a = self.rd(20)
                self.t += 16
                continue
            self.t += 20 + 56                           # 18CAh jr nz taken
            # 18D2h: ld b,5Ch; ld a,FFh; count falling edges
            self.t += 36 + 36
            n, a = 92, 0xFF
            low = False
            while n:
                if not low:
                    v = self.rd(40)                     # 18D6h bit 7,(hl)
                    self.t += 20
                    if v:
                        self.t += 36 + 60               # jr z; djnz
                        n -= 1
                        continue
                    # 18E2h, 18E6h: low twice, else count on as high
                    self.t += 56
                    if self.rd(40):
                        self.t += 20 + 56 + 60
                        n -= 1
                        continue
                    self.t += 20 + 36
                    if self.rd(40):
                        self.t += 20 + 56 + 60
                        n -= 1
                        continue
                    self.t += 20 + 36 + 20              # inc a
                    a = (a + 1) & 0xFF
                    low = True
                v = self.rd(40)                         # 18EBh bit 7,(hl)
                self.t += 20
                if v:
                    self.t += 56 + 60                   # jr nz 18DAh; djnz
                    low = False
                else:
                    self.t += 36 + 60                   # djnz 18EBh
                n -= 1
            self.t += 20 + 40 + 20 + 20 + 52            # rra, rl d, ld a,d, or a, ret
            return a & 1

    def byte(self):  # RDBYET 1865h, called from the block loop 179Ch
        self.t += 600
        d = 0
        for _ in range(8):
            b = self.bit()
            if b is None:
                return None
            d = ((d << 1) | b) & 0xFF
            self.t += 52 * 3 + 36 + 60 + 88 + 56 + 56 + 88   # back to 18A6h
        self.t += 900
        return d

    def sync(self):
        """182Dh: wait for a low level, read a bit from there (183Fh calls
        18C4h), repeat until a 1; then 7 more bits must make 80h (else start
        over); skip the 80h bytes and return the first other byte."""
        while True:
            while self.rd(1530):                         # 1832h: key check (16EAh), ld a,(6800h)
                pass
            while True:
                self.t += 56 + 52 + 88                   # 183Fh push hl, ld hl, call 18C4h
                b = self.bit(at_18c4=True)
                self.t += 52 + 40 + 36                   # pop hl, bit 0,a, jr z
                if b is None:
                    break
                if b == 1:
                    break
            if b is None:
                continue
            d, ok = 1, True
            for _ in range(7):                           # 184Bh: 189Eh x7
                self.t += 36 + 88
                b = self.bit()
                if b is None:
                    ok = False
                    break
                d = ((d << 1) | b) & 0xFF
            if not ok or d != 0x80:
                continue
            while True:
                c = self.byte()
                if c is None:
                    break
                if c != 0x80:
                    return c

def decode(lv, rate, speed=1.0):
    r = Rom(lv, rate, speed)
    files = []
    try:
        while True:
            # header 17C2h: FE x5, type, name (00h ends it)
            c = r.sync()
            if c != 0xFE:
                continue
            ok = True
            for _ in range(4):
                if r.byte() != 0xFE:
                    ok = False
                    break
            if not ok:
                continue
            ftype = r.byte()
            name = bytearray()
            while True:
                c = r.byte()
                if c is None or c == 0 or len(name) > 18:
                    break
                name.append(c)
            # the ROM prints "LOADING B:NAME" and compares the name: measured
            # 12.4 ms for a 5-letter name (sim, 17EDh to 19BCh), ~1.2 ms a letter
            r.t += (6.4e-3 + 1.2e-3 * len(name)) * F14M
            # block 19BCh: FFh, start, end, data, checksum
            if r.sync() != 0xFF:
                files.append((ftype, bytes(name), None, None, 'no data block'))
                continue
            hdr = [r.byte() for _ in range(4)]
            if None in hdr:
                files.append((ftype, bytes(name), None, None, 'cut in block header'))
                break
            start, end = hdr[0] | hdr[1] << 8, hdr[2] | hdr[3] << 8
            ck = sum(hdr) & 0xFFFF
            bad = None
            for i in range((end - start) & 0xFFFF):
                c = r.byte()
                if c is None:
                    bad = 'cut at byte %d' % i
                    break
                ck = (ck + c) & 0xFFFF
            if bad is None:
                lo, hi = r.byte(), r.byte()
                bad = 'ok' if lo == ck & 0xFF and hi == ck >> 8 else 'checksum'
            files.append((ftype, bytes(name), start, end, bad))
    except EOFError:
        pass
    return files


def main(argv):
    inv = '--invert' in argv
    speed = 1.0
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == '--speed':
            speed = float(argv[i + 1])
            i += 2
            continue
        if argv[i] != '--invert':
            args.append(argv[i])
        i += 1
    for path in args:
        try:
            lv, rate = (cas_levels if path.lower().endswith('.cas') else wav_levels)(path, inv)
        except Exception as e:  # noqa: BLE001 - report and go on
            print('%s: %s' % (path, e))
            continue
        files = decode(lv, rate, speed)
        if not files:
            print('%s: nothing decoded' % path)
        for t, n, s, e, st in files:
            print('%s: type %02X "%s" %s %s' % (
                path, t if t is not None else 0, n.decode('latin-1'),
                '%04X-%04X' % (s, e) if s is not None else '-', st))


if __name__ == '__main__':
    main(sys.argv[1:])
