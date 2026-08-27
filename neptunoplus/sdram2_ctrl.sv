// Static RAM controller implementation using SDRAM MT48LC16M16A2
// Copyright (c) 2015-2019 Sorgelig

module sdram
(
	input             init,        // reset to initialize RAM
	input             clk,         // clock ~100MHz

	inout  reg [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
	output            SDRAM_DQML,  // two byte masks
	output            SDRAM_DQMH,  //
	output reg  [1:0] SDRAM_BA,    // two banks
	output            SDRAM_nCS,   // a single chip select
	output            SDRAM_nWE,   // write enable
	output            SDRAM_nRAS,  // row address select
	output            SDRAM_nCAS,  // columns address select
	output            SDRAM_CKE,   // clock enable
	output            SDRAM_CLK,
	input             SDRAM_EN,    // clock enable

	input             sel,
	input      [26:1] addr,        // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [15:0] dout,        // data output to cpu
	input      [15:0] din,         // data input from cpu
	input             wr,          // request write
	input       [1:0] bs,          // bit1 - write high byte, bit0 - write low byte, Ignored while reading.
	input             rd,          // request read
	output reg        ready,
	input             refresh,

	input             cpsel,
	input      [26:1] cpaddr,
	input      [15:0] cpdin,
	output reg        cprd,
	input             cpreq,
	output reg        cpbusy,

	// NUEVO: diagnostico puro -- profundizar el FIFO de bios_wr (8->32) y
	// esperar a mem_not_ready en avalon_sdram_bridge.reset no cambiaron nada
	// en hardware (T/U siguen saturando igual). Hipotesis nueva: el pulso de
	// wr/rd del puente (un solo ciclo, sin reintento) solo se atiende dentro
	// de STATE_IDLE aqui abajo -- si llega mientras el FSM todavia esta en
	// IDLE_4..IDLE_1 terminando la transaccion anterior, se pierde en
	// silencio, sin importar que tan profundo sea el FIFO rio arriba (ese
	// cuello de botella esta despues del FIFO, no en el). Contador saturante
	// (satura en 0F) de cuantas veces paso esto desde el ultimo init.
	output reg [3:0]  dbg_ignored_cmd_cnt,

	// NUEVO (fix real, no solo diagnostico): "idle" -- alto SOLO cuando
	// state==STATE_IDLE de verdad, a diferencia de "ready" que sube temprano
	// dentro de STATE_RW, varios ciclos antes de que la maquina de estados
	// vuelva de verdad a STATE_IDLE. avalon_sdram_bridge debe esperar a los
	// DOS (ready Y idle) antes de mandar la siguiente sub-palabra de una
	// rafaga de 4 -- confirmado en simulacion (testbench aislado
	// avalon_sdram_bridge+sdram2_ctrl, sin el resto del core) que usando
	// solo "ready" el puente manda el pulso de escritura/lectura mientras
	// sdram2_ctrl todavia esta en IDLE_4..IDLE_1 terminando la transaccion
	// anterior, y ese pulso se pierde en silencio -- exactamente lo que
	// dbg_ignored_cmd_cnt de arriba detecta. Con "idle" agregado a la
	// condicion del puente (ver avalon_sdram_bridge.sv), dbg_ignored_cmd_cnt
	// quedo en 0 durante toda la simulacion, incluso en el peor caso
	// (rafaga de escrituras sin ningun hueco entre ellas).
	output reg        idle
);

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd780;  // (64000*100)/8192-1 Calc'd as (64ms @ 100MHz)/8192 rose
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;
reg        chip;

localparam STATE_STARTUP =  0;
localparam STATE_WAIT    =  1;
localparam STATE_RW      =  2;
localparam STATE_WAITCP  =  3;
localparam STATE_CP      =  4;
localparam STATE_IDLE    =  5;
localparam STATE_IDLE_1  =  6;
localparam STATE_IDLE_2  =  7;
localparam STATE_IDLE_3  =  8;
localparam STATE_IDLE_4  =  9;
localparam STATE_IDLE_5  = 10;
localparam STATE_RFSH    = 11;

always @(posedge clk) begin
	reg [CAS_LATENCY:0] data_ready_delay;
	reg        saved_wr;
	reg [12:0] cas_addr;
	reg [15:0] saved_data;
	reg  [8:0] cpcnt;
	reg        old_cpreq = 0;
	reg  [3:0] state = STATE_STARTUP;
	reg        refresh_old;

	refresh_count <= refresh_count+1'b1;

	data_ready_delay <= data_ready_delay>>1;
	if(data_ready_delay[0]) ready <= 1;

	dout <= SDRAM_DQ;
	SDRAM_DQ <= 'Z;

	if(SDRAM_EN) begin
		command <= CMD_NOP;
		case (state)
			STATE_STARTUP: begin
				SDRAM_A    <= 0;
				SDRAM_BA   <= 0;

				if (refresh_count == (startup_refresh_max-64)) chip <= 0;
				if (refresh_count == (startup_refresh_max-32)) chip <= 1;

				if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
					command     <= CMD_PRECHARGE;
					SDRAM_A[10] <= 1;  // all banks
					SDRAM_BA    <= 2'b00;
				end
				if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
					command     <= CMD_AUTO_REFRESH;
				end
				if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
					command     <= CMD_AUTO_REFRESH;
				end
				if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
					command     <= CMD_LOAD_MODE;
					SDRAM_A     <= MODE;
				end

				if (!refresh_count) begin
					state   <= STATE_IDLE;
					ready   <= 1;
					refresh_count <= 0;
				end
				cpbusy <= 0;
			end

			STATE_RFSH: begin
				state         <= STATE_IDLE_5;
				command       <= CMD_AUTO_REFRESH;
				chip          <= 1;
			end

			STATE_IDLE_5: state <= STATE_IDLE_4;
			STATE_IDLE_4: state <= STATE_IDLE_3;
			STATE_IDLE_3: state <= STATE_IDLE_2;
			STATE_IDLE_2: state <= STATE_IDLE_1;
			STATE_IDLE_1: state <= STATE_IDLE;

			STATE_IDLE: begin
				if (refresh ^ refresh_old) begin
					state      <= STATE_RFSH;
					command    <= CMD_AUTO_REFRESH;
					chip       <= 0;
					refresh_old<= refresh;
				end
				else if (sel & (rd | wr)) begin
					{cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~wr ? 2'b00 : ~bs, 1'b1, addr[25:1]};
					chip       <= addr[26];
					saved_data <= din;
					saved_wr   <= wr;
					command    <= CMD_ACTIVE;
					state      <= STATE_WAIT;
					ready      <= 0;
				end
				else begin
					cpbusy     <= 0;
					cprd       <= 0;
					old_cpreq  <= cpreq;
					if(~old_cpreq & cpreq & cpsel) begin
						{cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b0, cpaddr[25:1]};
						chip    <= cpaddr[26];
						cpbusy  <= 1;
						cpcnt   <= 511;
						command <= CMD_ACTIVE;
						state   <= STATE_WAITCP;
						cprd    <= 1;
					end
				end
			end

			STATE_WAIT: state <= STATE_RW;
			STATE_RW: begin
				state         <= STATE_IDLE_4;
				SDRAM_A       <= cas_addr;
				if(saved_wr) begin
					command    <= CMD_WRITE;
					SDRAM_DQ   <= saved_data;
					ready      <= 1;
				end
				else begin
					command    <= CMD_READ;
					data_ready_delay[CAS_LATENCY] <= 1;
				end
			end

			STATE_WAITCP: state <= STATE_CP;
			STATE_CP: begin
				SDRAM_A       <= {2'b00, !cpcnt, cas_addr[9:0]};
				cas_addr[8:0] <= cas_addr[8:0] + 1'd1;
				cpcnt         <= cpcnt - 1'd1;
				command       <= CMD_WRITE;
				SDRAM_DQ      <= cpdin;
				if(!cpcnt) begin
					state      <= STATE_IDLE_4;
					cprd       <= 0;
				end
			end
		endcase

		// NUEVO: diagnostico puro -- ver comentario junto al puerto
		// dbg_ignored_cmd_cnt. "state" aca es el mismo valor que el case()
		// de arriba acaba de usar para decidir (no cambia hasta el proximo
		// flanco), asi que esto detecta EXACTAMENTE la misma condicion que
		// hace que STATE_IDLE sea el UNICO lugar donde sel&(rd|wr) se
		// atiende -- si eso pasa en cualquier otro estado, el pulso ya se
		// perdio (sin cola, sin reintento).
		if (sel && (rd || wr) && state != STATE_IDLE) begin
			if (dbg_ignored_cmd_cnt != 4'hF)
				dbg_ignored_cmd_cnt <= dbg_ignored_cmd_cnt + 4'h1;
		end

		// NUEVO (fix real): ver comentario junto al puerto "idle"
		idle <= (state == STATE_IDLE);

		if (init) begin
			state         <= STATE_STARTUP;
			refresh_count <= startup_refresh_max - sdram_startup_cycles;
			dbg_ignored_cmd_cnt <= 4'h0; // NUEVO: re-arma en cada init
			idle          <= 1'b0; // NUEVO (fix real): a salvo mientras dura el re-init
			ready         <= 0;	// NUEVO -- FIX critico (causa raiz de BIOS=0 tras cualquier
						// reset/recarga): sin esto, "ready" retiene su valor previo
						// (normalmente 1, heredado de la operacion anterior) durante
						// TODO el re-init disparado por "init". STATE_STARTUP (arriba)
						// nunca toca "ready" salvo al terminar de verdad (bloque
						// "if (!refresh_count) ... ready<=1", linea ~131). Con ready
						// atascado en 1, quien consulte este puerto (avalon_sdram_bridge
						// y, a traves de el, ddram_inst) cree que cada lectura/escritura
						// se completa al instante, cuando en realidad esta controladora
						// esta ocupada reemitiendo PRECHARGE/AUTO_REFRESH/LOAD_MODE e
						// ignora "rd"/"wr" por completo mientras dura STATE_STARTUP -- la
						// transaccion se pierde en silencio. Este assign es seguro: no
						// puede pisar el "ready<=1" de terminacion real, porque mientras
						// "init" siga en alto este mismo bloque tambien re-arma
						// "refresh_count" cada ciclo (linea de arriba), asi que
						// "!refresh_count" nunca puede darse verdadero en el mismo ciclo
						// en que "init" sigue activo -- la finalizacion real solo ocurre
						// despues de que "init" ya cayo.
		end
	end
	else begin
		ready    <= 1;
		cpbusy   <= 0;
		cprd     <= 0;
		dout     <= 0;
		SDRAM_A  <= 0;
		SDRAM_BA <= 0;
		command  <= 0;
		chip     <= 0;
	end
end

altddio_out #(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone IV GX"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
) sdramclk_ddr (
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
