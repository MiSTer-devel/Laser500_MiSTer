// tape_overlay.sv - one box in the bottom-left corner of the picture for the
// tape status bar and the next-step hints (~/dev2/tape-standard.md rules
// 19-28). Mixed into the VTL's RGB before video_mixer; it never changes the
// machine. Text uses the MC6847 internal font (intfont.svh). Everything runs
// on F14M, one machine pixel per clock, the clock the tape player and the
// video run on, so the status needs no clock-domain handshake (rule 24).
// The outputs are registered: colour, syncs and blanking leave one clock
// later, together.
//
// What it shows (Tape overlay On), first match wins:
//  1. the deck playing:   TAPE > 0:09/ 1:24 X2  and a 64-step bar
//  2. the deck stopped, the ROM back at Ready after a good load it did not
//     start (CLOAD of BASIC, or a z88dk-style F1 file, laser500.sv):
//                                             TYPE RUN <ret>
//  3. the deck stopped, the tape at its start (mounted / rewound):
//                                             TYPE CRUN <ret>
//     CRUN loads BASIC (type F0) and starts it, and loads machine code (F1)
//     and jumps to it. It is a guess the tape does not state:
//     tools/laser500_tape.py found F0/F1 as the first file of every tape in
//     the corpus (docs/CASSETTE_STATUS.md).
//  each hint until Return (or a reset, a mount, a rewind).
//
// With the 216p vertical crop on, the box sits at the bottom of the lines
// video_freak keeps (CROP_SIZE 216, CROP_OFF 4), not of the whole picture.
module tape_overlay (
    input  logic        clk,
    input  logic        reset,        // machine reset
    input  logic        tape_en,      // OSD Tape overlay
    input  logic        vcrop,        // the 216-line crop is on
    // tape
    input  logic        tape_loaded,
    input  logic        tape_playing,
    input  logic        tape_fast,
    input  logic        tape_at_start,
    input  logic [31:0] tape_pos,
    input  logic [31:0] tape_len,
    input  logic [17:0] tape_hz,
    input  logic        tape_ready,   // pulse: mounted or rewound
    input  logic        need_run,// pulse: Ready after a load that needs RUN
    // keyboard (hps_io ps2_key: bit 10 toggles per event, 9 pressed)
    input  logic [10:0] ps2_key,
    // video in
    input  logic        hblank, vblank, hs, vs,
    input  logic  [5:0] r_in, g_in, b_in,
    // video out (one clock later)
    output logic        hblank_o, vblank_o, hs_o, vs_o,
    output logic  [5:0] r_out, g_out, b_out,
    // for the simulator's checks
    output logic        show_bar,     // tape status bar on screen
    output logic  [1:0] show_tape     // tape hint on screen: 1 CRUN, 2 RUN
);
    logic old_key;
    wire  return_key = ps2_key[10] != old_key && ps2_key[9] && ps2_key[7:0] == 8'h5A;  // Return, keypad Enter

    // ---- hints -----------------------------------------------------------
    logic crun_done, want_run;
    initial begin old_key = 0; crun_done = 0; want_run = 0; end

    always_ff @(posedge clk) begin
        old_key <= ps2_key[10];
        if (tape_ready) begin crun_done <= 0; want_run <= 0; end
        if (need_run && tape_loaded) want_run <= 1;
        if (return_key) begin
            want_run <= 0;
            if (tape_loaded && tape_at_start) crun_done <= 1;
        end
        if (reset) want_run <= 0;
    end

    assign show_bar  = tape_en && tape_loaded && tape_playing;
    assign show_tape = show_bar || !tape_en || !tape_loaded || tape_playing ? 2'd0 :
                       want_run ? 2'd2 : (tape_at_start && !crun_done) ? 2'd1 : 2'd0;

    // ---- tape times (BCD m:ss, saturating at 99:59) and bar fill ---------
    logic [15:0] elapsed, total;
    logic [17:0] frac;
    logic [31:0] last_pos, last_len, rem, cell_count;
    logic [17:0] last_hz;
    logic [6:0]  fill;
    logic        computing;
    initial begin
        elapsed = 0; total = 0; frac = 0; last_pos = 0; last_len = 0; last_hz = 0;
        rem = 0; cell_count = 0; fill = 0; computing = 0;
    end

    function automatic logic [15:0] bcd_tick(input logic [15:0] t);
        logic [15:0] n;
        n = t;
        if (t == 16'h9959) return t;
        if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
        else begin
            n[3:0] = 0;
            if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
            else begin
                n[7:4] = 0;
                if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
                else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
            end
        end
        return n;
    endfunction

    // the bar advances one step per 1/64 of the samples
    wire [31:0] cell_samples = tape_len[31:6] == 0 ? 32'd1 : {6'd0, tape_len[31:6]};
    always_ff @(posedge clk) begin
        last_pos <= tape_pos;
        if (tape_pos == 0 || tape_pos < last_pos) begin
            elapsed <= 0; frac <= 0; fill <= 0; cell_count <= 0;
        end else if (tape_pos != last_pos) begin
            if (frac + 18'd1 >= tape_hz) begin frac <= 0; elapsed <= bcd_tick(elapsed); end
            else frac <= frac + 18'd1;
            if (cell_count + 32'd1 >= cell_samples) begin
                cell_count <= 0;
                if (fill != 7'd64) fill <= fill + 7'd1;
            end else cell_count <= cell_count + 32'd1;
        end
        last_len <= tape_len; last_hz <= tape_hz;
        if (tape_len != last_len || tape_hz != last_hz) begin
            rem <= tape_len; total <= 0; computing <= tape_hz != 0;
        end else if (computing) begin
            if (rem >= {14'd0, tape_hz}) begin rem <= rem - {14'd0, tape_hz}; total <= bcd_tick(total); end
            else computing <= 0;
        end
    end

    // ---- picture position (measured, rule 23) ----------------------------
    logic [10:0] x, width;
    logic [9:0]  y, height;
    logic        line_active, old_hblank, old_vblank;
    initial begin x = 0; y = 0; width = 0; height = 0; line_active = 0; old_hblank = 0; old_vblank = 0; end

    always_ff @(posedge clk) begin
        old_hblank <= hblank; old_vblank <= vblank;
        if (!hblank && !vblank) begin x <= x + 11'd1; line_active <= 1; end
        if (hblank && !old_hblank) begin
            if (line_active) begin width <= x; y <= y + 10'd1; end
            x <= 0; line_active <= 0;
        end
        if (vblank && !old_vblank) begin height <= y; y <= 0; end
    end

    `include "intfont.svh"

    // ---- text ------------------------------------------------------------
    localparam logic [7:0] RET = 8'h01, PLAY = 8'h03;
    localparam logic [8*11-1:0] T_RUN  = {"TYPE RUN ", RET, " "};
    localparam logic [8*11-1:0] T_CRUN = {"TYPE CRUN ", RET};

    wire        visible = show_bar || show_tape != 0;
    wire [4:0]  chars = show_bar ? 5'd21 : show_tape == 2'd1 ? 5'd11 : 5'd10;

    // doubled on wide / tall pictures (rule 21)
    // (the 216p crop shows 216 lines: not doubled, it is scaled 5x instead)
    wire        cropped = vcrop && height > 10'd216;
    wire        sx = width >= 11'd512, sy = height >= 10'd300 && !cropped;
    wire [10:0] box_w = {3'd0, chars, 3'd0} + 11'd4;
    wire [9:0]  box_h = show_bar ? 10'd18 : 10'd12;
    // bottom of what is shown: the picture, or video_freak's crop window
    wire [9:0]  crop_top = 10'((height - 10'd216 + 10'd8) >> 1);
    wire [9:0]  bottom = cropped ? crop_top + 10'd216 : height;
    wire [10:0] x0 = 11'd4;
    wire [9:0]  y0 = bottom - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
    wire [10:0] dx = x - x0;
    wire [9:0]  dy = y - y0;
    wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
    wire [9:0]  ly = sy ? {1'b0, dy[9:1]} : dy;
    wire        in_box = visible && height > 10'd40 && x >= x0 && y >= y0 && lx < box_w && ly < box_h;

    wire [10:0] tx  = lx - 11'd2;
    wire [9:0]  ty  = ly - 10'd2;
    wire [4:0]  col = tx[7:3];

    function automatic logic [7:0] dig(input logic [3:0] d, input logic blank_zero);
        return blank_zero && d == 0 ? 8'h20 : 8'h30 + {4'd0, d};
    endfunction
    logic [7:0] st_ch;     // "TAPE > m:ss/ m:ss X2"
    always_comb begin
        case (col)
            5'd0: st_ch = "T";  5'd1: st_ch = "A";  5'd2: st_ch = "P";  5'd3: st_ch = "E";
            5'd5: st_ch = PLAY;
            5'd7: st_ch = dig(elapsed[15:12], 1'b1);  5'd8: st_ch = dig(elapsed[11:8], 1'b0);
            5'd9: st_ch = ":";  5'd10: st_ch = dig(elapsed[7:4], 1'b0);  5'd11: st_ch = dig(elapsed[3:0], 1'b0);
            5'd12: st_ch = "/";
            5'd13: st_ch = dig(total[15:12], 1'b1);  5'd14: st_ch = dig(total[11:8], 1'b0);
            5'd15: st_ch = ":";  5'd16: st_ch = dig(total[7:4], 1'b0);  5'd17: st_ch = dig(total[3:0], 1'b0);
            5'd19: st_ch = tape_fast ? "X" : " ";  5'd20: st_ch = tape_fast ? "2" : " ";
            default: st_ch = " ";
        endcase
    end
    wire [7:0] hint_ch = col >= 5'd11 ? 8'h20 :
                         show_tape == 2'd1 ? T_CRUN[8*11-1 - 8*col -: 8] : T_RUN[8*11-1 - 8*col -: 8];
    wire [7:0] ch = show_bar ? st_ch : hint_ch;

    logic [7:0] glyph_row;
    always_comb begin
        case (ch)
            RET:  glyph_row = 8'(64'h02022262FE602000 >> (8 * (7 - ty[2:0])));
            PLAY: glyph_row = 8'(64'h4060707870604000 >> (8 * (7 - ty[2:0])));
            default: glyph_row = ch >= 8'h20 && ch < 8'h60 ? intfont(ch[5:0], {1'b0, ty[2:0]} + 4'd2) : 8'h00;
        endcase
    end
    wire text_on  = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && glyph_row[3'd7 - tx[2:0]];
    wire bar_area = show_bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
    wire bar_on   = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

    always_ff @(posedge clk) begin
        {hblank_o, vblank_o, hs_o, vs_o} <= {hblank, vblank, hs, vs};
        {r_out, g_out, b_out} <= {r_in, g_in, b_in};
        if (in_box && !hblank && !vblank)
            {r_out, g_out, b_out} <= text_on && !bar_area ? {6'h3F, 6'h3F, 6'h3F} :   // white
                                     bar_on   ? {6'h11, 6'h33, 6'h11} :                 // green
                                     bar_area ? {6'h0C, 6'h0C, 6'h0C} :                 // dark grey
                                                18'd0;
    end
endmodule
