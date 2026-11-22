// Headless Verilator harness for the Laser 500 core (no SDL / ImGui).
// Build: make headless  ->  obj_hl/Vtop      Run from verilator/.
// ./obj_hl/Vtop --help lists the options.

#include "Vtop.h"
#include "Vtop___024root.h"
#include "verilated.h"
#include <zlib.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <set>
#include <map>
#include <memory>

static Vtop *top;
static uint64_t ticks = 0;      // clk_2x half periods
static uint64_t cpu_cycles = 0, pix_clocks = 0;
#ifdef SIM_MIXER
static uint64_t mix_nz = 0, mix_ce = 0, mix_de = 0, frk_de = 0, mix_hs_edges = 0, mix_vs_edges = 0;
static int last_mhs = 0, last_mvs = 0;
#endif
static int frame = 0;

// ---------------------------------------------------------------- options
struct Shot { int frame; };
static std::string rom_file = "boot.rom";
static std::string shot_dir = ".";
static std::string shot_prefix = "frame";
static int stop_frame = 200;
static std::set<int> shot_frames;
static int shot_every = 0;
static bool shot_end = false;
static int key_hold = 6, key_gap = 8;     // frames
static std::string audio_out;
static bool io_log = false;
static bool quiet = false;
static bool key_log = false;
static bool fdc_log = false;
static int fdc_force = -1;          // -1 auto (on when a disk is given), 0 off, 1 on
static int sd_latency = 3000;       // F14M clocks before sd_ack
struct DiskOpt { std::string file; int frame; bool ro; std::string save; };
static DiskOpt disk_opt[3] = {{"",0,false,""},{"",0,false,""},{"",0,true,""}};  // 2 = tape
static int tape_pitch = 0;
static bool tape_normal = false, tape_play = false, tape_audio = false, tape_no_overlay = false;
static std::vector<int> rewind_frames;
struct Ioctl { int frame; int index; std::string file; bool done; };
static std::vector<Ioctl> ioctls;
struct KeyText { int frame; std::string text; };
static std::vector<KeyText> key_texts;
struct Dump { int frame; std::string file; };
static std::vector<Dump> dumps;
static std::vector<Dump> track_dumps;
struct Joy { int frame; uint32_t v; int n; };
static std::vector<Joy> joys;
static std::vector<std::pair<int,int>> reset_frames;  // frame, length

static void usage() {
	puts(
"Vtop [options]\n"
"  --rom F               boot ROM loaded on ioctl index 0 at start (default boot.rom)\n"
"  --prg F[@FRAME]       .prg/.bin on index 1 (default frame 60)\n"
"  --ioctl FRAME:IDX:F   any download\n"
"  --stop-at-frame N     (default 200)\n"
"  --reset-at-frame N    pulse reset\n"
"  --send-keys FRAME:TEXT  type (PC layout, \\n Enter, \\b BS, \\e Esc, \\R Reset key)\n"
"  --key-hold N, --key-gap N   frames (default 6/8)\n"
"  --joy FRAME:HEX, --joy2 FRAME:HEX\n"
"  --screenshot N,..  --screenshot-every N  --screenshot-end\n"
"  --screenshot-dir D  --screenshot-prefix P\n"
"  --dump-ram FRAME:F    256 KB of the core's memory (16 KB pages 0-15)\n"
"  --audio-out F.wav     AUDIO_L at 48 kHz\n"
"  --dump-track FRAME:F  the floppy's 8 KB track buffer\n"
"  --io-log              log Z80 IN/OUT\n"
"  --disk1 F[@FRAME], --disk2 F[@FRAME]   mount .nic/.dsk in S0/S1 (default frame 0)\n"
"  --disk1-ro, --disk2-ro   mount read only\n"
"  --disk1-save F, --disk2-save F   write the image (with the core's writes) at exit\n"
"  --fdc on|off          floppy interface (default on when a disk is given)\n"
"  --fdc-log             log floppy port accesses and SD transfers\n"
"  --sd-latency N        F14M clocks before sd_ack (default 3000; tape a quarter)\n"
"  --tape F[@FRAME]      mount a .wav/.cas in the tape slot S2 (default frame 0)\n"
"  --tape-speed normal|2x   OSD Tape speed (default 2x)\n"
"  --tape-deck auto|play    OSD Tape deck (default auto)\n"
"  --tape-audio          OSD Tape audio On\n"
"  --tape-overlay off    OSD Tape overlay Off\n"
"  --rewind-at-frame N   OSD Rewind tape\n"
"  --tape-check          compare every played sample with the WAV\n"
"  --tape-pitch steady|+|-   OSD Tape pitch Steady / +1.6% / -1.6% (default Wow)\n"
"  --stop-on-load        end at the ROM's first LOADOK (1766h) or LOADERR (18F3h) (always printed)\n"
"  --stop-at-pos N       end when the tape reaches sample N\n"
"  --m1-trace F1:F2      log opcode fetches (F14M clock, bank:address) and tape port reads in frames F1-F2\n"
"  --quiet\n");
}

