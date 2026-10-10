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
    input  logic req_awck,
    input  logic mem_done
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
    //36*4=144bits, but actually 128bits for actual data, which is exactly
    //EMI's rdata btw, and rest 4bits per lane are parity bits which ill use
    //for flags
    (* ram_style = "block" *) logic [35:0] D_cache0 [0:2047];
    (* ram_style = "block" *) logic [35:0] D_cache1 [0:2047];
    (* ram_style = "block" *) logic [35:0] D_cache2 [0:2047];
    (* ram_style = "block" *) logic [35:0] D_cache3 [0:2047];

    logic [27:0] Dread_addr_lat;
    logic [12:0] cur_tag;
    logic [143:0] D_data_read;
    logic miss;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            Dread_addr_lat <= 28'h0;
        end else begin
            if (advance) begin //latch em bc BRAM req starts at EX and arrives at the start of MEM
                Dread_addr_lat <= Dread_addr;
            end
        end
    end

    always_ff @(posedge clk) begin : D1_read
            //Reading every cycle, no matter whether its stall or not, address
            //will be the same and i feel like reading on every cycle is safer.
            D_data_read[35:0] <= D_cache0[Dread_addr[14:4]];
            D_data_read[71:36] <= D_cache1[Dread_addr[14:4]];
            D_data_read[107:72] <= D_cache2[Dread_addr[14:4]];
            D_data_read[143:108] <= D_cache3[Dread_addr[14:4]];
    end : D1_read

    always_comb begin : data_out
        unique case (Dread_addr_lat[3:2])
            2'd0: D_data_out = {D_data_read[34:27], D_data_read[25:18], D_data_read[16:9], D_data_read[7:0]};
            2'd1: D_data_out = {D_data_read[70:63], D_data_read[61:54], D_data_read[52:45], D_data_read[43:36]};
            2'd2: D_data_out = {D_data_read[106:99], D_data_read[97:90], D_data_read[88:81], D_data_read[79:72]};
            2'd3: D_data_out = {D_data_read[142:135], D_data_read[133:126], D_data_read[124:117], D_data_read[115:108]};
        endcase
    end : data_out

    assign cur_tag = {D_data_read[8], D_data_read[17], D_data_read[26], D_data_read[35], D_data_read[44], D_data_read[53], D_data_read[62], D_data_read[71], D_data_read[80], D_data_read[89], D_data_read[98], D_data_read[107], D_data_read[116]};
    //Miss on invalid bit[143]
    //Or of course wrong tag, actually lemme explain it. Each sector stores
    //tag along the data to indicate which chunk of ddr3 its holding, which is
    //basically upper 13bits of address. That way miss in when you access
    //right address(you can't access wrong one bc cache address is basically
    //lower address bits) but in the wrong chunk of ddr3(wrong tag)
    assign miss = !D_data_read[143] || cur_tag != Dread_addr_lat[27:15];
    //If mem_rdy would become active during read or write address will change
    //mid-access leading to corruption ofc
    assign mem_rdy = (!re && !we) || !miss;
endmodule
