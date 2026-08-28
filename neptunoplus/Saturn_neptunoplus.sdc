# Timing constraints for the neptUNO+ (QMTech EP4CGX150) Saturn port.
# Adapted from delgrom/NeoGeo_FPGA's neptunoplus/NeoGeo_neptunoplus.sdc
# (same board). Expect to iterate on this once real timing closure starts -
# these are a reasonable starting point, not a final signed-off constraint
# set.

derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

set_time_format -unit ns -decimal_places 3

create_clock -name {CLOCK_50} -period 20.000 [get_ports {CLOCK_50}]
create_clock -name {SPI_SCK}  -period 41.666 -waveform { 20.8 41.666 } [get_ports {SPI_SCK}]

set sdram_clk "saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk[1]"
set sys_clk   "saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk[0]"

set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {CONF_DATA0}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_DI}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_SCK}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_SS2}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_SS3}]

set_input_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -min 3.2 [get_ports SDRAM_DQ[*]]

# SDRAM2 (chip de expansión) - mismo controlador (sdram2_ctrl, basado en
# sdram1.sv), mismo dominio de reloj (clk_ram = clk[1]), mismas hojas de
# datos de SDRAM genéricas, así que se reutilizan los mismos números.
set_input_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM2_CLK}] -max 6.4 [get_ports SDRAM2_DQ[*]]
set_input_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM2_CLK}] -min 3.2 [get_ports SDRAM2_DQ[*]]

set_output_delay -add_delay -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_DO}]

set_output_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -max 1.5 [get_ports {SDRAM_D* SDRAM_A* SDRAM_BA* SDRAM_n* SDRAM_CKE}]
set_output_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -min -0.8 [get_ports {SDRAM_D* SDRAM_A* SDRAM_BA* SDRAM_n* SDRAM_CKE}]

set_output_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM2_CLK}] -max 1.5 [get_ports {SDRAM2_D* SDRAM2_A* SDRAM2_BA* SDRAM2_n* SDRAM2_CKE}]
set_output_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM2_CLK}] -min -0.8 [get_ports {SDRAM2_D* SDRAM2_A* SDRAM2_BA* SDRAM2_n* SDRAM2_CKE}]

set_clock_groups -asynchronous -group [get_clocks {SPI_SCK}] -group [get_clocks {saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk[*]}]

# Salidas fisicas sin receptor sincrono real en nuestro diseño: DAC de audio
# analogico (AUDIO_L/R, hacia un filtro RC externo), el LED discreto, VGA
# (hacia un monitor/scaler externo, no otro dominio de reloj FPGA) y
# UART_TX (hacia un periferico externo asincrono). Antes tenian un
# set_output_delay de 1ns arbitrario contra sys_clk que solo generaba
# violaciones de timing "de mentira" en el dominio clk[0] - ningun
# receptor real necesita que se cumplan.
set_false_path -to [get_ports {AUDIO_L AUDIO_R LED VGA_* UART_TX}]

# JOY_DATA/JOY_XLOAD (entradas) son la cadena de joystick tipo daisy-chain
# del conector DB9, totalmente asincrona, sin relacion de reloj con
# clk_sys/clk_ram. JOY_XDATA es un simple passthrough combinacional de
# JOY_DATA (ver neptuno2_top.sv: "assign JOY_XDATA = JOY_DATA;"), asi que
# ya queda cubierto por el false path de JOY_DATA.
set_false_path -from [get_ports {JOY_DATA JOY_XLOAD}]
