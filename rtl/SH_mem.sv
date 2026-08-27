// synopsys translate_off
`timescale 1 ps / 1 ps
// synopsys translate_on

// NOTE (neptUNO+ port): the original implementation used `altdpram` in
// MLAB mode with an unregistered (asynchronous) read address - a small
// distributed-RAM style dual-port memory that Cyclone IV GX doesn't have
// (no MLAB blocks, and its M9K blocks only support *registered*-address
// dual-port access, i.e. one extra cycle of read latency that
// SH_regfile.sv's combinational `assign RA_Q = RAMA_Q;` doesn't expect).
// Replaced with a plain register array: at only 16x32 bits this is a
// trivial resource cost on any FPGA family, and it reproduces the same
// registered-write/combinational-read behavior exactly, so nothing
// downstream needs to change.
module SH_regram (
	input             clock,
	input      [31:0] data,
	input      [3:0]  rdaddress,
	input      [3:0]  wraddress,
	input             wren,
	output     [31:0] q
);

	reg [31:0] mem[16];

	always @(posedge clock) begin
		if (wren) mem[wraddress] <= data;
	end

	assign q = mem[rdaddress];

endmodule
