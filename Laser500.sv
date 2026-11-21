//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = {1'b0, fdc_active};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// the settings the machine runs with: taken from the OSD at every reset
// (Apply and reset, the board's reset, a core reload)
reg [127:0] cfg;
wire        reset;


`include "build_id.v" 
// OSD (~/dev2/osd-standard.md): media on the top page, then P1 Machine,
// P2 Video, "Changes pending" and Apply and reset. Settings are taken from
// the OSD at every reset (cfg).
// status bits: 0 Apply and reset; 2 Character set; 6 Disk interface;
// 9:8 Scale; 10 Vertical crop; 13:11 Scandoubler Fx; 14 Tape speed;
// 15 Tape overlay; 16 Tape audio; 17 Rewind tape; 18 Tape deck;
// 20:19 Tape pitch;
// 122:121 Aspect ratio. The video, audio and tape rows act at once
// (status, not cfg, and not in pending; tape standard rules 1-2).
localparam CONF_STR = {
	"LASER500;;",
	"-;",
	"H1S0,NICDSK,Pri. disk 1;",
	"h1-;",
	"H1S1,NICDSK,Disk 2;",
	"h1-;",
	"S2,WAVCAS,Tape;",
	"F1,PRGBIN,Load Program;",
	"F0,ROM,Load ROM;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P4,Audio;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[6],Disk interface,Auto,Off;",
	"P1O[14],Tape speed,2x,Normal;",
	"P1-;",
	"P1R[17],Rewind tape;",

	"P2O[2],Character set,Standard,Alternate;",
	"P2-;",
	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[9:8],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P2O[10],Vertical crop,Off,216p(5x);",
	"P2O[13:11],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2O[15],Tape overlay,On,Off;",

	"P4O[16],Tape audio,Off,On;",

	"P5O[18],Tape deck,Auto,Play;",
	"P5O[20:19],Tape pitch,Normal,+1.6%,-1.6%;",

	"I,Tape ready (rewound),Tape format not supported;",

	"v,1;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [21:0] gamma_bus;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;


wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;

wire [31:0] joystick_0, joystick_1;
wire st_alt_font = cfg[2];

wire pending = {status[2], status[6]} != {cfg[2], cfg[6]};
wire fdc_off = status[6];          // hide the disk rows as soon as it is chosen

// floppy (S0/S1), tape (S2)
wire  [2:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire  [2:0] sd_ack;
wire  [1:0] sd_rd, sd_wr;
wire [31:0] tape_sd_lba;
wire        tape_sd_rd;
wire        tape_ready, tape_bad;
// OSD info message (CONF_STR "I,"): 1 Tape ready (rewound), 2 not supported
reg   [7:0] info = 0;
reg         info_req = 0;
always @(posedge clk_sys) begin
	info_req <= 0;
	if (tape_ready) begin info <= 8'd1; info_req <= 1; end
	if (tape_bad)   begin info <= 8'd2; info_req <= 1; end
end
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout, sd_buff_din;
wire        sd_buff_wr;
wire        fdc_active;
wire  [1:0] fdc_mounted;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_index(ioctl_index),
	
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	 	
	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, fdc_off, pending}),   // bit 0 Changes pending, bit 1 disk rows hidden
	
	.ps2_key(ps2_key),

	.info_req(info_req),
	.info(info),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	// unpacked [VDNUM] arrays: '{} lists drive 0 first
	.sd_lba('{sd_lba, sd_lba, tape_sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt, sd_blk_cnt, 6'd0}),
	.sd_rd({tape_sd_rd, sd_rd}),
	.sd_wr({1'b0, sd_wr}),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din, sd_buff_din, 8'hFF}),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys = F14M;
wire F14Mx2, F14M, F3M;

pll pll
(
	.refclk(CLK_50M),
	.locked(pll_locked),
	.rst(0),
	.outclk_0(clk_vid),
	.outclk_1(F14Mx2),
	.outclk_2(F14M),
	.outclk_3(F3M)
);

// Disk interface Auto: fitted while an image is mounted (with no disk the
// ROM would wait for one forever). Off: never.
wire fdc_enable = |fdc_mounted & ~cfg[6];

// A disk mounted within about 3 s of the core starting (an MGL, or a quick OSD
// mount) resets the machine once, so the ROM finds the interface and boots
// from it. Later mounts just fit the interface; Reset boots the disk.
reg [25:0] boot_window = 0;          // counts to 3<<24 (3.4 s of F14M)
reg  [1:0] fdc_mounted_old = 0;
reg  [7:0] mount_reset = 0;
always @(posedge clk_sys) begin
	fdc_mounted_old <= fdc_mounted;
	if (~&boot_window[25:24]) boot_window <= boot_window + 1'd1;
	if (mount_reset) mount_reset <= mount_reset - 1'd1;
	if (~&boot_window[25:24] && !fdc_mounted_old && fdc_mounted && !cfg[6]) mount_reset <= 8'hFF;
end

assign reset = RESET | status[0] | buttons[1] | (mount_reset != 0);
always @(posedge clk_sys) if (reset) cfg <= status;
//////////////////////////////////////////////////////////////////


wire video_hs;
wire video_vs;
wire [5:0] video_r;
wire [5:0] video_g; 
wire [5:0] video_b;
wire non_visible_area;
wire hblank, vblank;

/////////////////////////////  video out  ////////////////////////////
// ~/dev2/video-standard.md. One machine pixel per F14M clock (the 80-column
// dot clock; 40 columns repeat pixels). CLK_VIDEO = 4 x F14M from the same
// PLL; ce_pix marks each F14M clock.
//
// Picture sent (DE, border included): 798 x 307 at 14.7785 MHz.
// Original aspect: PAR = 7.375 MHz (PAL square pixel) / 14.7785 MHz,
//   798 x PAR : 307 = 398.2 : 307  ->  ARX:ARY = 3982:3070 (1.297).
// Vertical crop 216p(5x): 216 of the 307 lines, centred on the 192-line
// picture (DE lines 61-252): window start (307-216)/2 + 4 = 49.
wire        clk_vid;
assign CLK_VIDEO = clk_vid;

reg  pix_tog = 0;
always @(posedge clk_sys) pix_tog <= ~pix_tog;
reg  [1:0] pix_tog_v;
reg        ce_pix;
always @(posedge clk_vid) begin
	pix_tog_v <= {pix_tog_v[0], pix_tog};
	ce_pix    <= pix_tog_v[1] ^ pix_tog_v[0];
end

wire [1:0] ar  = status[122:121];
wire [2:0] sfx = status[13:11];             // 0 None, 1 HQ2x, 2-4 CRT 25/50/75%
wire [2:0] sl  = sfx ? sfx - 3'd1 : 3'd0;
wire       scandoubler = (sfx != 3'd0) || forced_scandoubler;
assign VGA_SL = sl[1:0];

wire vcrop_en = status[10] && HDMI_WIDTH == 1920 && HDMI_HEIGHT == 1080
                && !forced_scandoubler && sfx == 3'd0;

// tape status bar and hints over the picture (rtl/tape_overlay.sv)
wire        tape_loaded, tape_playing, tape_fast, tape_at_start, tape_need_run;
wire [31:0] tape_pos, tape_len;
wire [17:0] tape_hz;
wire        ov_hs, ov_vs, ov_hblank, ov_vblank;
wire  [5:0] ov_r, ov_g, ov_b;

tape_overlay tape_overlay
(
	.clk(clk_sys),
	.reset(reset),
	.tape_en(~status[15]),
	.vcrop(vcrop_en),
	.tape_loaded(tape_loaded),
	.tape_playing(tape_playing),
	.tape_fast(tape_fast),
	.tape_at_start(tape_at_start),
	.tape_pos(tape_pos),
	.tape_len(tape_len),
	.tape_hz(tape_hz),
	.tape_ready(tape_ready),
	.need_run(tape_need_run),
	.ps2_key(ps2_key),
	.hblank(hblank), .vblank(vblank), .hs(video_hs), .vs(video_vs),
	.r_in(video_r), .g_in(video_g), .b_in(video_b),
	.hblank_o(ov_hblank), .vblank_o(ov_vblank), .hs_o(ov_hs), .vs_o(ov_vs),
	.r_out(ov_r), .g_out(ov_g), .b_out(ov_b),
	.show_bar(),
	.show_tape()
);

wire vga_de_mix;

video_mixer #(.LINE_LENGTH(800), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(ce_pix),
	.scandoubler(scandoubler),
	.hq2x(sfx == 3'd1),
	.gamma_bus(gamma_bus),
	.R({ov_r, ov_r[5:4]}),
	.G({ov_g, ov_g[5:4]}),
	.B({ov_b, ov_b[5:4]}),
	.HSync(~ov_hs),                          // VTL syncs are active low: positive here
	.VSync(~ov_vs),
	.HBlank(ov_hblank),
	.VBlank(ov_vblank),
	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de_mix)
);

video_freak video_freak
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_mix),
	.ARX((!ar) ? 12'd3982 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3070 : 12'd0),
	.CROP_SIZE(vcrop_en ? 12'd216 : 12'd0),
	.CROP_OFF(5'd4),
	.SCALE({1'b0, status[9:8]})
);

assign LED_USER = 0;


/******************************************************************************************/
/******************************************************************************************/
/***************************************** @pll *******************************************/
/******************************************************************************************/
/******************************************************************************************/

// F14M is the main 14MHz clock
// ram_clock is faster clock for the SDRAM chip, 1 complete read/write cycle in two F14M cyles
// pll_locked flags PLL is locked

wire pll_locked;
/*
wire F14Mx2;

pll pll (
	 .inclk0 ( CLOCK_27[0]   ),
	 .locked ( pll_locked    ),        // PLL is running stable
	 .c0     ( F14M          ),        // video generator clock frequency 14.77873 MHz
	 .c1     ( SDRAM_CLK     ),        // F14M x 8, phase shifted 	 
	 .c2     ( F3M           ),        // F14M / 4 
     .c3     ( F14Mx2        ),        // F14M x 2 for the scandoubler 
	 .c4     ( ram_clock     )         // F14M x 8, phase shifted 	 
);
*/
//
// F14M = 14778730 on real hardware with 6 clocks cycles skip every 944 ~= 14.698 
// F14M = 14700000 on the MiST almost close to the original 
//
localparam F14M_HZ = 14700000;

wire        sdram_clkref ;
wire [24:0] sdram_addr   ;
wire        sdram_wr     ;
wire        sdram_rd     ;
wire [7:0]  sdram_dout   ; 
wire [7:0]  sdram_din    ; 

laser500 laser500 (
    .F14M(clk_sys),
	.F14Mx2(F14Mx2),
	.F3M(F3M),
    .reset(reset),
	.pll_locked(pll_locked),

	// video
	.video_hs  ( video_hs ),
	.video_vs  ( video_vs ),
	.video_r( video_r  ),
	.video_g( video_g  ),
	.video_b( video_b  ),
	.non_visible_area(non_visible_area),
	.hblank(hblank),
	.vblank(vblank),

	.alt_font(st_alt_font),

	.AUDIO_L(AUDIO_L),
	.AUDIO_R(AUDIO_R),

	.UART_RX(UART_RXD),
	
	.joystick_0   ( joystick_0 ),
	.joystick_1   ( joystick_1 ),

	.ps2_key  ( ps2_key ),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_data),
	.ioctl_index(ioctl_index),

	// floppy interface: fitted while a disk image is mounted (the ROM boots
	// from it at reset; with no disk it would wait for one forever)
	.fdc_enable   ( fdc_enable    ),
	.fdc_active   ( fdc_active    ),
	.fdc_mounted  ( fdc_mounted   ),
	.img_mounted  ( img_mounted[1:0] ),
	.img_readonly ( img_readonly  ),
	.img_size     ( img_size      ),
	.sd_lba       ( sd_lba        ),
	.sd_blk_cnt   ( sd_blk_cnt    ),
	.sd_rd        ( sd_rd         ),
	.sd_wr        ( sd_wr         ),
	.sd_ack       ( sd_ack[1:0]   ),
	.sd_buff_addr ( sd_buff_addr  ),
	.sd_buff_dout ( sd_buff_dout  ),
	.sd_buff_din  ( sd_buff_din   ),
	.sd_buff_wr   ( sd_buff_wr    ),

	// tape (S2): the tape rows act at once (status, not cfg)
	.tape_mounted   ( img_mounted[2] ),
	.tape_sd_lba    ( tape_sd_lba    ),
	.tape_sd_rd     ( tape_sd_rd     ),
	.tape_sd_ack    ( sd_ack[2]      ),
	.tape_rewind    ( status[17]     ),
	.tape_turbo_en  ( ~status[14]    ),
	.tape_deck_play ( status[18]     ),
	.tape_audio_en  ( status[16]     ),
	.tape_pitch     ( status[20:19]  ),
	.tape_ready     ( tape_ready     ),
	.tape_bad       ( tape_bad       ),
	.tape_loaded    ( tape_loaded    ),
	.tape_playing   ( tape_playing   ),
	.tape_fast      ( tape_fast      ),
	.tape_at_start  ( tape_at_start  ),
	.tape_pos       ( tape_pos       ),
	.tape_len       ( tape_len       ),
	.tape_hz        ( tape_hz        ),
	.tape_need_run ( tape_need_run ),
	.tape_underflows ( )
);

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @ena *******************************************/
/******************************************************************************************/
/******************************************************************************************/

endmodule
