# Cassette status

How the tape works in this core and what was measured, against
`~/dev2/tape-standard.md`. Code: `rtl/laser500_tape.sv` (player),
`rtl/laser500.sv` (deck, turbo, hints), `rtl/VTL_chip.sv` (2x CPU beat),
`rtl/tape_overlay.sv` (status bar and hints). Decoder model:
`tools/laser500_tape.py`. Sim: `verilator/` (`--tape`, `--tape-check`).

## The machine

- **Input:** bit 7 of the mapped I/O read (6800h-6FFFh with I/O in bank 1),
  1 when the signal is above the comparator threshold (MAME
  `vtech2_m.cpp`, laser500emu `mapped_io.ts`). Output: latch bit 2.
- **Format** (ROM 27-0401-00-00.u6): 600 baud; a bit is one short cycle
  then either two more short cycles (1) or one long cycle (0); short half
  278 us, long half 556 us. File: 255 x 80h, 5 x FEh, type (F0 BASIC, F1
  machine code, F2 skipped), name, 00h; then 80h leader, FFh, start, end,
  data, 16-bit sum of start, end and data. MAME's `.cas` (`vt_cas.cpp`,
  vtech2) is this byte stream; the player turns it into samples at 10800
  per second.
- **Reader:** the bit loop at 18A6h waits for a falling edge (two low
  reads), waits about 0.30 ms and requires the level high again (a short
  half), then counts falling edges for about 1.07 ms: an odd count is 0, an
  even count is 1. All of it is timed by CPU loops; nothing else (no
  interrupt: the ROM runs the load with DI).
- **No motor relay**, no cartridge boot path, and loading starts from a
  typed command (`CLOAD`, `CRUN`).

## Decisions

| rule | here |
|---|---|
| 1 Tape speed | `2x` (default), `Normal`; Machine page, status bit 14, outside pending |
| 2 overlay / audio | Video: Tape overlay (bit 15); Audio: Tape audio (bit 16) |
| 3 Rewind | Machine page, bottom (bit 17) |
| 4 not remembered | `S2,WAVCAS,Tape;` |
| 5 rewound | every mount and Rewind start at sample 0; `I,Tape ready (rewound),Tape format not supported;` |
| 6 deck plays | no relay: the deck plays while the CPU fetches ROM code in 1714h-19DEh (CLOAD 1714h, CRUN 1958h, VERIFY 1962h, RDBYET 1865h, block header 19BCh), held 71 ms after the last fetch for the ROM's calls out (printing, bank switching). Advanced: Tape deck Play keeps it running for custom loaders, at 1x. |
| 7 timebase | CPU loops: the CPU and the tape both run 2x |
| 8 data | the samples are never changed. Advanced: Tape pitch sets only the rate: Wow (default, see below), Steady, +1.6%, -1.6% |
| 9 factor | T80pa needs a cen_p and a cen_n edge per T-state, so on the 14.7 MHz F14M the fastest CPU is F14M/2, twice the normal F14M/4 beat: **2x** is the largest clean factor. The CPU got its own RAM port (dpram port B) so its 2-clock beat never meets a video fetch; the wait beat per memory cycle (`skip_beat`) is kept, so every instruction takes exactly half the time. A 4x would need the CPU on the 29.4 MHz clock. |
| 10 underflow | one sample always prefetched, two 512-byte sector buffers; a late sample makes the tape wait and is counted (sim: `TAPE end ... underflows`) |
| 11-18 quick start | none: no boot path before the tape, loading is typed (other machines table) |
| 19-24 status bar | yes; F14M is both the tape's and the video's clock here, so the status needs no handoff. In the bottom border; with the 216p crop, at the bottom of the cropped picture, not doubled vertically there. |
| 25-28 hint | yes, see below |

### Hints

- At the start of a tape: `TYPE CRUN ↵`. The tape header says the file type
  (F0 BASIC, F1 machine code); CRUN loads and starts F0, and loads and jumps
  to F1. Every file the decoder finds in the corpus is F0 or F1.
