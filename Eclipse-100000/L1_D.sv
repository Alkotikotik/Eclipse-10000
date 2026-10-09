module L1_D (
    //D - data cache
    input logic clk,
    input logic rst,
    input logic advance, //not stall state

    input logic [27:0] Dread_addr, //D read address
    input logic [27:0] D_write_addr,
    input logic we, //EMI changed me - now im writing unreadable code...
    input logic re, //read enable

    input logic [31:0] D_data_in,
    input logic [1:0] byte_enable,

    output logic [31:0] D_data_out,
    output logic mem_rdy,

    output logic Dreq,
    output logic Dreq_we,
    output logic [23:0]  Dreq_addr,
    output logic [127:0] Dreq_wd_data,
    output logic [15:0]  Dreq_msk,

    input  logic [127:0] EMI_rdata,
    input  logic req_awck
);
    //32KB of D-cache, I settled on that number bc there is exactly 2 bits for
    //a lane, and 64KB just seems to much atm.
    //And 32KB per 1 core is fine, many modern CPUs have that exact amount.
    //Although if at the end ill have enough BRAM
    //Ill expand the cache bc im not wasting my resources
    //The Cache is split into 4 8KB lanes each one made of 4BRAM36 blocks.
    //The D-cache is at true dual port mode(TDP) bc EMI and CPU can write to
    //it. And it can write to EMI and CPU can read from it. I split it into
    //4lanes because each lane can output maximum of 36bit per request, thus
    //36*4=144bits, but actually 128 bc last 4are parity iirc, which is
    //exact EMI request length.
    (* ram_style = "block" *) logic [31:0] D_cache0 [0:2047];
    (* ram_style = "block" *) logic [31:0] D_cache1 [0:2047];
    (* ram_style = "block" *) logic [31:0] D_cache2 [0:2047];
    (* ram_style = "block" *) logic [31:0] D_cache3 [0:2047];

    logic [27:0] Dread_addr_lat, D_write_addr_lat;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            Dread_addr_lat <= 28'h0;
            D_write_addr_lat <= 28'h0;
        end else begin
            if (advance) begin //latch em bc BRAM req starts at EX and arrives at the start of MEM
                Dread_addr_lat <= Dread_addr;
                D_write_addr_lat <= D_write_addr;
            end



        end
    end