// ---------------------------------------------------------------- PNG
static void png_chunk(FILE *f, const char *type, const std::vector<uint8_t> &d) {
	uint8_t b[4];
	uint32_t n = d.size();
	b[0]=n>>24; b[1]=n>>16; b[2]=n>>8; b[3]=n; fwrite(b,1,4,f);
	fwrite(type,1,4,f);
	if (n) fwrite(d.data(),1,n,f);
	uLong c = crc32(0, (const Bytef*)type, 4);
	if (n) c = crc32(c, d.data(), n);
	b[0]=c>>24; b[1]=c>>16; b[2]=c>>8; b[3]=c; fwrite(b,1,4,f);
}
static bool write_png(const std::string &fn, int w, int h, const std::vector<uint32_t> &px, int stride, int x0, int y0) {
	FILE *f = fopen(fn.c_str(), "wb");
	if (!f) return false;
	static const uint8_t sig[8] = {0x89,'P','N','G','\r','\n',0x1a,'\n'};
	fwrite(sig,1,8,f);
	std::vector<uint8_t> ih(13);
	ih[0]=w>>24; ih[1]=w>>16; ih[2]=w>>8; ih[3]=w;
	ih[4]=h>>24; ih[5]=h>>16; ih[6]=h>>8; ih[7]=h;
	ih[8]=8; ih[9]=2; ih[10]=0; ih[11]=0; ih[12]=0;
	png_chunk(f,"IHDR",ih);
	std::vector<uint8_t> raw;
	raw.reserve((size_t)h*(w*3+1));
	for (int y=0;y<h;y++) {
		raw.push_back(0);
		for (int x=0;x<w;x++) {
			uint32_t p = px[(size_t)(y+y0)*stride + x + x0];
			raw.push_back(p>>16); raw.push_back(p>>8); raw.push_back(p);
		}
	}
	uLongf cl = compressBound(raw.size());
	std::vector<uint8_t> z(cl);
	compress2(z.data(), &cl, raw.data(), raw.size(), 6);
	z.resize(cl);
	png_chunk(f,"IDAT",z);
	png_chunk(f,"IEND",{});
	fclose(f);
	return true;
}

// ---------------------------------------------------------------- video capture
static const int FB_W = 1024, FB_H = 320;
static std::vector<uint32_t> fb(FB_W*FB_H), last_fb(FB_W*FB_H);
static int vx = 0, vy = 0, de_x0, de_x1, de_y0, de_y1, last_x0, last_x1, last_y0, last_y1;
static int line_len = 0, last_line_len = 0, lines = 0, last_lines = 0;
static bool prev_hs = 1, prev_vs = 1;

static void frame_reset_bounds() { de_x0 = FB_W; de_x1 = -1; de_y0 = FB_H; de_y1 = -1; }

static void save_shot(int n) {
	if (last_x1 < 0) { printf("SHOT %d none (no active video)\n", n); return; }
	char fn[512];
	snprintf(fn, sizeof fn, "%s/%s_%04d.png", shot_dir.c_str(), shot_prefix.c_str(), n);
	// whole raster incl. border; DE box printed for reference
	int w = last_line_len < FB_W ? last_line_len : FB_W;
	int h = last_lines < FB_H ? last_lines : FB_H;
	if (w <= 0 || h <= 0) return;
	write_png(fn, w, h, last_fb, FB_W, 0, 0);
	printf("SHOT %d %s %dx%d de=%d..%d,%d..%d\n", n, fn, w, h, last_x0, last_x1, last_y0, last_y1);
}

// called on each rising edge of clk_pix (F14M)
static void pixel_tick() {
	bool hs = top->VGA_HS, vs = top->VGA_VS;
	if (prev_hs && !hs) {           // hsync falling edge: new line
		if (vx > line_len) line_len = vx;
		vx = 0; vy++;
	}
	if (prev_vs && !vs) {           // vsync falling edge: new frame
		last_fb.swap(fb);
		last_x0 = de_x0; last_x1 = de_x1; last_y0 = de_y0; last_y1 = de_y1;
		last_line_len = line_len; last_lines = vy;
		line_len = 0; vy = 0; vx = 0;
		frame_reset_bounds();
		frame++;
	}
	prev_hs = hs; prev_vs = vs;
	if (vx < FB_W && vy < FB_H) {
		uint32_t p = ((uint32_t)top->VGA_R<<16) | ((uint32_t)top->VGA_G<<8) | top->VGA_B;
		fb[vy*FB_W + vx] = p;
		if (top->VGA_DE) {
			if (vx < de_x0) de_x0 = vx;
			if (vx > de_x1) de_x1 = vx;
			if (vy < de_y0) de_y0 = vy;
			if (vy > de_y1) de_y1 = vy;
		}
	}
	vx++;
}

