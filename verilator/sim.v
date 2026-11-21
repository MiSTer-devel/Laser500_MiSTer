`timescale 1ns/1ns
// Simulation top: stands in for the emu module (Laser500.sv) around rtl/laser500.sv.
// The C++ harness drives clk_2x (F14Mx2); F14M and F3M are divided from it here.

module top
(
	input         clk_2x /*verilator public_flat*/,
	input         reset  /*verilator public_flat*/,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        clk_pix,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,

	input  [10:0] ps2_key,
	input  [31:0] joystick_0,
	input  [31:0] joystick_1,
	input         alt_font,

	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	input   [7:0] ioctl_index,

	input         fdc_enable,
	output        fdc_active,
	output  [1:0] fdc_mounted,
	input   [2:0] img_mounted,        // 0-1 floppy drives, 2 tape
	input         img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba,
	output  [5:0] sd_blk_cnt,
	output  [2:0] sd_rd,
	output  [1:0] sd_wr,
	input   [2:0] sd_ack,
	output [31:0] tape_sd_lba,
	input  [13:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,

	// tape (Laser500.sv OSD rows)
	input         tape_turbo_en,
	input         tape_deck_play,
	input         tape_audio_en,
	input         tape_overlay_en,
	input         tape_rewind,
	input   [1:0] tape_pitch,
	output        tape_loaded,
	output        tape_playing,
	output        tape_fast,
	output [31:0] tape_pos,
	output [31:0] tape_len,
	output [15:0] tape_underflows,
	output        show_bar,
	output  [1:0] show_tape
);

`ifdef SIM_MIXER
wire clk_vid = clk_2x;            // the harness clock is 4 x F14M here
reg  clk2 = 0;
always @(posedge clk_vid) clk2 <= ~clk2;
`else
wire clk2 = clk_2x;
`endif
reg F14M = 0;
reg [1:0] div3 = 0;
always @(posedge clk2) F14M <= ~F14M;
always @(posedge F14M) div3 <= div3 + 1'd1;
wire F3M = div3[1];

assign clk_pix = F14M;

wire [5:0] video_r, video_g, video_b;
wire non_visible_area;
wire hblank, vblank;
wire vtl_hs, vtl_vs;