- After a good load that the ROM did not start (it prints Ready: reads the
  string at 21A8h after passing 1766h, and not through RUN at 27B4h):
  `TYPE RUN ↵`. That covers CLOAD of BASIC and the z88dk / laser500-wav
  programs, which are F1 files loaded at 8995h, the BASIC program area: a
  BASIC line that calls the code, so the ROM's jump returns and the program
  needs RUN (MAME's software list says "CLOAD, start tape. RUN.").

## Corpus

52 tape images, 45 different: TOSEC 2024 games (15 WAVs), CROSS-LIB (11),
RobertK's games (4 `.cas`, 4 WAVs, 3 `_MAME` WAVs), rcmolina's demo
(`.cas`, `.wav`), laser500emu's and Bonstra's test programs (Bonstra's
`htron_laser500.wav` is a different recording from RobertK's). All 8-bit or
16-bit mono, 44.1 kHz or 8 kHz. 43 are F1 machine code at 8995h (3 of
them `_MAME`), the demo (`.cas`, `.wav`) is F0 BASIC.

The 3 `_MAME` WAVs are recorded with 249 us halves (8% fast) because MAME's
Laser runs too fast; the author ships them for MAME only, and the core
rejects them at the ROM's own tolerance (about +-6%), as it should.

## Leader sync and Wow

Every WAV here has the same data-block waveform (272/567 us halves, a
4.2 ms gap after the header, a 10-byte 80h leader, as CSAVE writes). The ROM
prints `LOADING B:NAME`, then looks for the leader (182Dh): it waits for a
low level, reads one bit from there with no edge sync (183Fh calls 18C4h),
and needs a 1 followed by seven 0s; on anything else it starts over. A try
costs about a byte, so the 10-byte leader gives it about 8 tries. A try
that starts mid-bit misreads, and the next try starts at the same place in
the next byte: at an exact rate the tries repeat one pattern, so a tape
either always locks or never does. Traced in the core (`--m1-trace`) on
RobertK's `htron_laser500.wav`: 8 tries, each reading `C0h` or `81h`, then
the data, then `LOADING ERROR`. The same happens at 1x. The decoder model
(`tools/laser500_tape.py`) follows the core within a sample per step, but a
sample decides the pattern, so it cannot predict which tapes fail (it
decodes every tape but the `_MAME` ones).

A real deck's speed wanders (wow and flutter), so each try lands somewhere
new. Tape pitch **Wow** (default) does the same with the rate only: every
2^18 F14M clocks (18 ms) the rate becomes a new pseudo-random value within
+-1/64 (16-bit LFSR, running from power-on, so on hardware every load is
different). The ROM's bit reader takes +-6%, so the data is unaffected.

Sync trials (sim, `--stop-on-load`: the ROM reaches 1766h or 18F3h; 8 tapes
x 12 different CRUN times, which give 12 different wobble phases):

| rate | locks |
|---|---|
| Steady (4 CRUN times) | 12/32: 5 of the 8 tapes never |
| new rate every 2^17 clocks, +-1/128 | 81/96 |
| 2^15, +-1/128 | 77/96 |
| 2^16, +-1/64 | 87/96 |
| **2^18, +-1/64** | 90/96, and 86/96 at 12 other times |
| 2^19, +-1/64 | 82/96 |
| 2^20, +-1/64 | 83/96 |
| 2^18 / 2^19, +-1/32 | 83/96 each |

Nearly all misses are Bonstra's `htron_laser500.wav`: about half its tries
lock under any setting. Leave that one out and 2^18 +-1/64 locks in 174 of
176 tries.

## Corpus sweep (sim, CRUN at frame 70, Tape speed 2x)

RUN hint means the ROM loaded the file (1766h) and printed Ready.

| Tape pitch | F1 tapes loaded first time |
|---|---|
| Steady | 20 of 40 (all 15 TOSEC WAVs, both htron WAVs, `epb_laser500.wav`, `testj.wav`, `disk_dumper.wav` fail every time, at 1x too) |
| Wow | 39 of 40: Bonstra's `htron_laser500.wav` missed (it loads about half the time; Rewind and `CRUN` again) |

The 40 are the F1 tapes without the 3 `_MAME` files, which fail at both
rates, as they should. The demo (F0) loads and runs at both.
+1.6% and -1.6% rescue some tapes and lose others, so they are only a manual
trim.

## Measurements (simulation, CRUN typed at frame 70, 50 frames/s)

| tape | length | 1x | 2x |
|---|---|---|---|
| demo.wav (BASIC) | 5 s | load 4.9 s, runs | 2.5 s |
| demo.cas | 5 s | | 2.9 s (incl. 1 s lead), runs |
| htron_laser500.cas | 116 s | | 57.9 s, LOADING B:HTRON, Ready |
| mm_laser500.wav | 128 s | | 63.7 s |
| Xtrex_laser500_keyboard.wav | 127 s | | 63.6 s |
| ROM_CRC.wav | 63 s | | 31.6 s |

No underflows in any run; `--tape-check` finds 0 mismatches over 8.58M
played samples.

Hardware (MiSTer, SD card, 2x): demo.cas and htron_laser500.cas load, and
H-Tron runs after `TYPE RUN`. Before Wow, Cross Chase (2021) failed every
time at the exact rate and loaded at +1.6%. With Wow (default), four WAVs
that never load at Steady each loaded first time: Cross Chase (2021),
Stinger (runs to its title after `RUN`), RobertK's `htron_laser500.wav` and
`testj.wav`.