// ---------------------------------------------------------------- keyboard (PS/2 set 2, PC layout)
struct Sc { uint8_t code; bool ext; bool shift; };
static bool ascii_to_sc(int c, Sc &s) {
	static const char *lc = "abcdefghijklmnopqrstuvwxyz";
	static const uint8_t lcode[26] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,
	                                  0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
	static const uint8_t dig[10] = {0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46};
	s.ext = false; s.shift = false;
	if (c >= 'a' && c <= 'z') { s.code = lcode[c-'a']; return true; }
	if (c >= 'A' && c <= 'Z') { s.code = lcode[c-'A']; s.shift = true; return true; }
	if (c >= '0' && c <= '9') { s.code = dig[c-'0']; return true; }
	const char *sh = ")!@#$%^&*(";
	const char *p = strchr(sh, c);
	if (p && c) { s.code = dig[p-sh]; s.shift = true; return true; }
	struct { char ch; uint8_t code; bool shift; } t[] = {
		{' ',0x29,0},{'\n',0x5A,0},{'\b',0x66,0},{27,0x76,0},{'\t',0x0D,0},
		{'-',0x4E,0},{'_',0x4E,1},{'=',0x55,0},{'+',0x55,1},{'[',0x54,0},{'{',0x54,1},
		{']',0x5B,0},{'}',0x5B,1},{'\\',0x5D,0},{'|',0x5D,1},{';',0x4C,0},{':',0x4C,1},
		{'\'',0x52,0},{'"',0x52,1},{',',0x41,0},{'<',0x41,1},{'.',0x49,0},{'>',0x49,1},
		{'/',0x4A,0},{'?',0x4A,1},{'`',0x0E,0},{'~',0x0E,1}};
	for (auto &e : t) if (e.ch == c) { s.code = e.code; s.shift = e.shift; return true; }
	return false;
}
struct KeyEv { int frame; uint8_t code; bool ext; bool press; };
static std::deque<KeyEv> key_q;
static uint16_t ps2 = 0;
static int keys_free = 0;   // texts are typed one after another
static void schedule_text(int f, const std::string &t) {
	if (f < keys_free) f = keys_free;
	for (size_t i = 0; i < t.size(); i++) {
		int c = (unsigned char)t[i];
		if (c == '\\' && i+1 < t.size()) {
			char n = t[++i];
			if (n == 'R') {   // the Laser's Reset key (PS/2 77h)
				key_q.push_back({f, 0x77, false, true});
				key_q.push_back({f + key_hold, 0x77, false, false});
				f += key_hold + key_gap;
				continue;
			}
			c = n=='n' ? '\n' : n=='b' ? '\b' : n=='e' ? 27 : n=='t' ? '\t' : n;
		}
		Sc s;
		if (!ascii_to_sc(c, s)) { fprintf(stderr, "no key for '%c'\n", c); continue; }
		if (s.shift) key_q.push_back({f, 0x12, false, true});
		key_q.push_back({f + (s.shift?1:0), s.code, s.ext, true});
		key_q.push_back({f + (s.shift?1:0) + key_hold, s.code, s.ext, false});
		if (s.shift) key_q.push_back({f + key_hold + 2, 0x12, false, false});
		f += key_hold + key_gap + (s.shift?2:0);
	}
	keys_free = f;
}
static void key_tick() {
	// one PS/2 event per frame at most, in order
	if (!key_q.empty() && key_q.front().frame <= frame) {
		KeyEv e = key_q.front(); key_q.pop_front();
		ps2 = (uint16_t)((ps2 & 0x400) ^ 0x400) | (e.press ? 0x200 : 0) | (e.ext ? 0x100 : 0) | e.code;
		top->ps2_key = ps2;
		if (key_log) printf("KEY frame %d %s %02X\n", frame, e.press ? "down" : "up  ", e.code);
	}
}

// ---------------------------------------------------------------- ioctl (hps_io-like, on F14M)
struct Download { int index; std::vector<uint8_t> data; size_t pos; int phase; };
static std::unique_ptr<Download> dl;
static bool load_file(const std::string &fn, std::vector<uint8_t> &d) {
	FILE *f = fopen(fn.c_str(), "rb");
	if (!f) return false;
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	d.resize(n);
	size_t r = fread(d.data(), 1, n, f);
	fclose(f);
	return r == (size_t)n;
}
static void ioctl_tick() {   // on F14M rising edge
	if (!dl) {
		for (auto &i : ioctls) if (!i.done && i.frame <= frame) {
			i.done = true;
			dl.reset(new Download{i.index, {}, 0, 0});
			if (!load_file(i.file, dl->data)) { fprintf(stderr, "can't read %s\n", i.file.c_str()); exit(2); }
			printf("LOAD frame %d index %d %s (%zu bytes)\n", frame, i.index, i.file.c_str(), dl->data.size());
			top->ioctl_index = i.index;
			top->ioctl_download = 1;
			break;
		}
		return;
	}
	// one byte every 4 F14M clocks: wr high 1 clock
	top->ioctl_wr = 0;
	if (dl->phase == 0) {
		if (dl->pos < dl->data.size()) {
			top->ioctl_addr = dl->pos;
			top->ioctl_dout = dl->data[dl->pos];
			top->ioctl_wr = 1;
			dl->pos++;
		} else if (dl->phase == 0) {
			top->ioctl_download = 0;
			printf("LOAD done frame %d\n", frame);
			dl.reset();
			return;
		}
	}
	dl->phase = (dl->phase + 1) & 3;
}

