
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
	input wire         sd_buff_wr,

	// tape (hps_io S2, rtl/laser500_tape.sv); img_size and sd_buff_* shared with the floppy
	input wire        tape_mounted,
	output wire [31:0] tape_sd_lba,
	output wire       tape_sd_rd,
	input wire        tape_sd_ack,
	input wire        tape_rewind,     // OSD Rewind tape (pulse)
	input wire        tape_turbo_en,   // OSD Tape speed 2x
	input wire        tape_deck_play,  // OSD Tape deck: Play
	input wire        tape_audio_en,   // OSD Tape audio
	input wire  [1:0] tape_pitch,      // OSD Tape pitch: 0 Normal, 1 +1.6%, 2 -1.6%
	output wire       tape_ready,      // pulse: mounted/rewound, playable
	output wire       tape_bad,        // pulse: format not supported
	output wire       tape_loaded,
	output wire       tape_playing,
	output wire       tape_fast,
	output wire       tape_at_start,
	output wire [31:0] tape_pos,
	output wire [31:0] tape_len,
	output wire [17:0] tape_hz,
	output wire       tape_need_run, // pulse: Ready after a load that needs RUN
	output wire [15:0] tape_underflows
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
wire [17:0] cpu_ram_addr;
wire  [7:0] cpu_ram_din, cpu_ram_dout;
wire        cpu_ram_wr;
wire  [3:0] cpu_bank;
wire        CASIN, TAPE_LEVEL;      // cassette input (@audio below)
wire        BUZZER, CASOUT;
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
	.TURBO    ( tape_fast     ),
	.cpu_bank ( cpu_bank      ),
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

	.cpu_ram_addr ( cpu_ram_addr     ),
	.cpu_ram_din  ( cpu_ram_din      ),
	.cpu_ram_wr   ( cpu_ram_wr       ),
	.cpu_ram_dout ( cpu_ram_dout     ),
	
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
// Cassette. CASIN is bit 7 of the mapped I/O read: the tape player. (The
// emu's UART_RX is the HPS UART's TX, not a cassette line: it is not used.)
//
// The Laser has no motor relay: the deck plays while the CPU runs the BASIC
// ROM's tape-read code, 1714h-19DEh (CLOAD 1714h, CRUN 1958h, VERIFY 1962h,
// RDBYET 1865h through the block header 19BCh), held for 71 ms after the
// last fetch there so the ROM's calls out (printing FOUND, bank switching)
// don't stop it. OSD Tape deck Play keeps it playing whenever a tape is
// mounted, for programs with their own loaders. While the ROM reads with
// Tape speed 2x, the CPU (VTL_chip TURBO) and the tape run 2x (tape
// standard rule 7); never outside the ROM's tape code (rule 6).
assign      CASIN = TAPE_LEVEL;

wire        tape_rom_pc = !cpu_m1_n && !cpu_mreq_n && cpu_bank == 4'd0 &&
                          cpu_addr >= 16'h1714 && cpu_addr <= 16'h19DE;
reg  [19:0] tape_hold = 0;
always @(posedge F14M)
	if (tape_rom_pc)          tape_hold <= 20'hFFFFF;
	else if (tape_hold != 0)  tape_hold <= tape_hold - 20'd1;
wire        tape_rom  = tape_hold != 0;
wire        tape_play = tape_rom | tape_deck_play;

// overlay TYPE RUN: the ROM prints Ready (reads the string at 21A8h, from
// 22E9h, 3717h or 58E5h) after a good load (1766h, checksum passed) that it
// did not run itself: CLOAD of BASIC, or a machine-code file that returned.
// z88dk/laser500-wav programs are type F1 loaded at 8995h, the BASIC area: the ROM's jump there (176Dh) passes through RUN's code (27B4h)
// without starting the program, which needs RUN typed (sim: ROM_CRC.wav).
// CRUN of BASIC starts it: 1796h jumps to 27B4h, and that clears the flag.
reg         m1_seen, rd_seen;
reg         tape_good_load = 0;
reg  [15:0] last_m1;
wire        m1_rom = !cpu_m1_n && !cpu_mreq_n && !m1_seen && cpu_bank == 4'd0;
always @(posedge F14M) if (m1_rom) last_m1 <= cpu_addr;
wire        rd_ready = cpu_m1_n && !cpu_mreq_n && !cpu_rd_n && !rd_seen &&
                       cpu_bank == 4'd0 && cpu_addr == 16'h21A8;
always @(posedge F14M) begin
	m1_seen <= !cpu_m1_n && !cpu_mreq_n;
	rd_seen <= !cpu_mreq_n && !cpu_rd_n;
	if (CPU_RESET)                          tape_good_load <= 0;
	else if (m1_rom && cpu_addr == 16'h1766) tape_good_load <= 1;
	else if ((m1_rom && cpu_addr == 16'h27B4 && last_m1 == 16'h1796) || rd_ready) tape_good_load <= 0;
end
assign tape_need_run = rd_ready && tape_good_load;

wire tape_at_end;
assign tape_playing = tape_play && tape_loaded && !tape_at_end;

laser500_tape tape
(
	.clk          ( F14M             ),
	.img_mounted  ( tape_mounted     ),
	.img_size     ( img_size         ),
	.sd_lba       ( tape_sd_lba      ),
	.sd_rd        ( tape_sd_rd       ),
	.sd_ack       ( tape_sd_ack      ),
	.sd_buff_addr ( sd_buff_addr[8:0]),
	.sd_buff_dout ( sd_buff_dout     ),
	.sd_buff_wr   ( sd_buff_wr       ),
	.rewind       ( tape_rewind      ),
	.play         ( tape_play        ),
	.turbo_ok     ( tape_turbo_en & tape_rom ),
	.pitch        ( tape_pitch       ),
	.level        ( TAPE_LEVEL       ),
	.loaded       ( tape_loaded      ),
	.fast         ( tape_fast        ),
	.at_start     ( tape_at_start    ),
	.at_end       ( tape_at_end      ),
	.position     ( tape_pos         ),
	.length       ( tape_len         ),
	.hz           ( tape_hz          ),
	.ready_pulse  ( tape_ready       ),
	.bad_pulse    ( tape_bad         ),
	.underflows   ( tape_underflows  )
);

// Sound: the built-in speaker (latch bit 0), one level on the 16-bit
// unsigned output (AUDIO_S = 0). OSD Tape audio On mixes the tape input and
// the cassette output (latch bit 2) in quietly.
wire [15:0] snd_tin  = tape_audio_en && CASIN  ? 16'h0C00 : 16'h0000;
wire [15:0] snd_tout = tape_audio_en && CASOUT ? 16'h0C00 : 16'h0000;

always @(posedge F14M) begin
	AUDIO_L <= (BUZZER ? 16'h4000 : 16'h0000) + snd_tin + snd_tout;
	AUDIO_R <= (BUZZER ? 16'h4000 : 16'h0000) + snd_tin + snd_tout;
end

dpram #(8, 18) dpram
(
	.address_a(sdram_addr[17:0]),
	.clock_a(F14Mx2),
	.data_a(sdram_din),
	.q_a(sdram_dout),
	.wren_a(sdram_wr),

	// the CPU (VTL_chip cpu_ram_*)
	.address_b(cpu_ram_addr),
	.clock_b(F14Mx2),
	.data_b(cpu_ram_din),
	.q_b(cpu_ram_dout),
	.wren_b(cpu_ram_wr)
);

endmodule