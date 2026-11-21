# Laser 500/700 floppy interface and disk format

This is a spec for building the MiSTer FDC (SystemVerilog) for the VTech Laser 700
built-in disk interface and the Laser 350/500 add-on.

Tags: **(V)** means checked against the source code or a disk image (file:line is
given). **(I)** means inferred. Paths are relative to the repo root. `floppy.ts` is
`refs/laser500emu/src/floppy.ts`, nippur72's working emulator and the behavioural
reference. "Bonstra-FDC" is
`git -C refs/Bonstra_laser500emu show origin/experimental-accurate-fdc:floppy.js`,
a second, bit-level, read-only model.

All image findings come from scratch Python scripts (`python3 -I`). Those scripts
decoded every `.nic` image under `refs/laser500emu/software/` and the 7 `.dsk`
images in `software/mister11/`.

---

## 0. Summary of key numbers

| item | value | tag |
|---|---|---|
| I/O ports | 0x10 latch1 (W), 0x11 latch2 (W), 0x12 status (R), 0x13 data (R/W) | V |
| Encoding | Apple Disk II style GCR: 4-and-4 address field, 6-and-2 data field (342 nibbles + 1 checksum) | V |
| Geometry | 40 tracks, 16 sectors, 256 bytes, 1 side (VT-DOS 1.1 can also use 2 sides) | V |
| Bit cell / byte | 4 us/bit, 32 us per 8-bit nibble, 40 us per 10-bit self-sync FF | I (Bonstra-FDC:14-18) |
| CPU clock in laser500emu | F14M*944/950/4 = 3,671,348 Hz, so 32 us = 117.5 T-states | V `emulator.ts:206-207` |
| floppy.ts timing | none: status is always ready, and each 0x13 access moves on one byte | V `floppy.ts:165,281,295` |
| .nic | 8192 bytes per track (raw byte nibbles, no bit stream), track t at `t*8192`, side 1 at `+327680` | V |
| Physical order on track | sectors 0..15 in sequence, no physical interleave | V (images) |
| VT-DOS logical->physical | `phys = (3*L) mod 16` (soft skew) | V |
| CP/M logical->physical (boot) | `0,2,4,..,14,1,3,..,15` | V |
| .dsk (163840) | offset = `(track*16 + physical_sector)*256`, where physical_sector is the number in the address field | V (`4_s0.dsk` matches decoded `vt-dos.nic` on 640/640 sectors) |
| Boot | ROM checks loopback of 0xAA/0x40 on port 0x13, recalibrates, reads T0 S0 (physical) to 0xA200, jumps to 0xA200 | V |

---

## 1. Registers

### 1.1 Port map and decoding

| port | dir | function | tag |
|---|---|---|---|
| 0x10 | W | Latch 1: side, /WREQ, drive select, enable, phases 0-3 | V `floppy.ts:59-80`, `refs/Bonstra_laser500-doc/floppy.txt:22-39` |
| 0x11 | W | Latch 2: "self-sync" / "data write mode" (see 1.3) | V `floppy.ts:114-122` |
| 0x12 | R | Status: bit7 ready/empty, bit0 write protect | V `floppy.ts:147-170` |
| 0x13 | R | Data read latch | V `floppy.ts:172-182` |
| 0x13 | W | Data write latch | V `floppy.ts:124-145` |

- laser500emu decodes 0x10-0x14 (`refs/laser500emu/src/bus.ts:96-98`, writes at
  `bus.ts:163-169`). Port 0x14 does nothing: it reads 0x00 and ignores writes
  (`floppy.ts:41-43,53-55`). (V)
- Reads of 0x10 and 0x11 return 0x00 in floppy.ts (default case, `floppy.ts:41-43`)
  and in Bonstra-FDC (`floppy.js:659-662`). (V)
- 0x15-0x1F are not decoded in laser500emu. An unused port reads `port|1`
  (`bus.ts:105`, "value returned from unused ports on a real Laser 500"). (V)
- MAME maps 0x10-0x1F to its FDC (`refs/mame/src/mame/vtech/vtech2.cpp:98`), but
  that model is the VZ200/300 controller, not this one (`vtech2_m.cpp:12-13`). (V)
- Whether the real hardware mirrors 0x10-0x13 across 0x10-0x1F is unknown. VT-DOS,
  the ROM and the CP/M boot only use 0x10-0x13 (V, by grep). Recommendation: decode
  only 0x10-0x13 and return 0x00 for 0x14 (I).
- If the FDC is absent (core option), port 0x13 must **not** loop back. Return
  `port|1` = 0x13 as other unused ports do (`bus.ts:105`). Then the ROM skips the
  disk boot (section 8). (V)

### 1.2 Port 0x10, latch 1 (write only)

| bit | name | meaning | tag |
|---|---|---|---|
| 7 | SIDE | 0 = side 0, 1 = side 1 | V `floppy.ts:61,76` |
| 6 | /WREQ | 0 = write, 1 = read | V `floppy.ts:62,77` |
| 5 | DRVSEL | 0 = drive 1, 1 = drive 2 | V `floppy.ts:63,78` |
| 4 | ENBL | 1 = enable the selected drive (/ENBL1 or /ENBL2, motor on) | V `floppy.ts:64-65,79`, Bonstra doc `floppy.txt:31-34` |
| 3-0 | PH3..PH0 | stepper phases, one bit each, 1 = coil energised | V `floppy.ts:66-80` |

Side effects in floppy.ts:
- Steps the head when the phase pattern changes (section 2). (V)
- Reads and writes of 0x13 only touch the disk while ENBL=1. Reads need /WREQ=1
  and writes need /WREQ=0 (`floppy.ts:278,292`). (V)