// ---------------------------------------------------------------- audio
static FILE *wav = nullptr;
static uint32_t wav_samples = 0;
static double audio_acc = 0;
static void wav_open() {
	wav = fopen(audio_out.c_str(), "wb");
	if (!wav) { fprintf(stderr, "can't write %s\n", audio_out.c_str()); exit(2); }
	uint8_t h[44] = {0};
	fwrite(h, 1, 44, wav);
}
static void wav_close() {
	if (!wav) return;
	uint32_t rate = 48000, bytes = wav_samples * 2;
	auto w32 = [](uint8_t *p, uint32_t v){ p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; };
	uint8_t h[44];
	memcpy(h, "RIFF", 4); w32(h+4, 36 + bytes); memcpy(h+8, "WAVEfmt ", 8);
	w32(h+16, 16); h[20]=1; h[21]=0; h[22]=1; h[23]=0; w32(h+24, rate); w32(h+28, rate*2);
	h[32]=2; h[33]=0; h[34]=16; h[35]=0; memcpy(h+36, "data", 4); w32(h+40, bytes);
	fseek(wav, 0, SEEK_SET); fwrite(h, 1, 44, wav); fclose(wav); wav = nullptr;
}
static void audio_tick() {     // per F14M
	audio_acc += 48000.0 / 14700000.0;
	if (audio_acc >= 1.0) {
		audio_acc -= 1.0;
		int16_t s = (int16_t)((int)top->AUDIO_L - 0x2000);   // unsigned 0/4000h -> signed
		fwrite(&s, 2, 1, wav);
		wav_samples++;
	}
}

// ---------------------------------------------------------------- RAM dump
static void dump_ram(const std::string &fn) {
	auto &mem = top->rootp->top__DOT__laser500__DOT__dpram__DOT__mem;
	FILE *f = fopen(fn.c_str(), "wb");
	if (!f) { fprintf(stderr, "can't write %s\n", fn.c_str()); return; }
	for (int i = 0; i < (1<<18); i++) { uint8_t b = mem[i]; fwrite(&b, 1, 1, f); }
	fclose(f);
	printf("DUMP frame %d %s\n", frame, fn.c_str());
}

// ---------------------------------------------------------------- I/O log
static bool prev_io = false;
static void io_tick() {
	auto *r = top->rootp;
	bool io = !r->top__DOT__laser500__DOT__cpu_iorq_n && (!r->top__DOT__laser500__DOT__cpu_rd_n || !r->top__DOT__laser500__DOT__cpu_wr_n);
	if (io && !prev_io) {
		unsigned a = r->top__DOT__laser500__DOT__cpu_addr;
		if (!r->top__DOT__laser500__DOT__cpu_wr_n)
			printf("OUT frame %d port %02X = %02X\n", frame, a & 0xff, r->top__DOT__laser500__DOT__cpu_dout);
		else
			printf("IN  frame %d port %02X\n", frame, a & 0xff);
	}
	prev_io = io;
}

// ---------------------------------------------------------------- SD (hps_io-like), on F14M
struct Disk { std::vector<uint8_t> img; bool mounted; };
static Disk disks[3];
struct SdXfer { int d; bool wr; uint32_t lba; int len; int i; int phase; int wait; };
static std::unique_ptr<SdXfer> sdx;

static uint64_t sd_reads = 0, sd_writes = 0;

static void sd_tick() {
	top->img_mounted = 0;
	for (int d = 0; d < 3; d++) {
		if (!disks[d].mounted && !disk_opt[d].file.empty() && frame >= disk_opt[d].frame) {
			if (!load_file(disk_opt[d].file, disks[d].img)) { fprintf(stderr, "can't read %s\n", disk_opt[d].file.c_str()); exit(2); }
			disks[d].mounted = true;
			top->img_size = disks[d].img.size();
			top->img_readonly = disk_opt[d].ro;
			top->img_mounted = 1 << d;
			printf(d == 2 ? "MOUNT frame %d tape(%d) %s" : "MOUNT frame %d drive %d %s (%zu bytes%s)\n", frame, d+1, disk_opt[d].file.c_str(), disks[d].img.size(), disk_opt[d].ro ? ", ro" : "");
			return;
		}
	}
	top->sd_buff_wr = 0;
	if (!sdx) {
		for (int d = 0; d < 3; d++) {
			bool rd = (top->sd_rd >> d) & 1, wr = d < 2 && ((top->sd_wr >> d) & 1);
			if (rd || wr) {
				if (d == 2) sdx.reset(new SdXfer{d, false, top->tape_sd_lba, 512, 0, 0, sd_latency / 4});
				else sdx.reset(new SdXfer{d, wr, top->sd_lba, (top->sd_blk_cnt + 1) * 512, 0, 0, sd_latency});
				if (fdc_log && d < 2) printf("SD   frame %d drive %d %s lba %u blocks %d\n", frame, d+1, wr ? "write" : "read", sdx->lba, top->sd_blk_cnt + 1);
				if (wr) sd_writes++; else sd_reads++;
				break;
			}
		}
		return;
	}
	if (sdx->wait) { if (--sdx->wait == 0) top->sd_ack = 1 << sdx->d; return; }
	auto &img = disks[sdx->d].img;
	size_t off = (size_t)sdx->lba * 512 + sdx->i;
	if (sdx->i >= sdx->len) { top->sd_ack = 0; sdx.reset(); return; }
	// 4 clocks per byte: address, (data / wr), idle, idle
	switch (sdx->phase) {
	case 0: top->sd_buff_addr = sdx->i; break;
	case 1:
		if (!sdx->wr) { top->sd_buff_dout = off < img.size() ? img[off] : 0; top->sd_buff_wr = 1; }
		break;
	case 3:
		if (sdx->wr && off < img.size()) img[off] = top->sd_buff_din;
		sdx->i++;
		break;
	}
	sdx->phase = (sdx->phase + 1) & 3;
}

