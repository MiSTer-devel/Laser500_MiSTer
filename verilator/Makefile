# Laser 500 Verilator simulation (headless, scriptable).
#
#   make            -> obj_hl/Vtop      (run from verilator/, ./obj_hl/Vtop --help)
#   make clean
#
# CPU: t80sv_all.sv, the SystemVerilog T80 (cycle-identical to the VHDL
# rtl/T80 used for synthesis), through the T80pa shim in sim.v.
# The old ImGui front end (sim_main.cpp, sim/) is not built: it predates the
# current rtl/laser500.sv ports.

HL_DIR  = obj_hl
HL_RTL  = sim.v t80sv_all.sv ../rtl/laser500.sv ../rtl/downloader.sv ../rtl/dpram.sv \
          ../rtl/VTL_chip.sv ../rtl/eraser.v ../rtl/keyboard.v ../rtl/laser500_floppy.sv
HL_EXE  = $(HL_DIR)/Vtop

all: $(HL_EXE)

$(HL_EXE): $(HL_RTL) sim_headless.cpp Makefile
	verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast --noassert \
	  -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-EOFNEWLINE \
	  --public-flat-rw +define+SIMULATION=1 --top-module top --Mdir $(HL_DIR) \
	  -CFLAGS "-O2 -std=c++17" -LDFLAGS "-lz" \
	  $(HL_RTL) sim_headless.cpp

clean:
	rm -rf $(HL_DIR)

.PHONY: all clean

# video path check: the emu's video_mixer + video_freak on clk_2x -> obj_mix/Vtop
MIX_SYS = sim_video_mixer.sv ../sys/scandoubler.v ../sys/hq2x.sv ../sys/gamma_corr.sv \
          ../sys/video_freezer.sv ../sys/video_freak.sv ../sys/math.sv
mixer: $(HL_RTL) sim_headless.cpp Makefile
	verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast --noassert \
	  -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-EOFNEWLINE \
	  -Wno-PROCASSWIRE --public-flat-rw +define+SIMULATION=1 +define+SIM_MIXER=1 -CFLAGS "-O2 -std=c++17 -DSIM_MIXER" \
	  --top-module top --Mdir obj_mix -LDFLAGS "-lz" \
	  $(HL_RTL) $(MIX_SYS) sim_headless.cpp
.PHONY: mixer