- floppy.ts keeps 0x11 but nothing uses it (`floppy.ts:121`; `FDC_BITS` is never
  read). (V)

Bonstra-FDC (`floppy.js:618-652,686-732`): ENBL=1 with /WREQ=1 moves it from IDLE
to READ, which clears `read_counter` and `fifo_ready`. ENBL=0 moves it back to IDLE
and deselects both drives. Phases are only applied while the state is not IDLE,
that is while enabled. (V)

Software usage (V):
- The ROM keeps a shadow of 0x10 at 0x8612. VT-DOS keeps one at `IY+0x43` (IY =
  0xFE60), see `refs/laser500emu/docs/rom.disassembly.txt:16458-16473` and
  `DOS.5E00.ASM:4085-4098`.
- Typical values: 0x40 = read mode with the drive off, 0x50 = read with drive 1 on,
  0x10 = write with drive 1 on (ROM 0x6930-0x693B and 0x6B1A; DOS 0x7BBC and 0x7950).
- VT-DOS picks the drive with `(iy+0x0b)`: 0x40 means drive 1, anything else means
  drive 2 (bit 5 set) (`DOS.5E00.ASM:3723-3732`).
- VT-DOS 1.1 sets bit 7 for logical tracks 40-79
  (`refs/laser500emu/docs/DOS1.1_5E00.v3.txt`, at RAM:79D4-79E2).

### 1.3 Port 0x11, latch 2 (write only)

- laser500emu doc: 0xFF turns self-sync on and 0xD5 turns it off
  (`refs/laser500emu/docs/floppy.txt:41-45`). Bonstra doc: bit 0 selects the data
  write mode, 0 = 8 bit and 1 = 16 bit (`refs/Bonstra_laser500-doc/floppy.txt:41-45`).
  The Italian notes say "DATA SIZE ... 8 or 16 bit, does not seem to be used"
  (`floppy_310_vs_500.txt:38-41`). (V, as statements)
- What software actually does (V): VT-DOS writes to 0x11 only right after
  `WRITE_DISK_BYTE_D` (0x7864: wait for empty, `ld a,d`, `out (13h),a`). So the
  value written to 0x11 is always the byte that was just queued: 0xFF after a sync
  FF, 0xD5 after the D5 prologue byte (`DOS.5E00.ASM:1316-1323,1349-1357,1385-1389,3628-3633,3755-3766`).
  The ROM never writes 0x11; the hit at 0x1DB7 is a string mis-disassembled as code
  (`rom.disassembly.txt:4713`).
- 0xFF and 0xD5 both have bit 0 set, so "bit 0 = 16-bit" cannot be the switch the
  DOS toggles. The two values differ in bits 1, 3 and 5. (I)
- Model that fits the DOS write sequences (I): the mode is sampled when a byte moves
  from the buffer into the shift register. Sync on gives the 8 data bits plus 2
  zero bits (10-bit self-sync); sync off gives 8 bits. Under this model every FF in
  the gaps comes out as 10 bits and every mark or data byte as 8 bits. The DOS 1.1
  commenter assumes self-sync is on by default once /WREQ is asserted
  (`DOS1.1_5E00.v3.txt:1651,4977`), which the first gap bytes of a track or sector
  write depend on.
- **For a byte-level (.nic) FPGA model, port 0x11 can be a write-only register with
  no effect**, exactly as in floppy.ts (V). An FF stored in the track buffer is
  simply played back as an FF.

### 1.4 Port 0x12, status (read only)

| bit | meaning | tag |
|---|---|---|
| 7 | Read mode: 1 = data byte ready. Write mode: 1 = buffer empty, ready for the next byte | V `floppy.ts:150-154`, Bonstra doc `floppy.txt:47-53` |
| 6-1 | reserved; 0 in floppy.ts and in Bonstra-FDC | V `floppy.ts:167`, `floppy.js:656-674` |
| 0 | 1 = write protected (WPROT input of the selected drive) | V `floppy.ts:155-157,166-167` |

