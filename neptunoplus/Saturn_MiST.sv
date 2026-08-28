//============================================================================
//  Sega Saturn for neptUNO+ (QMTech EP4CGX150 Cyclone IV GX, MiST firmware
//  on RP2040 - microhack's mist-firmware-rp2040)
//
//  MILESTONE 1 shell: boots BIOS + cartridge/RAM games, no CD yet.
//  See docs/NEPTUNOPLUS_PORT.md for the full rationale and the list of
//  simplifications made versus the MiSTer "Saturn.sv" top this is derived
//  from - the memory/CD/VDP wiring below the CLOCKS section is copied
//  verbatim from that file on purpose (it does not depend on the MiSTer vs
//  MiST distinction), with a single deliberate width fix on the backup-RAM
//  sd_buff path called out where it happens.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module Saturn_MiST
(
	input         CLOCK_50,

	output        LED,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,

	// SDRAM interface (single chip on the QMTech EP4CGX150 board)
	inout  [15:0] SDRAM_DQ,
	output [12:0] SDRAM_A,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

	// SDRAM interface, expansion chip (edge connector). Backs everything
	// rtl/ddram.sv used to route to MiSTer's DDR3 (RAMH, VDP1 VRAM/FB,
	// CD RAM/buffer, cart, BIOS, Backup RAM) via avalon_sdram_bridge.sv +
	// sdram2_ctrl.sv below - see docs/NEPTUNOPLUS_PORT.md.
	inout  [15:0] SDRAM2_DQ,
	output [12:0] SDRAM2_A,
	output        SDRAM2_DQML,
	output        SDRAM2_DQMH,
	output        SDRAM2_nWE,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nCS,
	output  [1:0] SDRAM2_BA,
	output        SDRAM2_CLK,
	output        SDRAM2_CKE,

	// SPI interface to the RP2040 (MiST protocol)
	inout         SPI_DO,
	input         SPI_DI,
	input         SPI_SCK,
	input         SPI_SS2,    // data_io
	input         SPI_SS3,    // OSD
	input         SPI_SS4,    // direct SD upload
	input         CONF_DATA0, // SPI_SS for user_io

	output        AUDIO_L,
	output        AUDIO_R,
	output        I2S_BCK,
	output        I2S_LRCK,
	output        I2S_DATA,

	input         UART_RX,
	output        UART_TX,

	// SNAC / db9 pad-2 pass-through (wired in neptuno2_top.sv); Pad 1 comes
	// from user_io's joystick_0/1 like every other MiST core.
	input   [6:0] USER_IN,
	output reg [6:0] USER_OUT
);

/////////////////////////  CONFIG STRING (classic MiST syntax)  /////////////
// NOTE: MiSTer's Saturn.sv uses a 128-bit `status` with the modern
// "O[hi:lo]" bracket syntax and D#-prefixed conditional menu masking.
// Classic MiST firmware (mist-firmware-rp2040) does not parse that syntax,
// and `user_io` here only carries a 64-bit status word, so this string is
// rewritten to the old single-letter base36 bit-position format
// ('0'-'9'=0-9, 'A'-'Z'=10-35) and only exposes options that live in bits
// 0-35 - deliberately the SAME bit positions the copied-verbatim code below
// already reads, so nothing else needed to change. Everything at bit 36 and
// above (2nd pad type, lightgun config, composite blend, vertical crop,
// aspect ratio) is intentionally left at its default (0) for this first
// milestone - see docs/NEPTUNOPLUS_PORT.md for the full bit map and what a
// follow-up pass needs to do to expose them (likely a small, real edit to
// the copied core-wiring section to move them under bit 36).
`include "build_id.v"
localparam CONF_STR = {
	"Saturn;;",
	"S0,CUECHD,Insert Disc (CD not wired up yet);",
	"F0,BIN,Load bios;",
	"F3,BIN,Load cartridge;",
	"S1,SAV,Mount Backup RAM;",
	"RP,Save Backup RAM;",
	"OQ,Autosave,Off,On;",
	"-;",
	"OLN,Cartridge,None,ROM 2M,DRAM 1M,DRAM 4M,DRAM 6M DEV,BACKUP;",
	"OXZ,Region,Japan,Taiwan,USA,Brazil,Korea,Asia,Europe,Auto;",
	"-;",
	"OFI,Pad 1,Digital,Virt LGun,Wheel,Mission Stick,3D Pad,Dual Mission,Mouse,Keyboard,Off;",
	"OR,Pad 1 SNAC,Off,On;",
	"-;",
	"OS,SDRAM Timing,Original,Fast;",
	"OV,Blurred VDP1 mesh,Off,On;",
	"-;",
	"T0,Reset;",
	"V,neptUNO+ v0.",`BUILD_DATE
};

