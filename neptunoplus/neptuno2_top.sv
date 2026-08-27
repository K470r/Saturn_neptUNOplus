//============================================================================
//  neptUNO+ (QMTech EP4CGX150 Cyclone IV GX) board top-level for Sega Saturn.
//
//  This is the thin board-pin adapter, following the same pattern used by
//  delgrom's NeoGeo_FPGA and TurboGrafx16_FPGA neptUNO+ ports: it only maps
//  the physical neptUNO+/QMTech pins onto the MiST-protocol ports of the
//  shared core top-level (Saturn_MiST), it does not contain any core logic.
//============================================================================

module neptuno2_top
(
	input         CLOCK_50,

	output        LED = 1'b1, // '0' = LED on

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,

	// SDRAM interface
	output [12:0] SDRAM_A,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

	// SDRAM interface, expansion chip (edge connector). Reserved but not
	// yet driven by Saturn_MiST - see docs/NEPTUNOPLUS_PORT.md. Held
	// inactive (chip deselected, clock enable off, data bus tristated)
	// until the ddram/avalon_sdram_bridge/sdram2_ctrl chain is wired in.
	output [12:0] SDRAM2_A,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_DQML,
	output        SDRAM2_DQMH,
	output        SDRAM2_nWE,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nCS,
	output  [1:0] SDRAM2_BA,
	output        SDRAM2_CLK,
	output        SDRAM2_CKE,

	// SPI interface to the RP2040 (mist-firmware-rp2040)
	inout         SPI_DO,
	input         SPI_DI,
	input         SPI_SCK,
	input         SPI_SS2,
	input         SPI_SS3,
	input         SPI_SS4,
	input         CONF_DATA0,

	// Delta-sigma audio
	output        AUDIO_L,
	output        AUDIO_R,
	// I2S audio
	output        I2S_BCK,
	output        I2S_LRCK,
	output        I2S_DATA,

	input         UART_RX,
	output        UART_TX,

	// SD card (driven by the neptUNO+ middleboard)
	input         SD_SCK,
	input         SD_MISO,

	// db9 joystick (SNAC / pad 2)
	output        JOY_CLK    = 1'b1,
	output        JOY_LOAD   = 1'b1,
	input         JOY_DATA,
	output        JOY_SELECT = 1'b1,

	// joystick reflection (JAMMA-style shift register used by the
	// neptUNO+ middleboard for the 2nd pad / lightgun)
	input         JOY_XCLK,
	input         JOY_XLOAD,
	output        JOY_XDATA
);

// direct SD upload: while SPI_SS4 is asserted the FPGA drives SPI_DO from
// its own MiST logic; otherwise it passes the SD card's MISO through so the
// RP2040 can read the SD card directly (same trick used by every other
// neptUNO+ core).
wire spi_do_int;
assign spi_do_int = SPI_SS4 ? 1'bz : SD_MISO;
assign SPI_DO = spi_do_int;

// JAMMA/db9 joystick reflection for pad 2
assign JOY_CLK   = JOY_XCLK;
assign JOY_LOAD  = JOY_XLOAD;
assign JOY_XDATA = JOY_DATA;

wire [6:0] user_in  = {3'b111, JOY_DATA, 3'b111};
wire [6:0] user_out;

// Expansion SDRAM chip held inactive (deselected/CKE off/bus tristated)
// until the ddram/avalon_sdram_bridge/sdram2_ctrl chain is wired in below.
assign SDRAM2_A    = 13'h0;
assign SDRAM2_DQ    = 16'hZZZZ;
assign SDRAM2_DQML  = 1'b0;
assign SDRAM2_DQMH  = 1'b0;
assign SDRAM2_nWE   = 1'b1;
assign SDRAM2_nCAS  = 1'b1;
assign SDRAM2_nRAS  = 1'b1;
assign SDRAM2_nCS   = 1'b1;
assign SDRAM2_BA    = 2'b00;
assign SDRAM2_CLK   = 1'b0;
assign SDRAM2_CKE   = 1'b0;

Saturn_MiST saturn_mist
(
	.CLOCK_50   (CLOCK_50),

	.LED        (LED),

	.VGA_R      (VGA_R),
	.VGA_G      (VGA_G),
	.VGA_B      (VGA_B),
	.VGA_HS     (VGA_HS),
	.VGA_VS     (VGA_VS),

	.SDRAM_A    (SDRAM_A),
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_CLK  (SDRAM_CLK),
	.SDRAM_CKE  (SDRAM_CKE),

	.SPI_DO     (spi_do_int),
	.SPI_DI     (SPI_DI),
	.SPI_SCK    (SPI_SS4 ? SPI_SCK : SD_SCK),
	.SPI_SS2    (SPI_SS2),
	.SPI_SS3    (SPI_SS3),
	.SPI_SS4    (SPI_SS4),
	.CONF_DATA0 (CONF_DATA0),

	.AUDIO_L    (AUDIO_L),
	.AUDIO_R    (AUDIO_R),
	.I2S_BCK    (I2S_BCK),
	.I2S_LRCK   (I2S_LRCK),
	.I2S_DATA   (I2S_DATA),

	.UART_RX    (UART_RX),
	.UART_TX    (UART_TX),

	.USER_IN    (user_in),
	.USER_OUT   (user_out)
);

endmodule
