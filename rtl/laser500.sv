
module laser500 (
    input wire F14M,
	input wire F14Mx2,
	input wire F3M,
    input wire reset,
    input wire pll_locked,

	// video
	output wire video_hs,
	output wire video_vs,
	output wire [5:0] video_r,
	output wire [5:0] video_g,
	output wire [5:0] video_b,
	output wire non_visible_area,
	output wire hblank,
	output wire vblank,

	input wire  alt_font,
	
	input wire [31:0] joystick_0,
	input wire [31:0] joystick_1,

	input wire [10:0] ps2_key,

	output reg [15:0] AUDIO_L,
	output reg [15:0] AUDIO_R,

	input wire  UART_RX,

	input wire        ioctl_download,
	input wire        ioctl_wr,
	input wire [24:0] ioctl_addr,
    input wire [7:0]  ioctl_data,
	input wire [7:0]  ioctl_index,

	// floppy (hps_io S0/S1)
	input wire        fdc_enable,      // OSD: interface fitted
	output wire       fdc_active,      // drive motor on (LED)
	output wire [1:0] fdc_mounted,
	input wire  [1:0] img_mounted,
	input wire        img_readonly,
	input wire [63:0] img_size,
	output wire [31:0] sd_lba,
	output wire  [5:0] sd_blk_cnt,
	output wire  [1:0] sd_rd,
	output wire  [1:0] sd_wr,
	input wire   [1:0] sd_ack,
	input wire  [13:0] sd_buff_addr,
	input wire   [7:0] sd_buff_dout,
	output wire  [7:0] sd_buff_din,
	input wire         sd_buff_wr
);

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @t80 *******************************************/
/******************************************************************************************/
/******************************************************************************************/
	
//
// Z80 CPU
//
	
// CPU control signals
wire        CPUCK;          // CPU Clock not used yet
wire        CPUENA;         // CPU enable
wire        WAIT;           // CPU WAIT 
wire [15:0] cpu_addr;
wire [7:0]  cpu_din;
wire [7:0]  cpu_dout;
wire        cpu_rd_n;
wire        cpu_wr_n;
wire        cpu_mreq_n;
wire        cpu_m1_n;
wire        cpu_iorq_n;

