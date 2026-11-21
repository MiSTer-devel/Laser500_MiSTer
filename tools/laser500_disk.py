#!/usr/bin/env python3
# Laser 500/700 disk image tool (reference model for rtl/laser500_floppy.sv).
#
#   laser500_disk.py dsk2nic IN.dsk OUT.nic [--volume N]
#   laser500_disk.py nic2dsk IN.nic OUT.dsk
#   laser500_disk.py check IN.nic          decode every sector, report errors
#
# .dsk: 40 tracks x 16 sectors x 256 bytes, offset (track*16 + physical sector)*256.
# .nic: 8192 nibble bytes per track. dsk2nic writes "layout A" (docs/DISK.md 5.2):
# sector k in bytes k*512 .. k*512+511 of the track:
#   FF x8, D5 AA 96, 4&4 vol trk sec cks, DE AA, FF x8, D5 AA AD,
#   343 nibbles (6-and-2), DE AA, FF up to the end of the 512 bytes.
# Plain ASCII, no dependencies.

import sys

GCR = [
    0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6, 0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
    0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
    0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
    0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
]
INV = {n: i for i, n in enumerate(GCR)}
TRACK = 8192
NTRK = 40


def rev2(x):
    return ((x & 1) << 1) | ((x >> 1) & 1)


def encode62(data):
    """256 bytes -> 343 disk nibbles."""
    assert len(data) == 256
    s = []
    for i in range(86):
        v = rev2(data[i] & 3) | (rev2(data[i + 86] & 3) << 2)
        if i + 172 < 256:
            v |= rev2(data[i + 172] & 3) << 4
        s.append(v)
    s += [b >> 2 for b in data]
    out, prev = [], 0
    for v in s:
        out.append(GCR[v ^ prev])
        prev = v
    out.append(GCR[prev])
    return bytes(out)


def decode62(nib):
    """343 nibbles -> 256 bytes, or None on a bad code / checksum."""
    s, c = [], 0
    for n in nib[:342]:
        if n not in INV:
            return None
        c ^= INV[n]
        s.append(c)
    if nib[342] not in INV or INV[nib[342]] != c:
        return None
    aux, six = s[:86], s[86:]
    out = []
    for i in range(256):
        a = (aux[i % 86] >> (2 * (i // 86))) & 3
        out.append((six[i] << 2) | rev2(a))
    return bytes(out)


def enc44(x):
    return bytes([((x >> 1) | 0xAA) & 0xFF, (x | 0xAA) & 0xFF])


def dec44(a, b):
    return ((a << 1) | 1) & b & 0xFF


def nibblize_track(sectors, trk, vol=0):
    """sectors: list of 16 x 256 bytes (physical order) -> 8192 bytes."""
    t = bytearray()
    for k in range(16):
        blk = bytearray(b"\xFF" * 8)
        blk += b"\xD5\xAA\x96" + enc44(vol) + enc44(trk) + enc44(k) + enc44(vol ^ trk ^ k) + b"\xDE\xAA"
        blk += b"\xFF" * 8
        blk += b"\xD5\xAA\xAD" + encode62(sectors[k]) + b"\xDE\xAA"
        blk += b"\xFF" * (512 - len(blk))
        assert len(blk) == 512
        t += blk
    return bytes(t)


def denibblize_track(track, trk_expected=None):
    """8192 circular bytes -> {sector: 256 bytes}; errors list."""
    t = track + track[:600]  # wrap
    found, errs = {}, []
    i = 0
    while i < TRACK:
        if t[i] == 0xD5 and t[i + 1] == 0xAA and t[i + 2] == 0x96:
            vol, trk, sec, cks = (dec44(t[i + 3 + 2 * j], t[i + 4 + 2 * j]) for j in range(4))
            if vol ^ trk ^ sec ^ cks:
                errs.append("addr cks at %d" % i)
            elif trk_expected is not None and trk != trk_expected:
                errs.append("track %d at %d" % (trk, i))
            else:
                for j in range(i + 14, i + 60):
                    if t[j] == 0xD5 and t[j + 1] == 0xAA and t[j + 2] == 0xAD:
                        d = decode62(t[j + 3:j + 3 + 343])
                        if d is None:
                            errs.append("data cks sec %d" % sec)
                        else:
                            found[sec] = d
                        break
                else:
                    errs.append("no data field sec %d" % sec)
            i += 14
        else:
            i += 1
    return found, errs


def main(argv):
    if len(argv) < 3:
        print(__doc__ if __doc__ else "see source", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "dsk2nic":
        vol = 0
        if "--volume" in argv:
            vol = int(argv[argv.index("--volume") + 1], 0)
        d = open(argv[2], "rb").read()
        if len(d) != NTRK * 16 * 256:
            print("expected %d bytes" % (NTRK * 4096), file=sys.stderr)
            return 1
        out = bytearray()
        for trk in range(NTRK):
            secs = [d[(trk * 16 + k) * 256:(trk * 16 + k + 1) * 256] for k in range(16)]
            out += nibblize_track(secs, trk, vol)
        open(argv[3], "wb").write(out)
    elif cmd in ("nic2dsk", "check"):
        d = open(argv[2], "rb").read()
        ntrk = len(d) // TRACK
        out = bytearray(b"\x00" * (NTRK * 4096))
        bad = 0
        for trk in range(min(ntrk, NTRK)):
            secs, errs = denibblize_track(d[trk * TRACK:(trk + 1) * TRACK], trk)
            for s, v in secs.items():
                out[(trk * 16 + s) * 256:(trk * 16 + s + 1) * 256] = v
            missing = [s for s in range(16) if s not in secs]
            if missing or errs:
                bad += 1
                print("track %d: missing %s %s" % (trk, missing, errs[:3]))
        print("%s: %d tracks, %d with problems" % (argv[2], ntrk, bad))
        if cmd == "nic2dsk":
            open(argv[3], "wb").write(out)
    else:
        print("unknown command", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