static void save_disks() {
	for (int d = 0; d < 2; d++) if (!disk_opt[d].save.empty() && disks[d].mounted) {
		FILE *f = fopen(disk_opt[d].save.c_str(), "wb");
		if (!f) { fprintf(stderr, "can't write %s\n", disk_opt[d].save.c_str()); continue; }
		fwrite(disks[d].img.data(), 1, disks[d].img.size(), f);
		fclose(f);
		printf("SAVE drive %d %s\n", d+1, disk_opt[d].save.c_str());
	}
}

// tape check (--tape-check): every sample the player emits is compared with
// the level computed here from the image (8/16-bit PCM WAV, first channel)
static bool tape_check = false;
static int m1_from = -1, m1_to = -1;     // --m1-trace: opcode fetch addresses in these frames
static void m1_tick() {
	static bool seen = false;
	auto *r = top->rootp;
	bool m1 = !r->top__DOT__laser500__DOT__cpu_m1_n && !r->top__DOT__laser500__DOT__cpu_mreq_n;
	if (m1 && !seen) printf("M1 %llu %X:%04X %u\n", (unsigned long long)pix_clocks, r->top__DOT__laser500__DOT__cpu_bank, r->top__DOT__laser500__DOT__cpu_addr, top->tape_pos);
	seen = m1;
	// reads of the tape port (mapped I/O, bank 2, 6800h-6FFFh window)
	static bool rseen = false;
	bool rd = r->top__DOT__laser500__DOT__cpu_m1_n && !r->top__DOT__laser500__DOT__cpu_mreq_n && !r->top__DOT__laser500__DOT__cpu_rd_n
	          && r->top__DOT__laser500__DOT__cpu_bank == 2 && (r->top__DOT__laser500__DOT__cpu_addr & 0x3800) == 0x2800;
	if (rd && !rseen) printf("RD %llu %04X\n", (unsigned long long)pix_clocks, r->top__DOT__laser500__DOT__cpu_addr);
	rseen = rd;
}
// ROM load outcome (always on while a tape is mounted): 1766h good load,
// 18F3h LOADING ERROR; --stop-on-load ends the run at the first one
static bool stop_on_load = false, load_done = false;
static unsigned stop_pos = 0;           // --stop-at-pos: end when the tape reaches this sample
static void load_tick(int frame) {
	static bool seen = false;
	auto *r = top->rootp;
	bool m1 = !r->top__DOT__laser500__DOT__cpu_m1_n && !r->top__DOT__laser500__DOT__cpu_mreq_n && r->top__DOT__laser500__DOT__cpu_bank == 0;
	if (m1 && !seen) {
		unsigned a = r->top__DOT__laser500__DOT__cpu_addr;
		if (a == 0x1766 || a == 0x18F3) {
			printf("%s frame %d pos %u\n", a == 0x1766 ? "LOADOK" : "LOADERR", frame, top->tape_pos);
			if (stop_on_load) load_done = true;
		}
	}
	seen = m1;
}
static std::vector<uint8_t> tape_expect;
static uint64_t tape_checked = 0, tape_bad = 0;
static void tape_expect_load() {
	std::vector<uint8_t> f;
	if (!load_file(disk_opt[2].file, f) || f.size() < 44 || memcmp(f.data(), "RIFF", 4)) { tape_check = false; return; }
	size_t p = 12; int ch = 1, bits = 8;
	while (p + 8 <= f.size()) {
		uint32_t ln = f[p+4] | f[p+5] << 8 | f[p+6] << 16 | (uint32_t)f[p+7] << 24;
		if (!memcmp(&f[p], "fmt ", 4)) { ch = f[p+10] | f[p+11] << 8; bits = f[p+22] | f[p+23] << 8; }
		if (!memcmp(&f[p], "data", 4)) {
			int step = ch * bits / 8;
			for (size_t o = p + 8; o + step <= p + 8 + ln && o + step <= f.size(); o += step)
				tape_expect.push_back(bits == 16 ? (int16_t)(f[o] | f[o+1] << 8) > 1310 : f[o] > 133);
			break;
		}
		p += 8 + ln + (ln & 1);
	}
	printf("TAPECHECK %zu samples\n", tape_expect.size());
}
static void tape_check_tick() {
	static uint32_t last = 0;
	uint32_t pos = top->tape_pos;
	if (pos == last) return;
	if (pos == last + 1 && pos <= tape_expect.size()) {
		bool lv = top->rootp->top__DOT__laser500__DOT__TAPE_LEVEL;
		tape_checked++;
		if (lv != tape_expect[pos - 1] && tape_bad++ < 10)
			printf("TAPECHECK mismatch frame %d sample %u got %d want %d\n", frame, pos - 1, lv, tape_expect[pos - 1]);
	}
	last = pos;
}

