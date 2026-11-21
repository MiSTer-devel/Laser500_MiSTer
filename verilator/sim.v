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
	input   [1:0] img_mounted,
	input         img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba,
	output  [5:0] sd_blk_cnt,
	output  [1:0] sd_rd,
	output  [1:0] sd_wr,
	input   [1:0] sd_ack,
	input  [13:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr
);

reg F14M = 0;
reg [1:0] div3 = 0;
always @(posedge clk_2x) F14M <= ~F14M;
always @(posedge F14M) div3 <= div3 + 1'd1;
wire F3M = div3[1];

assign clk_pix = F14M;

wire [5:0] video_r, video_g, video_b;
wire non_visible_area;

assign VGA_DE = ~non_visible_area;
assign VGA_R  = { video_r, video_r[5:4] };
assign VGA_G  = { video_g, video_g[5:4] };
assign VGA_B  = { video_b, video_b[5:4] };

laser500 laser500
(
	.F14M(F14M),
	.F14Mx2(clk_2x),
	.F3M(F3M),
	.reset(reset),
	.pll_locked(1'b1),

	.video_hs(VGA_HS),
	.video_vs(VGA_VS),
	.video_r(video_r),
	.video_g(video_g),
	.video_b(video_b),
	.non_visible_area(non_visible_area),

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
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
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
