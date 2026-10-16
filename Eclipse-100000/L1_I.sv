module L1_I (
    //I - instruction cache reads every cycle even if stalled
    //Bc if it is stalled - it just fetches prev IF_PC. Refills on missess too
    input logic clk,
    input logic rst,

    input logic [27:0] I_addr, //aka IF_PC_next
    output logic [63:0] I_data_out,

    output logic I_req,
    output logic [23:0] I_req_addr,
    output logic mem_rdy,

    input logic [127:0] EMI_rdata,
    input logic req_awck,
    input logic mem_done
);

    //Still need E/O bc it reads 8bytes that are 4byte aligned, so it might
    //very well cross. I is much simpler tho - no victioms, evictions, writes
    //just reads and refill
    (* ram_style = "block" *) logic [35:0] I_cacheE0 [0:511];
    (* ram_style = "block" *) logic [35:0] I_cacheE1 [0:511];
    (* ram_style = "block" *) logic [35:0] I_cacheE2 [0:511];
    (* ram_style = "block" *) logic [35:0] I_cacheE3 [0:511];

    (* ram_style = "block" *) logic [35:0] I_cacheO0 [0:511];
    (* ram_style = "block" *) logic [35:0] I_cacheO1 [0:511];
    (* ram_style = "block" *) logic [35:0] I_cacheO2 [0:511];
    (* ram_style = "block" *) logic [35:0] I_cacheO3 [0:511];

    logic [21:0]  I_hi_line, I_hi_line_lat, refill_line;
    logic [143:0] I_read_E, I_read_O, I_data_read;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [27:0]  I_addr_lat;
    logic [143:0] I_data_read_n;
    logic [35:0]  word0_lane, word1_lane;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [13:0]  cur_tag, hi_tag;
    logic [9:0]   refill_row, rst_clr;
    logic [8:0]   even_idx, odd_idx;
    logic [2:0]   req_cnt, mem_done_cnt;
    logic [1:0]   refill_first;
    logic refilling, rd_par, overlap, miss, miss_lo, miss_hi;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            I_addr_lat <= 28'h0;
            I_hi_line_lat <= 22'h0;
            req_cnt <= 3'd0;
            mem_done_cnt <= 3'd0;
            refilling <= 1'b0;
            refill_line <= 22'h0;
            refill_first <= 2'b0;
            rst_clr <= 10'd512;
        end else begin
            I_addr_lat <= I_addr;
            I_hi_line_lat <= I_hi_line;
            if (rst_clr != 0) begin
                rst_clr <= rst_clr - 1;
            end
            if (refilling) begin
                if (I_req && req_awck) begin
                    req_cnt <= req_cnt + 1;
                end
                if (mem_done) begin
                    mem_done_cnt <= mem_done_cnt + 1;
                end
                if (mem_done_cnt == 4) begin
                    req_cnt <= 3'd0;
                    mem_done_cnt <= 3'd0;
                    refilling <= 1'b0;
                end
            end else if (miss && rst_clr == 0) begin
                refilling <= 1'b1;
                refill_line <=  miss_lo ? I_addr_lat[27:6] : I_hi_line_lat;
                refill_first <= miss_lo ? I_addr_lat[5:4] : 2'b00;
            end
        end
    end

    assign odd_idx   = I_addr[13:5];
    assign even_idx  = I_addr[13:5] + {8'd0, I_addr[4]};
    assign I_hi_line = I_addr[27:6] + {21'd0, &I_addr[5:4]};

    always_ff @(posedge clk) begin : I_read
        I_read_E[35:0]    <= I_cacheE0[even_idx];
        I_read_E[71:36]   <= I_cacheE1[even_idx];
        I_read_E[107:72]  <= I_cacheE2[even_idx];
        I_read_E[143:108] <= I_cacheE3[even_idx];

        I_read_O[35:0]    <= I_cacheO0[odd_idx];
        I_read_O[71:36]   <= I_cacheO1[odd_idx];
        I_read_O[107:72]  <= I_cacheO2[odd_idx];
        I_read_O[143:108] <= I_cacheO3[odd_idx];

        rd_par <= I_addr[4];
    end : I_read
    assign I_data_read   = rd_par ? I_read_O : I_read_E;
    assign I_data_read_n = rd_par ? I_read_E : I_read_O;
    assign refill_row    = {refill_line[7:0], refill_first + mem_done_cnt[1:0]};

    always_ff @(posedge clk) begin : I_EMI
        if (rst_clr != 0) begin
            I_cacheE3[rst_clr[8:0] - 9'd1] <= 36'b0;
            I_cacheO3[rst_clr[8:0] - 9'd1] <= 36'b0;
        end else if (mem_done) begin
            if (refill_row[0]) begin
                I_cacheO0[refill_row[9:1]] <= {refill_line[18], EMI_rdata[31:24],  refill_line[19], EMI_rdata[23:16],  refill_line[20], EMI_rdata[15:8],   refill_line[21], EMI_rdata[7:0]};
                I_cacheO1[refill_row[9:1]] <= {refill_line[14], EMI_rdata[63:56],  refill_line[15], EMI_rdata[55:48],  refill_line[16], EMI_rdata[47:40],  refill_line[17], EMI_rdata[39:32]};
                I_cacheO2[refill_row[9:1]] <= {refill_line[10], EMI_rdata[95:88],  refill_line[11], EMI_rdata[87:80],  refill_line[12], EMI_rdata[79:72],  refill_line[13], EMI_rdata[71:64]};
                I_cacheO3[refill_row[9:1]] <= {1'b1,            EMI_rdata[127:120], 1'b0,           EMI_rdata[119:112], refill_line[8],  EMI_rdata[111:104], refill_line[9],  EMI_rdata[103:96]};
            end else begin
                I_cacheE0[refill_row[9:1]] <= {refill_line[18], EMI_rdata[31:24],  refill_line[19], EMI_rdata[23:16],  refill_line[20], EMI_rdata[15:8],   refill_line[21], EMI_rdata[7:0]};
                I_cacheE1[refill_row[9:1]] <= {refill_line[14], EMI_rdata[63:56],  refill_line[15], EMI_rdata[55:48],  refill_line[16], EMI_rdata[47:40],  refill_line[17], EMI_rdata[39:32]};
                I_cacheE2[refill_row[9:1]] <= {refill_line[10], EMI_rdata[95:88],  refill_line[11], EMI_rdata[87:80],  refill_line[12], EMI_rdata[79:72],  refill_line[13], EMI_rdata[71:64]};
                I_cacheE3[refill_row[9:1]] <= {1'b1,            EMI_rdata[127:120], 1'b0,           EMI_rdata[119:112], refill_line[8],  EMI_rdata[111:104], refill_line[9],  EMI_rdata[103:96]};
            end
        end
    end : I_EMI

    always_comb begin : data_out
        overlap    = I_addr_lat[3:2] == 2'b11;
        //two words as core asks, that fetch_duo or something
        word0_lane = I_data_read[36*I_addr_lat[3:2] +: 36];
        word1_lane = overlap ? I_data_read_n[35:0] : I_data_read[36*2'(I_addr_lat[3:2] + 2'd1) +: 36];
        I_data_out = {word1_lane[7:0], word1_lane[16:9], word1_lane[25:18], word1_lane[34:27],
                      word0_lane[7:0], word0_lane[16:9], word0_lane[25:18], word0_lane[34:27]};
    end : data_out

    assign cur_tag = {I_data_read[8], I_data_read[17], I_data_read[26], I_data_read[35], I_data_read[44], I_data_read[53], I_data_read[62], I_data_read[71], I_data_read[80], I_data_read[89], I_data_read[98], I_data_read[107], I_data_read[116], I_data_read[125]};
    assign hi_tag  = {I_data_read_n[8], I_data_read_n[17], I_data_read_n[26], I_data_read_n[35], I_data_read_n[44], I_data_read_n[53], I_data_read_n[62], I_data_read_n[71], I_data_read_n[80], I_data_read_n[89], I_data_read_n[98], I_data_read_n[107], I_data_read_n[116], I_data_read_n[125]};

    assign miss_lo = !I_data_read[143] || cur_tag != I_addr_lat[27:14];
    assign miss_hi = !I_data_read_n[143] || hi_tag != I_hi_line_lat[21:8];
    assign miss = miss_lo || (overlap && miss_hi);

    assign mem_rdy = !miss && !refilling && rst_clr == 0; //yeah thats it
    assign I_req = refilling && req_cnt != 4;
    assign I_req_addr = {refill_line, refill_first + req_cnt[1:0]};

endmodule
