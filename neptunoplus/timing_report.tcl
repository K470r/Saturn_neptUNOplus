# Script de TimeQuest para sacar el detalle celda-por-celda de los peores
# caminos de timing, tanto en clk_sys (nucleo Saturn + mist_video) como en
# clk_ram (controladores SDRAM). Se corre con quartus_sta -t (no requiere
# abrir la GUI de Quartus).
#
# Uso (desde la carpeta neptunoplus, con el proyecto ya compilado al menos
# una vez con exito):
#   "C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sta.exe" -t timing_report.tcl
#
# Genera 3 archivos de texto en esta misma carpeta:
#   setup_clk_sys.txt  - peores 5 caminos de setup en clk_sys
#   setup_clk_ram.txt  - peores 5 caminos de setup en clk_ram
#   hold_clk_ram.txt   - peores 5 caminos de hold en clk_ram

project_open Saturn_neptunoplus -revision Saturn_neptunoplus
create_timing_netlist
read_sdc
update_timing_netlist

set sys_clk   "saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk\[0\]"
set sdram_clk "saturn_mist|pll_sys|altpll_component|auto_generated|pll1|clk\[1\]"

report_timing -setup -npaths 5 -detail full_path \
  -from_clock [get_clocks $sys_clk] -to_clock [get_clocks $sys_clk] \
  -panel_name {Setup clk_sys - top 5} \
  -file setup_clk_sys.txt

report_timing -setup -npaths 5 -detail full_path \
  -from_clock [get_clocks $sdram_clk] -to_clock [get_clocks $sdram_clk] \
  -panel_name {Setup clk_ram - top 5} \
  -file setup_clk_ram.txt

report_timing -hold -npaths 5 -detail full_path \
  -from_clock [get_clocks $sdram_clk] -to_clock [get_clocks $sdram_clk] \
  -panel_name {Hold clk_ram - top 5} \
  -file hold_clk_ram.txt

qexit