- floppy.ts: bit 7 is **always 1** (`floppy.ts:165`). When no drive has been
  selected yet (`FDC_DRIVE === -1`) it returns 0x13 (`floppy.ts:161-163`, "@Bonstra
  test"). `FDC_reset()` is never called (it is only defined at `floppy.ts:21`), so
  in practice this branch never runs. (V)
- Bonstra-FDC: bit 7 is the `fifo_ready` flag. Bit 0 is 1 by default and drops to 0
  only if enabled and the selected drive is not protected (`floppy.js:663-674`). (V)
- How software reads it (V):
  - Read wait: `in a,(12h); rlca; jr nc` (ROM 0x6A93 `rom.disassembly.txt:16379-16384`,
    DOS 0x784A `DOS.5E00.ASM:3611-3614`) or `in; or a; jp p` (DOS 0x7A13).
  - Write wait: `in; or a; jp p` (DOS 0x7978-0x79A4).
  - Write-protect test: `in a,(12h); rrca; jp c,error 4` (DOS 0x6835, 0x7935,
    0x7BEB).
  - None of these polls has a timeout, so a status that never becomes ready hangs
    the CPU. That is safe for SD-card latency and fatal with no disk (section 8).

### 1.5 Port 0x13, data (read/write)

- There is a single data latch. Writing 0x13 always loads it (`floppy.ts:131`).
  Reading 0x13 with ENBL=0, or in write mode, returns the last value written
  (`floppy.ts:179-181`, `read_byte` does nothing then). This loopback is what the ROM
  presence test uses (section 8). (V)
- Read mode with ENBL=1: the read returns `track[pos]` and moves `pos` on by one
  (`floppy.ts:278-282`). (V)
- Write mode with ENBL=1 and not protected: the write stores the latch at `pos` and
  moves `pos` on by one (`floppy.ts:292-296`). (V)
- Does reading 0x13 clear data-ready? In floppy.ts there is no flag. In Bonstra-FDC,
  yes: a read in READ state sets `fifo_ready=false` (`floppy.js:675-680`). Software
  needs this: every read loop does one status poll followed by one data read, so
  without the clear, real-time hardware would hand over each byte twice. **The FPGA
  must clear ready on a 0x13 read.** (I, required)
- Does writing 0x13 clear buffer-empty? In Bonstra-FDC, yes in WRITE state
  (`floppy.js:724-729`). The DOS write loops wait for bit 7 before each write. **The
  FPGA must clear empty on a 0x13 write and set it again when the byte is taken.** (I)
- With ENBL=0 or no drive, Bonstra's hardware test is quoted as IN(0x13)=0xFF and
  IN(0x12)=0x13 (`floppy.ts:162,178`, `refs/laser500emu/TODO.md:31`). This
  contradicts the ROM loopback test, which is run with 0x10=0x00, that is ENBL=0. It
  may be a "no interface" reading, because unused ports read `port|1` (0x12 gives
  0x13). Section 10 lists it as open.

### 1.6 Reset state

- floppy.ts `FDC_reset`: /WREQ=1, ENBL=0, PHASE=0, SIDE=0, DRIVE=-1, 0x11=0xFF,
  DATA=0 (`floppy.ts:21-29`). It is never called. Drive objects start with
  `track_x2=0` and `track_offset=0` (`floppy.ts:214-215`). (V)
- Recommendation for the FPGA (I):
  - latch1 = 0x40 (read mode, drives off, phases 0), latch2 = 0xFF, data latch = 0x00.
  - Head position is kept across CPU resets (it is mechanical) and set to track 0 at
    power-on or when an image is inserted.
  - The ROM always writes 0x10=0x00 first and recalibrates, so the reset values
    hardly matter (V, section 8).

---

## 2. Stepper

floppy.ts rule (`floppy.ts:95-111`, V):
- The new pattern must have exactly one phase on. If the previous latch value had
  the next-higher phase on, the head moves -1 half-track (outward). If it had the
  next-lower phase on, the head moves +1 half-track (inward). Phases wrap modulo 4.
- A pattern with two phases on never moves the head.
- The move applies to `drives[DRVSEL]` and only if ENBL=1 (`floppy.ts:299-303`).
- The "old phase" is the previous latch value, global to both drives.

| item | value | tag |
|---|---|---|
| Unit | half-track (`track_x2`); data track = `track_x2 >> 1`, so an odd half-track reads the lower track | V `floppy.ts:271,289` |
| Range | `track_x2` clamped to 0..79 (tracks 0..39); 0..81 (tracks 0..40) for 335872-byte (41-track) images | V `floppy.ts:224,233,302-303` |
| Track 0 | clamps at 0, no error (the mechanical stop) | V `floppy.ts:303` |
| Inward order | ph0->ph1->ph2->ph3->ph0, one phase change = +1 half-track | V |
| Outward order | ph0->ph3->ph2->ph1->ph0 | V |

ROM and DOS stepping (V):
- The ROM keeps a phase shadow at 0x8613 (initially 0x11, `rom.disassembly.txt:16185`).
- Step out (0x6AE2, `rom.disassembly.txt:16427-16448`): `rrca` the shadow, write
  old|new (two phases on), wait 0x73 loops, write new (one phase), wait 0x325 loops.
  That is one half-track. The count is doubled first (`sla b`), so one track = 2
  half-steps.
- Step in (0x6AB3, `:16403-16426`) does the same with `rlca`.
- The delay loop at 0x6AAD costs 26 T per iteration: 0x73 is about 0.81 ms and
  0x325 about 5.7 ms. Settle time after a seek is 0x0D7A (about 24 ms) after
  stepping out and 0x6BD (about 12 ms) after stepping in.
- VT-DOS does the same with shadow `IY+0x14` = 0x11 and delay units of about 1 ms
  (1 then 7) (`DOS.5E00.ASM:3664-3721`).
- Software clamps its track counters to 0..39 (ROM `cp 28h` at 0x6AB7, DOS 0x789B).
  The hardware does not clamp at 39; the 41-track CP/M disk needs track 40
  (section 5.4).
- Recalibrate: the ROM steps out 40 tracks (`ld b,28h` at 0x693E). DOS 1.0, after
  8000 bytes without an address mark, pretends it is on track 40 (0x7842) and seeks
  back, so the head bangs on the stop.

Bonstra-FDC (`floppy.js:376-448`, V):
- Head position runs 0..159 in quarter-track units. A one-phase position is even; a
  two-adjacent-phases position is odd (in between). Track = `(pos+2)>>2`, clamped to
  39.
- Phase changes only work if 1 or 2 phases are on. Movement follows the current
  phase `(pos>>1)&3`.
- Its arithmetic looks buggy (`ohs & 1 == 1`, `(p[cw]+1)&3` applied to booleans).
- Net movement for the ROM/DOS sequences is the same as floppy.ts (I).

**FPGA:** the floppy.ts rule is enough (V: it runs all images with VT-DOS 1.0/1.1
and CP/M in laser500emu). Keep `track_x2[drive]` 0..2*NTRK-1, with NTRK = 40, or 41
for 41-track images.

---

## 3. Read path timing

### 3.1 floppy.ts (behavioural reference)

- **No time base.** The floppy is never ticked: the only hooks are `FDC_io_read` and
  `FDC_io_write` from `bus.ts:98,168`, and `emulator.ts` only imports `drives`.
  Status bit 7 is constant 1. (V)
- Each 0x13 read (in read mode, ENBL=1) returns `floppy[track*8192 + side*FLOPPY_SIDE + track_offset]`
  and does `track_offset = (track_offset+1) % 8192` (`floppy.ts:276-281`). So one
  "revolution" is 8192 CPU accesses, whatever the time between them. (V)
- `track_offset` is per drive. It is shared by reads and writes and is not reset when
  the head steps, so rotation carries on across tracks (`floppy.ts:197,281,295,299-310`). (V)
- A late CPU read never loses data, there is no overrun, and motor-on has no spin-up
  delay. (V)
- Reading past the end of the image (`pos >= length`) returns 0xFF (`floppy.ts:280`). (V)
- CPU clock in the emulator: `cpuSpeed = 14778730*(944/950)/4` = 3,671,348 Hz
  (`emulator.ts:206-207`). The 944/950 factor accounts for 6 clocks lost per line in
  HSYNC. The nominal clock is 14.77873 MHz/4 = 3.6947 MHz (core:
  `rtl/VTL_chip.sv:204`, `Laser500.sv:168`). (V)

### 3.2 Real-time model (Bonstra-FDC; Disk II heritage)

- Constants: 300 rpm, 4 us per bit cell, 50000 cells and 6250 bytes per revolution
  (`floppy.js:14-18`). (V as model, I as hardware fact)
- Read: wait for the first 1 bit (`_syncRead`), shift in 7 more bits, then latch
  the byte into `fiforeg` and set `fifo_ready` (`floppy.js:515-562`). The 2 extra
  zero bits of a 10-bit sync byte are skipped automatically, which is what
  "self-sync" means. If the CPU reads late, the next byte overwrites the latch (no
  overrun flag) (`floppy.js:557-560`). (V)
- Timing check against the code (V, counted from the listings):
  - ROM data loop at 0x69BC: in 11 + rlca 4 + jr 7 + in 11 + ld 4 + ld 4 + xor 7 +
    ld 4 + ld 4/7 + inc 6 + djnz 13 = about 78 T.
  - DOS 1.0 read loop at 0x7A13: about 81 T. DOS write loop at 0x7984: about 80 T.
  - At 3.67 MHz, 32 us is 117.5 T, so there is about 35 T of margin. I/O wait states
    in the core (`rtl/VTL_chip.sv:316`) eat into it.
  - **Do not run faster than 32 us/byte**; 200 ms per 8192 bytes (24.4 us, 89.6 T)
    would be too tight. (I)

### 3.3 Motor and drive select

- floppy.ts: ENBL gates access; there is no spin-up and no motor timeout
  (`floppy.ts:278,292,300`). (V)
- Delays in software after motor on (V): ROM none beyond the seek; DOS about 2 ms
  (`7BBC: bc=2`) or about 20 ms before the WP check (`7BE0: bc=0x14`). Spin-up does
  not need modelling (I).
- Drive select: bit 5 picks `drives[0|1]` for reading, writing, stepping and WP
  (`floppy.ts:101,110,144,166,179`). (V)

---

## 4. Write path

- floppy.ts: a write to 0x13 with ENBL=1, /WREQ=0 and not protected stores the byte
  at `track_offset` and advances it (`floppy.ts:285-297`). Port 0x11 (8/16-bit or
  self-sync) is ignored; the byte is stored as is. Write protect is always 0 in
  floppy.ts (`floppy.ts:217`, no setter). (V)
- Bonstra-FDC: no write support (`floppy.js:599-601,632-634,716-721`). (V)
- What VT-DOS writes (V):
  - **Format a track** (DOS 1.0 0x6656-0x670B, `DOS.5E00.ASM:1310-1390`; DOS 1.1
    `DOS1.1_5E00.v3.txt:1640-1735`): /WREQ=0, then FF (out 13 directly) plus 127x FF,
    which is 128 FF in total. Then for each of the 16 sectors, numbered 0..15 in order:
    `D5 [out11] AA 96 44(vol) 44(trk) 44(sec) 44(vol^trk^sec) DE AA EB`, then
    `FF [out11=FF] FF FF FF FF` (5 FF), then `D5 [out11] AA AD`, then 343 nibbles,
    then `DE AA EB`. Between sectors come `FF [out11] + gap x FF`, with gap = 14 at
    first (`fe5b`), so 15 FF.
  - The formatted data is `E6, 84x96, B7, 256x96, F9`, which decodes to 256 x 0xE5
    (byte 85 is 0xE6) (V by decoding `vt-dos.nic` track 39).
  - After the format, the DOS verifies all 16 address fields. If one is missing it
    decrements the gap and reformats, down to a minimum of 5, after which it reports
    error 9 (`DOS.5E00.ASM:1398-1427`). Volume is `IY+0x7d` in DOS 1.0 and the
    DOUBLE_SIDED flag (0x00 or 0xAA) in 1.1 (`DOS1.1_5E00.v3.txt:1636-1637`).
  - **Write sector** (DOS 1.0 0x790A-0x79D4, `DOS.5E00.ASM:3723-3822`):
    1. Find the address field, read up to and including its `DE AA` (EB is not read).
    2. `djnz` 3 (about 40 T), /WREQ=0, then `FF` plus 4x FF, then `D5 [out11] AA AD`.
    3. 343 nibbles: GCR(buf[0]), then 341 x GCR(buf[i]^buf[i+1]), then GCR(buf[341]).
       Encode table at 0xFB00.
    4. `DE AA EB`, one more FF written **without waiting** for empty
       (`DOS.5E00.ASM:3812-3815`), wait for empty, /WREQ=1.
- Effect seen in the emulator-written image `vt-dos.nic` (V): on tracks the DOS
  rewrote, the address epilogue reads `DE AA FF` and the data D5 sits 18 bytes after
  the address D5 instead of 19. The write started at the EB byte, which shows writes
  are byte-continuous with the read position. In real time the splice lands 1-2
  bytes later (about 150 T between reading AA and the first FF) and stays inside the
  5-FF gap (I).
- Write protect: status bit 0. The DOS checks it before every write and format
  (error 4). floppy.ts also blocks the write (`floppy.ts:292`). (V)
- FPGA write model (I):
  - Each byte tick (32 us) in write mode with ENBL=1: if the buffer is full, store it
    at `pos`, mark it empty and set bit 7.
  - If the buffer is empty (underrun), store the old latch value again, as the Disk II
    does.
  - Set bit 7 (empty) as soon as /WREQ goes 0, because the DOS writes the first FF
    without polling.
  - On /WREQ 0->1, mark the track dirty.

---

## 5. .nic image format

### 5.1 Container (V `floppy.ts:186-255`)

| file size | layout |
|---|---|
| 327680 | 40 tracks x 8192 bytes, 1 side |
| 655360 | 2 sides: side 0 tracks 0-39 at `t*8192`, side 1 at `327680 + t*8192` |
| 335872 | 41 tracks x 8192 bytes, 1 side ("fd021_patched.nic (Chinese CP/M)", `floppy.ts:226-234`) |

- `pos = track*8192 + side*FLOPPY_SIDE + offset` (`floppy.ts:253-255`).
- Single-sided images are padded in memory with a side 1 of 0xFF. The side bit is
  ignored for them (`floppy.ts:236-250,276`).
- Blank disk: all 0xFF (`floppy.ts:192`).
- The bytes are **raw disk nibbles (MSB=1 bytes) as the CPU sees them at 0x13**. It
  is not a bit stream: 10-bit sync FFs are stored as plain FF bytes, and there is no
  index position and no timing.
- Byte n of a track is rotational position n of 8192. 8192 is larger than the
  roughly 6250 bytes a real revolution holds (I).
- On MiSTer, one .nic track is exactly 16 SD blocks of 512 bytes (I).

### 5.2 The two layouts found in real images (V, decoded)

**A. Chinese dumps** (`software/chinese_disks/fd0*.nic`; logic-analyzer captures
"decoded into NIC files" by a Python script, `chinese_disks/Readme.txt:7-10`). Every
track is 16 blocks of 512 bytes, and block k holds physical sector k:

| offset in block | bytes |
|---|---|
| 0-7 | FF x 8 |
| 8-10 | D5 AA 96 |
| 11-18 | 4&4 volume, track, sector, checksum |
| 19-20 | DE AA |
| 21-28 | FF x 8 (byte 21 sits where EB would be) |
| 29-31 | D5 AA AD |
| 32-374 | 343 data nibbles |
| 375-376 | DE AA |
| 377-511 | FF x 135 |

**B. Emulator-formatted** (`software/disks/vt-dos.nic`, VT-DOS 1.0 INIT under
floppy.ts): the format starts at an arbitrary `track_offset`. It writes 128 FF, then
16 sectors with a constant pitch of **383 bytes**, made of an address field (14),
5 FF, the data field (3+343+3) and 15 FF. That is 6241 bytes written; the other 1951
bytes stay 0xFF. Sector positions on track 0 run 145, 528, 911, ... (+383). Track 1
starts mid-format: sectors 6..15 at 137.. and 0..5 at 6031.., which is the
wrap-around.

### 5.3 Per-image results (V, script decode of all 16x40 address and data fields)

| image | tracks | volume | result |
|---|---|---|---|
| `disks/vt-dos.nic` | 40 | 0x00 | 640/640 sectors OK, layout B, VT-DOS 1.0 |
| `disks/vt-dos-11-dd.nic` | 80 (2 sides) | 0xAA | 1280 OK; the side-1 address track field is 0..39 (physical) |
| `disks/vt-dos-11.nic` | - | - | **broken**: the first ~170 KB is ASCII `defb` text; also `refs/laser500emu/TODO.md:36` |
| `fd005`, `fd010` (VT-DOS 1.1) | 40 | 0xAA | all OK, layout A |
| `fd004`, `fd007`-`fd018`, `fd020`-`fd022` (CP/M) | 40 | 0xCD | OK. 1-2 data checksum failures in fd004/007/020/022 (dump errors, I) |
| `fd019` (Logo / CCDOS) | 40 | 0x00 | all OK |
| `fd004_40tracks_dd.nic` | 80 | 0xCD | side 1 address fields are corrupt (track 0, sector = track index, bad checksum); not a usable DS reference |
| `fd021_patched.nic` | 41 | 0xCD | tracks 0-39 normal; track 40 has the **address prologue `AA D5 96`**, track field 0x28, sectors 0..15, valid checksums and normal `D5 AA AD` data (a key track) |

### 5.4 The 41-track special case

- floppy.ts selects 41 tracks by file size alone (335872) and lets the head reach
  track 40 (`floppy.ts:226-234`). (V)
- The Chinese CP/M disk reads track 40 with a non-standard prologue (V, image), so
  the FPGA needs NTRK=41 for 335872-byte images. A 2-sided 41-track image (671744
  bytes) is not handled by floppy.ts and was not seen. (V)

---

## 6. Logical format (VT-DOS, ROM; CP/M uses the same fields)

### 6.1 Address field (V: ROM 0x6A42-0x6A86, DOS 0x77D7-0x781C, images)

```
D5 AA 96  vv1 vv2  tt1 tt2  ss1 ss2  cc1 cc2  DE AA EB
4&4 encode: b1 = (x>>1)|0xAA ; b2 = x|0xAA
4&4 decode: x = ((b1<<1)|1) & b2      (ROM 0x6A9B, DOS 0x7852)
checksum  : cc = vol ^ trk ^ sec
```
- Track = physical cylinder 0..39 (40 on the key track); also 0..39 on side 1.
- Sector = physical number 0..15.
- Volume:
  - The ROM ignores it (`ld b,a` only, `rom.disassembly.txt:16344-16345`).
  - DOS 1.0 compares it with `IY+0x7d` (`DOS.5E00.ASM:3554,3564-3565`). Bonstra lists
    the IY+0x7d init value as 0x00 (`refs/Bonstra_laser500-doc/dos10-memory.txt:42`).
  - DOS 1.1 ignores it but copies it into DOUBLE_SIDED: 0x00 = single-sided, 0xAA =
    double-sided (`DOS1.1_5E00.v3.txt:4658,4679-4680,2178-2196`).
  - CP/M disks use 0xCD (V, images). The claim that CP/M rejects other volumes comes
    only from `refs/laser500emu/docs/floppy.txt:119-129` (I).
- Only `DE AA` is checked; nobody reads EB (V). Real dumps show FF in that slot
  (layout A).

### 6.2 Data field (V: ROM 0x699D-0x6A1C, DOS 0x79F5-0x7A6x, write 0x7975-0x79AC; image round-trip)

```
D5 AA AD  n[0..341]  n[342]=checksum  DE AA (EB)
```
- Pre-nibblize the 256 bytes b[] (Apple DOS 3.3 6-and-2):
  - `aux[i]` (i = 0..85) = `rev2(b[i]&3) | rev2(b[i+86]&3)<<2 | rev2(b[i+172]&3)<<4`.
    The third term only exists for i < 84. `rev2` swaps bit 0 and bit 1.
  - `six[i]` = `b[i]>>2`.
  - Stream: `s = aux[0..85] ++ six[0..255]` (342 six-bit values).
- On disk: `n[k] = GCR(s[k]^s[k-1])` with `s[-1]=0`, then `n[342] = GCR(s[341])`.
- Decode: `c=0; for k: c ^= INV[n[k]]; store c`. After all 343 nibbles, c must be 0.
  The ROM reads 256 + 87 nibbles into 0xA000 and rebuilds `byte = six<<2 | aux_bit0<<1 | aux_bit1`.
- GCR table (64 entries, 0x96..0xFF): the standard Apple 6-and-2 table
  (Bonstra-FDC `floppy.js:33-67`). The decode table is at ROM 0x6B2C, 0x6A bytes,
  indexed by nibble-0x96, copied to 0xA196 at boot (`rom.disassembly.txt:16189-16194,16476+`).
  DOS keeps its tables at 0xFB00 (encode) and 0xFB96 (decode).
- Checked: the script's encoder rebuilds the on-disk nibbles of `vt-dos.nic` T0 S0
  exactly, and every data checksum on the good images is 0.

### 6.3 Gaps, sectors, interleave

| item | value | tag |
|---|---|---|
| sectors/track, size | 16 x 256 | V |
| gap1 (track start) | 128 FF (format) | V `DOS.5E00.ASM:1310-1318` |
| gap2 (addr -> data) | 5 FF (format, 10-bit); 8 FF in layout A | V |
| gap3 (data -> next addr) | 15 FF at first, reduced down to 5 if the track doesn't fit | V `DOS.5E00.ASM:1385-1389,1422-1427` |
| physical order on track | 0,1,2,...,15 (format increments the sector number) | V `DOS.5E00.ASM:1386`, all images |
| VT-DOS soft skew | logical L -> physical `{0,3,6,9,12,15,2,5,8,11,14,1,4,7,10,13}[L]` = 3L mod 16 | V DOS 0x7C35 `DOS.5E00.ASM:4159-4174`, `BOOT.ASM:211-227`, DOS 1.1 0x7D28 |
| CP/M boot deinterleave | `{0,2,4,6,8,10,12,14,1,3,5,7,9,11,13,15}` | V `docs/cpm_boot/cpm_boot_commented.asm:111-114` |
| DOS 1.1 double-sided | logical track T >= 40 -> side 1, physical track 79-T | V `DOS1.1_5E00.v3.txt` RAM:79D1-79E2 |
| Bonstra .dsk converter | volume 0, gap3 14 and gap2 8 sync bytes (10-bit), **physical** interleave 3 (track order 0,6,11,1,7,12,2,8,13,3,9,14,4,10,15,5) | V `floppy.js:20-27,239-285`; contradicts real disks (section 10) |

Timeouts the layout must satisfy (V):
- ROM: no byte limit while hunting for D5. It only counts mismatched or bad address
  fields, 0x30 = 48 retries (`rom.disassembly.txt:16228-16232,16367-16371`). A
  missing sector number loops forever.
- DOS 1.0: 8000 (0x1F40) non-matching bytes between address marks before it
  recalibrates (0x779D-0x7847). The worst gap in a layout must stay well below that.
  8192-byte tracks with 16 sectors have gaps under 2000 bytes.

---

## 7. .dsk images (163840 bytes)

- **Verified:** `software/mister11/4_s0.dsk` equals the decoded `vt-dos.nic` on
  640/640 sectors when read as `offset = (track*16 + S)*256`, with S the
  **physical sector number in the address field**. Other orders score worse:
  VT-DOS-logical (3L mod 16) 610/640 and Apple DOS 3.3 order 614/640, both failing
  on tracks 0-2. (V)
  - `7_s0 !.dsk` matches `vt-dos.nic` on 634/640 under the same order.
  - `1_s0 !.dsk` and `3_s0 !.dsk` match `fd005.nic` (VT-DOS 1.1) on their system
    tracks 0-2 and 33-39. Every unique-sector match lands on the same physical
    index. (V)
- Five images (1, 2, 3, 4, 7) start with the VT-DOS boot sector `3E 06 D3 43 21 FF FF 7E ...`
  (BOOT.ASM:40-50). Images 5 and 6 start with zeros (data disks). (V)
- The .dsk stores no volume number. **Use volume 0x00** when nibblizing: the ROM
  ignores it, DOS 1.0 needs 0x00 and DOS 1.1 reads 0x00 as single-sided. Offer 0xCD
  as an option for CP/M .dsk images. (I)
- This is the same order Bonstra-FDC uses (`floppy.js:274-277`: the sector at
  `.dsk` offset `sect*256` gets address-field sector `sect`). (V)

---

## 8. Boot sequence (what must work first)

ROM cold start: after the cartridge scan (`refs/Bonstra_laser500-doc/boot.txt:1-13`),
the ROM calls DISK_CHECK at 0x6924 (`rom.disassembly.txt:15800`; raw `rom.raw.disassembly.txt:15983-15995`).

1. **Presence test** (IS_DRIVE_PRESENT 0x6975, `rom.disassembly.txt:16219-16226`;
   `refs/Bonstra_laser500-doc/boot.txt:15-21`):
   `out (10h),00h; out (13h),AAh; in a,(13h)`, which must equal 0xAA, then the same
   with 0x40. If either fails, it returns and BASIC starts. (V)
   - So the data latch must read back while ENBL=0 and /WREQ=0.
2. `out (10h),40h`, short `djnz` pause, phase shadow (0x8613)=0x11, motor on
   (0x10=0x50) (`:16180-16186`). (V)
3. Step out 40 tracks (80 half-steps, about 0.5 s) to recalibrate (`:16187-16188`). (V)
4. Copy the GCR decode table to 0xA196 and set the pointers: buffer (0x860B)=0xA200,
   secondary buffer (0x860D)=0xA000, track/sector (0x8608/9)=0/0 (`:16189-16198`). (V)
5. READSC (0x6980, also the ROM entry `0033: jp 6980h`, `rom.disassembly.txt:65`):
   - Seek to the track, find `D5 AA 96` with the right track and sector, then
     `DE AA`. Find `D5 AA AD`, read 343 nibbles, check the checksum, `DE AA`.
     Denibblize to 0xA200 (`:16228-16370`).
   - Motor off (0x6B21) and `jp 0A200h`. On failure it prints "DISK ERROR"
     (`:16199-16203`). (V)
6. The boot sector (BOOT.ASM) maps RAM page 6 into bank 3. It reads 34 logical
   sectors through READSC (logical L -> physical `3L mod 16`): track 0, track 1 and
   2 sectors of track 2, to 0xDE00-0xFFFF. Then it jumps to 0x5F2D with page 6 in
   bank 1 (`BOOT.ASM:57-137`). The CP/M boot reads 37 sectors from T0 S11 onward
   with the +2 deinterleave, to 0xC400 (`cpm_boot_commented.asm:27-109`). (V)

FPGA bring-up order: (a) the 0x13 loopback, (b) stepping with ENBL=1, (c) status
bit 7 plus a 0x13 read that clears ready, (d) the nibble stream of track 0.

**No-disk hazard:** with the FDC present but no valid address marks (blank FF disk
or no data), the ROM loops forever at 0x6A42-0x6A4D. laser500emu has the same
problem with its default empty drives (`floppy.ts:339-342`), and its fix is the
`nodisk` option (`refs/laser500emu/src/browser.ts:260-262`). (V by code reading)
- Recommendation: when no image is mounted at reset, make the interface absent, so
  0x13 does not loop back. An OSD option can force on or off. (I)

---

## 9. FPGA implementation notes

Minimum state (per controller):
- latch1[7:0], the data latch[7:0], the ready/empty flag, and latch2[7:0]
  (write-only, no effect).
- `wr_full` (a byte waiting), and a byte-tick divider (32 us). From F14M = 14.77873
  MHz that is 472.92 clocks; use a fractional accumulator or 473.
- Per drive: `track_x2[6:0]`, `mounted`, `wp`, `ntrk` (40/41), `sides` (1/2),
  `dirty`, and the rotational position `pos[12:0]` (one counter can be shared, like
  `track_offset`).
- Per drive: an **8 KB nibble track buffer** (BRAM; 2 x 8 KB, or 1 x 8 KB that is
  reloaded when the drive changes).

Read (per byte tick while ENBL=1, the drive is mounted and the buffer is loaded):
- In read mode: `latch <= buf[pos]; ready <= 1`.
- `pos <= (pos+1) mod 8192`. If the image has a shorter track length, use that.
- A 0x13 read returns the latch and clears ready. A 0x12 read returns
  `{ready, 6'b0, wp}`.
- While a track is loading from SD, hold ready=0. Every software poll waits
  forever, so stalling is safe (V, section 1.4).
- Optional "floppy.ts mode": ready is always 1 and each 0x13 access moves `pos` on.
  It is known to run all the software in laser500emu, and it is a useful fallback
  if real-time timing turns out marginal.

Write (per byte tick while ENBL=1 and /WREQ=0 and not wp):
- `buf[pos] <= wr_full ? latch : latch` (underrun repeats the latch), then
  `wr_full <= 0`, `empty <= 1`, `pos++`, `dirty <= 1`.
- A 0x13 write: `latch <= d`, `wr_full <= 1`, `empty <= 0`.
- If a single /WREQ=0 burst is longer than about 400 bytes (a format), fill the rest
  of the track with FF afterwards. Formatting into an 8192-byte buffer otherwise
  leaves stale sectors in the unused ~1951 bytes. Duplicate stale fields are visible
  in the broken `vt-dos-11.nic` tracks 21-39, which mix 383- and 416-byte pitches.
  (I)

Track change: when `track_x2>>1`, the side or the drive changes:
- If dirty, write the old buffer back.
- Load the new one, with no index reset; keep `pos` running.
- Odd half-tracks read the lower track (floppy.ts).

`.nic` mounting:
- Track t, side s is at byte `s*ntrk*8192 + t*8192`, that is 16 SD blocks starting
  at LBA `s*ntrk*16 + t*16`. Load and store it raw.
- Sizes: 327680 = 1 side x 40, 655360 = 2 sides x 40, 335872 = 1 side x 41.

`.dsk` mounting:
- Nibblize: for each physical sector k = 0..15, read 256 bytes at `(t*16+k)*256`.
  Emit 512 bytes in layout A (section 5.2), with vol=0x00, trk=t, sec=k,
  cks=vol^trk^sec. Use 6-and-2 encoding with the standard table.
- That is exactly 8192 bytes per track, a sector-per-512-byte-block layout proven to
  boot VT-DOS 1.1 and CP/M in laser500emu. Gap2 = 8 FF is enough for the DOS write
  splice (5 FF written plus 1-2 bytes of latency).
- If more fidelity is wanted, play only `pos < 6250` (a real revolution at 32 us).
  For VT-DOS that would need layout B (383-byte pitch, 6241 bytes). (I)
- Denibblize on write-back:
  1. Scan the 8192-byte circular buffer, with wrap-around, for `D5 AA 96`.
  2. Decode the 4&4 vol/trk/sec/cks and check `vol^trk^sec^cks == 0` and `trk == t`.
  3. Look for `D5 AA AD` within about 40 bytes.
  4. XOR-chain decode 343 nibbles (all must be valid GCR codes) and check the final
     value is 0.
  5. Rebuild the 256 bytes and write them to `(t*16+sec)*256`.
  6. Skip fields that fail. If a sector appears twice, keep the one closest after
     the last write position (I).
- Alternative: denibblize the write stream on the fly. Look for D5 AA AD just after
  the last address field read, and capture the 343 nibbles into a 256-byte sector
  buffer.

---

## 10. Open questions and discrepancies

1. **Port 0x11 meaning.** The laser500emu doc says 0xFF = self-sync on and 0xD5 =
   off. The Bonstra doc says bit 0 = 8/16-bit. Both values the DOS writes have bit 0
   = 1, so the real control bit is one of bits 1, 3 or 5. Other open points: when
   the mode is sampled (buffer->shifter load is assumed), and whether /WREQ resets it
   to "on". None of this matters for a byte-level model.
2. **Real bit and byte timing.** 4 us/bit and 300 rpm come only from Bonstra's model
   (Disk II heritage). There are no schematics or measurements. The bytes per real
   revolution (about 6250) and whether VT-DOS INIT's 6241-byte track (with 10-bit
   syncs, about 50,800 cells vs 50,000) really fits are unverified. The DOS gap-reduction loop
   suggests it sometimes doesn't.
