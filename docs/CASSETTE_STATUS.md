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

52 tape images: TOSEC 2024 games (15 WAVs), CROSS-LIB (11), RobertK's games
(4 `.cas`, 4 WAVs, 3 `_MAME` WAVs), rcmolina's demo (`.cas`, `.wav`),
laser500emu's and Bonstra's test programs (11). All 8-bit or 16-bit mono,
44.1 kHz or 8 kHz.

`tools/laser500_tape.py` models the ROM reader in the core's T-states (one
per 4 F14M clocks, plus the wait beats: two per opcode fetch, one per other
memory cycle). It decodes **49 of 52**; the 3 failures are RobertK's `_MAME`
WAVs, recorded with 249 us halves (8% fast) because MAME's Laser runs too
fast: the author ships them for MAME only, and the core (sim, 1x) rejects
them as the model does. 48 files are F1 at 8995h, one is F0 (the demo).

Tolerance of the reader in the core's timing (model): tape speed -6% to
+6% (a +6% WAV fails, as the `_MAME` files show).

## Measurements (simulation, CRUN typed at frame 70, 50 frames/s)

| tape | length | 1x | 2x |
|---|---|---|---|
| demo.wav (BASIC) | 5 s | load 4.9 s, runs | 2.5 s |
| demo.cas | 5 s | | 2.9 s (incl. 1 s lead), runs |
| htron_laser500.cas | 116 s | | 57.9 s, LOADING B:HTRON, Ready |
| mm_laser500.wav | 128 s | | 63.7 s |
| Xtrex_laser500_keyboard.wav | 127 s | | 63.6 s |
| ROM_CRC.wav | 63 s | | 31.6 s |

No underflows in any run. Hardware (MiSTer, SD card): demo.cas and
htron_laser500.cas load at 2x.