wire [63:0] status_lo;
wire [127:0] status = {64'b0, status_lo};

wire  [1:0] buttons;
wire        scandoubler_disable;
wire        ypbpr;
wire        no_csync;

wire [31:0] joystick_0_32, joystick_1_32, joystick_2_32, joystick_3_32, joystick_4_32;
wire [13:0] joystick_0 = joystick_0_32[13:0];
wire [13:0] joystick_1 = joystick_1_32[13:0];
wire [13:0] joystick_2 = joystick_2_32[13:0];
wire [13:0] joystick_3 = joystick_3_32[13:0];
wire [13:0] joystick_4 = joystick_4_32[13:0];

// Analog stick bytes (3D Pad / Mission Stick / Dual Mission pad types):
// not wired up yet in this milestone, held centered.
wire  [7:0] joy0_x0 = 8'h80, joy0_y0 = 8'h80, joy0_x1 = 8'h80, joy0_y1 = 8'h80;
wire  [7:0] joy1_x0 = 8'h80, joy1_y0 = 8'h80, joy1_x1 = 8'h80, joy1_y1 = 8'h80;

wire        ioctl_download;
wire        ioctl_upload_req;  // unused (MiSTer-only upload path, dead here)
wire        ioctl_wr;
wire [26:0] ioctl_addr_27;
wire [25:0] ioctl_addr = ioctl_addr_27[25:0];
wire [15:0] ioctl_data;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;
reg         ioctl_wait = 0;

// sd_lba0/sd_ack0 correspond to CONF_STR's "S0" (CD image) slot. The
// Saturn core in this repo streams CD sectors through the MiSTer-only
// ioctl_download "cdd_download" bulk path (index group 2), not through
// this classic sd_lba/img_mounted block-device protocol, so this slot is
// left mounted-but-inert for now - see docs/NEPTUNOPLUS_PORT.md.
wire        sd_ack0 = 1'b0;

reg  [31:0] sd_lba = '0;
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din;
wire        sd_buff_wr;
wire  [1:0] img_mounted;
wire        img_readonly = 1'b0;
wire [63:0] img_size;

wire [10:0] ps2_key;
wire  [2:0] ps2_kbd_led_status = 3'b000; // no keyboard-LED feedback path yet
wire  [2:0] ps2_kbd_led_use = 3'b111;
wire [24:0] ps2_mouse = 25'h0;    // mouse pad type not wired up yet
wire [15:0] ps2_mouse_ext = 16'h0;

wire [64:0] RTC = 65'h0;          // no RTC source in this milestone
wire [35:0] EXT_BUS = 36'h0;      // unused expansion bus

wire  [2:0] cart_type = status[23:21];

// No discrete hardware reset pin on this board (classic MiST doesn't have
// one either); the core resets via the OSD "Reset" option (status[0]) and
// user_io's buttons[1] instead, same as every other line here.
wire        RESET = 1'b0;

// MiSTer-only top-level input telling the core whether the OSD is
// currently open, used to gate one of the autosave triggers below (the
// other, sd_lba/img_mounted-driven autosave-on-change path still works
// without it). No equivalent signal from classic MiST's user_io - tied
// low, so that specific "autosave while OSD is open" trigger just never
// fires in this milestone.
wire        OSD_STATUS = 1'b0;

// These were declared right after hps_io in MiSTer's Saturn.sv and are read
// deep inside the copied-verbatim core-wiring block below; missing them was
// an oversight in the first draft (Quartus caught it as "not declared").
wire        bios_download   = ioctl_download & (ioctl_index[5:2] == 4'b0000 && ioctl_index[1:0] != 2'h3);
wire        cart_download   = ioctl_download & (ioctl_index[5:2] == 4'b0000 && ioctl_index[1:0] == 2'h3);
wire        save_download   = ioctl_download & (ioctl_index[5:2] == 4'b0001);
wire        save_upload     = 1'b0; // no ioctl_upload path in classic MiST data_io
wire        cdd_download    = ioctl_download & (ioctl_index[5:2] == 4'b0010);
wire        cdboot_download = ioctl_download & (ioctl_index[5:2] == 4'b0011);

/////////////////////////  USER I/O (joystick, status, ps2, sd)  ////////////
wire [1:0] sd_ack_x;
wire       key_pressed_w, key_extended_w, key_strobe_w;
wire [7:0] key_code_w;
reg        kbd_toggle = 0;
always @(posedge clk_sys) if (key_strobe_w) kbd_toggle <= ~kbd_toggle;
assign ps2_key = {kbd_toggle, key_pressed_w, key_extended_w, key_code_w};
assign sd_ack  = sd_ack_x[1];

user_io #(.STRLEN($size(CONF_STR)>>3)) user_io
(
	.clk_sys(clk_sys),
	.clk_sd(clk_sys),

	.conf_str(CONF_STR),
	.conf_addr(),
	.conf_chr(8'h0),

	.SPI_CLK(SPI_SCK),
	.SPI_SS_IO(CONF_DATA0),
	.SPI_MISO(SPI_DO),
	.SPI_MOSI(SPI_DI),

	.joystick_0(joystick_0_32),
	.joystick_1(joystick_1_32),
	.joystick_2(joystick_2_32),
	.joystick_3(joystick_3_32),
	.joystick_4(joystick_4_32),
	.joystick_analog_0(),
	.joystick_analog_1(),

	.buttons(buttons),
	.switches(),
	.scandoubler_disable(scandoubler_disable),
	.ypbpr(ypbpr),
	.no_csync(no_csync),

	.status(status_lo),
	.core_mod(),
	.rtc(),

	.sd_lba(sd_lba),
	.sd_rd({sd_rd, 1'b0}),
	.sd_wr({sd_wr, 1'b0}),
	.sd_ack(),
	.sd_ack_conf(),
	.sd_ack_x(sd_ack_x),
	.sd_conf(1'b0),
	.sd_sdhc(1'b1),
	.sd_dout(sd_buff_dout),
	.sd_dout_strobe(sd_buff_wr),
	.sd_din(sd_buff_din),
	.sd_din_strobe(),
	.sd_buff_addr(sd_buff_addr),

	.img_mounted(img_mounted),
	.img_size(img_size),

	.ps2_kbd_clk(),
	.ps2_kbd_data(),
	.ps2_kbd_clk_i(1'b1),
	.ps2_kbd_data_i(1'b1),
	.ps2_mouse_clk(),
	.ps2_mouse_data(),
	.ps2_mouse_clk_i(1'b1),
	.ps2_mouse_data_i(1'b1),

	.key_pressed(key_pressed_w),
	.key_extended(key_extended_w),
	.key_code(key_code_w),
	.key_strobe(key_strobe_w),

	.kbd_out_data(8'h0),
	.kbd_out_strobe(1'b0),

	.mouse_x(),
	.mouse_y(),
	.mouse_z(),
	.mouse_flags(),
	.mouse_strobe(),
	.mouse_idx(),

	.i2c_start(),
	.i2c_read(),
	.i2c_addr(),
	.i2c_subaddr(),
	.i2c_dout(),
	.i2c_din(8'h0),
	.i2c_ack(1'b0),
	.i2c_end(1'b0),

	.serial_data(8'h0),
	.serial_strobe(1'b0)
);

data_io #(.DOUT_16(1'b1)) data_io
(
	.clk_sys(clk_sys),
	.SPI_SCK(SPI_SCK),
	.SPI_DI(SPI_DI),
	.SPI_DO(SPI_DO),
	.SPI_SS2(SPI_SS2),
	.SPI_SS4(SPI_SS4),

	.QCSn(1'b1),
	.QSCK(1'b0),
	.QDAT(4'h0),

	.clkref_n(1'b0),

	.ioctl_download(ioctl_download),
	.ioctl_upload(),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr_27),
	.ioctl_dout(ioctl_data),
	.ioctl_din(ioctl_din),
	.ioctl_fileext(),
	.ioctl_filesize(),

	.hdd_clk(1'b0),
	.hdd_cmd_req(1'b0),
	.hdd_cdda_req(1'b0),
	.hdd_dat_req(1'b0),
	.hdd_cdda_wr(),
	.hdd_status_wr(),
	.hdd_addr(),
	.hdd_wr()
);

assign LED = ~ioctl_download;

/////////////////////////  CLOCKS  ///////////////////////////////////////
// NOTE: MiSTer's Saturn.sv retunes clk_sys at runtime (Altera reconfigurable
// PLL) between 4 exact frequencies to match PAL/NTSC x normal/hi-res
// SMPC_DOTSEL combinations. Cyclone IV GX has no equivalent IP wired up
// here yet, so this milestone fixes clk_sys to the NTSC/normal-dotclock
// rate (53.748200 MHz) via a plain altpll. See docs/NEPTUNOPLUS_PORT.md for
// the exact numbers and what regenerating this PLL in Quartus needs.
wire clk_sys, clk_ram, locked;

pll_sys pll_sys
(
	.inclk0 (CLOCK_50),
	.c0     (clk_sys),  // ~53.748200 MHz - regenerate in Quartus, see docs
	.c1     (clk_ram),  // same rate, phase-advanced for SDRAM setup/hold
	.locked (locked)
);

assign SDRAM_CLK = clk_ram;

	wire reset = RESET | status[0] | buttons[1];
	
	reg rst_ram = 0, stv_res = 0;
	reg download;
	always @(posedge clk_sys) begin
		reg [7:0] delay_cnt;
		
		download <= bios_download || cart_download;
		if (delay_cnt) delay_cnt <= delay_cnt - 8'd1;
		else rst_ram <= 0;
		
		if ((!bios_download && !cart_download && download) || reset) begin
			rst_ram <= 1;
			delay_cnt <= '1;
		end
	end
	
	wire rst_sys = reset | download | rst_ram | stv_res;
	
`ifndef MISTER_DUAL_SDRAM
	wire fast_timing = status[28];
`else
	wire fast_timing = 0;
`endif
	wire blur_mesh = status[31];
	
	//region select
`ifndef STV_BUILD
	reg [127: 0] game_id;
	reg [  7: 0] cd_area_symbol;
	reg          dezaemon2_hack = 0;
	always @(posedge clk_sys) begin
		if (cdboot_download && ioctl_wr) begin
			case (ioctl_addr[7:0])
				8'h20: game_id[127:112] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h22: game_id[111:96] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h24: game_id[95:80] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h26: game_id[79:64] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h28: game_id[63:48] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h2A: game_id[47:32] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h2C: game_id[31:16] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h2E: game_id[15:0] <= {ioctl_data[7:0],ioctl_data[15:8]};
				8'h30: dezaemon2_hack <= (game_id[127:64] == "T-16804G");
				8'h40: cd_area_symbol <= ioctl_data[7:0];
			endcase
		end
	end
	wire [3:0] cd_area_code = cd_area_symbol == "J" ? 4'h1 :
	                          cd_area_symbol == "T" ? 4'h2 :
	                          cd_area_symbol == "U" ? 4'h4 :
	                          cd_area_symbol == "B" ? 4'h5 :
	                          cd_area_symbol == "K" ? 4'h6 :
	                          cd_area_symbol == "A" ? 4'hA :
	                          cd_area_symbol == "E" ? 4'hC :
	                          cd_area_symbol == "L" ? 4'hD :
										                       4'h1;
	
	wire  [3:0] area_code = status[35:33] == 3'd0 ? 4'h1 :	//Japan area
									status[35:33] == 3'd1 ? 4'h2 :	//Asia NTSC area
									status[35:33] == 3'd2 ? 4'h4 :	//North America area
									status[35:33] == 3'd3 ? 4'h5 :	//Central/S. America NTSC area
									status[35:33] == 3'd4 ? 4'h6 :	//Korea area
									status[35:33] == 3'd5 ? 4'hA :	//Asia PAL area
									status[35:33] == 3'd6 ? 4'hC :	//Europe PAL area
																	cd_area_code;	//Auto
`else
	wire [3:0] area_code = 4'h1;
`endif
																	
`ifndef STV_BUILD														
	wire [15:0] joy1 = {~joystick_0[0]|joystick_0[1], ~joystick_0[1]|joystick_0[0], ~joystick_0[2]|joystick_0[3], ~joystick_0[3]|joystick_0[2], ~joystick_0[7], ~joystick_0[4], ~joystick_0[6], ~joystick_0[5],
							  ~joystick_0[8], ~joystick_0[9], ~joystick_0[10], ~joystick_0[11], ~joystick_0[12], 3'b111};
	wire [15:0] joy2 = {~joystick_1[0]|joystick_1[1], ~joystick_1[1]|joystick_1[0], ~joystick_1[2]|joystick_1[3], ~joystick_1[3]|joystick_1[2], ~joystick_1[7], ~joystick_1[4], ~joystick_1[6], ~joystick_1[5],
							  ~joystick_1[8], ~joystick_1[9], ~joystick_1[10], ~joystick_1[11], ~joystick_1[12], 3'b111};
`else
	wire [13:0] joy1 = ~joystick_0[13:0];
	wire [13:0] joy2 = ~joystick_1[13:0];
`endif

	wire snac = status[27];
	reg  [6:0] USERJOYSTICK;
	wire [6:0] USERJOYSTICKOUT;
	always @(posedge clk_sys) begin
		if (snac) begin
			USERJOYSTICK <= {USER_IN[4], USER_IN[6], USER_IN[2], USER_IN[3], USER_IN[5], USER_IN[0], USER_IN[1]};//TH, C(TR), B(TL), R, L, D, U
			USER_OUT <= {USERJOYSTICKOUT[5], USERJOYSTICKOUT[2], USERJOYSTICKOUT[6], USERJOYSTICKOUT[3], USERJOYSTICKOUT[4], USERJOYSTICKOUT[0], USERJOYSTICKOUT[1]};
		end else begin
			USER_OUT <= '1;
		end
	end
	
	
	wire [24: 0] MEM_A;
	wire [31: 0] MEM_DI;
	wire [31: 0] MEM_DO;
	wire         ROM_CS_N;
	wire         SRAM_CS_N;
	wire         RAML_CS_N;
	wire         RAMH_CS_N;
	wire         RAMH_BURST;
	wire         RAMH_RFS;
	wire [ 3: 0] MEM_DQM_N;
	wire         MEM_RD_N;
	wire         MEM_WAIT_N;
`ifdef STV_BUILD
	wire         STVIO_CS_N;
`endif
	
	wire [18: 1] VDP1_VRAM_A;
	wire [15: 0] VDP1_VRAM_D;
	wire [15: 0] VDP1_VRAM_Q;
	wire [ 1: 0] VDP1_VRAM_WE;
	wire         VDP1_VRAM_RD;
	wire [ 8: 0] VDP1_VRAM_BLEN;
	wire         VDP1_VRAM_RDY;
	wire [17: 1] VDP1_FB0_A;
	wire [15: 0] VDP1_FB0_D;
	wire [15: 0] VDP1_FB0_Q;
	wire [ 1: 0] VDP1_FB0_WE;
	wire         VDP1_FB0_RD;
	wire [17: 1] VDP1_FB1_A;
	wire [15: 0] VDP1_FB1_D;
	wire [15: 0] VDP1_FB1_Q;
	wire [ 1: 0] VDP1_FB1_WE;
	wire         VDP1_FB1_RD;
	wire         VDP1_FB_RDY;
	wire         VDP1_FB_MODE3;
	
	wire [17: 1] VDP2_RA0_A;
	wire [16: 1] VDP2_RA1_A;
	wire [63: 0] VDP2_RA_D;
	wire [ 7: 0] VDP2_RA_WE;
	wire         VDP2_RA_RD;
	wire [31: 0] VDP2_RA0_Q;
	wire [31: 0] VDP2_RA1_Q;
	wire [17: 1] VDP2_RB0_A;
	wire [16: 1] VDP2_RB1_A;
	wire [63: 0] VDP2_RB_D;
	wire [ 7: 0] VDP2_RB_WE;
	wire         VDP2_RB_RD;
	wire [31: 0] VDP2_RB0_Q;
	wire [31: 0] VDP2_RB1_Q;
	
	wire [18: 1] SCSP_RAM_A;
	wire [15: 0] SCSP_RAM_D;
	wire [ 1: 0] SCSP_RAM_WE;
	wire         SCSP_RAM_RD;
	wire         SCSP_RAM_CS;
	wire [15: 0] SCSP_RAM_Q;
	wire         SCSP_RAM_RFS;
	wire         SCSP_RAM_RDY;
	
	wire         SMPC_DOTSEL;
	wire [ 6: 0] SMPC_PDR1I;
	wire [ 6: 0] SMPC_PDR1O;
	wire [ 6: 0] SMPC_DDR1;
	wire [ 6: 0] SMPC_PDR2I;
	wire [ 6: 0] SMPC_PDR2O;
	wire [ 6: 0] SMPC_DDR2;
	
	wire         CD_CDATA;
	wire         CD_HDATA;
	wire         CD_COMCLK;
	wire         CD_COMREQ_N;
	wire         CD_COMSYNC_N;
	wire [17: 0] CD_DATA;
	wire         CD_CK;
	wire         CD_AUDIO;
	
	wire [18: 1] CD_RAM_A;
	wire [15: 0] CD_RAM_D;
	wire [ 1: 0] CD_RAM_WE;
	wire         CD_RAM_RD;
	wire         CD_RAM_CS;
	wire [15: 0] CD_RAM_Q;
	wire         CD_RAM_RDY;
	
	wire [25: 1] CART_MEM_A;
	wire [15: 0] CART_MEM_D;
	wire [15: 0] CART_MEM_Q;
	wire [ 1: 0] CART_MEM_WE;
	wire         CART_MEM_RD;
	wire         CART_MEM_RDY;
	wire [24: 1] CART_RAX_MEM_A;
	wire [15: 0] CART_RAX_MEM_DI;
	wire [15: 0] CART_RAX_MEM_DO;
	wire         CART_RAX_MEM_RD;
	wire         CART_RAX_MEM_WR;
	wire         CART_RAX_MEM_RDY;
	wire [15: 0] RAX_SOUND_L;
	wire [15: 0] RAX_SOUND_R;
	
	wire [ 7: 0] R, G, B;
	wire         HS_N,VS_N;
	wire         DCLK;
	wire         HBL_N, VBL_N;
	wire         FIELD;
	wire         INTERLACE;
	wire [ 1: 0] HRES;
	wire [ 1: 0] VRES;
	wire         DCE_R;
	wire [15: 0] SOUND_L;
	wire [15: 0] SOUND_R;
	
	bit MCLK_DIV;
	always @(posedge clk_sys) MCLK_DIV <= ~MCLK_DIV;
	wire SYS_CE_R =  MCLK_DIV;
	wire SYS_CE_F = ~MCLK_DIV;
	
	reg [31:0] in_clk;
	always @(posedge clk_sys) 
		in_clk <= !PAL ? (!SMPC_DOTSEL ? 53748200 : 57272800) :
	                    (!SMPC_DOTSEL ? 53375000 : 56875000);

	
	wire SCSP_2X_CE;
	CEGen SCSP_CEGen
	(
		.CLK(clk_sys),
		.RST_N(1),
		.IN_CLK(in_clk),
		.IN_CE(1),
		.OUT_CLK(22579200*2),
		.CE(SCSP_2X_CE)
	);
	
	wire SCSP_CE;		//SCSP clock 22.5792MHz
	wire SCSP_DIV;
	always @(posedge clk_sys) 
		if (SCSP_2X_CE) SCSP_DIV <= ~SCSP_DIV;
		
	assign SCSP_CE = SCSP_2X_CE & SCSP_DIV;
		
	wire SMPC_CE;		//SMPC clock 4.0000MHz
	CEGen SMPC_CEGen
	(
		.CLK(clk_sys),
		.RST_N(1),
		.IN_CLK(22579200*2),
		.IN_CE(SCSP_2X_CE),
		.OUT_CLK(4000000),
		.CE(SMPC_CE)
	);
	
	wire CD_CE;			//CD clock freq 20.000MHz
	CEGen CD_CEGen
	(
		.CLK(clk_sys),
		.RST_N(1),
		.IN_CLK(22579200*2),
		.IN_CE(SCSP_2X_CE),
		.OUT_CLK(20000000*2),
		.CE(CD_CE)
	);
	
	wire CDD_2X_CE;	//CD data clock 44.1kHz x 2(channel) x 2(speed)
	CEGen CDD_CEGen
	(
		.CLK(clk_sys),
		.RST_N(1),
		.IN_CLK(22579200*2),
		.IN_CE(SCSP_2X_CE),
		.OUT_CLK(44100*2*2),
		.CE(CDD_2X_CE)
	);
	
	Saturn 
`ifdef MISTER_DUAL_SDRAM
	#(.RAMH_SLOW(0))
`else
	#(.RAMH_SLOW(1))
`endif
	saturn
	(
		.CLK(clk_sys),
		.RST_N(~rst_sys),
		.EN(~DBG_PAUSE),
		
		.SYS_CE_F(SYS_CE_F),
		.SYS_CE_R(SYS_CE_R),
		
		.SRES_N(~status[0]),
		
		.PAL(PAL),
		
		.MEM_A(MEM_A),
		.MEM_DI(MEM_DI),
		.MEM_DO(MEM_DO),
		.MEM_DQM_N(MEM_DQM_N),
		.ROM_CS_N(ROM_CS_N),
		.SRAM_CS_N(SRAM_CS_N),
		.RAML_CS_N(RAML_CS_N),
		.RAMH_CS_N(RAMH_CS_N),
		.RAMH_BURST(RAMH_BURST),
		.RAMH_RFS(RAMH_RFS),
`ifdef STV_BUILD
		.STVIO_CS_N(STVIO_CS_N),
`endif
		.MEM_RD_N(MEM_RD_N),
		.MEM_WAIT_N(MEM_WAIT_N),
		
		.VDP1_VRAM_A(VDP1_VRAM_A),
		.VDP1_VRAM_D(VDP1_VRAM_D),
		.VDP1_VRAM_WE(VDP1_VRAM_WE),
		.VDP1_VRAM_RD(VDP1_VRAM_RD),
		.VDP1_VRAM_BLEN(VDP1_VRAM_BLEN),
		.VDP1_VRAM_Q(VDP1_VRAM_Q),
		.VDP1_VRAM_RDY(VDP1_VRAM_RDY),
		.VDP1_FB0_A(VDP1_FB0_A),
		.VDP1_FB0_D(VDP1_FB0_D),
		.VDP1_FB0_WE(VDP1_FB0_WE),
		.VDP1_FB0_RD(VDP1_FB0_RD),
		.VDP1_FB0_Q(VDP1_FB0_Q),
		.VDP1_FB1_A(VDP1_FB1_A),
		.VDP1_FB1_D(VDP1_FB1_D),
		.VDP1_FB1_WE(VDP1_FB1_WE),
		.VDP1_FB1_RD(VDP1_FB1_RD),
		.VDP1_FB1_Q(VDP1_FB1_Q),
		.VDP1_FB_RDY(VDP1_FB_RDY),
		.VDP1_FB_MODE3(VDP1_FB_MODE3),
			
		.VDP2_RA0_A(VDP2_RA0_A),
		.VDP2_RA1_A(VDP2_RA1_A),
		.VDP2_RA_D(VDP2_RA_D),
		.VDP2_RA_WE(VDP2_RA_WE),
		.VDP2_RA_RD(VDP2_RA_RD),
		.VDP2_RA0_Q(VDP2_RA0_Q),
		.VDP2_RA1_Q(VDP2_RA1_Q),
		.VDP2_RB0_A(VDP2_RB0_A),
		.VDP2_RB1_A(VDP2_RB1_A),
		.VDP2_RB_D(VDP2_RB_D),
		.VDP2_RB_WE(VDP2_RB_WE),
		.VDP2_RB_RD(VDP2_RB_RD),
		.VDP2_RB0_Q(VDP2_RB0_Q),
		.VDP2_RB1_Q(VDP2_RB1_Q),
		
		.SCSP_CE(SCSP_CE),
		.SCSP_RAM_A(SCSP_RAM_A),
		.SCSP_RAM_D(SCSP_RAM_D),
		.SCSP_RAM_WE(SCSP_RAM_WE),
		.SCSP_RAM_RD(SCSP_RAM_RD),
		.SCSP_RAM_CS(SCSP_RAM_CS),
		.SCSP_RAM_Q(SCSP_RAM_Q),
		.SCSP_RAM_RFS(SCSP_RAM_RFS),
		.SCSP_RAM_RDY(SCSP_RAM_RDY),
		
		.SMPC_CE(SMPC_CE),
		.TIME_SET(~status[32]),
		.RTC(RTC),
		.SMPC_AREA(area_code),
		.SMPC_DOTSEL(SMPC_DOTSEL),
`ifndef STV_BUILD
		.SMPC_PDR1I(snac ? USERJOYSTICK : SMPC_PDR1I),
`else
		.SMPC_PDR1I(7'h5C),
`endif
		.SMPC_PDR1O(SMPC_PDR1O),
		.SMPC_DDR1(SMPC_DDR1),
`ifndef STV_BUILD
		.SMPC_PDR2I(SMPC_PDR2I),
`else
		.SMPC_PDR2I({6'b111111,STV_EEP_DO}),
`endif
		.SMPC_PDR2O(SMPC_PDR2O),
		.SMPC_DDR2(SMPC_DDR2),
		
`ifndef STV_BUILD
		.CD_CE(CD_CE),
		.CD_CDATA(CD_CDATA),
		.CD_HDATA(CD_HDATA),
		.CD_COMCLK(CD_COMCLK),
		.CD_COMREQ_N(CD_COMREQ_N),
		.CD_COMSYNC_N(CD_COMSYNC_N),
		.CD_D(CD_DATA),
		.CD_CK(CD_CK),
		.CD_AUDIO(CD_AUDIO),
		.CD_RAM_A(CD_RAM_A),
		.CD_RAM_D(CD_RAM_D),
		.CD_RAM_WE(CD_RAM_WE),
		.CD_RAM_RD(CD_RAM_RD),
		.CD_RAM_CS(CD_RAM_CS),
		.CD_RAM_Q(CD_RAM_Q),
		.CD_RAM_RDY(CD_RAM_RDY),
`endif
		
`ifndef STV_BUILD
		.CART_MODE(cart_type),
`else
		.STV_5881_MODE(STV_MODE[3:0] == 4'h1 ? STV_MODE[7:4] : 4'h0),
		.STV_5838_MODE(STV_MODE[3:0] == 4'h2),
		.STV_BATMAN_MODE(STV_MODE[3:0] == 4'h3),
`endif
		.CART_MEM_A(CART_MEM_A),
		.CART_MEM_D(CART_MEM_D),
		.CART_MEM_WE(CART_MEM_WE),
		.CART_MEM_RD(CART_MEM_RD),
		.CART_MEM_Q(CART_MEM_Q),
		.CART_MEM_RDY(CART_MEM_RDY),
		
`ifdef STV_BUILD
		.RAX_MEM_A(CART_RAX_MEM_A),
		.RAX_MEM_DI(CART_RAX_MEM_DI),
		.RAX_MEM_DO(CART_RAX_MEM_DO),
		.RAX_MEM_RD(CART_RAX_MEM_RD),
		.RAX_MEM_WR(CART_RAX_MEM_WR),
		.RAX_MEM_RDY(CART_RAX_MEM_RDY),
		.RAX_SOUND_L(RAX_SOUND_L),
		.RAX_SOUND_R(RAX_SOUND_R),
`endif
		
`ifdef STV_BUILD
		.STV_SW('1),
`endif
		
		.R(R),
		.G(G),
		.B(B),
		.DCLK(DCLK),
		.VS_N(VS_N),
		.HS_N(HS_N),
		.HBL_N(HBL_N),
		.VBL_N(VBL_N),
		
		.FIELD(FIELD),
		.INTERLACE(INTERLACE),
		.HRES(HRES), 				//[1]:0-normal,1-hi-res; [0]:0-320p,1-352p
		.VRES(VRES), 				//0-224,1-240,2-256
		.DCE_R(DCE_R),
		
		.SOUND_L(SOUND_L),
		.SOUND_R(SOUND_R),
		
		.FAST(fast_timing),
		.BLUR_MESH(blur_mesh),
		
		.SCRN_EN(SCRN_EN),
		.SND_EN(SND_EN),
		.DBG_PAUSE(DBG_PAUSE),
		.DBG_BREAK(DBG_BREAK),
		.DBG_RUN(DBG_RUN),
		.DBG_EXT(DBG_EXT)
	);
// NOTE (neptUNO+ port): MiSTer's Saturn.sv drives the top-level 16-bit
// AUDIO_L/AUDIO_R ports directly from here. On this board AUDIO_L/AUDIO_R
// are the single-bit delta-sigma DAC pins instead (driven from the VIDEO/
// AUDIO OUTPUT section below via SOUND_L/SOUND_R directly), so this
// assignment is dropped to avoid a second driver on those ports.
`ifdef STV_BUILD
	wire [15:0] audio_l_stv = STV_MODE[3:0] == 4'h3 ? RAX_SOUND_L : SOUND_L;
	wire [15:0] audio_r_stv = STV_MODE[3:0] == 4'h3 ? RAX_SOUND_R : SOUND_R;
`endif
	
`ifdef STV_BUILD
	wire [ 7:0] STVIO_DO;
	STVIO STVIO
	(
		.CLK(clk_sys),
		.RST_N(~rst_sys),
		.CE_R(SYS_CE_R),
		.CE_F(SYS_CE_F),
		
		.RES_N(1'b1),
		
		.A(MEM_A[6:1]),
		.DI(MEM_DO[7:0]),
		.DO(STVIO_DO),
		.CS_N(STVIO_CS_N),
		.RW_N(MEM_DQM_N[0]),
		
		.JOY1(joy1),
		.JOY2(joy2),
		
		.MODE(STV_MODE)
	);
	
	reg  [ 6: 1] STV_EEPROM_ADDR;
	reg          STV_EEPROM_RD;
	wire [15: 0] STV_EEPROM_Q;
	wire         STV_EEPROM_RDY;
	always @(posedge clk_sys) begin
		reg eep_load_skip = 0;
		reg [1:0] eep_state;
		reg bios_sel_old = 0;
		reg [3:0] stv_res_delay;
		
		STV_EEP_MEM_WREN <= 0;
		if (reset) begin
			STV_EEPROM_ADDR <= ioctl_addr[6:1];
			STV_EEP_MEM_DI <= {ioctl_data[7:0],ioctl_data[15:8]};
			STV_EEP_MEM_WREN <= save_download & ioctl_wr & ioctl_addr[16];
			if (save_download && !eep_load_skip) eep_load_skip <= 1;
			eep_state <= eep_load_skip ? 2'd3 : 2'd0;
			stv_res <= 1;
			stv_res_delay <= '0;
		end else begin
			bios_sel_old <= bios_sel;
			eep_load_skip <= 0;
			case (eep_state)
				2'd0: begin
					STV_EEPROM_RD <= 1;
					eep_state <= 2'd1;
				end
				
				2'd1: if (STV_EEPROM_RDY) begin
					STV_EEPROM_RD <= 0;
					if (STV_EEPROM_ADDR == 6'd0 && STV_EEPROM_Q != 16'h5345) begin
						//do not update, leave default eeprom.
						stv_res <= 0;
						eep_state <= 2'd3;
					end else begin
						STV_EEP_MEM_DI <= STV_EEPROM_Q;
						STV_EEP_MEM_WREN <= 1;
						eep_state <= 2'd2;
					end
				end
				
				2'd2: begin
					STV_EEPROM_ADDR <= STV_EEPROM_ADDR + 6'd1;
					if (STV_EEPROM_ADDR == 6'd63) begin
						stv_res <= 0;
						eep_state <= 2'd3;
					end
					else eep_state <= 2'd0;
				end
				
				2'd3: begin
					STV_EEPROM_ADDR <= ioctl_addr[6:1];
					
					if (bios_sel != bios_sel_old) begin
						stv_res <= 1;
						stv_res_delay <= 15;
					end
					
					if (stv_res_delay) stv_res_delay <= stv_res_delay - 1'd1;
					else if (stv_res) stv_res <= 0;
				end
			endcase
		end
	end
	
	wire         STV_EEP_DO;
	reg  [15: 0] STV_EEP_MEM_DI;
	reg  [15: 0] STV_EEP_MEM_DO;
	reg          STV_EEP_MEM_WREN;
	E93C45 #("rtl/stv_eeprom.mif") STV_EEP 
	(
		.CLK(clk_sys),
		.RST_N(~rst_sys),
		
		.DI(SMPC_PDR1O[4] & SMPC_DDR1[4]),
		.DO(STV_EEP_DO),
		.CS(SMPC_PDR1O[2] & SMPC_DDR1[2]),
		.SK(SMPC_PDR1O[3] & SMPC_DDR1[3]),
		
		.MEM_A(STV_EEPROM_ADDR),
		.MEM_DI(STV_EEP_MEM_DI),
		.MEM_WREN(STV_EEP_MEM_WREN),
		.MEM_DO(STV_EEP_MEM_DO)
	);
`endif
	
	assign USERJOYSTICKOUT = SMPC_PDR1O | ~SMPC_DDR1;	
	
`ifndef STV_BUILD
	HPS2PAD PAD
	(
		.CLK(clk_sys),
		.RST_N(~rst_sys),
		.SMPC_CE(SMPC_CE),
		
		.PDR1I(SMPC_PDR1I),
		.PDR1O(SMPC_PDR1O),
		.DDR1(SMPC_DDR1),
		.PDR2I(SMPC_PDR2I),
		.PDR2O(SMPC_PDR2O),
		.DDR2(SMPC_DDR2),
		
		.JOY1(status[76] ? joy2 : joy1),
		.JOY2(status[76] ? joy1 : joy2),

		.JOY1_X1(joy0_x0),
		.JOY1_Y1(joy0_y0),
		.JOY1_X2(joy0_x1),
		.JOY1_Y2(joy0_y1),
		.JOY2_X1(joy1_x0),
		.JOY2_Y1(joy1_y0),
		.JOY2_X2(joy1_x1),
		.JOY2_Y2(joy1_y1),

		.JOY1_TYPE(status[18:15]),
		.JOY2_TYPE(status[45:42]),

		.MOUSE(ps2_mouse),
		.MOUSE_EXT(ps2_mouse_ext),
		.PS2_KEY(ps2_key),
		.PS2_LED(ps2_kbd_led_status),
		
		.LGUN_P1_TRIG(lg_p1_a),
		.LGUN_P1_START(lg_p1_start),
		.LGUN_P1_SENSOR(lg_p1_sensor),
		
		.LGUN_P2_TRIG(lg_p2_a),
		.LGUN_P2_START(lg_p2_start),
		.LGUN_P2_SENSOR(lg_p2_sensor)		
	);
	
	
`ifndef DEBUG
	wire lg_p1_ena = (status[18:15]==4'd1);
	
	wire       lg_p1_sensor;
	wire       lg_p1_a;
	wire       lg_p1_b;
	wire       lg_p1_c;
	wire       lg_p1_start;

	wire       gun_p1_xy_mode    = status[46];
	wire       gun_p1_btn_mode   = status[47];
	wire [1:0] gun_p1_cross_size = status[49:48];
	wire [7:0] gun_p1_sensor_delay = 8'd2;

	wire CROSS_DRAW_P1;
	wire [2:0] lg_p1_target = {2'b00, CROSS_DRAW_P1};	// RED Crosshair.
	
	lightgun  lightgun_p1
	(
		.CLK(clk_sys),
		.RESET(rst_sys),

		.MOUSE(ps2_mouse),
		.MOUSE_XY(gun_p1_xy_mode),		// 0=Use joystick to control LGun XY.
												// 1=Use Mouse to control LGun XY.

		.JOY_X(joy0_x0),					// Player 1 joystick.
		.JOY_Y(joy0_y0),
		.JOY(joystick_0),

		.BTN_MODE(gun_p1_btn_mode),	// 0=Use Joystick buttons for LG.
												// 1=Use Mouse buttons for LG.
		
		.RELOAD(1'b1),						// Enable Auto-Reload.

		.HDE(HBL_N),						// Blanking signals are Active-Low. So should act as "DE" (Data Enable) signals when High!
		.VDE(VBL_N),						// ie. No need to invert here.
		.CE_PIX(DCLK),
		
		.FIELD(FIELD),
		.INTERLACE(INTERLACE),
		.HRES(HRES), 						// input [1:0]   [1]:0-normal,1-hi-res; [0]:0-320p,1-352p
		.VRES(VRES), 						// input [1:0]   0-224,1-240,2-256
		.DCE_R(DCE_R),
		
		.SIZE(gun_p1_cross_size),
		.SENSOR_DELAY(gun_p1_sensor_delay),	// Originally based on the MD lightgun module.
														// Not sure if any Saturn LG games use polling, or even need this? EA
		.CROSS_DRAW(CROSS_DRAW_P1),
		
		.SENSOR(lg_p1_sensor),		// output  SENSOR  ("Light detected" signal, to VDP2).
		.BTN_A(lg_p1_a),				// output  BTN_A   (used as the Trigger "button" signal, to HPS2PAD).
		.BTN_B(lg_p1_b),				// output  BTN_B   (used for Auto-Reload in this module - Don't use the BTN_B / lg_p1_b output when using the RELOAD option!)
		.BTN_C(lg_p1_c),
		.BTN_START(lg_p1_start)		// (used as the Start button signal, to HPS2PAD).
	);


	wire lg_p2_ena = (status[45:42]==4'd1);
	
	wire       lg_p2_sensor;
	wire       lg_p2_a;
	wire       lg_p2_b;
	wire       lg_p2_c;
	wire       lg_p2_start;

	wire       gun_p2_xy_mode    = status[57];
	wire       gun_p2_btn_mode   = status[58];
	wire [1:0] gun_p2_cross_size = status[60:59];
	wire [7:0] gun_p2_sensor_delay = 8'd2;
	
	wire CROSS_DRAW_P2;
	wire [2:0] lg_p2_target = {1'b0, CROSS_DRAW_P2, 1'b0};	// GREEN Crosshair.

	lightgun  lightgun_p2
	(
		.CLK(clk_sys),
		.RESET(rst_sys),

		.MOUSE(ps2_mouse),
		.MOUSE_XY(gun_p2_xy_mode),		// 0=Use joystick to control LGun XY.
												// 1=Use Mouse to control LGun XY.

		.JOY_X(joy1_x0),					// Player 2 joystick.
		.JOY_Y(joy1_y0),
		.JOY(joystick_1),

		.BTN_MODE(gun_p2_btn_mode),	// 0=Use Joystick buttons for LG.
												// 1=Use Mouse buttons for LG.
		
		.RELOAD(1'b1),						// Enable Auto-Reload.

		.HDE(HBL_N),						// Blanking signals are Active-Low. So should act as "DE" (Data Enable) signals when High!
		.VDE(VBL_N),						// ie. No need to invert here.
		.CE_PIX(DCLK),
		
		.FIELD(FIELD),
		.INTERLACE(INTERLACE),
		.HRES(HRES), 						// input [1:0]   [1]:0-normal,1-hi-res; [0]:0-320p,1-352p
		.VRES(VRES), 						// input [1:0]   0-224,1-240,2-256
		.DCE_R(DCE_R),
		
		.SIZE(gun_p2_cross_size),
		.SENSOR_DELAY(gun_p2_sensor_delay),	// Originally based on the MD lightgun module.
														// Not sure if any Saturn LG games use polling, or even need this? EA
		.CROSS_DRAW(CROSS_DRAW_P2),
		
		.SENSOR(lg_p2_sensor),		// output  SENSOR  ("Light detected" signal, to VDP2).
		.BTN_A(lg_p2_a),				// output  BTN_A   (used as the Trigger "button" signal, to HPS2PAD).
		.BTN_B(lg_p2_b),				// output  BTN_B   (used for Auto-Reload in this module - Don't use the BTN_B / lg_p1_b output when using the RELOAD option!)
		.BTN_C(lg_p2_c),
		.BTN_START(lg_p2_start)		// (used as the Start button signal, to HPS2PAD).
	);
`else
	wire lg_p1_ena = 0;
	wire lg_p1_a = 0;
	wire lg_p1_start = 0;
	wire lg_p1_sensor = 0;
	wire [2:0] lg_p1_target = '0;
	wire [1:0] gun_p1_cross_size = '0;
		
	wire lg_p2_ena = 0;
	wire lg_p2_a = 0;
	wire lg_p2_start = 0;
	wire lg_p2_sensor = 0;	
	wire [2:0] lg_p2_target = '0;
	wire [1:0] gun_p2_cross_size = '0;
`endif

	
	wire [13:1] CD_BUF_ADDR;
	wire [15:0] CD_BUF_DI;
	wire        CD_BUF_RD;
	wire        CD_BUF_RDY;
	HPS2CDD CDD (
		.CLK(clk_sys),
		.RST_N(~rst_sys),
		
		.EXT_BUS(EXT_BUS),
		
		.CDD_CE(CDD_2X_CE),
		.CD_CDATA(CD_CDATA),
		.CD_HDATA(CD_HDATA),
		.CD_COMCLK(CD_COMCLK),
		.CD_COMREQ_N(CD_COMREQ_N),
		.CD_COMSYNC_N(CD_COMSYNC_N),
		
		.CDD_ACT(cdd_download),
		.CDD_WR(ioctl_wr),
		.CDD_DI(ioctl_data),
		
		.CD_BUF_ADDR(CD_BUF_ADDR),
		.CD_BUF_DI(CD_BUF_DI),
		.CD_BUF_RD(CD_BUF_RD),
		.CD_BUF_RDY(CD_BUF_RDY),
			
		.CD_DATA(CD_DATA),
		.CD_CK(CD_CK),
		.CD_AUDIO(CD_AUDIO)
	);
`endif

	//SDRAM1
	sdram1 sdram1
	(
		.SDRAM_CLK(SDRAM_CLK),
		.SDRAM_A(SDRAM_A),
		.SDRAM_BA(SDRAM_BA),
		.SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CKE(SDRAM_CKE),
		
		.clk(clk_ram),
		.init(rst_ram),
		.sync(DCE_R),
	
		.addr_a0(VDP2_RA0_A[17:1]),
		.addr_a1(VDP2_RA1_A[16:1]),
		.din_a(VDP2_RA_D),
		.wr_a(VDP2_RA_WE),
		.rd_a(VDP2_RA_RD),
		.dout_a0(VDP2_RA0_Q),
		.dout_a1(VDP2_RA1_Q),
	
		.addr_b0(VDP2_RB0_A[17:1]),
		.addr_b1(VDP2_RB1_A[16:1]),
		.din_b(VDP2_RA_D),///////////////
		.wr_b(VDP2_RB_WE),
		.rd_b(VDP2_RB_RD),
		.dout_b0(VDP2_RB0_Q),
		.dout_b1(VDP2_RB1_Q),
		
		.ch2addr({1'b0,SCSP_RAM_A}),
		.ch2din(SCSP_RAM_D),
		.ch2wr(SCSP_RAM_WE & {2{SCSP_RAM_CS}}),
		.ch2rd(SCSP_RAM_RD & SCSP_RAM_CS),
		.ch2dout(SCSP_RAM_Q),
		.ch2rdy(SCSP_RAM_RDY)
	);

	//DDRAM
	always @(posedge clk_sys) begin
		ioctl_wait <= (bios_download && bios_busy) || (cart_download && bios_busy) || (save_download && bsram_busy) || (save_upload && bsram_busy);
	end
	wire [26: 1] IO_ADDR = cart_download ? {1'b1,ioctl_addr[25:1]} : {8'b00000000,ioctl_addr[18:1]};
	wire [15: 0] IO_DATA = {ioctl_data[7:0],ioctl_data[15:8]};
	wire         IO_WR = (bios_download | cart_download) & ioctl_wr;
	
`ifndef STV_BUILD
	reg  [31: 0] ramh_din;
	reg  [ 3: 0] ramh_wr;
	always @(posedge clk_ram) begin
		ramh_din <= dezaemon2_hack && MEM_A[19:0] == 20'h1746C && MEM_DO == 32'h5A015E01 ? 32'h5A115E01 : MEM_DO;
		ramh_wr <= {4{~RAMH_CS_N}} & ~MEM_DQM_N;
	end
	wire [21: 1] raml_addr = {~RAML_CS_N,~SRAM_CS_N,ROM_CS_N&SRAM_CS_N&MEM_A[19],MEM_A[18:1]};
`else
	wire [31: 0] ramh_din = MEM_DO;
	wire [ 3: 0] ramh_wr = {4{~RAMH_CS_N}} & ~MEM_DQM_N;
	
	wire [21: 1] raml_addr = !RAML_CS_N ? {2'b10,MEM_A[19:1]} :
	                         !SRAM_CS_N ? {6'b010000,MEM_A[15:1]} :
									              {2'b00,bios_sel,MEM_A[18:1]};
`endif
	
	wire [15:0] cdram_do,raml_do,vdp1vram_do,vdp1fb_do,cdbuf_do,cart_do,eeprom_do,bsram_do,rax_do;
	wire [31:0] ramh_do;
	wire        cdram_busy,raml_busy,ramh_busy,vdp1vram_busy,vdp1fb_busy,cdbuf_busy,cart_busy,eeprom_busy,bios_busy,bsram_busy,rax_busy;
	ddram ddram
	(
		.*,
		.clk(clk_ram),
		.rst(reset || rst_ram),
		
		//CPU bus (RAMH)
`ifdef MISTER_DUAL_SDRAM
		.ramh_addr('0),
		.ramh_din ('0),
		.ramh_wr  ('0),
		.ramh_rd  (0),
`else
		.ramh_addr(MEM_A[19:2]),
		.ramh_din (ramh_din),
		.ramh_wr  (ramh_wr),
		.ramh_rd  (~RAMH_CS_N & ~MEM_RD_N),
`endif
		.ramh_dout(ramh_do),
		.ramh_busy(ramh_busy),
		
`ifndef STV_BUILD
		//CD RAM
		.cdram_addr(CD_RAM_A[18:1]),
		.cdram_din (CD_RAM_D),
		.cdram_wr  (CD_RAM_WE & {2{CD_RAM_CS}}),
		.cdram_rd  (CD_RAM_RD & CD_RAM_CS),
		.cdram_dout(cdram_do),
		.cdram_busy(cdram_busy),
`endif
	
		//CPU bus (ROM,SRAM,RAML)
		.raml_addr(raml_addr),
		.raml_din (MEM_DO[15:0]),
		.raml_wr  ({2{~SRAM_CS_N|~RAML_CS_N}} & ~MEM_DQM_N[1:0]),
		.raml_rd  ((~ROM_CS_N | ~SRAM_CS_N | ~RAML_CS_N) & ~MEM_RD_N),
		.raml_dout(raml_do),
		.raml_busy(raml_busy),
	
		//VDP1 VRAM
		.vdp1vram_addr(VDP1_VRAM_A[18:1]),
		.vdp1vram_din (VDP1_VRAM_D),
		.vdp1vram_wr  (VDP1_VRAM_WE),
		.vdp1vram_rd  (VDP1_VRAM_RD),
		.vdp1vram_blen(VDP1_VRAM_BLEN),
		.vdp1vram_dout(vdp1vram_do),
		.vdp1vram_busy(vdp1vram_busy),
	
		//VDP1 FB (rest)
		.vdp1fb_addr(VDP1_A),
		.vdp1fb_din (VDP1_D),
		.vdp1fb_wr  (VDP1_WE),
		.vdp1fb_rd  (VDP1_RD),
		.vdp1fb_dout(vdp1fb_do),
		.vdp1fb_busy(vdp1fb_busy),
		
`ifndef STV_BUILD
		//CD BUF
		.cdbuf_addr(CD_BUF_ADDR),
		.cdbuf_rd  (CD_BUF_RD),
		.cdbuf_dout(cdbuf_do),
		.cdbuf_busy(cdbuf_busy),
`endif
		
		//CART MEM (0x34000000)
`ifdef DEBUG
		.cart_addr('0),
		.cart_din ('0),
		.cart_wr  ('0),
		.cart_rd  (0),
`else
		.cart_addr(CART_MEM_A),
		.cart_din (CART_MEM_D),
		.cart_wr  (CART_MEM_WE),
		.cart_rd  (CART_MEM_RD),
`endif
		.cart_dout(cart_do),
		.cart_busy(cart_busy),
		
`ifdef STV_BUILD
		//STV EEPROM (0x32000000)
		.eeprom_addr(STV_EEPROM_ADDR),
		.eeprom_rd  (STV_EEPROM_RD),
		.eeprom_dout(eeprom_do),
		.eeprom_busy(eeprom_busy),
		
		//STV RAX ROM (0x36000000)
		.rax_addr(CART_RAX_MEM_A[24:1]),
		.rax_din (CART_RAX_MEM_DO),
		.rax_wr  ({2{CART_RAX_MEM_WR&CART_RAX_MEM_A[24]}}),
		.rax_rd  (CART_RAX_MEM_RD),
		.rax_dout(rax_do),
		.rax_busy(rax_busy),
`endif
	
		//BIOS/CART load
		.bios_addr(IO_ADDR),
		.bios_din (IO_DATA),
		.bios_wr  ({2{IO_WR}}),
		.bios_busy(bios_busy),
		
		//SRAM backup
`ifndef STV_BUILD
		.bsram_addr(sd_lba[11:7] ? {1'b1,sd_lba[10:7]-4'h1,sd_lba[6:0],tmpram_addr} : {5'b00000,sd_lba[6:0],tmpram_addr}),
		.bsram_din ({8'hFF,tmpram_dout[15:8]}),
		.bsram_wr  ({2{tmpram_req & bk_loading}}),
		.bsram_rd  ((tmpram_req & ~bk_loading)),
`else
		.bsram_addr({5'b00000,ioctl_addr[15:1]}),
		.bsram_din ({8'hFF,ioctl_data[15:8]}),
		.bsram_wr  ({2{save_download & ioctl_wr & ~ioctl_addr[16]}}),
		.bsram_rd  (save_upload & ioctl_rd & ~ioctl_addr[16]),
`endif
		.bsram_dout(bsram_do),
		.bsram_busy(bsram_busy)
	);
	assign VDP1_VRAM_Q = vdp1vram_do;
	assign VDP1_VRAM_RDY = ~vdp1vram_busy;

`ifndef STV_BUILD
	assign CD_RAM_Q = cdram_do;
	assign CD_RAM_RDY = ~cdram_busy;
	
	assign CD_BUF_DI = cdbuf_do;
	assign CD_BUF_RDY = ~cdbuf_busy;
	
	assign CART_MEM_Q = cart_do;
	assign CART_MEM_RDY = ~cart_busy;
	
	assign ioctl_din = '0;
`else
	assign CART_MEM_Q = STV_MODE[3:0] == 4'h4 ? ~{{cart_do[14],cart_do[8],cart_do[13],cart_do[15],cart_do[9],cart_do[11],cart_do[12],cart_do[10]},{cart_do[6],cart_do[0],cart_do[5],cart_do[7],cart_do[1],cart_do[3],cart_do[4],cart_do[2]}} : //sanjeon
	                    CART_MEM_A >= (26'h0200000>>1) ? {cart_do[7:0],cart_do[15:8]} : cart_do;
	assign CART_MEM_RDY = ~cart_busy;
	
	assign STV_EEPROM_Q = eeprom_do;
	assign STV_EEPROM_RDY = ~eeprom_busy;
	
	assign CART_RAX_MEM_DI = rax_do;
	assign CART_RAX_MEM_RDY = ~rax_busy;
	
	assign ioctl_din = !ioctl_addr[16] ? {bsram_do[7:0],bsram_do[15:8]} : {STV_EEP_MEM_DO[7:0],STV_EEP_MEM_DO[15:8]};
`endif


`ifdef MISTER_DUAL_SDRAM
	//SDRAM2
	wire sdr2_busy;
	wire [31:0] sdr2_do;
	sdram2 sdram2
	(
		.SDRAM_CLK(SDRAM2_CLK),
		.SDRAM_A(SDRAM2_A),
		.SDRAM_BA(SDRAM2_BA),
		.SDRAM_DQ(SDRAM2_DQ),
		.SDRAM_nCS(SDRAM2_nCS),
		.SDRAM_nWE(SDRAM2_nWE),
		.SDRAM_nRAS(SDRAM2_nRAS),
		.SDRAM_nCAS(SDRAM2_nCAS),
		
		.init(rst_ram),
		.clk(clk_ram),
		
		.addr(MEM_A[19:2]),
		.din(ramh_din),
		.wr(ramh_wr),
		.rd(~RAMH_CS_N & ~MEM_RD_N),
		.burst(RAMH_BURST),
		.dout(sdr2_do),
		.rfs(~RAMH_CS_N & RAMH_RFS),
		.busy(sdr2_busy)
	);
`endif
	
`ifdef MISTER_DUAL_SDRAM

	assign MEM_DI     = !RAMH_CS_N ? sdr2_do : 
`ifdef STV_BUILD
	                    !STVIO_CS_N ? {24'hFFFFFF,STVIO_DO} : 
`endif
							  raml_do;
	assign MEM_WAIT_N = !RAMH_CS_N ? ~sdr2_busy : 
`ifdef STV_BUILD
	                    !STVIO_CS_N ? 1'b1 : 
`endif
							  ~raml_busy;
							  
`else

	assign MEM_DI     = !RAMH_CS_N ? ramh_do : 
`ifdef STV_BUILD
	                    !STVIO_CS_N ? {24'hFFFFFF,STVIO_DO} : 
`endif
							  raml_do;
	assign MEM_WAIT_N = !RAMH_CS_N ? ~ramh_busy : 
`ifdef STV_BUILD
	                    !STVIO_CS_N ? 1'b1 : 
`endif
							  ~raml_busy;
							  
`endif


	//VDP1 FB
`ifdef SATURN_FULL_FB
	wire        FB0_EXT_SEL = 0;
	wire        FB1_EXT_SEL = 0;
`else
	wire        FB0_EXT_SEL = VDP1_FB_MODE3 ? VDP1_FB0_A[17:9] >= 9'd352 : VDP1_FB0_A[9:1] >= 9'd352;
	wire        FB1_EXT_SEL = VDP1_FB_MODE3 ? VDP1_FB1_A[17:9] >= 9'd352 : VDP1_FB1_A[9:1] >= 9'd352;
	bit  [15:0] FB0_EXT_Q;
	bit  [15:0] FB1_EXT_Q;
`endif
	wire [17:1] FB0_A = VDP1_FB_MODE3 ? {VDP1_FB0_A[17:9],VDP1_FB0_A[8:1]} : {VDP1_FB0_A[9:1],VDP1_FB0_A[17:10]};
	wire [17:1] FB1_A = VDP1_FB_MODE3 ? {VDP1_FB1_A[17:9],VDP1_FB1_A[8:1]} : {VDP1_FB1_A[9:1],VDP1_FB1_A[17:10]};
	
	bit [15:0] FB0_Q,FB1_Q;
`ifdef SATURN_FULL_FB
	vdp1_fb_512x256x16 vdp1_fb0
	(
		.clock(clk_sys),
		.address(FB0_A),
		.data(VDP1_FB0_D),
		.wren(VDP1_FB0_WE),
		.q(FB0_Q)
	);

	vdp1_fb_512x256x16 vdp1_fb1
	(
		.clock(clk_sys),
		.address(FB1_A),
		.data(VDP1_FB1_D),
		.wren(VDP1_FB1_WE),
		.q(FB1_Q)
	);
`else
	//first 352x256x16 bit
	vdp1_fb_352x256x16 vdp1_fb0
	(
		.clock(clk_sys),
		.address(FB0_A),
		.data(VDP1_FB0_D),
		.wren(VDP1_FB0_WE & {2{~FB0_EXT_SEL}}),
		.q(FB0_Q)
	);

	vdp1_fb_352x256x16 vdp1_fb1
	(
		.clock(clk_sys),
		.address(FB1_A),
		.data(VDP1_FB1_D),
		.wren(VDP1_FB1_WE & {2{~FB1_EXT_SEL}}),
		.q(FB1_Q)
	);
`endif

	assign VDP1_FB0_Q = !FB0_EXT_SEL ? FB0_Q : FB0_EXT_Q;
	assign VDP1_FB1_Q = !FB1_EXT_SEL ? FB1_Q : FB1_EXT_Q;

`ifndef SATURN_FULL_FB
`ifndef DEBUG
	bit [18:1] VDP1_A;
	bit [15:0] VDP1_D;
	bit [ 1:0] VDP1_WE;
	bit        VDP1_RD;
	bit        VDP1_FB0_BUSY;
	bit        VDP1_FB1_BUSY;
	always @(posedge clk_ram) begin
		reg vram_rd_old,fb0_rd_old,fb1_rd_old;
		reg vram_we_old,fb0_we_old,fb1_we_old;
		reg [1:0] VDP1_FB0_WPEND;
		reg [1:0] VDP1_FB1_WPEND;
		reg VDP1_FB0_RPEND;
		reg VDP1_FB1_RPEND;
		reg [1:0] vdp1_state;
		
		if (rst_sys) begin
			VDP1_FB0_WPEND <= '0;
			VDP1_FB1_WPEND <= '0;
			VDP1_FB0_RPEND <= 0;
			VDP1_FB1_RPEND <= 0;
			VDP1_FB0_BUSY <= 0;
			VDP1_FB1_BUSY <= 0;
			VDP1_WE <= '0;
			VDP1_RD <= 0;
			vdp1_state <= '0;
		end else begin
			//VDP1 FB0 (rest 160x256x16 bit)
			fb0_rd_old <= VDP1_FB0_RD;
			fb0_we_old <= |VDP1_FB0_WE;
			if (((VDP1_FB0_RD && !fb0_rd_old) || (VDP1_FB0_WE && !fb0_we_old)) && FB0_EXT_SEL) begin
				VDP1_FB0_WPEND <= VDP1_FB0_WE;  
				VDP1_FB0_RPEND <= VDP1_FB0_RD;  
				VDP1_FB0_BUSY <= 1;
			end
			
			//VDP1 FB1 (rest 160x256x16 bit)
			fb1_rd_old <= VDP1_FB1_RD;
			fb1_we_old <= |VDP1_FB1_WE;
			if (((VDP1_FB1_RD && !fb1_rd_old) || (VDP1_FB1_WE && !fb1_we_old)) && FB1_EXT_SEL) begin
				VDP1_FB1_WPEND <= VDP1_FB1_WE;  
				VDP1_FB1_RPEND <= VDP1_FB1_RD; 
				VDP1_FB1_BUSY <= 1;
			end
			
			VDP1_WE <= '0;
			VDP1_RD <= 0;
			case (vdp1_state)
				2'd0: begin
					if ((VDP1_FB0_RD && FB0_EXT_SEL) || VDP1_FB0_RPEND) begin
						VDP1_A <= {1'b0,FB0_A};
						VDP1_RD <= 1;
						VDP1_FB0_RPEND <= 0; 
						vdp1_state <= 2'd1;
					end else if (VDP1_FB0_WPEND && !VDP1_WE) begin
						if (!vdp1fb_busy) begin
							VDP1_A <= {1'b0,FB0_A};
							VDP1_D <= VDP1_FB0_D;
							VDP1_WE <= VDP1_FB0_WPEND;
							VDP1_FB0_WPEND <= '0;
							VDP1_FB0_BUSY <= 0;
							vdp1_state <= 2'd0;
						end
					end else if ((VDP1_FB1_RD && FB1_EXT_SEL) || VDP1_FB1_RPEND) begin
						VDP1_A <= {1'b1,FB1_A};
						VDP1_RD <= 1;
						VDP1_FB1_RPEND <= 0; 
						vdp1_state <= 2'd2;
					end else if (VDP1_FB1_WPEND && !VDP1_WE) begin
						if (!vdp1fb_busy) begin
							VDP1_A <= {1'b1,FB1_A};
							VDP1_D <= VDP1_FB1_D;
							VDP1_WE <= VDP1_FB1_WPEND;
							VDP1_FB1_WPEND <= '0;
							VDP1_FB1_BUSY <= 0;
							vdp1_state <= 2'd0;
						end
					end
				end
				
				2'd1: begin
					if (!vdp1fb_busy && !VDP1_RD) begin
						FB0_EXT_Q <= vdp1fb_do;
						VDP1_FB0_BUSY <= 0;
						vdp1_state <= 2'd0;
					end
				end
				
				2'd2: begin
					if (!vdp1fb_busy && !VDP1_RD) begin
						FB1_EXT_Q <= vdp1fb_do;
						VDP1_FB1_BUSY <= 0;
						vdp1_state <= 2'd0;
					end
				end
				
				default:;
			endcase
		end
	end
	assign VDP1_FB_RDY = ~(VDP1_FB0_BUSY | VDP1_FB1_BUSY);
`else
	wire [24:1] VDP1_A = '0;
	wire [15:0] VDP1_D = '0;
	wire [ 1:0] VDP1_WE = '0;
	wire        VDP1_RD = 0;
	
	assign FB0_EXT_Q = '0;
	assign FB1_EXT_Q = '0;
	assign VDP1_FB_RDY = 1;
`endif
`endif

/////////////////////////  BRAM SAVE/LOAD  /////////////////////////////
`ifndef STV_BUILD
	wire downloading = save_download;
	wire bk_cart    = cart_type == 3'h5;
	wire bk_change  = (~SRAM_CS_N & ~MEM_DQM_N[0]) | (CART_MEM_WE[0] & bk_cart);
	wire bk_load    = status[24];
	wire bk_save    = status[25];
	wire autosave   = status[26];

	reg bk_ena = 0;
	reg sav_pending = 0;
	always @(posedge clk_sys) begin
		reg old_downloading = 0;
		reg old_change = 0;

		old_downloading <= downloading;
		if(downloading && !old_downloading) bk_ena <= 0;

		//Save file always mounted in the end of downloading state.
		if(downloading && img_mounted[1] && !img_readonly) bk_ena <= 1;

		old_change <= bk_change;
		if (bk_change && !old_change) sav_pending <= 1;
		else if (bk_state) sav_pending <= 0;
	end

	wire bk_save_a  = autosave & OSD_STATUS;
	reg  bk_loading = 0;
	reg  bk_state   = 0;
	//reg  bk_reload  = 0;
	wire [11:0] last_block = {bk_cart,11'h07F};

	always @(posedge clk_sys) begin
		reg old_downloading = 0;
		reg old_load = 0, old_save = 0, old_save_a = 0, old_ack;
		reg [1:0] state;

		old_downloading <= downloading;

		old_load   <= bk_load;
		old_save   <= bk_save;
		old_save_a <= bk_save_a;
		old_ack    <= sd_ack;

		if(sd_ack && !old_ack) {sd_rd, sd_wr} <= 0;

		if (!bk_state) begin
			tmpram_tx_start <= 0;
			state <= 0;
			sd_lba <= 0;
	//		bk_reload <= 0;
			bk_loading <= 0;
			if (bk_ena && ((bk_load && !old_load) | (bk_save && !old_save) | (bk_save_a && !old_save_a && sav_pending))) begin
				bk_state <= 1;
				bk_loading <= bk_load;
	//			bk_reload <= bk_load;
				sd_rd <=  bk_load;
				sd_wr <= 0;
			end
			if (old_downloading && !bios_download && !cart_download && bk_ena) begin
				bk_state <= 1;
				bk_loading <= 1;
				sd_rd <= 1;
				sd_wr <= 0;
			end
		end
		else begin
			if (bk_loading) begin
				case(state)
					0: begin
							sd_rd <= 1;
							state <= 1;
						end
					1: if (!sd_ack && old_ack) begin
							tmpram_tx_start <= 1;
							state <= 2;
						end
					2: if(tmpram_tx_finish) begin
							tmpram_tx_start <= 0;
							state <= 0;
							sd_lba <= sd_lba + 1'd1;
							if (sd_lba[11:0] == last_block) bk_state <= 0;
						end
				endcase
			end
			else begin
				case(state)
					0: begin
							tmpram_tx_start <= 1;
							state <= 1;
						end
					1: if (tmpram_tx_finish) begin
							tmpram_tx_start <= 0;
							sd_wr <= 1;
							state <= 2;
						end
					2: if (!sd_ack && old_ack) begin
							state <= 0;
							sd_lba <= sd_lba + 1'd1;
							if (sd_lba[11:0] == last_block) bk_state <= 0;
						end
				endcase
			end
		end
	end

	wire [15:0] tmpram_dout;
	wire [15:0] tmpram_din = {bsram_do[7:0],bsram_do[15:8]};
	wire        tmpram_busy = bsram_busy;

	// NOTE (neptUNO+ port): side B was widened from the MiSTer hps_io "WIDE(1)"
	// 16-bit/8-bit-word-address sd_buff bus to classic MiST user_io's 8-bit/
	// 9-bit-byte-address sd_buff bus (same 512-byte/4096-bit total capacity).
	wire [7:0] tmpram_sd_buff_q;
	dpram_dif #(8,16,9,8) tmpram
	(
		.clock(clk_sys),

		.address_a(tmpram_addr),
		.wren_a(~bk_loading & tmpram_req & ~tmpram_busy),
		.data_a(tmpram_din),
		.q_a(tmpram_dout),

		.address_b(sd_buff_addr),
		.wren_b(sd_buff_wr & sd_ack /*& |sd_lba[10:4]*/),
		.data_b(sd_buff_dout),
		.q_b(tmpram_sd_buff_q)
	);

	reg  [8:1] tmpram_addr;
	reg tmpram_tx_start;
	reg tmpram_tx_finish;
	reg tmpram_req;
	always @(posedge clk_sys) begin
		reg state;
		
		if (tmpram_req && !tmpram_busy) tmpram_req <= 0;

		if (~tmpram_tx_start) {tmpram_addr, state, tmpram_tx_finish} <= '0;
		else if (~tmpram_tx_finish) begin
			if (!state) begin
				tmpram_req <= 1;
				state <= 1;
			end
			else if (tmpram_req && !tmpram_busy) begin
				state <= 0;
				if (~&tmpram_addr) tmpram_addr <= tmpram_addr + 1'd1;
				else tmpram_tx_finish <= 1;
			end
		end
	end

	assign sd_buff_din = tmpram_sd_buff_q; 
	assign ioctl_upload_req = 0;
`else
	wire bk_change  = (~SRAM_CS_N & ~MEM_DQM_N[0]);
	wire bk_load    = status[24];
	wire bk_save    = status[25];
	wire autosave   = status[26];
	
	wire bk_save_a  = autosave & OSD_STATUS;
	
	reg bk_save_req = 0;
	always @(posedge clk_sys) begin
		reg old_save = 0,old_save_a = 0;
		reg old_change;
		reg sav_pending;

		old_change <= bk_change;
		if (bk_change && !old_change) sav_pending <= 1;
		
		old_save <= bk_save;
		old_save_a <= bk_save_a;
		if((bk_save && !old_save) || (bk_save_a && !old_save_a && sav_pending)) begin
			bk_save_req <= 1; 
			sav_pending <= 0;
		end
		else begin
			bk_save_req <= 0;
		end
	end
	
	assign ioctl_upload_req = bk_save_req;
`endif

	
/////////////////////////  Video  /////////////////////////////
	wire PAL = (area_code >= 4'hA);//status[7];
	
	reg new_vmode;
	always @(posedge clk_sys) begin
		reg old_pal;
		int to;
		
		if(!rst_sys) begin
			old_pal <= PAL;
			if(old_pal != PAL) to <= 5000000;
		end
		else to <= 5000000;
		
		if(to) begin
			to <= to - 1;
			if(to == 1) new_vmode <= ~new_vmode;
		end
	end
	
	assign VGA_F1 = FIELD;
	
	//lock resolution for the whole frame.
	reg [3:0] res = 4'b0000;
	always @(posedge clk_sys) begin
		reg old_vbl;
		
		old_vbl <= VBL_N;
		if(old_vbl & ~VBL_N) res <= {VRES,HRES};
	end
	
//`ifndef DEBUG
	wire [2:0] scale = status[3:1];
	wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
//	wire scandoubler = ~INTERLACE & (|scale | forced_scandoubler);
//	wire hq2x = (scale == 1);
//`else
//	wire [2:0] sl = '0;
	wire scandoubler = 0;
	wire hq2x = 0;
//`endif

	//horizontal crop
`ifndef DEBUG
	wire hcrop_en = status[64];

	reg [9:0] h_count;
	wire active_video = ~cofi_hbl;

	always @(posedge clk_sys) begin
		if (DCLK) begin
			h_count <= active_video ? h_count + 10'd1 : 10'd0;
		end
	end

	wire [9:0] active_width = (HRES[1] && HRES[0]) ? 10'd704 :
	(HRES[1]) ? 10'd640 :
	(HRES[0]) ? 10'd352 :
	10'd320;

	wire [9:0] crop_amount = hcrop_en ? ((active_width == 10'd704) ? 10'd4 : (INTERLACE ? 10'd4 : 10'd2)) : 10'd0;

	wire hcrop_blank = (h_count < crop_amount) || (h_count >= (active_width - crop_amount));
	
	wire [7:0] cofi_r, cofi_g, cofi_b;
	wire       cofi_hs, cofi_vs, cofi_hbl, cofi_vbl;

	cofi coffee (
		.clk(clk_sys),
		.pix_ce(DCLK),          
		.enable(status[50]),    
		.hblank(~HBL_N),        
		.vblank(~VBL_N),
		.hs(~HS_N),
		.vs(~VS_N),
		.red(R),
		.green(G),
		.blue(B),
		.hblank_out(cofi_hbl),
		.vblank_out(cofi_vbl),
		.hs_out(cofi_hs),
		.vs_out(cofi_vs),
		.red_out(cofi_r),
		.green_out(cofi_g),
		.blue_out(cofi_b)
	);
`else
	wire [7:0] cofi_r = R, cofi_g = G, cofi_b = B;
	wire cofi_hs = ~HS_N, cofi_vs = ~VS_N;
	wire cofi_hbl = ~HBL_N, cofi_vbl = ~VBL_N;
`endif

`ifndef STV_BUILD
	wire lg_p1_targ_draw = (|lg_p1_target) && lg_p1_ena && (gun_p1_cross_size < 2'd3);
	wire lg_p2_targ_draw = (|lg_p2_target) && lg_p2_ena && (gun_p2_cross_size < 2'd3);
	wire [7:0] mixer_r = lg_p1_targ_draw ? {8{lg_p1_target[0]}} : lg_p2_targ_draw ? {8{lg_p2_target[0]}} : cofi_r;
	wire [7:0] mixer_g = lg_p1_targ_draw ? {8{lg_p1_target[1]}} : lg_p2_targ_draw ? {8{lg_p2_target[1]}} : cofi_g;
	wire [7:0] mixer_b = lg_p1_targ_draw ? {8{lg_p1_target[2]}} : lg_p2_targ_draw ? {8{lg_p2_target[2]}} : cofi_b;
	wire [7:0] crop_r = (hcrop_en && hcrop_blank) ? 8'd0 : mixer_r;
	wire [7:0] crop_g = (hcrop_en && hcrop_blank) ? 8'd0 : mixer_g;
	wire [7:0] crop_b = (hcrop_en && hcrop_blank) ? 8'd0 : mixer_b;
`else
	wire [7:0] crop_r = (hcrop_en && hcrop_blank) ? 8'd0 : cofi_r;
	wire [7:0] crop_g = (hcrop_en && hcrop_blank) ? 8'd0 : cofi_g;
	wire [7:0] crop_b = (hcrop_en && hcrop_blank) ? 8'd0 : cofi_b;
`endif

//adjust analog H/V
	wire analog_hs, analog_vs;
	
`ifdef STV_BUILD
	wire [4:0] hoffset = status[75] ? status[69:65] : 5'd0;
	wire [4:0] voffset = status[75] ? status[74:70] : 5'd0;

	jtframe_resync #(5) resync (
		.clk(clk_sys),
		.pxl_cen(DCLK),
		.hs_in(cofi_hs),
		.vs_in(cofi_vs),
		.LVBL(~cofi_vbl),
		.LHBL(~cofi_hbl),
		.hoffset(-hoffset),
		.voffset(-voffset),
		.hres_mode(HRES[1]),
		.hs_out(analog_hs),
		.vs_out(analog_vs)
	);
`else
	assign analog_hs = cofi_hs;
	assign analog_vs = cofi_vs;
`endif
	
	//debug
	reg  [ 7: 0] SCRN_EN = 8'b11111111;
	reg  [ 2: 0] SND_EN = 3'b111;
	reg          DBG_PAUSE = 0;
	reg          DBG_BREAK = 0;
	reg          DBG_RUN = 0;
	
	reg  [ 7: 0] DBG_EXT = '0;

/////////////////////////  EXPANSION SDRAM (ddram.sv backing store)  ////////
// rtl/ddram.sv (from files_core.qip, unmodified) drives DDRAM_CLK/BUSY/
// BURSTCNT/ADDR/DOUT/DOUT_READY/RD/DIN/BE/WE via the `.*` port binding on
// its instantiation above. MiSTer's own top level wires those to physical
// DDR3 pins; this board has no DDR3, so they're bridged to the expansion
// SDRAM chip (edge connector) instead.
//
// Deliberately on the SAME clk_ram domain as ddram.sv itself (and
// sdram1.sv) - no second clock domain, no CDC synchronizers. sdram2_ctrl's
// own altddio_out generates a correctly-phased SDRAM2_CLK pin from
// whatever clock it's given, so clk_ram doesn't need to already be
// phase-shifted going in. See docs/NEPTUNOPLUS_PORT.md for why an earlier
// attempt with a separate, phase-shifted clk_ram2 domain (and 2-FF req/ack
// synchronizers into it) hit a CDC pulse-loss bug here instead.
wire        DDRAM_CLK;        // unused: ddram.sv's own echo of its clk input
wire        DDRAM_BUSY;
wire  [7:0] DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT;
wire        DDRAM_DOUT_READY;
wire        DDRAM_RD;
wire [63:0] DDRAM_DIN;
wire  [7:0] DDRAM_BE;
wire        DDRAM_WE;

wire [26:1] sd2_addr;
wire [15:0] sd2_dout, sd2_din;
wire  [1:0] sd2_bs;
wire        sd2_wr, sd2_rd, sd2_ready, sd2_idle;

avalon_sdram_bridge sdram2_bridge
(
	.clk   (clk_ram),
	.reset (reset || rst_ram), // same reset condition ddram.sv itself uses

	.av_addr          (DDRAM_ADDR),
	.av_din           (DDRAM_DIN),
	.av_dout          (DDRAM_DOUT),
	.av_read          (DDRAM_RD),
	.av_write         (DDRAM_WE),
	.av_be            (DDRAM_BE),
	.av_burstcount    (DDRAM_BURSTCNT),
	.av_waitrequest   (DDRAM_BUSY),
	.av_readdatavalid (DDRAM_DOUT_READY),

	.sd_addr (sd2_addr),
	.sd_dout (sd2_dout),
	.sd_din  (sd2_din),
	.sd_wr   (sd2_wr),
	.sd_bs   (sd2_bs),
	.sd_rd   (sd2_rd),
	.sd_ready(sd2_ready),
	.sd_idle (sd2_idle)
);

// Conservative free-running refresh request: toggles every 256 clk_ram
// cycles (~2.4us @ 107.5MHz), more often than the ~7.8us an 8192-row chip
// actually needs - costs a little spare bandwidth, not correctness.
reg [8:0] sd2_ref_cnt;
always @(posedge clk_ram) sd2_ref_cnt <= sd2_ref_cnt + 1'd1;

sdram sdram2_ctrl
(
	.init    (rst_ram),
	.clk     (clk_ram),
	.SDRAM_EN(1'b1),

	.SDRAM_DQ  (SDRAM2_DQ),
	.SDRAM_A   (SDRAM2_A),
	.SDRAM_DQML(SDRAM2_DQML),
	.SDRAM_DQMH(SDRAM2_DQMH),
	.SDRAM_BA  (SDRAM2_BA),
	.SDRAM_nCS (SDRAM2_nCS),
	.SDRAM_nWE (SDRAM2_nWE),
	.SDRAM_nRAS(SDRAM2_nRAS),
	.SDRAM_nCAS(SDRAM2_nCAS),
	.SDRAM_CKE (SDRAM2_CKE),
	.SDRAM_CLK (SDRAM2_CLK),

	.sel    (1'b1),
	.addr   (sd2_addr),
	.dout   (sd2_dout),
	.din    (sd2_din),
	.wr     (sd2_wr),
	.bs     (sd2_bs),
	.rd     (sd2_rd),
	.ready  (sd2_ready),
	.refresh(sd2_ref_cnt[8]),

	.cpsel (1'b0),
	.cpaddr('0),
	.cpdin ('0),
	.cprd  (),
	.cpreq (1'b0),
	.cpbusy(),

	.dbg_ignored_cmd_cnt(),
	.idle(sd2_idle)
);

/////////////////////////  VIDEO OUTPUT (MiST)  //////////////////////////
// Replaces MiSTer's video_mixer/video_freak/scandoubler/HDMI-framebuffer
// stage above (removed) with mist_video, fed from the same crop_r/g/b and
// analog_hs/vs/cofi_hbl/cofi_vbl signals the copied-verbatim block already
// produces.
//
// NOTE (neptUNO+ port): this build's mist_video.v (mist-modules/, pinned
// submodule) has no "osd_enable" port - it drives the OSD overlay itself
// straight off SPI_SS3/SPI_SCK/SPI_DI, no external enable needed. It does
// need "ce_divider" though (missing before, which left the scandoubler's
// internal pixel-clock detection undriven): using 3'd3 (clk_sys/4), the
// scandoubler's own documented "for compatibility" default. Revisit if
// OSD alignment/scandoubler timing looks off on real hardware - our
// actual DOT_CE_R/DCLK ratio to clk_sys hasn't been tuned here yet.
mist_video #(.SD_HCNT_WIDTH(10), .COLOR_DEPTH(8), .OUT_COLOR_DEPTH(8), .USE_BLANKS(1'b1)) mist_video
(
	.clk_sys(clk_sys),

	.SPI_SCK(SPI_SCK),
	.SPI_SS3(SPI_SS3),
	.SPI_DI(SPI_DI),

	.scanlines(2'b00),
	.ce_divider(3'd3),
	.scandoubler_disable(scandoubler_disable),
	.ypbpr(ypbpr),
	.no_csync(no_csync),
	.rotate(2'b00),
	.blend(1'b0),

	.R(crop_r),
	.G(crop_g),
	.B(crop_b),
	.HSync(analog_hs),
	.VSync(analog_vs),
	.HBlank(cofi_hbl),
	.VBlank(cofi_vbl),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_HB(),
	.VGA_VB(),
	.VGA_DE()
);

/////////////////////////  AUDIO OUTPUT  //////////////////////////////////
dac #(.C_bits(16)) dac_l
(
	.clk_i(clk_sys),
	.res_n_i(locked),
	.dac_i(SOUND_L),
	.dac_o(AUDIO_L)
);

dac #(.C_bits(16)) dac_r
(
	.clk_i(clk_sys),
	.res_n_i(locked),
	.dac_i(SOUND_R),
	.dac_o(AUDIO_R)
);

i2s i2s
(
	.reset(~locked),
	.clk(clk_sys),
	.clk_rate(32'd53_748_200),

	.sclk(I2S_BCK),
	.lrclk(I2S_LRCK),
	.sdata(I2S_DATA),

	.left_chan(SOUND_L),
	.right_chan(SOUND_R)
);

endmodule
