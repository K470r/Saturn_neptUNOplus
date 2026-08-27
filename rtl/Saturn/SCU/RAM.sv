// synopsys translate_off
`define SIM
// synopsys translate_on

module DSP_PRG_RAM
#(
	parameter addr_width = 8,
	parameter data_width = 8,
	parameter mem_init_file = " ",
	parameter mem_sim_file = " "
)
(
	input                   CLK,
	
	input  [addr_width-1:0] ADDR,
	input  [data_width-1:0] DATA,
	input                   WREN,
	output [data_width-1:0] Q
);

`ifdef SIM
	
	reg [data_width-1:0] MEM [2**addr_width];

	initial begin
		$readmemh(mem_sim_file, MEM);
	end
	
	always @(posedge CLK) begin
		if (WREN) begin
			MEM[ADDR] <= DATA;
		end
	end
		
	assign Q = MEM[ADDR];

`else

	wire [data_width-1:0] sub_wire0;

	altsyncram	altsyncram_component (
				.address_a (ADDR),
				.clock0 (CLK),
				.data_a (DATA),
				.wren_a (WREN),
				.q_a (sub_wire0),
				.aclr0 (1'b0),
				.aclr1 (1'b0),
				.address_b (1'b1),
				.addressstall_a (1'b0),
				.addressstall_b (1'b0),
				.byteena_a (1'b1),
				.byteena_b (1'b1),
				.clock1 (1'b1),
				.clocken0 (1'b1),
				.clocken1 (1'b1),
				.clocken2 (1'b1),
				.clocken3 (1'b1),
				.data_b (1'b1),
				.eccstatus (),
				.q_b (),
				.rden_a (1'b1),
				.rden_b (1'b1),
				.wren_b (1'b0));

	defparam
		altsyncram_component.clock_enable_input_a = "BYPASS",
		altsyncram_component.clock_enable_output_a = "BYPASS",
		altsyncram_component.intended_device_family = "Cyclone V",
		altsyncram_component.lpm_hint = "ENABLE_RUNTIME_MOD=NO",
		altsyncram_component.lpm_type = "altsyncram",
		altsyncram_component.numwords_a = 2**addr_width,
		altsyncram_component.operation_mode = "SINGLE_PORT",
		altsyncram_component.outdata_aclr_a = "NONE",
		altsyncram_component.outdata_reg_a = "UNREGISTERED",
		altsyncram_component.power_up_uninitialized = "FALSE",
		altsyncram_component.ram_block_type = "M10K",
		altsyncram_component.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		altsyncram_component.widthad_a = addr_width,
		altsyncram_component.width_a = data_width,
		altsyncram_component.width_byteena_a = 1,
		altsyncram_component.init_file = mem_init_file;

	assign Q = sub_wire0;
	
`endif
	
endmodule


module DSP_DATA_RAM
#(
	parameter addr_width = 8,
	parameter data_width = 8,
	parameter mem_init_file = " ",
	parameter mem_sim_file = " "
)
(
	input                   CLK,
	
	input  [addr_width-1:0] ADDR,
	input  [data_width-1:0] DATA,
	input                   WREN,
	output [data_width-1:0] Q
);

`ifdef SIM
	
	reg [data_width-1:0] MEM [2**addr_width];

	initial begin
		$readmemh(mem_sim_file, MEM);
	end
	
	always @(posedge CLK) begin
		if (WREN) begin
			MEM[ADDR] <= DATA;
		end
	end
		
	assign Q = MEM[ADDR];
	
`else

	wire [data_width-1:0] sub_wire0;
	
	altsyncram	altsyncram_component (
				.address_a (ADDR),
				.clock0 (CLK),
				.data_a (DATA),
				.wren_a (WREN),
				.address_b (ADDR),
				.clock1 (~CLK),
				.q_b (sub_wire0),
				.aclr0 (1'b0),
				.aclr1 (1'b0),
				.addressstall_a (1'b0),
				.addressstall_b (1'b0),
				.byteena_a (1'b1),
				.byteena_b (1'b1),
				.clocken0 (1'b1),
				.clocken1 (1'b1),
				.clocken2 (1'b1),
				.clocken3 (1'b1),
				.data_b ({data_width{1'b1}}),
				.eccstatus (),
				.q_a (),
				.rden_a (1'b1),
				.rden_b (1'b1),
				.wren_b (1'b0));
	defparam
		altsyncram_component.address_aclr_b = "NONE",
		altsyncram_component.address_reg_b = "CLOCK1",
		altsyncram_component.clock_enable_input_a = "BYPASS",
		altsyncram_component.clock_enable_input_b = "BYPASS",
		altsyncram_component.clock_enable_output_b = "BYPASS",
		altsyncram_component.intended_device_family = "Cyclone V",
		altsyncram_component.lpm_type = "altsyncram",
		altsyncram_component.numwords_a = 2**addr_width,
		altsyncram_component.numwords_b = 2**addr_width,
		altsyncram_component.operation_mode = "DUAL_PORT",
		altsyncram_component.outdata_aclr_b = "NONE",
		altsyncram_component.outdata_reg_b = "UNREGISTERED",
		altsyncram_component.power_up_uninitialized = "FALSE",
		altsyncram_component.ram_block_type = "M10K",
		altsyncram_component.widthad_a = addr_width,
		altsyncram_component.widthad_b = addr_width,
		altsyncram_component.width_a = data_width,
		altsyncram_component.width_b = data_width,
		altsyncram_component.width_byteena_a = 1,
		altsyncram_component.init_file = mem_init_file;
		
	assign Q = sub_wire0;
	
`endif
	
endmodule


module SCU_CBUS_CACHE
(
	input         CLK,
	
	input  [ 2:0] WADDR,
	input  [31:0] DATA,
	input         WREN,
	input  [ 2:0] RADDR,
	output [31:0] Q
);

`ifdef SIM
	
	reg [31:0] MEM [8];
	
	always @(posedge CLK) begin
		if (WREN) begin
			MEM[WADDR] <= DATA;
		end
	end
		
	assign Q = MEM[RADDR];
	
`else

	// NOTE (neptUNO+ port): same plain register array as the `ifdef SIM`
	// branch above - altdpram/MLAB with an unregistered read address
	// doesn't exist on Cyclone IV GX (see rtl/SH_mem.sv's SH_regram for
	// the full explanation). Behavior is unchanged either way.
	reg [31:0] MEM [8];

	always @(posedge CLK) begin
		if (WREN) begin
			MEM[WADDR] <= DATA;
		end
	end

	assign Q = MEM[RADDR];

`endif

endmodule