T80pa cpu
(
	.reset_n ( ~SYS_RESET    ),  
	
	.clk     ( F14M          ),   
	.cen_p   ( CPUENA        ),   // CPU enable (positive edge)
	.cen_n   ( ~CPUENA       ),   // CPU enable (negative edge)

	.a       ( cpu_addr      ),   // 16 bit address bus
	.DO      ( cpu_dout      ),   // 8 bit data bus (output)
	.di      ( cpu_din       ),   // 8 bit data bus (input)
	
	.rd_n    ( cpu_rd_n      ),   // READ       0=cpu reads
	.wr_n    ( cpu_wr_n      ),   // WRITE      0=cpu writes
	
	.iorq_n  ( cpu_iorq_n    ),   // IO REQUEST 0=read from I/O
	.mreq_n  ( cpu_mreq_n    ),   // MEMORY REQUEST, idicates the bus has a valid memory address
	.m1_n    ( cpu_m1_n      ),   // expansion port on the Laser 500
	.rfsh_n  (               ),   // expansion port on the Laser 500

	.busrq_n ( 1'b1          ),   // connected to VCC on the Laser 500
	.int_n   ( video_vs      ),   // VSYNC interrupt
	.nmi_n   ( 1'b1          ),   // connected to VCC on the Laser 500
	.wait_n  ( ~WAIT         )    // 
	
);

/*
tv80s cpu 
(
	.reset_n(~CPU_RESET ),
	.clk(clk),
	//.cen(CPUENA),
	.wait_n(~WAIT ),
	.int_n(video_vs),
	.nmi_n(1'b1),
	.busrq_n(1'b1),
	.m1_n(),
	.rfsh_n(rfsh_n),
	.mreq_n(cpu_mreq_n),
	.iorq_n(cpu_iorq_n),
	.rd_n(cpu_rd_n),
	.wr_n(cpu_wr_n),
	.A(cpu_addr),
	.di(cpu_din),
	.dout(cpu_dout)
);
*/

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @keyboard **************************************/
/******************************************************************************************/
/******************************************************************************************/

// One-clock strobe for each new ps2_key event (bit 10 toggles per event).
// keyboard.v applies the key while valid is high, so it must be a pulse.
wire [ 6:0] KD;
wire        reset_key;   // keyboard Reset key (Pause/Num Lock), see SYS_RESET
wire        SYS_RESET;
reg old_state;
reg key_strobe;

always @(posedge F14M) begin
	old_state  <= ps2_key[10];
	key_strobe <= ~CPU_RESET && (old_state != ps2_key[10]);
end

wire [15:0] adapter_key;
wire        adapter_key_status;

// If extended bit [8] = 1, put 0xE0 in the top byte, else 0x00.
// Lower byte is the scancode [7:0].
assign adapter_key        = ps2_key[8] 
                            ? {8'hE0, ps2_key[7:0]} 
                            : {8'h00, ps2_key[7:0]};

// key_status is simply the pressed bit [9].
assign adapter_key_status = ~ps2_key[9];

keyboard keyboard 
(
	.reset    ( CPU_RESET ),
	.clk      ( F14M  ),

	.key  ( adapter_key ),
	.valid	  ( key_strobe  ),
	.key_status( adapter_key_status ),

	.address  ( cpu_addr  ),
	.KD       ( KD        ),
	.reset_key( reset_key )	
);

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @vdc *******************************************/
/******************************************************************************************/
/******************************************************************************************/

//
// VTL CHIP GA1
//
					
wire [24:0] vdc_sdram_addr; 
wire        vdc_sdram_wr;
wire        vdc_sdram_rd;
wire  [7:0] vdc_sdram_din;
		  
// VTL custom chip
VTL_chip VTL_chip 
(	
	.F14M   ( F14M        ),
	.F14Mx2	( F14Mx2	  ),
	.RESET  ( CPU_RESET   ),
	.KEY_RESET ( reset_key ),
	.BLANK  ( BLANK       ),		
	
	 // cpu
    .CPUCK    ( CPUCK         ),
	.CPUENA   ( CPUENA        ),
	.MREQ_n   ( cpu_mreq_n    ),	
	.IORQ_n   ( cpu_iorq_n    ),
	.RD_n     ( cpu_rd_n      ), 
	.WR_n     ( cpu_wr_n      ),
	.A        ( cpu_addr      ),
	.DI       ( cpu_din       ),
	.DO       ( cpu_dout      ),
		
	// video
	.hsync  ( video_hs    ),
	.vsync  ( video_vs    ),
	.r      ( video_r     ),
	.g      ( video_g     ),
	.b      ( video_b     ),

	.non_visible_area(non_visible_area),
	.hblank(hblank),
	.vblank(vblank),
	
	//	SDRAM interface
	.sdram_addr   ( vdc_sdram_addr   ), 
	.sdram_din    ( vdc_sdram_din    ),
	.sdram_rd     ( vdc_sdram_rd     ),
	.sdram_wr     ( vdc_sdram_wr     ),
	.sdram_dout   ( sdram_dout       ), 
	
	.joystick_0   ( joystick_0 ),
	.joystick_1   ( joystick_1 ),
	
	.KD           ( KD      ),	
	.BUZZER       ( BUZZER  ),
	.CASOUT       ( CASOUT  ),
	.CASIN        ( CASIN   ),
	
	.alt_font     ( alt_font ),
	.cnt          ( ),
	
	.fdc_en       ( fdc_enable ),
	.fdc_rd       ( fdc_rd     ),
	.fdc_wr       ( fdc_wr     ),
	.fdc_dout     ( fdc_dout   )
);

/******************************************************************************************/
/***************************************** @floppy ****************************************/
/******************************************************************************************/

wire       fdc_rd, fdc_wr;
wire [7:0] fdc_dout;

laser500_floppy floppy
(
	.clk          ( F14M          ),
	.reset        ( CPU_RESET     ),

	.io_rd        ( fdc_rd        ),
	.io_wr        ( fdc_wr        ),
	.io_port      ( cpu_addr[1:0] ),
	.io_din       ( cpu_dout      ),
	.io_dout      ( fdc_dout      ),

	.active       ( fdc_active    ),

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
	.sd_buff_wr   ( sd_buff_wr    ),

	.mounted      ( fdc_mounted   )
);

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @downloader ************************************/
/******************************************************************************************/
/******************************************************************************************/

wire        is_downloading;
wire [24:0] download_addr;
wire [7:0]  download_data;
wire        download_wr;
wire        boot_completed;

// ROM download helper
downloader 
#
(
	.ROM_START_ADDR(25'h0),               // start of ROM in SDRAM
	.PRG_START_ADDR(25'h10000 + 25'h995), // start of PRG in SDRAM (0x8995)
	.PTR_END_BASE('h8995),                // base value to sum to END pointer (0x8995)
	.PTR_PROGND(25'h10000 + 25'h3E9)      // SDRAM address of END pointer (0x83e9)
)
downloader (
	
	.ioctl_download(ioctl_download),
    .ioctl_index   (ioctl_index),
    .ioctl_addr    (ioctl_addr),
    .ioctl_dout    (ioctl_data),
    .ioctl_wr      (ioctl_wr),

	// signal indicating an active rom download
	.downloading ( is_downloading  ),
    .ROM_done    ( boot_completed  ),	
	         
    // external ram interface
    .clk    ( F14Mx2        ),
	.clk_ena( 1             ),
    .wr     ( download_wr   ),
    .addr   ( download_addr ),
    .data   ( download_data )
);

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @eraser ****************************************/
/******************************************************************************************/
/******************************************************************************************/

wire eraser_busy;
wire eraser_wr;
wire [24:0] eraser_addr;
wire [7:0]  eraser_data;

eraser 
#(
	// erases from page 3 to page 7 (all 64K RAM)
	.START_RAM( { 7'd0, 4'h3, 14'b0 }),  
	.END_RAM  ( { 7'd0, 4'h8, 14'b0 })  
)
eraser
(
	.clk      ( F14Mx2      ),
	.ena      ( 1           ),
	.trigger  ( reset       ),	
	.erasing  ( eraser_busy ),
	.wr       ( eraser_wr   ),
	.addr     ( eraser_addr ),
	.data     ( eraser_data )
);

assign WAIT = 0; 

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @sdram *****************************************/
/******************************************************************************************/
/******************************************************************************************/


	
//
// RAM (SDRAM)
//
						

reg         sdram_clkref ;
reg  [24:0] sdram_addr   ;
reg         sdram_wr     ;
reg         sdram_rd     ;
wire [7:0]  sdram_dout   ; 
reg  [7:0]  sdram_din    ; 

always @(*) begin
	if(is_downloading && download_wr) begin
		sdram_din    = download_data;
		sdram_addr   = download_addr;
		sdram_wr     = download_wr;
		sdram_rd     = 1'b1;
		sdram_clkref = F14M;
	end	
	else if(eraser_busy) begin		
		sdram_din    = eraser_data;
		sdram_addr   = eraser_addr;
		sdram_wr     = eraser_wr;
		sdram_rd     = 1'b1;		
		sdram_clkref = F14M;
	end	
	else begin
		sdram_din    = vdc_sdram_din;
		sdram_addr   = vdc_sdram_addr;
		sdram_wr     = vdc_sdram_wr;
		sdram_rd     = vdc_sdram_rd;
		sdram_clkref = F14M;
	end	
end

wire CPU_RESET = ~boot_completed | is_downloading | eraser_busy | reset;
// the keyboard's Reset key drives the Z80 /RES line (and bank 0 back to the
// ROM) only: RAM and video keep running and the ROM does a warm start
assign SYS_RESET = CPU_RESET | reset_key;
wire BLANK     = ~boot_completed | is_downloading | eraser_busy;

/******************************************************************************************/
/******************************************************************************************/
/***************************************** @audio *****************************************/
/******************************************************************************************/
/******************************************************************************************/
// latches cassette input

reg CASIN;
always @(posedge F14M) begin
	CASIN <= ~UART_RX;
end

wire BUZZER;
wire CASOUT;

//
// BUZZER for emulating the keyboard builtin speaker
// CASIN for tape monitor
// CASOUT for save to tape wire
// One level on the 16-bit unsigned output (AUDIO_S = 0).
//
wire speaker = BUZZER ^ CASIN ^ (~CASOUT);

always @(posedge F14M) begin
	AUDIO_L <= speaker ? 16'h4000 : 16'h0000;
	AUDIO_R <= speaker ? 16'h4000 : 16'h0000;
end

dpram #(8, 18) dpram
(
	.address_a(sdram_addr[17:0]),
	.clock_a(F14Mx2),
	.data_a(sdram_din),
	.q_a(sdram_dout),
	.wren_a(sdram_wr)
);

endmodule