create_clock -period 3.333 -name clk [get_ports clk]
set_input_delay 0.5 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk}]

set_property DONT_TOUCH true [get_cells {SoItBegins ItContinues}]
set_property DONT_TOUCH true [get_cells C_alig3_reg*]
