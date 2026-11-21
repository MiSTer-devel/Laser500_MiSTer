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

assign VGA_SL = 0;
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

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v" 
localparam CONF_STR = {
	"LASER500;;",
	"S0,NICDSK,Pri. disk 1;",
	"S1,NICDSK,Disk 2;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O2,Custom charset ROM,Off,On;",
	"F1,PRGBIN,Load Program;",
	"-;",
	"R0,Reset;",
	"V,v",`BUILD_DATE 
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;


wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;

wire [31:0] joystick_0, joystick_1;
wire st_alt_font = status[2];

// floppy (S0/S1)
wire  [1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire  [1:0] sd_rd, sd_wr, sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout, sd_buff_din;
wire        sd_buff_wr;
wire        fdc_active;
wire  [1:0] fdc_mounted;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

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
	.status_menumask({status[5]}),
	
	.ps2_key(ps2_key),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba, sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt, sd_blk_cnt}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din, sd_buff_din}),
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
	.outclk_0(),
	.outclk_1(F14Mx2),
	.outclk_2(F14M),
	.outclk_3(F3M)
);

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
	if (~&boot_window[25:24] && !fdc_mounted_old && fdc_mounted) mount_reset <= 8'hFF;
end

wire reset = RESET | status[0] | buttons[1] | (mount_reset != 0);
//////////////////////////////////////////////////////////////////

wire [1:0] col = status[4:3];

wire video_hs;
wire video_vs;
wire ce_pix;
wire [7:0] video;

wire [5:0] video_r;
wire [5:0] video_g; 
wire [5:0] video_b;
wire non_visible_area;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = 1'b1;

assign VGA_DE = ~non_visible_area;
assign VGA_HS = video_hs;
assign VGA_VS = video_vs;
assign VGA_R  = { video_r[5:4] , video_r };
assign VGA_G  = { video_g[5:4] , video_g };
assign VGA_B  = { video_b[5:4] , video_b };

assign LED_USER = 0;

wire [2:0] hcnt;

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
	.fdc_enable   ( |fdc_mounted  ),
	.fdc_active   ( fdc_active    ),
	.fdc_mounted  ( fdc_mounted   ),
	.img_mounted  ( img_mounted   ),
	.img_readonly ( img_readonly  ),
	.img_size     ( img_size      ),
	.sd_lba       ( sd_lba        ),
	.sd_blk_cnt   ( sd_blk_cnt    ),
	.sd_rd        ( sd_rd         ),
	.sd_wr        ( sd_wr         ),
	.sd_ack       ( sd_ack        ),
	.sd_buff_addr ( sd_buff_addr  ),
	.sd_buff_dout ( sd_buff_dout  ),
	.sd_buff_din  ( sd_buff_din   ),
	.sd_buff_wr   ( sd_buff_wr    )
);

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @ena *******************************************/
/******************************************************************************************/
/******************************************************************************************/

endmodule
