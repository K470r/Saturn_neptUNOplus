module avalon_sdram_bridge (
    input clk,
    input reset,

    // Avalon 64-bit (Viene del ddram.sv de MiSTer)
    input  [28:0] av_addr,
    input  [63:0] av_din,
    output reg [63:0] av_dout,
    input         av_read,
    input         av_write,
    input  [7:0]  av_be,
    input  [7:0]  av_burstcount,
    output reg    av_waitrequest,
    output reg    av_readdatavalid,

    // Conexión a la SDRAM 16-bit física
    output reg [26:1] sd_addr,
    input  [15:0] sd_dout,
    output reg [15:0] sd_din,
    output reg        sd_wr,
    output reg [1:0]  sd_bs,
    output reg        sd_rd,
    input             sd_ready,

    // NUEVO (fix real): "ready" sube temprano, dentro de STATE_RW de
    // sdram2_ctrl, varios ciclos antes de que la maquina de estados vuelva
    // de verdad a STATE_IDLE (el unico estado donde acepta un comando
    // nuevo). Confirmado en simulacion (testbench aislado, sin el resto del
    // core): usando solo "sd_ready" para decidir cuando mandar la siguiente
    // sub-palabra de una rafaga de 4, el pulso de wr/rd se manda mientras
    // sdram2_ctrl todavia esta en IDLE_4..IDLE_1 terminando la transaccion
    // anterior -- ese pulso se pierde en silencio (sdram2_ctrl solo atiende
    // sel&(rd|wr) dentro de STATE_IDLE). Esto explica la corrupcion de BIOS
    // que ni profundizar bios_fifo (8->32) ni mem_not_ready en el reset de
    // este mismo modulo lograban arreglar: la perdida ocurre DESPUES del
    // FIFO, en esta rafaga interna. "sd_idle" es la señal real y sin
    // ambiguedad de "sdram2_ctrl ya puede aceptar algo nuevo".
    input             sd_idle
);

    reg [7:0] burst_cnt;
    reg [1:0] word_cnt;
    reg [2:0] state;

    always @(posedge clk) begin
        if (reset) begin
            state <= 0;
            av_waitrequest <= 1;
            av_readdatavalid <= 0;
            sd_wr <= 0;
            sd_rd <= 0;
            sd_addr <= 0;
            sd_din <= 0;
            sd_bs <= 0;
        end else begin
            av_readdatavalid <= 0;
            sd_rd <= 0;
            sd_wr <= 0;

            case (state)
                0: begin
                    av_waitrequest <= 0;
                    if (av_read) begin
                        av_waitrequest <= 1;
                        burst_cnt <= av_burstcount;
                        word_cnt <= 0;
                        sd_addr <= {av_addr[24:0], 2'b00};
                        sd_rd <= 1; // Primer pulso de lectura inmediato
                        state <= 1;
                    end else if (av_write) begin
                        av_waitrequest <= 1;
                        burst_cnt <= av_burstcount;
                        word_cnt <= 0;
                        sd_addr <= {av_addr[24:0], 2'b00};
                        state <= 3; // Iniciar escritura
                    end
                end

                // LECTURA PIPELINED (Desactivación del pulso en 1 ciclo)
                1: begin
                    sd_rd <= 0; // Apagamos el pulso inmediatamente
                    state <= 2; // Pasar a esperar el dato físico de la SDRAM
                end

                2: if (sd_ready && sd_idle) begin // FIX: antes solo sd_ready -- ver comentario junto al puerto sd_idle
                    case (word_cnt)
                        2'd0: av_dout[63:48] <= sd_dout;
                        2'd1: av_dout[47:32] <= sd_dout;
                        2'd2: av_dout[31:16] <= sd_dout;
                        2'd3: av_dout[15:0]  <= sd_dout;
                    endcase
                    word_cnt <= word_cnt + 1'd1;
                    sd_addr <= sd_addr + 1'd1;

                    if (word_cnt == 2'd3) begin
                        av_readdatavalid <= 1;
                        // FIX: ddram.sv solo procesa DDRAM_DOUT_READY dentro de su
                        // gate "else if (!DDRAM_BUSY) ... case(state) 3'h2: if
                        // (DDRAM_DOUT_READY)". Antes, av_waitrequest se mantenía en
                        // 1 durante TODO el burst y solo bajaba un ciclo después del
                        // ÚLTIMO pulso de av_readdatavalid -- ddram.sv nunca llegaba
                        // a ver ambas condiciones juntas en ningún beat, de ninguna
                        // lectura, y se quedaba trabado en el estado 3'h2 para
                        // siempre (coincide exacto con "R0 L1 C0001 -> R0 L1 C0000"
                        // fijo en el debug_uart). Bajarlo en el mismo ciclo que se
                        // pulsa av_readdatavalid soluciona el deadlock. La escritura
                        // NO se toca: ahí ddram.sv sí depende de que av_waitrequest
                        // se mantenga en alto hasta terminar el burst completo (no
                        // hay señal de "dato listo" equivalente en esa ruta), y eso
                        // ya funciona bien.
                        av_waitrequest <= 0;
                        burst_cnt <= burst_cnt - 1'd1;
                        if (burst_cnt == 8'd1) begin
                            state <= 0; // Ráfaga Avalon completada
                        end else begin
                            sd_rd <= 1; // Siguiente ráfaga Avalon: iniciar pulso inmediato
                            state <= 1;
                        end
                    end else begin
                        sd_rd <= 1; // Siguiente palabra: iniciar pulso de lectura inmediato
                        state <= 1;
                    end
                end

                // ESCRITURA PIPELINED (Carga de datos síncronos)
                3: if (sd_ready && sd_idle) begin // FIX: antes solo sd_ready -- ver comentario junto al puerto sd_idle
                    case (word_cnt)
                        2'd0: begin sd_din <= av_din[63:48]; sd_bs <= av_be[7:6]; end
                        2'd1: begin sd_din <= av_din[47:32]; sd_bs <= av_be[5:4]; end
                        2'd2: begin sd_din <= av_din[31:16]; sd_bs <= av_be[3:2]; end
                        2'd3: begin sd_din <= av_din[15:0];  sd_bs <= av_be[1:0]; end
                    endcase
                    sd_wr <= 1; // Pulso de escritura síncrono de un ciclo
                    state <= 4;
                end

                4: begin
                    // Esperamos 1 ciclo para que la SDRAM registre la señal y sd_ready baje a cero
                    state <= 5;
                end

                5: if (sd_ready && sd_idle) begin // FIX: antes solo sd_ready -- ver comentario junto al puerto sd_idle
                    word_cnt <= word_cnt + 1'd1;
                    sd_addr <= sd_addr + 1'd1;

                    if (word_cnt == 2'd3) begin
                        burst_cnt <= burst_cnt - 1'd1;
                        state <= (burst_cnt == 8'd1) ? 3'd0 : 3'd3;
                    end else begin
                        state <= 3; // Siguiente palabra de la ráfaga
                    end
                end

                default: state <= 0;
            endcase
        end
    end
endmodule
