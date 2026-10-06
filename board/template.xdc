# Pin template for board/fpga_top.vhd.
# Replace every <PIN> with the package pin from your board's master XDC.
# Example values in the comments are for the Digilent Arty A7-100T (untested).

set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports clk100]   ;# Arty A7: E3
create_clock -name clk100 -period 10.000 [get_ports clk100]

# Reset button, active low
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports rst_n]    ;# Arty A7: C2

# USB-UART bridge, named from the FPGA's point of view
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports uart_rx]  ;# Arty A7: A9
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports uart_tx]  ;# Arty A7: D10

# Status LEDs: 0 heartbeat, 1 busy, 2 last command OK, 3 last command error
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports {led[0]}] ;# Arty A7: H5
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports {led[1]}] ;# Arty A7: J5
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports {led[2]}] ;# Arty A7: T9
set_property -dict { PACKAGE_PIN <PIN> IOSTANDARD LVCMOS33 } [get_ports {led[3]}] ;# Arty A7: T10

# Asynchronous I/O: synchronized inside the design or human-speed
set_false_path -from [get_ports {rst_n uart_rx}]
set_false_path -to   [get_ports {uart_tx led[*]}]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
