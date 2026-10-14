module L1_D (
    //D - data cache
    input logic clk,
    input logic rst,
    input logic advance, //not stall state

    input logic [27:0] Dread_addr, //D read address
    input logic [14:0] D_write_addr,
    input logic we, //EMI changed me - now im writing unreadable code...
    input logic re, //read enable

    input logic [31:0] D_data_in,
    input logic [1:0]  mem_size,

    output logic [31:0] D_data_out,
    output logic mem_rdy,

    output logic Dreq,
    output logic Dreq_we,
    output logic [23:0]  Dreq_addr,
    output logic [127:0] Dreq_wd_data,
    output logic [15:0]  Dreq_msk,

    input logic [127:0] EMI_rdata,
    input logic req_awck,
    input logic mem_done
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
    (* ram_style = "block" *) logic [35:0] D_cacheE0 [0:1023];
    (* ram_style = "block" *) logic [35:0] D_cacheE1 [0:1023];
    (* ram_style = "block" *) logic [35:0] D_cacheE2 [0:1023];
    (* ram_style = "block" *) logic [35:0] D_cacheE3 [0:1023];

    (* ram_style = "block" *) logic [35:0] D_cacheO0 [0:1023];
    (* ram_style = "block" *) logic [35:0] D_cacheO1 [0:1023];
    (* ram_style = "block" *) logic [35:0] D_cacheO2 [0:1023];
    (* ram_style = "block" *) logic [35:0] D_cacheO3 [0:1023]; //-O3

    logic [27:0]  Dread_addr_lat;
    logic [21:0]  Dread_addr_plus16_lat, Dread_box_plus1, refill_line;
    logic [12:0]  hi_tag;
    logic [1:0]   refill_first;
    logic miss_lo, cap_lo;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [143:0] cap_src;
    /* verilator lint_on UNUSEDSIGNAL */
    logic overlap, miss_hi;
    logic [31:0]  store_bytes;
    logic [3:0]   store_msk, lane3_meta;
    logic [12:0]  cur_tag;
    logic [15:0]  wen; //write enable for n
    logic [143:0] D_data_read, D_data_read_n, D_read_E, D_read_O, rd_data;
    logic [4:0]   pos;
    logic [9:0]   even_idx, odd_idx;
    logic [10:0]  refill_row;
    logic rd_par;
    logic miss, last_was_store;
    logic Dreq_EMI;
    logic [10:0] last_store_row;
    logic [11:0] rst_clr;

    //Thats an actual name lmao
    logic [127:0] victim_data [0:3];
    logic [12:0]  victim_tag;
    logic [8:0]   victim_index;
    logic [3:0]   victim_dirty;
    logic [1:0] read_cnt, box;
    logic [10:0] Dread_addr_real;
    logic capturing, drain, refill_req;

    logic [2:0] req_cnt, mem_done_cnt;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            Dread_addr_lat <= 28'h0;
            req_cnt <= 3'b00;
            mem_done_cnt <= 3'b00;
            Dreq_EMI <= 0;
            rst_clr <= 12'd2048;
            capturing <= 1'b0;
            read_cnt <= 2'b0;
            victim_dirty <= 4'b0;
            victim_tag <= 13'h0;
            victim_index <= 9'h0;
            refill_line <= 22'h0;
            refill_first <= 2'b0;
            cap_lo <= 1'b1;
            last_was_store <= 1'b0;
            last_store_row <= 11'h0;
        end else begin
            if (advance) begin //latch em bc BRAM req starts at EX and arrives at the start of MEM
                Dread_addr_lat <= Dread_addr;
                Dread_addr_plus16_lat <= Dread_box_plus1;
            end
            if (rst_clr != 0) begin
                rst_clr <= rst_clr - 1;
            end
            //On miss req 4reads from EMI, 4 because im fetching 4 at ones.
            //basically thats kinda like cache works, if I want this data
            //chances are I might want data near it.
            if (Dreq_EMI) begin
                if (refill_req && req_awck) begin
                    req_cnt <= req_cnt + 1;
                end
                if (mem_done) begin
                    mem_done_cnt <= mem_done_cnt + 1;
                end
                if (mem_done_cnt == 4) begin
                    req_cnt <= 3'd0;
                    mem_done_cnt <= 3'd0;
                    Dreq_EMI <= 1'b0;
                end
            end else if ((re | we) && miss && !Dreq_EMI && victim_dirty == 0 && rst_clr == 0) begin
                Dreq_EMI  <= 1'b1;
                capturing <= 1'b1;
                read_cnt  <= 2'b0;
                victim_tag <= miss_lo ? cur_tag : hi_tag;
                victim_index <= miss_lo ? Dread_addr_lat[14:6] : Dread_addr_plus16_lat[8:0];
                refill_line <= miss_lo ? Dread_addr_lat[27:6] : Dread_addr_plus16_lat;
                refill_first <= miss_lo ? Dread_addr_lat[5:4] : 2'b00;
                cap_lo <= miss_lo;
            end
            if (capturing) begin //checking if its dirty
                //This happens at the same time as im writing data to cache,
                //because while im writing well im not reading so might as well
                read_cnt <= read_cnt + 1;
                victim_dirty[refill_first + read_cnt] <= cap_src[125];
                if (read_cnt == 3) begin
                    capturing <= 1'b0;
                end
            end
            if (drain && req_awck) begin
                victim_dirty[box] <= 1'b0;
            end
            last_was_store <= we && mem_rdy;
            last_store_row <= D_write_addr[14:4];
        end
    end

    always_ff @(posedge clk) begin
        if (capturing) begin
            victim_data[refill_first + read_cnt] <= {
                cap_src[142:135], cap_src[133:126], cap_src[124:117], cap_src[115:108],
                cap_src[106:99],  cap_src[97:90],   cap_src[88:81],   cap_src[79:72],
                cap_src[70:63],   cap_src[61:54],   cap_src[52:45],   cap_src[43:36],
                cap_src[34:27],   cap_src[25:18],   cap_src[16:9],    cap_src[7:0]
            };
        end
    end

    //reading every cycle, no matter whether its stall or not, address
    //will be the same and i feel like reading on every cycle is safer.
    //also in separate always_ff without async reset, otherwise vivado
    //just wouldn't map it on actual bram bc it doesn't support async
    //rst, it supports sync tho, but idgaf.
    assign Dread_addr_real = capturing ? {refill_line[8:0], refill_first + read_cnt + 2'd1}: Dread_addr[14:4];
    assign cap_src = (read_cnt == 0 && !cap_lo) ? D_data_read_n : D_data_read;
    assign odd_idx  = Dread_addr_real[10:1];
    assign even_idx = Dread_addr_real[10:1] + {9'd0, Dread_addr_real[0]};
    always_ff @(posedge clk) begin : D1_read
        D_read_E[35:0]    <= D_cacheE0[even_idx];
        D_read_E[71:36]   <= D_cacheE1[even_idx];
        D_read_E[107:72]  <= D_cacheE2[even_idx];
        D_read_E[143:108] <= D_cacheE3[even_idx];

        D_read_O[35:0]    <= D_cacheO0[odd_idx];
        D_read_O[71:36]   <= D_cacheO1[odd_idx];
        D_read_O[107:72]  <= D_cacheO2[odd_idx];
        D_read_O[143:108] <= D_cacheO3[odd_idx];

        rd_par <= Dread_addr_real[0];
    end : D1_read
    assign D_data_read   = rd_par ? D_read_O : D_read_E;
    assign D_data_read_n = rd_par ? D_read_E : D_read_O;
    assign refill_row    = {refill_line[8:0], refill_first + mem_done_cnt[1:0]};

    //EMI write to BRAM's respective address based on current beat and ofc addr.
    //Also im writing tag to the parity bits which is why it looks so evil.
    //CPU write to BRAM 36bit of data and just, and mask the meta. As well as
    //everything I don't want to write based on fragmented registers, stores
    //and etc, just read the code bruh.
    always_ff @(posedge clk) begin : D1_write
        if (rst_clr != 0) begin //just clean all flags on rst
            if (rst_clr[0])
                D_cacheE3[rst_clr[10:1]] <= 36'b0;
            else
                D_cacheO3[rst_clr[10:1] - 10'd1] <= 36'b0;
        end else if (mem_done) begin //miss
            if (refill_row[0]) begin
                D_cacheO0[refill_row[10:1]] <= {refill_line[18], EMI_rdata[31:24],  refill_line[19], EMI_rdata[23:16],  refill_line[20], EMI_rdata[15:8],   refill_line[21], EMI_rdata[7:0]};
                D_cacheO1[refill_row[10:1]] <= {refill_line[14], EMI_rdata[63:56],  refill_line[15], EMI_rdata[55:48],  refill_line[16], EMI_rdata[47:40],  refill_line[17], EMI_rdata[39:32]};
                D_cacheO2[refill_row[10:1]] <= {refill_line[10], EMI_rdata[95:88],  refill_line[11], EMI_rdata[87:80],  refill_line[12], EMI_rdata[79:72],  refill_line[13], EMI_rdata[71:64]};
                D_cacheO3[refill_row[10:1]] <= {1'b1,               EMI_rdata[127:120], 1'b0,              EMI_rdata[119:112], 1'b0,              EMI_rdata[111:104], refill_line[9], EMI_rdata[103:96]};
            end else begin
                D_cacheE0[refill_row[10:1]] <= {refill_line[18], EMI_rdata[31:24],  refill_line[19], EMI_rdata[23:16],  refill_line[20], EMI_rdata[15:8],   refill_line[21], EMI_rdata[7:0]};
                D_cacheE1[refill_row[10:1]] <= {refill_line[14], EMI_rdata[63:56],  refill_line[15], EMI_rdata[55:48],  refill_line[16], EMI_rdata[47:40],  refill_line[17], EMI_rdata[39:32]};
                D_cacheE2[refill_row[10:1]] <= {refill_line[10], EMI_rdata[95:88],  refill_line[11], EMI_rdata[87:80],  refill_line[12], EMI_rdata[79:72],  refill_line[13], EMI_rdata[71:64]};
                D_cacheE3[refill_row[10:1]] <= {1'b1,               EMI_rdata[127:120], 1'b0,              EMI_rdata[119:112], 1'b0,              EMI_rdata[111:104], refill_line[9], EMI_rdata[103:96]};
            end
        end else if (we && mem_rdy) begin
            for (integer i = 0; i < 4; i++) begin
                if (D_write_addr[4]) begin
                    if (wen[i + 0]) begin
                        D_cacheO0[D_write_addr[14:5]][9 * i +: 9] <= {Dread_addr_lat[27 - 4*0 - i], store_bytes[31 - 8*i -: 8]};
                    end if (wen[i + 4]) begin
                        D_cacheO1[D_write_addr[14:5]][9 * i +: 9] <= {Dread_addr_lat[27 - 4*1 - i], store_bytes[31 - 8*i -: 8]};
                    end if (wen[i + 8]) begin
                        D_cacheO2[D_write_addr[14:5]][9 * i +: 9] <= {Dread_addr_lat[27 - 4*2 - i], store_bytes[31 - 8*i -: 8]};
                    end if (wen[i + 12]) begin
                        D_cacheO3[D_write_addr[14:5]][9 * i +: 9] <= {lane3_meta[i],(D_write_addr[3:2] == 3 && store_msk[i]) ? store_bytes[31 - 8*i -: 8] : D_data_read[108 + 9*i +: 8]}; //If you are physically seeing this then: this is for dirty bits, if CPU actually writes there I jsut set dirty flag and put data there, if it doesn't I just set the dirty flag
                    end
                end else begin
                    if (wen[i + 0]) begin
                        D_cacheE0[D_write_addr[14:5]][9 * i +: 9] <= {Dread_addr_lat[27 - 4*0 - i], store_bytes[31 - 8*i -: 8]};
                    end if (wen[i + 4]) begin
                        D_cacheE1[D_write_addr[14:5]][9 * i +: 9] <= {Dread_addr_lat[27 - 4*1 - i], store_bytes[31 - 8*i -: 8]};
                    end if (wen[i + 8]) begin
                        D_cacheE2[D_write_addr[14:5]][9 * i +: 9] <= {Dread_addr_lat[27 - 4*2 - i], store_bytes[31 - 8*i -: 8]};
                    end if (wen[i + 12]) begin
                        D_cacheE3[D_write_addr[14:5]][9 * i +: 9] <= {lane3_meta[i],(D_write_addr[3:2] == 3 && store_msk[i]) ? store_bytes[31 - 8*i -: 8] : D_data_read[108 + 9*i +: 8]};
                    end
                end
            end
        end
    end : D1_write

    //Basically i gotta do some dancing with even and odd lanes, but why?
    //The thing is - unaligned load can touch two bram rows at ones, eg u32 load at the
    //edge, and bram physically cannot provide it. So one solution is to just
    //stall and read in two cycles, but ofc im not doing that. The other
    //solution is to split bram into even and odd rows and read both at ones
    //every time, and then merge results. But to make it actually handle it
    //I have to check if it overlaps with the next even/odd block and if it
    //does read some bytes from it. The lower bytes block is called lo and higher
    //is called hi and they always have opposite parity(any 2 conseq blocks do).
    always_comb begin : data_out
        //btw for in always_comb unrolls to 4 parallel instances
        //if it reaches into hi, I gotta check for hi miss too
        overlap = {1'b0, Dread_addr_lat[3:0]} + (5'd1 << mem_size) > 16;
        for (int i = 0; i < 4; i++) begin
            pos = {1'b0, Dread_addr_lat[3:0]} + 5'(i);
            if (pos[4]) begin //>0xF check, bc if it is, it overlaps and I gotta read from hi, which is opposite of lo
                rd_data = D_data_read_n;
            end else begin
                rd_data = D_data_read;
            end
            D_data_out[31 - 8*i -: 8] = rd_data[36*pos[3:2] + 9*pos[1:0] +: 8]; //-: 8bits before ofc, bc big endian
        end
        case (mem_size)
            2'b10, 2'b11: begin
                store_bytes = D_data_in;
                store_msk = 4'b1111;
            end
            2'b01: begin
                store_bytes = {D_data_in[15:0], D_data_in[15:0]}; //dupe and then mask
                store_msk = 4'b0011;
            end
            2'b00: begin
                store_bytes = {D_data_in[7:0], D_data_in[7:0], D_data_in[7:0], D_data_in[7:0]};
                store_msk = 4'b0001;
            end
        endcase
        store_msk = store_msk << D_write_addr[1:0]; //I love bit tricks
        wen = {12'b0, store_msk} << {D_write_addr[3:2], 2'b00}; //shift it to the right lane
        wen[13] = 1; //always dirty bit on writes from CPU
        lane3_meta = {1'b1, 1'b0, 1'b1, Dread_addr_lat[15]};
    end : data_out

    assign refill_req = Dreq_EMI && req_cnt != 4;
    assign drain = |victim_dirty && !capturing && !refill_req;
    assign box = victim_dirty[0] ? 2'd0 : victim_dirty[1] ? 2'd1 : victim_dirty[2] ? 2'd2 : 2'd3;
    assign Dreq_we = drain;
    assign Dreq_wd_data = victim_data[box];
    assign Dreq_msk = 16'h0;
    //24bits of addr. read 4conseq 128bit chunks so 512bit of
    //total data. the [5:4] bits requests the data CPU needs the
    //most first and then the rest
    assign Dreq_addr = refill_req ? {refill_line, refill_first + req_cnt[1:0]} : {victim_tag, victim_index, box}; //refill : victim

    assign cur_tag = {D_data_read[8], D_data_read[17], D_data_read[26], D_data_read[35], D_data_read[44], D_data_read[53], D_data_read[62], D_data_read[71], D_data_read[80], D_data_read[89], D_data_read[98], D_data_read[107], D_data_read[116]};
    assign hi_tag = {D_data_read_n[8], D_data_read_n[17], D_data_read_n[26], D_data_read_n[35], D_data_read_n[44], D_data_read_n[53], D_data_read_n[62], D_data_read_n[71], D_data_read_n[80], D_data_read_n[89], D_data_read_n[98], D_data_read_n[107], D_data_read_n[116]};
    assign Dread_box_plus1 = Dread_addr[27:6] + {21'd0, &Dread_addr[5:4]};
    //Miss on invalid bit[143]
    //Or of course wrong tag, actually lemme explain it. Each sector stores
    //tag along the data to indicate which chunk of ddr3 its holding, which is
    //basically upper 13bits of address. That way miss in when you access
    //right address(you can't access wrong one bc cache address is basically
    //lower address bits) but in the wrong chunk of ddr3(wrong tag)
    assign miss_lo = !D_data_read[143] || cur_tag != Dread_addr_lat[27:15];
    assign miss = miss_lo || (overlap && miss_hi);
    assign miss_hi = !D_data_read_n[143] || hi_tag != Dread_addr_plus16_lat[21:9]; //plus16 bc hi and lo re 16bytes apart anf if they are 32KB they are basically cooked
    //If mem_rdy would become active during read or write address will change
    //mid-access leading to corruption ofc. Also if read same address as just
    //written to, just stall, its just so unlikely to happen like why tf would
    //you read what you just wrote? Anyways ill test forwarding later
    assign mem_rdy = (!re && !we) || (!miss && !Dreq_EMI && !(last_was_store && last_store_row == Dread_addr_lat[14:4])) && (rst_clr == 0);
    assign Dreq = refill_req || drain; //There would be other Dreqs causes here
endmodule
