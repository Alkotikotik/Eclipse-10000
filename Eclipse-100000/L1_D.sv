module L1_D (
    //D - data cache
    input logic clk,
    input logic rst,

    input logic [27:0] Dread_addr, //D read address
    input logic [27:0] Ewrite_addr,
    input logic we, //write enable EMI changed me - now im writing unreadable code...
    input logic re, //read enable

    input logic [31:0] D_data_in,
    input logic [1:0] byte_enable,

    output logic [31:0] Ddata_out,

);
