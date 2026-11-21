# Laser 500 Verilator simulation

Headless and scriptable: no SDL or ImGui.

```bash
cd verilator
make                 # -> obj_hl/Vtop  (needs verilator and zlib)
./obj_hl/Vtop --help
./regression.sh      # boot, keyboard, PRG, disk read and write
```

The sim runs the same RTL as the FPGA build (`rtl/`). The only difference is the
CPU: `t80sv_all.sv`, a SystemVerilog T80 that is cycle-identical to the VHDL
`rtl/T80` (from the t80sv package, BSD-style T80 licence in `t80sv_LICENSE`).
`sim.v` puts it behind a `T80pa` shim. It runs at about 7 frames a second on an
Apple M-series Mac.

`boot.rom` (the 32 KB BASIC ROM `27-0401-00-00.u6` from MAME's `laser350` set)
must be in `verilator/`. It is not in git.

## Examples

```bash
# boot, type a line, screenshot (PNG of the whole raster, border included)
./obj_hl/Vtop --stop-at-frame 260 --send-keys '70:PRINT 2+3\n' --screenshot 260

# a .prg at frame 100, then RUN
./obj_hl/Vtop --prg ../software/mister11/cross_chase.prg@100 --send-keys '110:RUN\n' --stop-at-frame 300 --screenshot 300

# boot VT-DOS from a disk (.nic or .dsk), DIR
./obj_hl/Vtop --disk1 vt-dos.nic --send-keys '230:DIR\n' --stop-at-frame 450 --screenshot 450

# save a program, write the changed image at exit
./obj_hl/Vtop --disk1 w.nic --disk1-save w2.nic --send-keys '230:10 PRINT "OK"\n' \
    --send-keys '240:SAVE "TEST"\n' --stop-at-frame 800
```

Keys are typed with a PC layout as PS/2 set-2 codes (6 frames held, 8 frames
between keys by default; shorter holds drop keys, as on the real ROM). The
Laser starts in caps mode: unshifted letters give capitals, so type DOS file
names in lower case (`run "tarzan"`).

Output lines start with a tag for grepping: `LOAD`, `MOUNT`, `SD`, `SHOT`,
`DUMP`, `SAVE`, `KEY`, `FDC`, `FDCST`, `HEAD`, `FDCRD`, `IN`, `OUT`, `DONE`.

| group | options |
|---|---|
| run | `--stop-at-frame N`, `--reset-at-frame N`, `--quiet` |
| media | `--rom F`, `--prg F[@FRAME]`, `--ioctl FRAME:INDEX:FILE` |
| disks | `--disk1 F[@FRAME]`, `--disk2 F[@FRAME]`, `--disk1-ro`, `--disk2-ro`, `--disk1-save F`, `--disk2-save F`, `--fdc on\|off`, `--sd-latency N` |
| input | `--send-keys FRAME:TEXT` (`\n` `\b` `\e` `\t`), `--key-hold N`, `--key-gap N`, `--joy FRAME:HEX`, `--joy2 FRAME:HEX` |
| output | `--screenshot N,..`, `--screenshot-every N`, `--screenshot-end`, `--screenshot-dir D`, `--screenshot-prefix P`, `--dump-ram FRAME:F` (256 KB, 16 KB pages 0-15), `--dump-track FRAME:F` (the floppy's 8 KB track buffer), `--audio-out F.wav` |
| debug | `--io-log`, `--fdc-log`, `--key-log` |

`DONE` reports the CPU clock as a fraction of F14M (about F14M/4.95: one wait
state per memory cycle, as in laser500emu).

The old ImGui front end (`sim_main.cpp`, `sim/`) is not built: it predates the
current `rtl/laser500.sv` ports.