3. **Status and data with no drive selected.** The "@Bonstra test" values
   IN(0x12)=0x13 and IN(0x13)=0xFF conflict with the ROM loopback, which runs with
   ENBL=0. Possibly they were taken with the interface absent. Reserved status bits
   6-1 read as 0 in both emulators; real values are unknown.
4. **Mirroring.** It is unknown whether 0x10-0x13 repeat across 0x14-0x1F.
   laser500emu decodes 0x14 as a dead FDC port and MAME maps 0x10-0x1F to a
   different (VZ) controller model.
5. **Data-ready semantics on real hardware.** It is unknown whether a 0x13 read
   clears bit 7, or whether bit 7 is the latch MSB as on the Disk II. Software works
   either way, as long as a byte is not handed over twice.
6. **Physical interleave.** Real formats (DOS INIT code, all dumps) are sequential
   0..15. Bonstra's `.dsk` converter uses physical interleave 3, which is harmless
   but different. The Chinese NIC layout A may have been re-synthesized by the
   dumper's script (exact 512-byte blocks, FF in the EB slot), so its gap sizes are
   not measurements.
7. **Epilogue third byte.** It is EB as written by the DOS, but FF in all real dumps
   (both fields). No software checks it.
8. **Volume and CP/M.** It is unconfirmed that CP/M rejects volumes other than 0xCD
   (the CP/M BIOS is not in refs). DOS 1.0's IY+0x7d is taken as 0x00 from the
   Bonstra notes.
9. **Double-sided.** Only VT-DOS 1.1 DD (`vt-dos-11-dd.nic`, volume 0xAA, side 1 =
   reversed logical tracks) was checked. `fd004_40tracks_dd.nic` side 1 is corrupt.
   The side-select bit is "apparently not used" on real single-sided drives
   (`floppy_310_vs_500.txt:20`).
10. **Stepper physics.** floppy.ts moves the head on any adjacent single-phase
    transition, whatever the absolute head phase. Bonstra models absolute phases and
    quarter tracks, and its arithmetic looks buggy. Both agree for ROM and DOS step
    sequences.
11. **Broken image.** `software/disks/vt-dos-11.nic` is ASCII assembler text, not a
    disk (`refs/laser500emu/TODO.md:36`). Use `chinese_disks/fd005.nic` for VT-DOS
    1.1 SS instead.
12. **The no-disk hang** at ROM 0x6A42 is inferred from the code. It has not been
    checked against a real Laser 700 with an empty drive.