// the tape overlay, as Laser500.sv puts it before the mixer
wire [5:0] ov_r, ov_g, ov_b;
wire       ov_hb, ov_vb;
wire       tape_at_start, tape_need_run, tape_ready, tape_bad;
wire [17:0] tape_hz;
tape_overlay tape_overlay
(
	.clk(F14M), .reset(reset), .tape_en(tape_overlay_en), .vcrop(1'b0),
	.tape_loaded(tape_loaded), .tape_playing(tape_playing), .tape_fast(tape_fast),
	.tape_at_start(tape_at_start), .tape_pos(tape_pos), .tape_len(tape_len), .tape_hz(tape_hz),
	.tape_ready(tape_ready), .need_run(tape_need_run), .ps2_key(ps2_key),
	.hblank(hblank), .vblank(vblank), .hs(vtl_hs), .vs(vtl_vs),
	.r_in(video_r), .g_in(video_g), .b_in(video_b),
	.hblank_o(ov_hb), .vblank_o(ov_vb), .hs_o(VGA_HS), .vs_o(VGA_VS),
	.r_out(ov_r), .g_out(ov_g), .b_out(ov_b),
	.show_bar(show_bar), .show_tape(show_tape)
);

reg nva_d;
always @(posedge F14M) nva_d <= non_visible_area;
assign VGA_DE = ~nva_d;
assign VGA_R  = { ov_r, ov_r[5:4] };
assign VGA_G  = { ov_g, ov_g[5:4] };
assign VGA_B  = { ov_b, ov_b[5:4] };

`ifdef SIM_MIXER
`ifndef MIX_HS
`define MIX_HS ~VGA_HS
`define MIX_VS ~VGA_VS
`endif
// the emu's video path (Laser500.sv), run on clk_2x for a functional check
wire [5:0] r6 = ov_r, g6 = ov_g, b6 = ov_b;
wire hblank_m = ov_hb, vblank_m = ov_vb;
reg  pix_tog = 0;
always @(posedge F14M) pix_tog <= ~pix_tog;
reg  [1:0] pt;
reg  ce_mix;
always @(posedge clk_vid) begin pt <= {pt[0], pix_tog}; ce_mix <= pt[1] ^ pt[0]; end
wire [21:0] gamma_bus;
assign gamma_bus[20:0] = 0;
wire mix_ce, mix_de, mix_hs, mix_vs;
wire [7:0] mix_r, mix_g, mix_b;
video_mixer_sim #(.LINE_LENGTH(800), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(clk_vid), .CE_PIXEL(mix_ce), .ce_pix(ce_mix), .scandoubler(1'b0), .hq2x(1'b0),
	.gamma_bus(gamma_bus),
	.R({r6, r6[5:4]}), .G({g6, g6[5:4]}), .B({b6, b6[5:4]}),
	.HSync(`MIX_HS), .VSync(`MIX_VS), .HBlank(hblank_m), .VBlank(vblank_m),
	.HDMI_FREEZE(1'b0), .freeze_sync(),
	.VGA_R(mix_r), .VGA_G(mix_g), .VGA_B(mix_b), .VGA_VS(mix_vs), .VGA_HS(mix_hs), .VGA_DE(mix_de)
);
wire        frk_de;
wire [12:0] frk_arx, frk_ary;
video_freak video_freak
(
	.CLK_VIDEO(clk_vid), .CE_PIXEL(mix_ce), .VGA_VS(mix_vs),
	.HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080),
	.VGA_DE(frk_de), .VIDEO_ARX(frk_arx), .VIDEO_ARY(frk_ary), .VGA_DE_IN(mix_de),
	.ARX(12'd3982), .ARY(12'd3070), .CROP_SIZE(12'd0), .CROP_OFF(5'd4), .SCALE(3'd0)
);
`endif

laser500 laser500
(
	.F14M(F14M),
	.F14Mx2(clk2),
	.F3M(F3M),
	.reset(reset),
	.pll_locked(1'b1),

	.video_hs(vtl_hs),
	.video_vs(vtl_vs),
	.video_r(video_r),
	.video_g(video_g),
	.video_b(video_b),
	.non_visible_area(non_visible_area),
	.hblank(hblank),
	.vblank(vblank),

	.alt_font(alt_font),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key),

	.AUDIO_L(AUDIO_L),
	.AUDIO_R(AUDIO_R),

	.UART_RX(1'b1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_index(ioctl_index),

	.fdc_enable(fdc_enable),
	.fdc_active(fdc_active),
	.fdc_mounted(fdc_mounted),
	.img_mounted(img_mounted[1:0]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd[1:0]),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack[1:0]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.tape_mounted(img_mounted[2]),
	.tape_sd_lba(tape_sd_lba),
	.tape_sd_rd(sd_rd[2]),
	.tape_sd_ack(sd_ack[2]),
	.tape_rewind(tape_rewind),
	.tape_turbo_en(tape_turbo_en),
	.tape_deck_play(tape_deck_play),
	.tape_audio_en(tape_audio_en),
	.tape_pitch(tape_pitch),
	.tape_ready(tape_ready),
	.tape_bad(tape_bad),
	.tape_loaded(tape_loaded),
	.tape_playing(tape_playing),
	.tape_fast(tape_fast),
	.tape_at_start(tape_at_start),
	.tape_pos(tape_pos),
	.tape_len(tape_len),
	.tape_hz(tape_hz),
	.tape_need_run(tape_need_run),
	.tape_underflows(tape_underflows)
);

endmodule

// T80pa (VHDL, used for synthesis) -> t80sv_T80pa (SystemVerilog, cycle-identical).
// Port names as rtl/laser500.sv writes them.
module T80pa #(parameter Mode = 0)
(
	input         reset_n,
	input         clk,
	input         cen_p,
	input         cen_n,
	input         wait_n,
	input         int_n,
	input         nmi_n,
	input         busrq_n,
	output        m1_n,
	output        mreq_n,
	output        iorq_n,
	output        rd_n,
	output        wr_n,
	output        rfsh_n,
	output        halt_n,
	output        busak_n,
	output [15:0] a,
	input   [7:0] di,
	output  [7:0] DO
);

t80sv_T80pa #(.Mode(Mode)) cpu
(
	.RESET_n(reset_n), .CLK(clk), .CEN_p(cen_p), .CEN_n(cen_n),
	.WAIT_n(wait_n), .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(busrq_n),
	.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
	.RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n), .OUT0(1'b0),
	.A(a), .DI(di), .DO(DO), .R800_mode(1'b0), .REG(), .DIRSet(1'b0), .DIR(212'd0)
);

endmodule
