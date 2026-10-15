module L1_I (
    //I - instruction cache reads every advance cycle
    //Refills on missess too
    input logic clk,
    input logic rst,
    input logic advance,

    input logic [27:0] I_addr, //IF_PC_next
    output logic [63:0] I_data_out,

    output logic I_req,
    output logic [23:0] I_req_addr,

    input logic [127:0] EMI_rdata,
    input logic req_awck,
    input logic mem_done
);
