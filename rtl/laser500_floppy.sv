//============================================================================
// VTech Laser 500/700 floppy interface (Laser 700 built in, Laser 350/500
// add-on) and two drives. See docs/DISK.md for the sources of every rule here.
//
// Ports (decoded by the caller as 10h-13h, A[1:0] here):
//   OUT 10h latch 1: b7 side, b6 /WREQ (0 = write), b5 drive select,
//           b4 drive enable (motor), b3-0 stepper phases
//   OUT 11h latch 2 (self-sync / data size): stored, no effect at byte level
//   IN  12h status: b7 read: byte ready / write: buffer empty, b0 write protect
//   IN  13h data latch (clears ready). OUT 13h data latch (clears empty).
//   With the drive disabled the data latch reads back what was written: the
//   ROM uses this loopback to detect the interface.
//
// Disk model: one 8 KB nibble track buffer (raw bytes as the CPU sees them,
// MSB always 1), the .nic layout of laser500emu. A byte passes under the head
// at most every 32 us (473 clocks of F14M) and never before the CPU took the
// last one (no overrun, see "disk rotation"); the position is shared by both
// drives and kept across track changes, as in laser500emu.
// Stepper: floppy.ts rule, half-track steps, odd half-tracks read the track
// below.
//
// Images (by size):
//   327680  .nic, 40 tracks x 8192, 1 side       (read/write)
//   335872  .nic, 41 tracks x 8192, 1 side       (read/write)
//   655360  .nic, 40 tracks x 8192, 2 sides      (read/write)
//   163840  .dsk, 40 tracks x 16 x 256, 1 side   (read only for now: mounted
//           write protected so VT-DOS reports error 4 instead of losing data)
// A .nic track is 16 SD blocks loaded and stored as is. A .dsk track is 8
// blocks, nibblized into the buffer in "layout A" (docs/DISK.md 5.2): sector k
// at k*512: FF x8, D5 AA 96, 4&4 vol trk sec cks, DE AA, FF x8, D5 AA AD,
// 343 6-and-2 nibbles, DE AA, FF to the end. tools/laser500_disk.py is the
// reference model.
// A dirty track is written back when the head leaves it and when the motor
// is switched off.
//============================================================================

