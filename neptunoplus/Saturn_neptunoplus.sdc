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

set sdram_clk "saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk[0]"
set sys_clk   "saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk[0]"

set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {CONF_DATA0}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_DI}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_SCK}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_SS2}]
set_input_delay -add_delay -clock_fall -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_SS3}]

set_input_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -min 3.2 [get_ports SDRAM_DQ[*]]

set_output_delay -add_delay -clock [get_clocks {SPI_SCK}] 1.000 [get_ports {SPI_DO}]
set_output_delay -add_delay -clock [get_clocks $sys_clk]  1.000 [get_ports {AUDIO_L}]
set_output_delay -add_delay -clock [get_clocks $sys_clk]  1.000 [get_ports {AUDIO_R}]
set_output_delay -add_delay -clock [get_clocks $sys_clk]  1.000 [get_ports {LED}]
set_output_delay -add_delay -clock [get_clocks $sys_clk]  1.000 [get_ports {VGA_*}]

set_output_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -max 1.5 [get_ports {SDRAM_D* SDRAM_A* SDRAM_BA* SDRAM_n* SDRAM_CKE}]
set_output_delay -clock [get_clocks $sdram_clk] -reference_pin [get_ports {SDRAM_CLK}] -min -0.8 [get_ports {SDRAM_D* SDRAM_A* SDRAM_BA* SDRAM_n* SDRAM_CKE}]

set_clock_groups -asynchronous -group [get_clocks {SPI_SCK}] -group [get_clocks {saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk[*]}]

set_multicycle_path -to {VGA_*[*]} -setup 3
set_multicycle_path -to {VGA_*[*]} -hold 2