// tape: log changes of the deck (loaded, playing, 2x) and of the overlay
static void tape_tick() {
	static int last = -1;
	int st = top->tape_loaded | top->tape_playing << 1 | top->tape_fast << 2 | top->show_bar << 3 | top->show_tape << 4;
	if (st == last) return;
	last = st;
	printf("TAPE frame %d loaded %d playing %d fast %d bar %d hint %d pos %u/%u\n", frame, top->tape_loaded,
	       top->tape_playing, top->tape_fast, top->show_bar, top->show_tape, top->tape_pos, top->tape_len);
}

// floppy port log (decoded strobes inside the core)
static void fdc_tick() {
	auto *r = top->rootp;
	static int last_st = -1, last_in = -1;
	int st = r->top__DOT__laser500__DOT__floppy__DOT__st, in = r->top__DOT__laser500__DOT__floppy__DOT__img_in;
	static int last_dirty = -1, last_en = -1;
	int dirty = r->top__DOT__laser500__DOT__floppy__DOT__dirty, en = r->top__DOT__laser500__DOT__floppy__DOT__latch1 >> 4 & 1;
	if (dirty != last_dirty || en != last_en) { printf("FDCDIRTY frame %d dirty %d enbl %d flush_on_stop %d tag_trk %d\n", frame, dirty, en, r->top__DOT__laser500__DOT__floppy__DOT__flush_on_stop, r->top__DOT__laser500__DOT__floppy__DOT__tag_trk); last_dirty = dirty; last_en = en; }
	static int last_x2 = -1;
	int x2 = r->top__DOT__laser500__DOT__floppy__DOT__track_x2[0];
	if (x2 != last_x2) { printf("HEAD frame %d drive 1 track_x2 %d\n", frame, x2); last_x2 = x2; }
	if (st != last_st || in != last_in) {
		printf("FDCST frame %d st %d img_in %d tag_ok %d tag_trk %d sd_rd %d\n", frame, st, in, r->top__DOT__laser500__DOT__floppy__DOT__tag_ok, r->top__DOT__laser500__DOT__floppy__DOT__tag_trk, top->sd_rd);
		last_st = st; last_in = in;
	}
	if (r->top__DOT__laser500__DOT__fdc_rd)
		printf("FDCRD %u %02X %d %X\n", (unsigned)r->top__DOT__laser500__DOT__floppy__DOT__pos, r->top__DOT__laser500__DOT__fdc_dout, r->top__DOT__laser500__DOT__floppy__DOT__ready, r->top__DOT__laser500__DOT__cpu_addr & 0xff);
	if (r->top__DOT__laser500__DOT__fdc_wr)
		printf("FDC  frame %d OUT %02X = %02X\n", frame, 0x10 | (r->top__DOT__laser500__DOT__cpu_addr & 3), r->top__DOT__laser500__DOT__cpu_dout);
}

#ifdef SIM_MIXER
// mixer output capture: lines on HS rising edge, frames on VS rising edge,
// pixels while DE (any polarity is fine: edges of the raw signal)
static std::vector<uint32_t> mfb(1024*640), mlast(1024*640);
static int mx = 0, my = 0, mw = 0, mh = 0, mlw = 0, mlh = 0, mframe = 0, pmhs = 0, pmvs = 0, mde_lines = 0, mlast_de_lines = 0;
static bool mline_de = false;
static void mix_pixel(int hs, int vs, int de, int r, int g, int b) {
	if (hs && !pmhs) { if (mx > mw) mw = mx; if (mline_de) mde_lines++; mline_de = false; mx = 0; my++; }
	if (vs && !pmvs) { mlast.swap(mfb); mlw = mw; mlh = my; mlast_de_lines = mde_lines; mde_lines = 0; mw = 0; my = 0; mframe++; std::fill(mfb.begin(), mfb.end(), 0); }
	pmhs = hs; pmvs = vs;
	if (de) { mline_de = true; if (mx < 1024 && my < 640) mfb[my*1024 + mx] = (r<<16)|(g<<8)|b; mx++; }
}
static void save_mix_shot(int n) {
	char fn[512];
	snprintf(fn, sizeof fn, "%s/%s_mix_%04d.png", shot_dir.c_str(), shot_prefix.c_str(), n);
	int w = mlw ? (mlw < 1024 ? mlw : 1024) : 1, h = mlh ? (mlh < 640 ? mlh : 640) : 1;
	write_png(fn, w, h, mlast, 1024, 0, 0);
	printf("MIXSHOT %d %s %dx%d lines_with_de %d\n", n, fn, w, h, mlast_de_lines);
}
#endif

