## Xilinx design constaint(XDC/.xdc)
## This thing maps my signal to a physical ports, or more specifically balls of the FPGA
## Idk why they call it constaint, i'd call it oppurtunity xdo

##DQ one ball for one bit of dq
##Honestly idk why are those specific balls, I just copied it from MIG, I assume its due to FPGA's structure
set_property PACKAGE_PIN D21 [get_ports {ddr3_dq[0]}]
set_property PACKAGE_PIN C21 [get_ports {ddr3_dq[1]}]
set_property PACKAGE_PIN B22 [get_ports {ddr3_dq[2]}]
set_property PACKAGE_PIN B21 [get_ports {ddr3_dq[3]}]
set_property PACKAGE_PIN D19 [get_ports {ddr3_dq[4]}]
set_property PACKAGE_PIN E20 [get_ports {ddr3_dq[5]}]
set_property PACKAGE_PIN C19 [get_ports {ddr3_dq[6]}]
set_property PACKAGE_PIN D20 [get_ports {ddr3_dq[7]}]
set_property PACKAGE_PIN C23 [get_ports {ddr3_dq[8]}]
set_property PACKAGE_PIN D23 [get_ports {ddr3_dq[9]}]
set_property PACKAGE_PIN B24 [get_ports {ddr3_dq[10]}]
set_property PACKAGE_PIN B25 [get_ports {ddr3_dq[11]}]
set_property PACKAGE_PIN C24 [get_ports {ddr3_dq[12]}]
set_property PACKAGE_PIN C26 [get_ports {ddr3_dq[13]}]
set_property PACKAGE_PIN A25 [get_ports {ddr3_dq[14]}]
set_property PACKAGE_PIN B26 [get_ports {ddr3_dq[15]}]

##addr don't ask we why its backwards
set_property PACKAGE_PIN G15 [get_ports {ddr3_addr[13]}]
set_property PACKAGE_PIN C18 [get_ports {ddr3_addr[12]}]
set_property PACKAGE_PIN H15 [get_ports {ddr3_addr[11]}]
set_property PACKAGE_PIN F20 [get_ports {ddr3_addr[10]}]
set_property PACKAGE_PIN F15 [get_ports {ddr3_addr[9]}]
set_property PACKAGE_PIN H14 [get_ports {ddr3_addr[8]}]
set_property PACKAGE_PIN E16 [get_ports {ddr3_addr[7]}]
set_property PACKAGE_PIN H16 [get_ports {ddr3_addr[6]}]
set_property PACKAGE_PIN D16 [get_ports {ddr3_addr[5]}]
set_property PACKAGE_PIN G16 [get_ports {ddr3_addr[4]}]
set_property PACKAGE_PIN C17 [get_ports {ddr3_addr[3]}]
set_property PACKAGE_PIN F17 [get_ports {ddr3_addr[2]}]
set_property PACKAGE_PIN G17 [get_ports {ddr3_addr[1]}]
set_property PACKAGE_PIN E17 [get_ports {ddr3_addr[0]}]

##ba(nk)
set_property PACKAGE_PIN A17 [get_ports {ddr3_ba[2]}]
set_property PACKAGE_PIN D18 [get_ports {ddr3_ba[1]}]
set_property PACKAGE_PIN B17 [get_ports {ddr3_ba[0]}]

##rascasvas
set_property PACKAGE_PIN A19 [get_ports ddr3_ras_n]
set_property PACKAGE_PIN B19 [get_ports ddr3_cas_n]
set_property PACKAGE_PIN A18 [get_ports ddr3_we_n]

##other stuff
set_property PACKAGE_PIN H17 [get_ports ddr3_reset_n]
set_property PACKAGE_PIN E18 [get_ports ddr3_cke]
set_property PACKAGE_PIN G19 [get_ports ddr3_odt]
set_property PACKAGE_PIN A22 [get_ports {ddr3_dm[0]}]
set_property PACKAGE_PIN C22 [get_ports {ddr3_dm[1]}]
set_property PACKAGE_PIN B20 [get_ports {ddr3_dqs_p[0]}]
set_property PACKAGE_PIN A20 [get_ports {ddr3_dqs_n[0]}]
set_property PACKAGE_PIN A23 [get_ports {ddr3_dqs_p[1]}]
set_property PACKAGE_PIN A24 [get_ports {ddr3_dqs_n[1]}]
set_property PACKAGE_PIN F18 [get_ports ddr3_ck_p]
set_property PACKAGE_PIN F19 [get_ports ddr3_ck_n]


##Slew fast for everyone!!
set_property SLEW FAST [get_ports ddr3_*]

##the IOSTANDARD is basically which voltage do pins consider 1 and 0
## SSTL135 is standard chip 1.35V for 1, it compares again VREF of exactly 0.675V
set_property IOSTANDARD SSTL135 [get_ports {{ddr3_dq[*]} {ddr3_addr[*]} {ddr3_ba[*]} {ddr3_dm[*]} ddr3_ras_n ddr3_cas_n ddr3_we_n ddr3_cke ddr3_odt ddr3_reset_n}]
set_property INTERNAL_VREF 0.675 [get_iobanks 16]
##That's differential, i love differential
set_property IOSTANDARD DIFF_SSTL135 [get_ports {ddr3_ck_p ddr3_ck_n {ddr3_dqs_p[*]} {ddr3_dqs_n[*]}}]

##When signals become fast, upon hitting any wire end(revieving pin) they literally bounce like umm uhhh waves
##ODT tries fixing that, and that thing does it too, they work pretty well tho
set_property IN_TERM UNTUNED_SPLIT_50 [get_ports {{ddr3_dq[*]} {ddr3_dqs_p[*]} {ddr3_dqs_n[*]}}]

##clk
set_property PACKAGE_PIN M21 [get_ports sys_clk]
##general purpose and crystal standard >2.0V = high, <0.8V = low, we don't talk about what happens in between
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
##that doesn't actually govern anythinks its just for PLL to compute freqs
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

##Thats LEDs
set_property PACKAGE_PIN H7 [get_ports sys_rst_n]
set_property PACKAGE_PIN G21 [get_ports {led[0]}]
set_property PACKAGE_PIN G20 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n {led[*]}}]