module laser500_floppy
(
	input             clk,             // F14M
	input             reset,

	// CPU side: one-clock strobes for an I/O access to ports 10h-13h
	input             io_rd,
	input             io_wr,
	input       [1:0] io_port,
	input       [7:0] io_din,
	output      [7:0] io_dout,

	output            active,          // a drive is enabled (LED)

	// hps_io, drives 0 and 1 (S0/S1), BLKSZ = 512
	input       [1:0] img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg  [5:0] sd_blk_cnt,
	output reg  [1:0] sd_rd,
	output reg  [1:0] sd_wr,
	input       [1:0] sd_ack,
	input      [13:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	output      [1:0] mounted          // image in drive 0/1
);

localparam [8:0] BYTE_CLKS = 9'd473;   // 32 us at 14.77 MHz

// ---------------------------------------------------------------- registers
reg  [7:0] latch1 = 8'h40;
reg  [7:0] latch2 = 8'hFF;
reg  [7:0] data   = 8'h00;
reg        ready;          // read mode: byte waiting in the latch
reg        empty;          // write mode: buffer empty
reg        wr_full;        // write mode: a byte waits to be written

wire       side   = latch1[7];
wire       wreq_n = latch1[6];
wire       drv    = latch1[5];
wire       enbl   = latch1[4];

// per drive
reg  [1:0] img_in;
reg  [1:0] img_dsk;
reg  [1:0] img_wp;
reg  [1:0] img_41;
reg  [1:0] img_2s;
reg  [6:0] track_x2 [2];

assign mounted = img_in;
assign active  = enbl;

wire       cur_in  = img_in[drv];
wire       cur_wp  = img_wp[drv] | ~cur_in;
wire       cur_2s  = img_2s[drv];
wire [6:0] cur_x2  = track_x2[drv];
wire [5:0] cur_trk = cur_x2[6:1];
wire       cur_sd  = cur_2s & side;           // side 1 only exists on 2-sided images

assign io_dout = (io_port == 2'd2) ? { (wreq_n ? ready : empty), 6'd0, cur_wp } :
                 (io_port == 2'd3) ? data : 8'h00;

// ---------------------------------------------------------------- track buffer (8 KB)
reg  [12:0] pos;                         // rotational position
reg  [12:0] b_addr;
reg   [7:0] b_din;
reg         b_we;
reg   [7:0] buf_q_a, buf_q_b;
reg   [7:0] tbuf [8192];
// port A: one address (pos) for read and write, so the RAM maps to a
// true dual-port block; the write happens on the tick, before pos moves on
wire        a_we;
// Quartus true dual-port template (new data on a same-port write)
always @(posedge clk) begin
	if (a_we) begin tbuf[pos] <= data; buf_q_a <= data; end
	else buf_q_a <= tbuf[pos];
end
always @(posedge clk) begin
	if (b_we) begin tbuf[b_addr] <= b_din; buf_q_b <= b_din; end
	else buf_q_b <= tbuf[b_addr];
end

// .dsk staging RAM: one track of sectors (4 KB)
reg  [11:0] s_addr;
reg   [7:0] s_q;
reg   [7:0] stage [4096];
reg         s_we;
reg  [11:0] s_waddr;
reg   [7:0] s_wdata;
always @(posedge clk) begin
	if (s_we) stage[s_waddr] <= s_wdata;
	s_q <= stage[s_addr];
end

assign sd_buff_din = buf_q_b;

// ---------------------------------------------------------------- GCR 6-and-2
function [7:0] gcr(input [5:0] v);
	case (v)
		6'd0:  gcr = 8'h96; 6'd1:  gcr = 8'h97; 6'd2:  gcr = 8'h9A; 6'd3:  gcr = 8'h9B;
		6'd4:  gcr = 8'h9D; 6'd5:  gcr = 8'h9E; 6'd6:  gcr = 8'h9F; 6'd7:  gcr = 8'hA6;
		6'd8:  gcr = 8'hA7; 6'd9:  gcr = 8'hAB; 6'd10: gcr = 8'hAC; 6'd11: gcr = 8'hAD;
		6'd12: gcr = 8'hAE; 6'd13: gcr = 8'hAF; 6'd14: gcr = 8'hB2; 6'd15: gcr = 8'hB3;
		6'd16: gcr = 8'hB4; 6'd17: gcr = 8'hB5; 6'd18: gcr = 8'hB6; 6'd19: gcr = 8'hB7;
		6'd20: gcr = 8'hB9; 6'd21: gcr = 8'hBA; 6'd22: gcr = 8'hBB; 6'd23: gcr = 8'hBC;
		6'd24: gcr = 8'hBD; 6'd25: gcr = 8'hBE; 6'd26: gcr = 8'hBF; 6'd27: gcr = 8'hCB;
		6'd28: gcr = 8'hCD; 6'd29: gcr = 8'hCE; 6'd30: gcr = 8'hCF; 6'd31: gcr = 8'hD3;
		6'd32: gcr = 8'hD6; 6'd33: gcr = 8'hD7; 6'd34: gcr = 8'hD9; 6'd35: gcr = 8'hDA;
		6'd36: gcr = 8'hDB; 6'd37: gcr = 8'hDC; 6'd38: gcr = 8'hDD; 6'd39: gcr = 8'hDE;
		6'd40: gcr = 8'hDF; 6'd41: gcr = 8'hE5; 6'd42: gcr = 8'hE6; 6'd43: gcr = 8'hE7;
		6'd44: gcr = 8'hE9; 6'd45: gcr = 8'hEA; 6'd46: gcr = 8'hEB; 6'd47: gcr = 8'hEC;
		6'd48: gcr = 8'hED; 6'd49: gcr = 8'hEE; 6'd50: gcr = 8'hEF; 6'd51: gcr = 8'hF2;
		6'd52: gcr = 8'hF3; 6'd53: gcr = 8'hF4; 6'd54: gcr = 8'hF5; 6'd55: gcr = 8'hF6;
		6'd56: gcr = 8'hF7; 6'd57: gcr = 8'hF9; 6'd58: gcr = 8'hFA; 6'd59: gcr = 8'hFB;
		6'd60: gcr = 8'hFC; 6'd61: gcr = 8'hFD; 6'd62: gcr = 8'hFE; default: gcr = 8'hFF;
	endcase
endfunction

function [1:0] rev2(input [1:0] x); rev2 = {x[0], x[1]}; endfunction

// 4&4: first byte (x>>1)|AA, second x|AA
function [7:0] enc44(input [7:0] x, input second);
	enc44 = second ? (x | 8'hAA) : ({1'b0, x[7:1]} | 8'hAA);
endfunction

// ---------------------------------------------------------------- track buffer state
reg        tag_ok;                 // buffer holds tag_drv/tag_sd/tag_trk
reg        tag_drv, tag_sd;
reg  [5:0] tag_trk;
reg        dirty;
reg  [1:0] stale;

wire       want_change = ~tag_ok | (tag_drv != drv) | (tag_sd != cur_sd) | (tag_trk != cur_trk);

localparam ST_IDLE  = 4'd0, ST_FLUSH = 4'd1, ST_FLUSHW = 4'd2, ST_LOAD = 4'd3, ST_LOADW = 4'd4,
           ST_BLANK = 4'd5, ST_AUX   = 4'd6, ST_EMIT  = 4'd7, ST_FILL = 4'd8;
reg  [3:0] st = ST_IDLE;
wire       busy = (st != ST_IDLE);

// nibblizer
reg  [3:0] n_sec;
reg  [8:0] n_i;           // byte in the 512-byte sector block / aux byte counter
reg  [6:0] n_jm;          // n_i mod 86 during AUX
reg  [1:0] n_jd;          // n_i / 86 during AUX
reg  [1:0] n_ph;          // 0 issue stage address, 1 wait, 2 use s_q
reg  [5:0] aux [86];
reg  [5:0] n_prev;
reg  [5:0] ld_trk;
reg        ld_drv;

// fill after a long write burst (format): FF to the end of the 8 KB
reg [12:0] wr_count;
reg [12:0] fill_left;

// byte clock
reg  [8:0] tick_cnt;
wire       tick = (tick_cnt == BYTE_CLKS - 1'd1);

reg        old_enbl;
reg        old_wreq_n;
reg  [1:0] old_ack;
reg        flush_on_stop;

assign a_we = tick && enbl && cur_in && !busy && !want_change && !wreq_n && wr_full && !cur_wp;

// nibblizer byte n_i of sector block n_sec (layout A)
wire [8:0] n_k    = n_i - 9'd32;              // data nibble index when n_i is 32..374
wire [7:0] n_k86  = n_k[7:0] - 8'd86;         // sector byte for nibbles 86..341
wire [5:0] n_sval = (n_k < 9'd86) ? aux[n_k[6:0]] : s_q[7:2];
wire [7:0] n_vol  = 8'h00;
wire [7:0] n_trk  = {2'd0, ld_trk};
wire [7:0] n_snum = {4'd0, n_sec};
wire [7:0] n_cks  = n_vol ^ n_trk ^ n_snum;
reg  [7:0] emit_byte;
always @(*) begin
	emit_byte = 8'hFF;
	case (n_i)
		9'd8:  emit_byte = 8'hD5;
		9'd9:  emit_byte = 8'hAA;
		9'd10: emit_byte = 8'h96;
		9'd11: emit_byte = enc44(n_vol, 0);
		9'd12: emit_byte = enc44(n_vol, 1);
		9'd13: emit_byte = enc44(n_trk, 0);
		9'd14: emit_byte = enc44(n_trk, 1);
		9'd15: emit_byte = enc44(n_snum, 0);
		9'd16: emit_byte = enc44(n_snum, 1);
		9'd17: emit_byte = enc44(n_cks, 0);
		9'd18: emit_byte = enc44(n_cks, 1);
		9'd19: emit_byte = 8'hDE;
		9'd20: emit_byte = 8'hAA;
		9'd29: emit_byte = 8'hD5;
		9'd30: emit_byte = 8'hAA;
		9'd31: emit_byte = 8'hAD;
		9'd375: emit_byte = 8'hDE;
		9'd376: emit_byte = 8'hAA;
		default:
			if (n_i >= 9'd32 && n_i < 9'd374) emit_byte = gcr(n_sval ^ n_prev);
			else if (n_i == 9'd374)           emit_byte = gcr(n_prev);
	endcase
end

// ---------------------------------------------------------------- main
wire [3:0] ph_new = io_din[3:0];
wire [3:0] ph_old = latch1[3:0];
wire       one_ph = (ph_new == 4'b0001) | (ph_new == 4'b0010) | (ph_new == 4'b0100) | (ph_new == 4'b1000);
// next-higher phase was on -> outward (-1); next-lower -> inward (+1)
wire       step_out = one_ph & |(ph_new & {ph_old[0], ph_old[3:1]});
wire       step_in  = one_ph & |(ph_new & {ph_old[2:0], ph_old[3]});

always @(posedge clk) begin
	b_we  <= 0;
	s_we  <= 0;
	old_ack <= sd_ack;

	tick_cnt <= tick ? 9'd0 : tick_cnt + 1'd1;

	// ---- image mount
	for (int d = 0; d < 2; d++) begin
		if (img_mounted[d]) begin
			img_in[d]  <= (img_size == 64'd327680) || (img_size == 64'd335872) ||
			              (img_size == 64'd655360) || (img_size == 64'd163840);
			img_dsk[d] <= (img_size == 64'd163840);
			img_wp[d]  <= img_readonly | (img_size == 64'd163840);
			img_41[d]  <= (img_size == 64'd335872);
			img_2s[d]  <= (img_size == 64'd655360);
			track_x2[d] <= 7'd0;
			stale[d] <= 1;          // new image: drop the buffer if it holds this drive
		end
	end

	// ---- CPU writes
	if (io_wr) begin
		case (io_port)
			2'd0: begin
				latch1 <= io_din;
				if (io_din[4]) begin   // ENBL: the head of the selected drive moves
					if (step_out && track_x2[io_din[5]] != 7'd0)
						track_x2[io_din[5]] <= track_x2[io_din[5]] - 1'd1;
					else if (step_in && track_x2[io_din[5]] < (img_41[io_din[5]] ? 7'd81 : 7'd79))
						track_x2[io_din[5]] <= track_x2[io_din[5]] + 1'd1;
				end
			end
			2'd1: latch2 <= io_din;
			2'd3: begin data <= io_din; wr_full <= 1; empty <= 0; end
			default: ;
		endcase
	end
	if (io_rd && io_port == 2'd3) ready <= 0;

	// ---- write request edges
	old_wreq_n <= wreq_n;
	old_enbl   <= enbl;
	if (old_wreq_n & ~wreq_n) begin       // start of a write: buffer empty at once
		empty    <= 1;
		wr_count <= 0;
	end
	if (~old_wreq_n & wreq_n & enbl & (wr_count > 13'd400) & ~busy) begin
		fill_left <= 13'd8191 - wr_count;  // a format: clear the stale rest of the track
		b_addr    <= pos;
		st        <= ST_FILL;
	end
	if (old_enbl & ~enbl & dirty) flush_on_stop <= 1;

	// ---- disk rotation
	// No overrun, as laser500emu: a byte is presented at most every 32 us, but
	// only once the CPU has taken the previous one (read), and a byte is written
	// only when the CPU has supplied one (write). The CPU in this core (one wait
	// per memory cycle, as laser500emu) misses bytes in the ROM's address-field
	// reader at a strict 32 us. While the CPU does not access the disk the head
	// stays where it is.
	if (tick && enbl && cur_in && !busy && !want_change) begin
		if (wreq_n) begin
			if (!ready) begin
				data  <= buf_q_a;          // tbuf[pos], pos stable since the last tick
				ready <= 1;
				pos   <= pos + 1'd1;
			end
		end
		else if (wr_full && !cur_wp) begin
			wr_full  <= 0;                 // a_we writes the latch at pos
			empty    <= 1;
			dirty    <= 1;
			wr_count <= wr_count + 1'd1;
			pos      <= pos + 1'd1;
		end
	end

	// ---- track buffer state machine
	case (st)
	ST_IDLE: begin
		if (|stale) begin
			if (stale[tag_drv]) begin tag_ok <= 0; dirty <= 0; end
			stale <= 0;
		end
		else if (dirty && (want_change || flush_on_stop) && tag_ok && !img_dsk[tag_drv]) begin
			// write the buffer back: 16 blocks
			sd_lba     <= {21'd0, (tag_sd ? (img_41[tag_drv] ? 7'd41 : 7'd40) : 7'd0) + tag_trk, 4'd0};
			sd_blk_cnt <= 6'd15;
			sd_wr[tag_drv] <= 1;
			st <= ST_FLUSHW;
		end
		else if (want_change) begin
			flush_on_stop <= 0;
			dirty  <= 0;
			tag_ok <= 0;
			ld_drv <= drv;
			ld_trk <= cur_trk;
			tag_drv <= drv;
			tag_sd  <= cur_sd;
			tag_trk <= cur_trk;
			if (!cur_in || cur_trk >= (img_41[drv] ? 6'd41 : 6'd40)) begin
				b_addr <= 0;
				st <= ST_BLANK;
			end
			else if (img_dsk[drv]) begin
				sd_lba     <= {23'd0, cur_trk, 3'd0};
				sd_blk_cnt <= 6'd7;
				sd_rd[drv] <= 1;
				st <= ST_LOADW;
			end
			else begin
				sd_lba     <= {21'd0, (cur_sd ? (img_41[drv] ? 7'd41 : 7'd40) : 7'd0) + cur_trk, 4'd0};
				sd_blk_cnt <= 6'd15;
				sd_rd[drv] <= 1;
				st <= ST_LOADW;
			end
		end
		else begin
			if (!dirty) flush_on_stop <= 0;
			// buffer port B follows the SD address (registered read for sd_buff_din)
			b_addr <= sd_buff_addr[12:0];
		end
	end

	// write back: hps_io reads sd_buff_din at sd_buff_addr
	ST_FLUSHW: begin
		b_addr <= sd_buff_addr[12:0];
		if (sd_ack[tag_drv]) sd_wr <= 0;
		if (old_ack[tag_drv] & ~sd_ack[tag_drv]) begin
			dirty <= 0;
			flush_on_stop <= 0;
			st <= ST_IDLE;
		end
	end

	// load: hps_io writes sd_buff_dout at sd_buff_addr
	ST_LOADW: begin
		if (sd_ack[ld_drv]) sd_rd <= 0;
		if (sd_buff_wr & sd_ack[ld_drv]) begin
			if (img_dsk[ld_drv]) begin
				s_we    <= 1;
				s_waddr <= sd_buff_addr[11:0];
				s_wdata <= sd_buff_dout;
			end
			else begin
				b_we   <= 1;
				b_addr <= sd_buff_addr[12:0];
				b_din  <= sd_buff_dout;
			end
		end
		if (old_ack[ld_drv] & ~sd_ack[ld_drv]) begin
			if (img_dsk[ld_drv]) begin
				n_sec <= 0;
				n_i   <= 0; n_jm <= 0; n_jd <= 0; n_ph <= 0;
				for (int k = 0; k < 86; k++) aux[k] <= 6'd0;
				st <= ST_AUX;
			end
			else begin
				tag_ok <= 1;
				st <= ST_IDLE;
			end
		end
	end

	ST_BLANK: begin
		b_we  <= 1;
		b_din <= 8'hFF;
		if (b_we) b_addr <= b_addr + 1'd1;
		if (b_we && b_addr == 13'd8191) begin
			b_we   <= 0;
			tag_ok <= 1;
			st     <= ST_IDLE;
		end
	end

	ST_FILL: begin
		b_we  <= 1;
		b_din <= 8'hFF;
		if (b_we) begin
			b_addr    <= b_addr + 1'd1;
			fill_left <= fill_left - 1'd1;
			if (fill_left == 13'd1) begin b_we <= 0; st <= ST_IDLE; end
		end
	end

	// .dsk: aux values of sector n_sec (low 2 bits of each byte, bit-swapped)
	ST_AUX: begin
		case (n_ph)
			2'd0: begin s_addr <= {n_sec, n_i[7:0]}; n_ph <= 2'd1; end
			2'd1: n_ph <= 2'd2;
			default: begin
				n_ph <= 2'd0;
				case (n_jd)
					2'd0: aux[n_jm] <= aux[n_jm] | {4'd0, rev2(s_q[1:0])};
					2'd1: aux[n_jm] <= aux[n_jm] | {2'd0, rev2(s_q[1:0]), 2'd0};
					default: aux[n_jm] <= aux[n_jm] | {rev2(s_q[1:0]), 4'd0};
				endcase
				if (n_jm == 7'd85) begin n_jm <= 0; n_jd <= n_jd + 1'd1; end
				else n_jm <= n_jm + 1'd1;
				if (n_i == 9'd255) begin
					n_i    <= 0;
					n_prev <= 0;
					st     <= ST_EMIT;
				end
				else n_i <= n_i + 1'd1;
			end
		endcase
	end

	// .dsk: the 512 bytes of sector block n_sec
	ST_EMIT: begin
		case (n_ph)
			2'd0: begin s_addr <= {n_sec, n_k86}; n_ph <= 2'd1; end
			2'd1: n_ph <= 2'd2;
			default: begin
				n_ph   <= 2'd0;
				b_we   <= 1;
				b_addr <= {n_sec, n_i};
				b_din  <= emit_byte;
				if (n_i >= 9'd32 && n_i < 9'd374) n_prev <= n_sval;
				if (n_i == 9'd511) begin
					n_i <= 0; n_jm <= 0; n_jd <= 0;
					for (int k = 0; k < 86; k++) aux[k] <= 6'd0;
					if (n_sec == 4'd15) begin
						tag_ok <= 1;
						st     <= ST_IDLE;
					end
					else begin
						n_sec <= n_sec + 1'd1;
						st    <= ST_AUX;
					end
				end
				else n_i <= n_i + 1'd1;
			end
		endcase
	end

	default: st <= ST_IDLE;
	endcase

	if (reset) begin
		latch1 <= 8'h40;
		latch2 <= 8'hFF;
		ready  <= 0;
		empty  <= 0;
		wr_full <= 0;
	end
end

endmodule