// ---------------------------------------------------------------- main
static std::vector<int> parse_list(const char *s) {
	std::vector<int> v;
	while (*s) { v.push_back(atoi(s)); const char *c = strchr(s, ','); if (!c) break; s = c+1; }
	return v;
}
static bool split_frame(const std::string &a, int &f, std::string &rest) {
	size_t c = a.find(':');
	if (c == std::string::npos) return false;
	f = atoi(a.substr(0, c).c_str()); rest = a.substr(c+1);
	return true;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> std::string { if (i+1 >= argc) { usage(); exit(2); } return argv[++i]; };
		if (a == "--help" || a == "-h") { usage(); return 0; }
		else if (a == "--rom") rom_file = next();
		else if (a == "--prg") {
			std::string v = next(); int f = 60; size_t at = v.rfind('@');
			if (at != std::string::npos) { f = atoi(v.substr(at+1).c_str()); v = v.substr(0, at); }
			ioctls.push_back({f, 1, v, false});
		}
		else if (a == "--ioctl") {
			std::string v = next(), rest; int f;
			if (!split_frame(v, f, rest)) { usage(); return 2; }
			size_t c = rest.find(':');
			ioctls.push_back({f, atoi(rest.substr(0,c).c_str()), rest.substr(c+1), false});
		}
		else if (a == "--stop-at-frame") stop_frame = atoi(next().c_str());
		else if (a == "--reset-at-frame") reset_frames.push_back({atoi(next().c_str()), 2});
		else if (a == "--send-keys") { std::string v = next(), t; int f; if (!split_frame(v, f, t)) { usage(); return 2; } key_texts.push_back({f, t}); }
		else if (a == "--key-hold") key_hold = atoi(next().c_str());
		else if (a == "--key-gap") key_gap = atoi(next().c_str());
		else if (a == "--joy" || a == "--joy2") { std::string v = next(), t; int f; split_frame(v, f, t); joys.push_back({f, (uint32_t)strtoul(t.c_str(), 0, 16), a == "--joy2"}); }
		else if (a == "--screenshot") for (int n : parse_list(next().c_str())) shot_frames.insert(n);
		else if (a == "--screenshot-every") shot_every = atoi(next().c_str());
		else if (a == "--screenshot-end") shot_end = true;
		else if (a == "--screenshot-dir") shot_dir = next();
		else if (a == "--screenshot-prefix") shot_prefix = next();
		else if (a == "--dump-ram") { std::string v = next(), t; int f; split_frame(v, f, t); dumps.push_back({f, t}); }
		else if (a == "--dump-track") { std::string v = next(), t; int f; split_frame(v, f, t); track_dumps.push_back({f, t}); }
		else if (a == "--audio-out") audio_out = next();
		else if (a == "--io-log") io_log = true;
		else if (a == "--quiet") quiet = true;
		else if (a == "--key-log") key_log = true;
		else if (a == "--fdc-log") fdc_log = true;
		else if (a == "--fdc") fdc_force = next() == "on";
		else if (a == "--sd-latency") sd_latency = atoi(next().c_str());
		else if (a == "--disk1" || a == "--disk2") {
			int d = a == "--disk2"; std::string v = next(); size_t at = v.rfind('@');
			if (at != std::string::npos) { disk_opt[d].frame = atoi(v.substr(at+1).c_str()); v = v.substr(0, at); }
			disk_opt[d].file = v;
		}
		else if (a == "--tape") {
			std::string v = next(); size_t at = v.rfind('@');
			if (at != std::string::npos) { disk_opt[2].frame = atoi(v.substr(at+1).c_str()); v = v.substr(0, at); }
			disk_opt[2].file = v;
		}
		else if (a == "--tape-speed") tape_normal = next() == "normal";
		else if (a == "--tape-deck") tape_play = next() == "play";
		else if (a == "--tape-audio") tape_audio = true;
		else if (a == "--tape-check") tape_check = true;
		else if (a == "--tape-pitch") { std::string v = next(); tape_pitch = v == "steady" ? 1 : v == "+" ? 2 : v == "-" ? 3 : 0; }
		else if (a == "--stop-on-load") stop_on_load = true;
		else if (a == "--stop-at-pos") stop_pos = strtoul(next().c_str(), nullptr, 0);
		else if (a == "--m1-trace") { std::string v = next(); m1_from = atoi(v.c_str()); m1_to = atoi(v.substr(v.find(':')+1).c_str()); }
		else if (a == "--tape-overlay") tape_no_overlay = next() == "off";
		else if (a == "--rewind-at-frame") rewind_frames.push_back(atoi(next().c_str()));
		else if (a == "--disk1-ro") disk_opt[0].ro = true;
		else if (a == "--disk2-ro") disk_opt[1].ro = true;
		else if (a == "--disk1-save") disk_opt[0].save = next();
		else if (a == "--disk2-save") disk_opt[1].save = next();
		else if (a[0] == '+') {}
		else { fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return 2; }
	}
	ioctls.insert(ioctls.begin(), {0, 0, rom_file, false});
	std::stable_sort(key_texts.begin(), key_texts.end(), [](const KeyText &x, const KeyText &y){ return x.frame < y.frame; });
	for (auto &k : key_texts) schedule_text(k.frame, k.text);
	std::stable_sort(key_q.begin(), key_q.end(), [](const KeyEv &x, const KeyEv &y){ return x.frame < y.frame; });
	if (!audio_out.empty()) wav_open();

	top = new Vtop;
	frame_reset_bounds();
	top->reset = 1;
	top->ps2_key = 0;
	top->joystick_0 = top->joystick_1 = 0;
	top->alt_font = 0;
	top->fdc_enable = fdc_force >= 0 ? fdc_force : (!disk_opt[0].file.empty() || !disk_opt[1].file.empty());
	top->sd_ack = 0; top->img_mounted = 0;
	if (tape_check) tape_expect_load();
	top->tape_turbo_en = !tape_normal; top->tape_deck_play = tape_play;
	top->tape_audio_en = tape_audio; top->tape_pitch = tape_pitch; top->tape_overlay_en = !tape_no_overlay; top->tape_rewind = 0;
	int reset_until = -1;

	int last_frame = -1;
	bool prev_pix = 0;
	while (frame <= stop_frame && !load_done && !(stop_pos && top->tape_pos >= stop_pos) && !Verilated::gotFinish()) {
		top->clk_2x = !top->clk_2x;
		top->eval();
		ticks++;
		if (ticks == 20) top->reset = 0;

#ifdef SIM_MIXER
		if (top->clk_2x) {
			auto *r = top->rootp;
			if (r->top__DOT__mix_ce) {
				mix_ce++;
				if (r->top__DOT__mix_de) mix_de++;
				if (r->top__DOT__frk_de) { frk_de++; if (r->top__DOT__mix_r | r->top__DOT__mix_g | r->top__DOT__mix_b) mix_nz++; }
				if (r->top__DOT__mix_hs != last_mhs) { mix_hs_edges++; last_mhs = r->top__DOT__mix_hs; }
				if (r->top__DOT__mix_vs != last_mvs) { mix_vs_edges++; last_mvs = r->top__DOT__mix_vs; }
				mix_pixel(r->top__DOT__mix_hs, r->top__DOT__mix_vs, r->top__DOT__frk_de, r->top__DOT__mix_r, r->top__DOT__mix_g, r->top__DOT__mix_b);
			}
		}
#endif
		bool pix = top->clk_pix;
		if (pix && !prev_pix) {
			pix_clocks++;
			if (top->rootp->top__DOT__laser500__DOT__CPUENA) cpu_cycles++;
			pixel_tick();
			ioctl_tick();
			if (wav) audio_tick();
			if (io_log) io_tick();
			sd_tick();
			if (fdc_log) fdc_tick();
			tape_tick();
			if (tape_check) tape_check_tick();
			if (frame >= m1_from && frame <= m1_to) m1_tick();
			if (!disk_opt[2].file.empty()) load_tick(frame);
		}
		prev_pix = pix;

		if (frame != last_frame) {
			last_frame = frame;
			key_tick();
			for (auto &j : joys) if (j.frame == frame) { if (j.n) top->joystick_1 = j.v; else top->joystick_0 = j.v; }
			for (auto &r : reset_frames) if (r.first == frame) { top->reset = 1; reset_until = frame + r.second; printf("RESET frame %d\n", frame); }
			if (frame == reset_until) top->reset = 0;
			top->tape_rewind = 0;
			for (int f : rewind_frames) if (f == frame) { top->tape_rewind = 1; printf("REWIND frame %d\n", frame); }
			for (auto &d : dumps) if (d.frame == frame) dump_ram(d.file);
			for (auto &d : track_dumps) if (d.frame == frame) {
				FILE *f = fopen(d.file.c_str(), "wb");
				auto &tb = top->rootp->top__DOT__laser500__DOT__floppy__DOT__tbuf;
				for (int i = 0; i < 8192; i++) { uint8_t b = tb[i]; fwrite(&b, 1, 1, f); }
				fclose(f);
				printf("DUMP track buffer frame %d %s\n", frame, d.file.c_str());
			}
			if (frame > 0 && (shot_frames.count(frame) || (shot_every && frame % shot_every == 0))) {
				save_shot(frame);
#ifdef SIM_MIXER
				save_mix_shot(frame);
#endif
			}
			if (!quiet && frame % 50 == 0) { printf("FRAME %d lines=%d len=%d\n", frame, last_lines, last_line_len); fflush(stdout); }
		}
	}
	if (shot_end) save_shot(frame);
	save_disks();
	printf("SD reads %llu writes %llu\n", (unsigned long long)sd_reads, (unsigned long long)sd_writes);
	wav_close();
#ifdef SIM_MIXER
	printf("MIXER nonzero %llu ce %llu de %llu freak_de %llu hs_edges %llu vs_edges %llu arx %u ary %u\n", (unsigned long long)mix_nz, (unsigned long long)mix_ce, (unsigned long long)mix_de,
		(unsigned long long)frk_de, (unsigned long long)mix_hs_edges, (unsigned long long)mix_vs_edges,
		(unsigned)top->rootp->top__DOT__frk_arx, (unsigned)top->rootp->top__DOT__frk_ary);
#endif
	if (!disk_opt[2].file.empty())
		printf("TAPE end frame %d pos %u/%u underflows %u\n", frame, top->tape_pos, top->tape_len, top->tape_underflows);
	if (tape_check) printf("TAPECHECK checked %llu mismatches %llu\n", (unsigned long long)tape_checked, (unsigned long long)tape_bad);
	printf("DONE frame %d ticks %llu cpu_cycles %llu F14M %llu (cpu = F14M/%.3f)\n", frame, (unsigned long long)ticks, (unsigned long long)cpu_cycles, (unsigned long long)pix_clocks, (double)pix_clocks/cpu_cycles);
	top->final();
	delete top;
	return 0;
}
