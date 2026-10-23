module CORE(
    input logic clk,
    input logic reset,
    input logic [7:0] ENC_10K_KeyIn,
    input logic ENC_10K_ModArr, //for shifts/alts

    output logic [31:0] vram_addr,
    output logic [31:0] vram_data_out,
    output logic vram_write,

    output logic EMI_req, EMI_req_we,
    output logic [23:0] EMI_req_addr,
    output logic [127:0] EMI_req_wd,
    output logic [15:0] EMI_req_msk,

    input logic EMI_req_awck, EMI_mem_done,
    input logic [127:0] EMI_rdata

);
    //====//
    //Pipilined 5 cycle CPU, I chose 5 cycles because its perfect balance
    //between clock speed, which is higher because of shorter critical path, and
    //penatly for mispredicted branch which is 3 cycles for regular branches
    //and literally 0 for unconditional ones. The penalty is 0 for correctly
    //predicted ones too.

    //The estimated CPI is ~=1.02-1.08 considering average instruction split
    //obviosely varies by program being executed.
    //That is about 2.8 times faster than my multi-cycle design(~= 2.9CPI) as
    //well as higher estimated clock frequency due to shorter critical path
    //3 cycles per instruction to 5, we'll see about that I gotta optimze it.

    //Stages go as follows:
    //IF(Instruction Fetch) |=> GA(Gather) |=> EX(Execute) |=> VER(Verify) |=> WB(Write - back)
    //====//

    logic  demolish;   //Removes current instructions on the branch misprediction/branch
    logic  stall;     //Stalls on memory accesses in future but atm on divs
    logic  bubble;   //for handling load-use hazard

    logic  early_target_ok;
    assign early_target_ok = (opcode == 6'b010000) ? (EX_early_target == EX_LR) : (EX_early_target == EX_EPC);

    //Basically thats a massive check for unexpected PC change, like branch
    //misprediction, interrupt and JR maybe other but I forgot
    assign demolish  =  isEX_valid && !mem_stall && !VER_redirect &&
                        (irq_taken ||
                        (PCWrite &&
                        !(opcode == 6'b111111 || opcode == 6'b111000) &&
                        !((opcode == 6'b010000 || opcode == 6'b111101) && early_target_ok)));

    assign stall     = div_stall || mem_stall;
    assign bubble    = (mul_use_hazard || load_use_hazard || rr2_conflict || mdx_idx_hazard) && !stall; //If we already stall no point in bubble, it also breaks div

    //== IF(Instruction Fetch) ==//
    logic [31:0] IF_PC;
    logic [31:0] IF_PC_plus4_or8;
    logic [27:0] IF_PC_tofetch;
    logic [31:0] IF_PC_plus4, IF_PC_plus8;
    logic [8:0]  IF_even_tofetch;
    logic IF_jump, IF_redir, IF_skip, IF_take;

    function automatic [8:0] even_row(input [13:4] a);
        even_row = a[13:5] + {8'd0, a[4]};
    endfunction
    logic I_mem_rdy, I_miss_ff, I_took_ff, I_kill;

    assign IF_PC_plus4 = IF_PC + 32'd4;
    assign IF_PC_plus8 = IF_PC + 32'd8;
    assign IF_PC_plus4_or8 = (IF_64 || IF_branch) ? IF_PC_plus8 : IF_PC_plus4;

    logic [31:0] IF_PC_next;
    assign IF_jump = instr_fetch_data[31:26] == 6'b111111 || instr_fetch_data[31:26] == 6'b111000 || instr_fetch_data[31:26] == 6'b010000 || instr_fetch_data[31:26] == 6'b111101 || IF_predicted_taken;
    assign IF_PC_next = IF_jump ? IF_redirect_target : IF_PC_plus4_or8;

    //Either fetch next seq, or next predicted branch or stall or kill on miss
    always_comb begin
        if (BTB_hit) begin
            unique case (BTB_read[35:34])
                2'b01: IF_PC_tofetch = BTB_read[25:0]; //JMP/CALL
                //2'b10: IF_PC_tofetch = RAS top
                2'b11: IF_PC_tofetch = pht_out[1] : BTB_read[25:0] ? IF_PC_plus8;
                default: IF_PC_tofetch = 26'hdead67; //theoretically unreachable
            endcase
        end else begin
            IF_PC_tofetch = I_kill ? GA_PC[27:0] : IF_take ? IF_PC_plus4[27:0] : IF_PC[27:0];
        end
    end

    //Alright so to optimize critical path I had to basically fetch IF_PC
    //+ 8 every cycle no matter what. That doesn't touch regular branches
    //because they kill anyways, however it does add 1 stall cycle to every
    //uncond branch like JMP/CALL/RET. And it is a little bit unfortunate,
    //however a BTB or whatever its called should fix it.
    (* keep = "true" *) logic [8:0] IF_even_kill, IF_even_take, IF_even_hold;
    assign IF_even_kill = even_row(GA_PC[13:4]);
    assign IF_even_take = even_row(IF_PC_plus4[13:4]);
    assign IF_even_hold = even_row(IF_PC[13:4]);
    assign IF_even_tofetch = I_kill ? IF_even_kill
        : IF_take ? IF_even_take : IF_even_hold;

    assign IF_take = !stall && !bubble && I_mem_rdy && !IF_redir;

    always_ff @(posedge clk or posedge reset) begin : IF_window
        if (reset) begin
            IF_redir <= 1'b0;
            IF_skip  <= 1'b0;
        end else begin
            IF_redir <= (IF_take && IF_jump && !I_kill) || VER_fault || VER_redirect;
            IF_skip  <= IF_take && (IF_64 || IF_branch) && !VER_fault && !VER_redirect && !I_kill;
        end
    end : IF_window

    always_ff @(posedge clk or posedge reset) begin : IF_main
        if (reset) IF_PC <= 32'h0;
        else if(VER_fault) IF_PC <= memFault ? 32'h00000070 : 32'h00000074;
        else if(VER_redirect) IF_PC <= VER_redirect_target;
        else if(I_kill) IF_PC <= GA_PC;
        else if(IF_take) IF_PC <= IF_PC_next;
        else IF_PC <= IF_PC; //I just can't omit it
    end : IF_main

    logic [63:0] instr_fetch_duo;
    logic [31:0] instr_fetch_data; //from RAM's dedicated instruction port
    logic [31:0] IF_IR_2; //Second 32-bits for 64-bit instruction i hate word instruction its so long to type and annoying to spell, and shortened instr sucks too

    assign instr_fetch_data = instr_fetch_duo[31:0];
    assign IF_IR_2 = instr_fetch_duo[63:32];   //fetch is 4 byte aligned so this is always PC+4
    //So unconditional branches: JMP, CALL, RET, RETU are immediately resolved
    //in the IF stage, so no penatly for them whatsoever
    logic [31:0] IF_redirect_target;
    logic [5:0] IF_op;
    assign IF_op = instr_fetch_data[31:26];

    //One more important thing - JMP and CALL are now absolute jumps(same for
    //conds later), because since, as already stated, labels are 4byte aligned
    //and last 2bits are always zero, we can just shift the 28bit
    //address(256MB) right by 2 in assembler, which would give us 256MB range
    //in 32bit instructions, and its so goddamn beatiful.
    always_comb begin
        unique case (IF_op)
            6'b111101: IF_redirect_target = EPC; //RETU
            6'b010000: IF_redirect_target = LR; //RET
            6'b111111, 6'b111000: IF_redirect_target = {4'b0, instr_fetch_data[25:0], 2'b00}; //JMP / CALL
            6'b110000: IF_redirect_target = {4'b0, IF_IR_2[25:0], 2'b00}; //64bit branches
            default: IF_redirect_target = {4'b0, IF_IR_2[25:0], 2'b00};
        endcase
    end

    //== 64bit instructions ==//
    //If opcode is 000000 we check for sub-op of its 000000 too then its just
    //a NOP, if it isn't 000000 though, its a 64-bit instruction
    logic  IF_64; //That spells much cooler than IF_isInst64bit or some, so im ready to sacrafire readability for this no one's gonna read it anyways
    assign IF_64 = ((instr_fetch_data[31:26] == 6'b000000) && (|instr_fetch_data[9:4]));

    logic  IF_branch; //Separate escape code for 64bit branch instructions
    assign IF_branch = ((instr_fetch_data[31:26] == 6'b110000) && (|instr_fetch_data[9:5]));

    //== Branch prediction ==//
    //My implementation of gshare branch predictor, source McFalring's 1991 paper
    //Idk who I explain it to but I just want to explain gshare branch predictor.
    //So Basically all branch predictors work on one main principle - branches
    //tends to do the same thing they did last time, so if it was taken last time - chances are it will ba taken this time
    //So we just make a bigass table of all recent branches with saturating counters of 2 bits. Why 2 bits -
    //well there are occasionally anomalous results and 2 bit counter handles
    //them much better than 1 bit one.
    //Except I kinda lied - branches tends to follow the pattern not just
    //based on what they did last time, but what pattern of previous branches
    //led to it. This is actually beatiful, take a look at my render.flar
    //program, branches follow a strict pattern based on phase, that pattern
    //could be captured by gshare allowing for nearly 100% accuracy after
    //a couple of training iterations
    //The GHR is this exact register that holds outputs of previous branches,
    //xoring it with pht_idx gives us different address every time output of
    //previous branches is different.
    //
    //Exact numbers in comments are outdated: I changed PHT to 4kb per core
    //and hence everything else

    //PHT - pattern history table 4KB of BRAM. It actually doesn't store
    //saturing counters for each branch, it just stores saturating counters
    //without any inherit meaning associated with them. 4KB per core btw
    (* ram_style = "block" *) logic [1:0] PHT [0:16383];

    //Default is weakly taken simply because branches are usually taken
    //then not, though if particular one isn't its just 1 time calibration
    initial begin
        for (integer i = 0; i< 16384; i = i + 1) PHT[i] = 2'b10;
    end

    //GHR - Global history register 12 bits because its just enough to address
    //all 4KB
    logic [15:0] GHR;

    logic [13:0] pht_read_idx;
    //Last 14 bits of imm26 13:2 because last two bits are always 0 since labels are 4 byte aligned
    //IF_PC_next because BRAM read happens on the next clock cycle to the request
    assign pht_read_idx = IF_PC_tofetch[16:3] ^ GHR[13:0] ^ {5'b0, GHR[15:14], 7'b0};
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0] pht_out; //Actual counter for particular branch, only lowest bit isn't really read
    /* verilator lint_on UNUSEDSIGNAL */

    //We gotta check whether branch was actually taken or not

    //Simple table:
    //00 || 01 - predict not taken
    //10 || 11 - predict taken
    logic  IF_predicted_taken;
    assign IF_predicted_taken = IF_branch && pht_out[1];

    function automatic [1:0] updated_pht(input [1:0] prev_pht, input taken);
        if (taken) begin
            updated_pht = (prev_pht == 2'b11) ? 2'b11 : prev_pht + 2'b01;
        end else begin
            updated_pht = (prev_pht == 2'b00) ? 2'b00 : prev_pht - 2'b01;
        end
    endfunction

    logic [13:0] pht_idx_r;
    always_ff @(posedge clk) begin
        pht_idx_r <= pht_read_idx;
    end

    //This all coming together
    //Only read EX_pht_idx rather than combinationally like previousely
    always_ff @(posedge clk) begin : predict_branch
        pht_out <= PHT[pht_read_idx];
        if (isVER_valid && VER_branch && !VER_irq && !mem_stall)
            PHT[VER_pht_idx] <= updated_pht(VER_pht_val, branch_cond_met);
    end : predict_branch

    //GHR is still in flops though
    always_ff @(posedge clk or posedge reset) begin
        if (reset) GHR <= 16'b0;
        else if (isVER_valid && VER_branch && !VER_irq && !mem_stall) GHR <= {GHR[14:0], branch_cond_met};
    end

    //BTB aka Branch Target Buffer.
    //It stores the target address of any branch and gshare predicts taken it
    //pulls address from here. It also pulls address from here on JMP/CALL/RET
    //Which brings that back to 0cycles penalty in most of the cases, however
    //when it misses the tag(similar to cache) it does pay a little.
    //I implement it using BRAM36 with encoding as follows:
    //2bits kind(very kind), 8bits tag(aka PC[18:11]), 26bits target.
    //kind is: 00 - empty, 01 - JMP/CALL, 10 - RET, 11 - fused cond

    (* ram_style = "block" *) logic [1023:0] BTB [35:0]; //up to 1024branch instructions stored
    initial begin
        for (integer i = 0; i < 1024; i = i + 1) BTB[i] = 36'd0;
    end
    logic [35:0] BTB_read;
    always_ff @(posedge clk) begin
        BTB_read <= BTB[IF_PC_tofetch[10:2]];
    end

    logic  BTB_hit;
    assign BTB_hit = (BTB_read == IF_PC_tofetch[18:11]) && BTB[35:34] != 00; //00 is for startup mainly

    always_ff @(posedge clk) begin
        if (!BTB_hit || !BTB_www) begin
            //512KB aliases are simply cought by the mispredict machinery
            BTB[IF_PC[11:2]] <= {2'b01, IF_PC[20:12], instr_fetch_data[25:0]};
        end
    end

    logic BTB_www;
    always_comb begin
        unique case (BTB[35:34])
            2'b01: BTB_www = (instr_fetch_data[31:26] == 6'b111111 || instr_fetch_data[31:26] == 6'b111000) && (instr_fetch_data[25:0] == BTB[25:0]);
            2'b10: BTB_www =  instr_fetch_data[31:26] == 6'b010000; //rest in EX
            2'b11: BTB_www = (instr_fetch_data[31:26] == 6'b110000) && (IF_IR_2 == BTB_read[25:0]);
            default: BTB_www <= 1'b0; //startup again
        endcase
    end

    //== That looks nice ==//
    //== Anyways GA(Gather) stage ==//
    logic [31:0] GA_PC, GA_IR; //Each stage gets its own IR and PC
    logic [31:0] GA_early_target;
    logic [13:0] GA_pht_idx;
    logic [1:0]  GA_pht_val;

    logic isGA_valid, isGA_valid_ff;
    logic GA_branch;
    logic GA_predicted_taken;
    logic [31:0] GA_IR_2;
    logic GA_64;

    always_ff @(posedge clk or posedge reset) begin : GA_rst
        if (reset) begin
            isGA_valid_ff <= 0;
            I_took_ff <= 0;
            //Vivado started to complain when I added memFault, but whatever
            //I can just split it into to if blocks
        end else begin
            I_took_ff <= IF_take && !VER_redirect && !VER_fault;
            if (VER_redirect || VER_fault || I_kill) begin
                isGA_valid_ff <= 0;
            end else if (!stall && !bubble) begin
                isGA_valid_ff <= I_mem_rdy && !IF_redir;
            end
        end
    end : GA_rst

    assign I_kill     = I_miss_ff && I_took_ff;
    assign isGA_valid = isGA_valid_ff && !I_kill;

    always_ff @(posedge clk) begin : GA_main
        if (!stall && !bubble) begin
            GA_PC <= IF_PC;
            GA_64 <= IF_64;
            GA_IR_2 <= IF_IR_2;
            GA_branch <= IF_branch;
            GA_IR <= instr_fetch_data;
            GA_early_target <= IF_redirect_target;
            GA_pht_idx <= pht_idx_r;
            GA_pht_val <= pht_out;
            GA_predicted_taken <= IF_predicted_taken;
        end
        //else: stall holds PC and IR as they are
    end : GA_main

    //==Multi-dimensional operations - sounds cool asf
    logic isGA_mdx;
    assign isGA_mdx = GA_64 && (GA_IR[9:4] == 6'b011110 || GA_IR[9:4] == 6'b011101 || GA_IR[9:4] == 6'b011100);

    logic isGA_mdsx;
    assign isGA_mdsx = GA_64 && (GA_IR[9:4] == 6'b011100);

    logic GA_uses_rr2; //LDX, STX, MDLX, MDCX, MDSX
    assign GA_uses_rr2 = GA_64 && (GA_IR[9:4] == 6'b011111 || GA_IR[9:4] == 6'b010000 || isGA_mdx);

    //DSP accepts signed and signed only
    logic signed [24:0] GA_mdx_ri;
    logic signed [13:0] GA_stride;
    logic signed [31:0] GA_imm13;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] GA_mdx_idx;
    /* verilator lint_on UNUSEDSIGNAL */ 
    //ri can be only up to 2^24 signed because its the limitation of one DSP
    //slice which is 18x25bits, unfornutely increasing it to 2 chained slices
    //leads to a critical path. Not a big deal tho im not gonna use arrays
    //past 16MB considering my whole memory is 256MB
    logic  mdx_mem_hit, mdx_wb_hit;
    assign mdx_mem_hit = isVER_valid && VER_gpr_write && !VER_is_load && (VER_gpr_dest[7:3] == GA_IR_2[31:27]) &&
                         (!GA_banked2 || VER_kernelMode == EX_kernel_mode);
    assign mdx_wb_hit  = isWB_valid && WB_gpr_write && (WB_gpr_dest[7:3] == GA_IR_2[31:27]) &&
                         (!GA_banked2 || WB_kernelMode == EX_kernel_mode);

    logic [31:0] mdx_reg;
    assign mdx_reg = (GA_banked2 && EX_kernel_mode) ? (GA_IR_2[27] ? KGPR1 : KGPR0) : GPRs_data_out2;

    //mdx forwarding really a same thing to a regular forwarding
    logic [1:0] mdx_rel;
    always_comb begin
        for (int lane = 0; lane < 4; lane++) begin
            mdx_rel = 2'(lane) - VER_base;
            if (mdx_mem_hit && VER_lanes[lane])     GA_mdx_idx[8*lane +: 8] = VER_result[8*mdx_rel +: 8];
            else if (mdx_wb_hit && WB_lanes[lane])  GA_mdx_idx[8*lane +: 8] = WB_aligned[8*lane +: 8];
            else                                    GA_mdx_idx[8*lane +: 8] = mdx_reg[8*lane +: 8];
        end
    end
    assign GA_mdx_ri  = GA_mdx_idx[24:0];
    assign GA_stride = {GA_IR[20:18], GA_IR[12:10], GA_IR[3:0], GA_IR_2[16:13]};
    assign GA_imm13  = {{19{GA_IR_2[12]}}, GA_IR_2[12:0]};

    //Finishes at the start of EX
    //So thats a cool one: DSP supports fused add multiply and I really love
    //fused add multiply. I remember first learning vfmadd231pd and I was
    //quite faschinated by it. Now I finally implement it myself
    //
    //Uhh there goes my nice looking dsp like I didn't do it myself, first of
    //all DSP48E1 has intermediate Pipilined M register which is A * B, so we
    //save that register at the end of GA and when add C to it at the start of
    //Otherwise its just dsp with a few modifications. Refer to UG479 if you
    //are interested, its pretty interesting ngl glad I got to use information
    //From there bc I initially read it for fun.
    logic [31:0] EX_mdx_product;
    `ifdef SYNTHESIS //for vivado(actual FPGA)
        /* verilator lint_off UNUSEDSIGNAL */
        logic [47:0] mdx_p;
        /* verilator lint_on UNUSEDSIGNAL */
        DSP48E1 #(
            .AREG(0), .ACASCREG(0), .BREG(0), .BCASCREG(0), .CREG(1), .DREG(0), .ADREG(0),
            .MREG(1), .PREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0),
            .INMODEREG(0), .OPMODEREG(0), .USE_MULT("MULTIPLY"), .USE_DPORT("FALSE")
        ) mdx_dsp (
            .CLK(clk),
            .A({{5{GA_mdx_ri[24]}}, GA_mdx_ri}),
            .B({{4{GA_stride[13]}}, GA_stride}),
            .C({{16{GA_imm13[31]}}, GA_imm13}),
            .D(25'd0),
            .OPMODE(7'b0110101), //P(result) = M + C
            .ALUMODE(4'b0000), .INMODE(5'b00000), .CARRYINSEL(3'b000), .CARRYIN(1'b0),
            .CEM(!stall), .CEC(!stall),
            .CEA1(1'b0), .CEA2(1'b0), .CEB1(1'b0), .CEB2(1'b0), .CED(1'b0), .CEAD(1'b0), .CEP(1'b0),
            .CEALUMODE(1'b0), .CECTRL(1'b0), .CECARRYIN(1'b0), .CEINMODE(1'b0),
            .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0), .RSTM(1'b0), .RSTP(1'b0),
            .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTCTRL(1'b0), .RSTINMODE(1'b0),
            .ACIN(30'd0), .BCIN(18'd0), .PCIN(48'd0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
            .P(mdx_p),
            .ACOUT(), .BCOUT(), .PCOUT(), .CARRYOUT(), .CARRYCASCOUT(), .MULTSIGNOUT(),
            .OVERFLOW(), .UNDERFLOW(), .PATTERNDETECT(), .PATTERNBDETECT()
        );
        assign EX_mdx_product = mdx_p[31:0];
    `else // for verilator
        logic [31:0] EX_mdx_mul, EX_imm13;
        always_ff @(posedge clk) begin
            if (!stall) begin
                EX_mdx_mul <= 32'(GA_mdx_ri * GA_stride);
                EX_imm13   <= GA_imm13;
            end
        end
        assign EX_mdx_product = EX_mdx_mul + EX_imm13;
    `endif

    //We need to compare those registers to EX's ones it case they
    //overlap - stall
    //So the regfile read is moved to the GA, saves up on critical path and GA
    //is almost empty anyways so I might as well fill it as much as possible
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0]  GA_rx0, GA_rx1; //Selector last 3bits are unused
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] GA_rx0_val, GA_rx1_val, GA_rx2_val;

    assign GA_rx0 = GA_IR[25:18];
    assign GA_rx1 = GA_IR[17:10];
    //No rx2 I just use GA_IR_2[something:something]

    logic GA_wb_hit0, GA_wb_hit1, GA_wb_hit2;
    logic GA_banked0, GA_banked1, GA_banked2;
    assign GA_banked0 = (GA_rx0[7:3] <= 5'd1);
    assign GA_banked1 = (GA_rx1[7:3] <= 5'd1);
    assign GA_banked2 = (GA_IR_2[31:27] <= 5'd1);

    //Basically MDXs shifter register overlap with LDX/STX rxi so they share
    //1 index operand, and we can kinda abuse that
    logic [4:0]  GA_rxi_base;
    logic        GA_rxi_banked;
    logic [31:0] GA_rxi_val;
    assign GA_rxi_base   = isGA_mdx ? GA_rx0[7:3] : GA_IR_2[31:27];
    assign GA_rxi_banked = isGA_mdx ? GA_banked0  : GA_banked2;
    assign GA_rxi_val    = isGA_mdx ? GA_rx0_val  : GA_rx2_val;

    //== FWD(Forwarding) ==//
    //I moved forwarding into GA only now??

    //So its a pretty interesting one, if instruction needs result(EX) that hasn't
    //been written to GPRs yet(end of WB), instead of stalling I check for this
    //condition, if its true I just use VER/WB result, otherwise read from registers

    //The problem is sub registers: a selector is {base_id[4:0], offset[2:0]} and the
    //offset picks which slice of the 32bit register you actually touch:
    //000 - rx, 001 - ry0, 010 - ry1, 011 - rz0, 100 - rz1, 101 - rz2, 110 - rz3
    //Two selectors that differ only in the offset still name the exact same physical
    //register, so comparing the whole 8bit selector breaks everything.
    //The fix is only match using base_id and apply offset only at the end
    logic [7:0] GA_pick0, GA_pick1, GA_pick2;
    logic [3:0] GA_keep0, GA_keep1, GA_keep2;
    assign GA_pick0 = slice_pick(isGA_mdx ? 3'b000 : GA_rx0[2:0]); //Which fragment value does instruction use
    assign GA_pick1 = slice_pick(GA_uses_rr2 ? 3'b000 : GA_rx1[2:0]);
    assign GA_pick2 = slice_pick(isGA_mdx ? 3'b000 : GA_IR_2[26:24]);
    assign GA_keep0 = slice_keep(isGA_mdx ? 3'b000 : GA_rx0[2:0]); //Which output fragment value exists at all
    assign GA_keep1 = (GA_uses_rr2 && GA_rx1[7:3] == 5'd31) ? 4'b0000 : slice_keep(GA_uses_rr2 ? 3'b000 : GA_rx1[2:0]);
    assign GA_keep2 = slice_keep(isGA_mdx ? 3'b000 : GA_IR_2[26:24]);

    logic  mem_go0, mem_go1, mem_go2, wb_go0, wb_go1, wb_go2; //Will the instrction that would be in VER on next cycle write to pick?
    assign mem_go0 = isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == GA_rx0[7:3]) && (!GA_banked0 || isKernelMode == EX_kernel_mode);
    assign mem_go1 = isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == GA_rx1[7:3]) && (!GA_banked1 || isKernelMode == EX_kernel_mode);
    assign mem_go2 = isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == GA_rxi_base) && (!GA_rxi_banked || isKernelMode == EX_kernel_mode);
    assign wb_go0  = isVER_valid && VER_gpr_write && (VER_gpr_dest[7:3] == GA_rx0[7:3]) && (!GA_banked0 || VER_kernelMode == kernel_mode_go);
    assign wb_go1  = isVER_valid && VER_gpr_write && (VER_gpr_dest[7:3] == GA_rx1[7:3]) && (!GA_banked1 || VER_kernelMode == kernel_mode_go);
    assign wb_go2  = isVER_valid && VER_gpr_write && (VER_gpr_dest[7:3] == GA_rxi_base) && (!GA_rxi_banked || VER_kernelMode == kernel_mode_go);

    logic [3:0] GA_from_mem0, GA_from_mem1, GA_from_mem2, GA_wsel0, GA_wsel1, GA_wsel2;
    logic [7:0] GA_mem_byte0, GA_mem_byte1, GA_mem_byte2;
    always_comb begin //Final select based on allat data, whether they actually collide or not
        for (int b = 0; b < 4; b++) begin
            GA_from_mem0[b] = GA_keep0[b] && mem_go0 && EX_lanes[GA_pick0[2*b +: 2]];
            GA_from_mem1[b] = GA_keep1[b] && mem_go1 && EX_lanes[GA_pick1[2*b +: 2]];
            GA_from_mem2[b] = GA_keep2[b] && mem_go2 && EX_lanes[GA_pick2[2*b +: 2]];
            GA_wsel0[b] = GA_keep0[b] && wb_go0  && VER_lanes[GA_pick0[2*b +: 2]];
            GA_wsel1[b] = GA_keep1[b] && wb_go1  && VER_lanes[GA_pick1[2*b +: 2]];
            GA_wsel2[b] = GA_keep2[b] && wb_go2  && VER_lanes[GA_pick2[2*b +: 2]];
            GA_mem_byte0[2*b +: 2] = GA_pick0[2*b +: 2] - EX_base;
            GA_mem_byte1[2*b +: 2] = GA_pick1[2*b +: 2] - EX_base;
            GA_mem_byte2[2*b +: 2] = GA_pick2[2*b +: 2] - EX_base;
        end
    end

    //WB arm and the register pick are done here now, the value that would sit in
    //WB_aligned next cycle is VER_aligned right now, so EX only keeps the VER arm
    logic [31:0] VER_aligned;
    assign VER_aligned = fwd_align(VER_gpr_dest[2:0], VER_val);

    logic [31:0] GA_raw0, GA_raw1, GA_raw2, GA_opnd0, GA_opnd1, GA_opnd2;
    assign GA_raw0 = (GA_banked0 && kernel_mode_go) ? (GA_rx0[3]   ? KGPR1_next : KGPR0_next) : GA_rx0_val;
    assign GA_raw1 = (GA_banked1 && kernel_mode_go) ? (GA_rx1[3]   ? KGPR1_next : KGPR0_next) : GA_rx1_val;
    assign GA_raw2 = (GA_rxi_banked && kernel_mode_go) ? (GA_rxi_base[0] ? KGPR1_next : KGPR0_next) : GA_rxi_val;

    always_comb begin
        for (int b = 0; b < 4; b++) begin
            if (GA_wsel0[b])       GA_opnd0[8*b +: 8] = VER_aligned[8*GA_pick0[2*b +: 2] +: 8];
            else if (GA_keep0[b])  GA_opnd0[8*b +: 8] = GA_raw0[8*GA_pick0[2*b +: 2] +: 8];
            else                   GA_opnd0[8*b +: 8] = 8'h0;

            if (GA_wsel1[b])       GA_opnd1[8*b +: 8] = VER_aligned[8*GA_pick1[2*b +: 2] +: 8];
            else if (GA_keep1[b])  GA_opnd1[8*b +: 8] = GA_raw1[8*GA_pick1[2*b +: 2] +: 8];
            else                   GA_opnd1[8*b +: 8] = 8'h0;

            if (GA_wsel2[b])       GA_opnd2[8*b +: 8] = VER_aligned[8*GA_pick2[2*b +: 2] +: 8];
            else if (GA_keep2[b])  GA_opnd2[8*b +: 8] = GA_raw2[8*GA_pick2[2*b +: 2] +: 8];
            else                   GA_opnd2[8*b +: 8] = 8'h0;
        end
    end

    //Individdual bytes can only come out of VER_result bytes
    function automatic [1:0] fwd_code(input [1:0] lane, input [1:0] rel);
        unique case ({lane, rel})
            4'b11_11, 4'b10_10, 4'b01_01: fwd_code = 2'd1;
            4'b11_01, 4'b10_00, 4'b01_11: fwd_code = 2'd2;
            4'b11_00, 4'b01_00:           fwd_code = 2'd3;
            default:                      fwd_code = 2'd0;
        endcase
    endfunction

    logic [7:2] GA_fwd_src0, GA_fwd_src1, GA_fwd_src2;
    always_comb begin
        for (int b = 1; b < 4; b++) begin
            GA_fwd_src0[2*b +: 2] = GA_from_mem0[b] ? fwd_code(2'(b), GA_mem_byte0[2*b +: 2]) : 2'd0;
            GA_fwd_src1[2*b +: 2] = GA_from_mem1[b] ? fwd_code(2'(b), GA_mem_byte1[2*b +: 2]) : 2'd0;
            GA_fwd_src2[2*b +: 2] = GA_from_mem2[b] ? fwd_code(2'(b), GA_mem_byte2[2*b +: 2]) : 2'd0;
        end
    end

    logic GA_is3reg;
    assign GA_is3reg = (GA_IR[31:26] == 6'b000001 || GA_IR[31:26] == 6'b000011 || GA_IR[31:26] == 6'b000111 ||
                        GA_IR[31:26] == 6'b000101 || GA_IR[31:26] == 6'b001001 || GA_IR[31:26] == 6'b001011);

    logic [31:0] GA_rx1_imm;
    always_comb begin
        if (GA_is3reg) begin
            unique case (GA_IR[1:0])
                2'b00: GA_rx1_imm = 32'd0;
                2'b01: GA_rx1_imm = 32'd1;
                2'b10: GA_rx1_imm = 32'd2;
                2'b11: GA_rx1_imm = -32'sd1;
            endcase
        end
        else if (GA_IR[31:30] == 2'b10) GA_rx1_imm = {{22{GA_IR[9]}}, GA_IR[9:0]};
        else                            GA_rx1_imm = {22'h0, GA_IR[9:0]};
    end

    //SPR bypassing into GA as well
    logic [1:0] GA_spr_sel;
    logic       GA_spr_hit;
    assign GA_spr_sel =
            (GA_IR[31:26] == 6'b101000 || GA_IR[31:26] == 6'b101001 || GA_IR[31:26] == 6'b101010 ||
            GA_IR[31:26] == 6'b101011 || GA_IR[31:26] == 6'b101100 || GA_IR[31:26] == 6'b101101) ? GA_IR[17:16] : 2'b00;
    assign GA_spr_hit = ((GA_spr_sel == 2'b00) && SPRWrite && (spr_target_sel == 2'b00) && (isKernelMode == EX_kernel_mode)) ||
                        ((GA_spr_sel == 2'b01) && ((isCallState && opcode == 6'b111000) || (SPRWrite && spr_target_sel == 2'b01))) ||
                        ((GA_spr_sel == 2'b10) && SPRWrite && (spr_target_sel == 2'b10) && (isKernelMode == EX_kernel_mode));

    //Ladies and gentlemen we are currentely wintessing a crime scene: EX steams GA's rr2!!!
    //In reality though: MDSX needs to read 4 registers and I don't feel like
    //adding 4th LUTRAM read port bc its gonna copy LUTRAM which i just don't
    //want to do. And because address only arrives at EX we can freely just
    //steal this read from GA.
    logic [4:0] rr2_sel;
    assign rr2_sel = (isEX_valid && isEX_mdsx) ? EX_IR_2[26:22] : GA_IR_2[31:27];

    //Not freely tho, if next instruction needs 3 read ports we gotta bubble.
    logic mdx_idx_hazard;
    assign mdx_idx_hazard = isGA_valid && isGA_mdx &&
                            ((isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == GA_IR_2[31:27])) ||
                             (isVER_valid && VER_gpr_write && (VER_is_load || VER_is_lomul || VER_is_himul) && (VER_gpr_dest[7:3] == GA_IR_2[31:27])) ||
                             (isWB_valid && WB_gpr_write && (WB_is_lomul || WB_is_himul) && (WB_gpr_dest[7:3] == GA_IR_2[31:27])));

    logic rr2_conflict;
    assign rr2_conflict = isEX_valid && isEX_mdsx && isGA_valid && GA_uses_rr2;

    //For later when memory would take actual clock cycles to reach
    //Well its later now
    //The load use-hazard creates a 1 cycle bubble if GA_uses_EX_dest in VER
    //when dest hasn't been written and gets read. Now I used a forwarding up
    //until that point, but that wouldn't work now because if we forward from
    //the middle of the cycle, like with the mem read, it adds this half
    //a cycle to a critical path. So to avoid it just add this 1cycle bubble.
    //This would increase the CPI, but by a small amount, there is no way to
    //avoid it though, at least as far as im aware.
    logic  EX_is_load;
    assign EX_is_load = isEX_valid && (GPRsSrc == 3'b001);

    logic  load_use_hazard;
    //MDSX will bubble if prev instruction was load into used register so not
    //a big deal
    assign load_use_hazard = isGA_valid && EX_is_load && (GA_uses_EX_dest || (isGA_mdsx && (gpr_rw0_sel[7:3] == GA_IR_2[26:22])));

    //the CPU will get mul result only at the end of VER, hence it introduces
    //mul-use hazard, if next instruction uses mul and we don't have the
    //result yet, we have to bubble, same as load use
    logic  EX_is_mul, VER_is_mul;
    assign EX_is_mul  = isEX_valid && (opcode == 6'b000111 || opcode == 6'b001101);
    assign VER_is_mul = isVER_valid && (VER_is_lomul || VER_is_himul);

    //Alright I wrote this all for nothing bc the fix is literally just gate
    //it by GA_64 ill leave it here anyways bc why not.
    //Note: Sometimes by next instruction I mean next 2 instructions
    //Checking if either EX and VER use the same registers as mul used
    //So I don't check for GPRsWrite is usual because that means it would have
    //to wait for this whole mem safety thing, which im gonna move to the VER soon,
    //And hence keeps critical path short. However that does introduce
    //a problem, since I unconditionally check for GA_IR_2[31:27], if first
    //5 bits of opcode of next insruction perfectly align with the exact base
    //register used bits it would lead to uneccessery bubble. Now unfornutely
    //Its not as uncommon as it might seem, actually is is pretty damn uncommon:
    //Most commonely used registers are rx29-rx24 which all start with 11, and
    //since there is handful of 11' instruction it should appear as often. Btw
    //it isn't possible with rx30 and rx31 because they are almost never a mul
    //dest. This also would almost never fire if next instruction is 64bit
    //unless it is branch and we used any of rx24 registers, it would fire in that case yeah.
    //It might also fire if we mul to any rx22 and next instruction is SPRSUB
    //or SPRLEA. And yeah afterall its not like it breaks anything it might
    //just increase overall CPI by 0.025 which is a random estimate I just came
    //up with.
    logic  GA_uses_EX_dest, GA_uses_VER_dest;
    assign GA_uses_EX_dest  = (gpr_rw0_sel[7:3]  == GA_rx0[7:3]) || (gpr_rw0_sel[7:3]  == GA_rx1[7:3]) || (GA_64 && (gpr_rw0_sel[7:3]  == GA_IR_2[31:27]));
    assign GA_uses_VER_dest = (VER_gpr_dest[7:3] == GA_rx0[7:3]) || (VER_gpr_dest[7:3] == GA_rx1[7:3]) || (GA_64 && (VER_gpr_dest[7:3] == GA_IR_2[31:27]));

    logic  mul_use_hazard;
    assign mul_use_hazard = isGA_valid && ((EX_is_mul && GA_uses_EX_dest) || (VER_is_mul && GA_uses_VER_dest) ||
                                           (EX_is_mul && isGA_mdsx && (gpr_rw0_sel[7:3] == GA_IR_2[26:22])));


    //== EX(Execute) ==//
    //A lot of things happen here, full enum in CU.sv
    logic [31:0] EX_PC, EX_IR;
    logic [31:0] EX_IR_2;
    logic [31:0] EX_early_target;
    logic [13:0] EX_pht_idx;
    logic [1:0]  EX_pht_val;
    logic [31:0] EX_rx0_val, EX_rx1_val, EX_rx2_val;
    logic       EX_from_mem0, EX_from_mem1, EX_from_mem2;
    logic [1:0] EX_mem_byte0, EX_mem_byte1, EX_mem_byte2;
    logic [7:2] EX_fwd_src0, EX_fwd_src1, EX_fwd_src2;
    logic       EX_spr_hit;
    logic isEX_mdx, isEX_mdsx;
    logic EX_predicted_taken;
    logic isEX_valid;
    logic EX_branch;
    logic EX_64;
    logic [3:0] EX_lanes;
    logic [1:0] EX_base, EX_idx_sh;
    logic [31:0] EX_rx1_imm;

    //Alright so there was a big always_ff block here previousely, which
    //apparantely led to high fanout, so just splitting it into 2 always_ff
    //Should do the trick
    always_ff @(posedge clk or posedge reset) begin : EX_rst
        if (reset) begin
            isEX_valid <= 0;
        end else if (VER_redirect || bubble || VER_fault) begin
            isEX_valid <= 0;
        end else if (!stall) begin
            isEX_valid <= isGA_valid;
        end
    end : EX_rst

    always_ff @(posedge clk) begin : EX_main
        if (!stall) begin
            EX_PC <= GA_PC; //Handing instruction to the EX
            EX_IR <= GA_IR;
            EX_64 <= GA_64;
            EX_IR_2 <= GA_IR_2;
            EX_rx0_val <= GA_opnd0;
            EX_rx1_val <= GA_opnd1;
            EX_rx2_val <= GA_opnd2;
            EX_idx_sh  <= isGA_mdx ? GA_IR_2[18:17] : GA_IR_2[23:22];
            EX_rx1_imm <= GA_rx1_imm;
            EX_branch <= GA_branch;
            EX_early_target <= GA_early_target;
            EX_pht_idx <= GA_pht_idx;
            EX_pht_val <= GA_pht_val;
            EX_predicted_taken <= GA_predicted_taken;

            //Forwarding entirely in GA now yayyy
            EX_from_mem0 <= GA_from_mem0[0];
            EX_from_mem1 <= GA_from_mem1[0];
            EX_from_mem2 <= GA_from_mem2[0];
            EX_mem_byte0 <= GA_mem_byte0[1:0];
            EX_mem_byte1 <= GA_mem_byte1[1:0];
            EX_mem_byte2 <= GA_mem_byte2[1:0];
            EX_fwd_src0   <= GA_fwd_src0;
            EX_fwd_src1   <= GA_fwd_src1;
            EX_fwd_src2   <= GA_fwd_src2;
            EX_spr_hit <= GA_spr_hit;

            isEX_mdx <= isGA_mdx;
            isEX_mdsx <= isGA_mdsx;
        end
    end : EX_main

    //====//
    logic [5:0] opcode;
    logic [5:0] op_64;
    logic [4:0] branch_op; //32 possible branches
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] rx0, rx1, rx2, rxi; //rxi for LDX/STX, a lot of special stuff for it, But I love them nontheless(for that reason too)
    /* verilator lint_on UNUSEDSIGNAL */

    assign opcode = EX_IR[31:26];
    assign rx0 = EX_IR[25:18];
    assign rx1 = EX_IR[17:10];
    assign rx2 = EX_IR[9:2];
    assign rxi = EX_IR_2[31:24];
    assign op_64 = EX_IR[9:4];
    assign branch_op = EX_IR[9:5];


    logic [31:0] sign_ext_imm18;
    assign sign_ext_imm18 = { {14{EX_IR[17]}}, EX_IR[17:0] };


    logic [31:0] sign_ext_imm16;
    assign sign_ext_imm16 = { {16{EX_IR[15]}}, EX_IR[15:0] };


    //Is it useless? Absolutely not, imagine it for "for" loops
    logic [31:0] sign_ext_imm2;

    always_comb begin
        unique case (EX_IR[1:0])
            2'b00: sign_ext_imm2 = 32'd0;
            2'b01: sign_ext_imm2 = 32'd1;
            2'b10: sign_ext_imm2 = 32'd2; //Here is a crazy idea for ya 0b10 signed is 2
            2'b11: sign_ext_imm2 = -32'sd1;
        endcase
    end


    logic  is_imm2_op;
    assign is_imm2_op = (opcode == 6'b000001 || opcode == 6'b000011 || opcode == 6'b000111 ||
                         opcode == 6'b000101 || opcode == 6'b001001 || opcode == 6'b001011);

    logic [31:0] alu_imm2;
    assign alu_imm2 = is_imm2_op ? sign_ext_imm2 : 32'd0;

    //Just diveded into several concurrent muxes instead of one bit ALU mux
    //lets see. Hell yeah it did 9.848ns bitch
    logic [2:0] alu_sel;
    always_comb begin
        unique case (opcode)
            6'b000001: alu_sel = 3'b000; // ADD
            6'b000011: alu_sel = 3'b100; //SUB
            6'b001000, 6'b001100, 6'b001010: alu_sel = 3'b010; // SHL/SHR/SRA
            6'b000101, 6'b001011, 6'b001001: alu_sel = 3'b011; // DIV/MOD/SDIV
            default:                         alu_sel = 3'b001; // bitwise + MOV
        endcase
    end

    logic [2:0] result_sel;
    always_comb begin
        unique case (GPRsSrc)
            3'b011:  result_sel = 3'b011; // LOAD
            3'b101:  result_sel = isEX_mdx ? 3'b101 : 3'b110; // MDCX : SPRLEA
            3'b110:  result_sel = 3'b011; // LMA
            3'b111:  result_sel = 3'b011; // RNG
            default: result_sel = alu_sel;
        endcase
    end

    //One rx1 + imm adder for everyone
    logic [31:0] mul_y_in, rx1_plus_imm;
    assign rx1_plus_imm = FWD_rx1 + EX_rx1_imm;
    assign mul_y_in = rx1_plus_imm;

    logic[31:0] LDX_base, LDX_idx, LDX_imm29; //Just enough to cover all 256MB signed

    assign LDX_base = FWD_rx1; //Theoretically it is base +- imm29, but usually base is 0 so rx31
    //I don't even know why Im making it that way because in case RAM would
    //become more than 256MB basically whole architecture would be cooked, but whatever. Oh wait I remembered - its for accesses 
    //That are unknown at the compile-time, literally thought of that like 4 hours ago
    assign LDX_idx = FWD_rxi << EX_idx_sh;
    assign LDX_imm29 = {{3{EX_IR[12]}}, EX_IR[12:10], EX_IR[3:0], EX_IR_2[21:0]};

    //Same this as IF_PC_plus4_or8
    logic [31:0] EX_PC_next;
    assign EX_PC_next = EX_PC + {28'd0, (EX_64 || EX_branch), !(EX_64 || EX_branch), 2'b00};

    //This is forwarding too, EX needs to know the new mode immediately after
    //VER made the change, becase kernel mode now changes in VER
    //In always_ff bc its a flop
    logic  EX_kernel_mode, kernel_mode_next;
    assign kernel_mode_next = (!mem_stall && isEX_valid && !stall && !VER_fault && !VER_redirect) ? isKernelMode : (VER_fault || EX_kernel_mode);

    logic  kernel_mode_go;
    //Kernel mode when nohgin stalls, faults or redirectrs, which is known earlier
    assign kernel_mode_go = isEX_valid ? isKernelMode : EX_kernel_mode;


    always_ff @(posedge clk or posedge reset) begin
        if (reset) EX_kernel_mode <= 0;
        else EX_kernel_mode <= kernel_mode_next;
    end


    logic [4:0] shift_amount;
    assign shift_amount = FWD_rx1[4:0] + EX_IR[4:0];

    logic key_interrupt_taken;
    logic timer_interrupt_taken;


    //== RNG ==//
    //literally a random number generator. I am using the xoshiro128**
    //algorithm, it runs every cycle and it dgaf about anything - stall,
    //memfault, interrupt, trap like whatever happens it just doesn't care and
    //exectes xoshiro128**. I did this to increase unpredictability further.
    //Now the interesting part is seeding on init - more on that later tho.
    //It takes 1 cycle to execute - just a really fast neat instruction

    logic [31:0] s [3:0]; //state idk why crygrophers use variable name that go against all conventions but i kinda like it
    logic [31:0] s_comb [3:0];
    logic [31:0] t, t1, t2; //temp
    logic [31:0] rng_result, rng_result_comb;

    initial begin //Very scientific numbers
        s[0] = 32'h923423;
        s[1] = 32'h23408;
        s[2] = 32'h23572395;
        s[3] = 32'h2357329;
    end

    always_comb begin : xoshiro128
        t1 = (s[1] << 2) + s[1];  //Thats just multiplication by 5
        t2 = (t1 << 7) | (t1 >> 25); //32-7

        rng_result_comb = (t2 << 3) + t2; //And this is by 9

        t = s[1] << 9;

        s_comb[2] = s[2] ^ s[0];
        s_comb[3] = s[3] ^ s[1];
        s_comb[1] = s[1] ^ s_comb[2];
        s_comb[0] = s[0] ^ s_comb[3];
        s_comb[2] = s_comb[2] ^ t;
        s_comb[3] = (s_comb[3] << 11) | (s_comb[3] >> 21); //32 - 9

    end : xoshiro128

    always_ff @(posedge clk) begin //Again - no reset
        rng_result <= rng_result_comb;

        s[0] <= (s_comb[0] ^ inject_rng) | {31'b0, finish_seed}; //Ensures it can't be zero
        s[1] <= s_comb[1];
        s[2] <= s_comb[2];
        s[3] <= s_comb[3];
    end

    //== Seeding
    //This is the seeding i mentioned: we are gonna seed initial value using XADC which is a special module on
    //Artix-7 FPGAs that monitors a lot of stuff like FPGA temprerature, voltages, I/Os and other stuff its
    //Pretty cool. The thing I care about is voltages - the thing is even though voltage is 1V at all times
    //Its not exactly 1V it always flactuate at list a little bit, and those flactuations are fairy random.
    //XADC's internal ADC converts those voltages into 12bit digital signal,
    //and according my to assumptions at least 4 LSBs should flactuate randomly.
    //So I am going to sample 4LSBs of  V_CCINT(main), V_CCAUX(secondary) and V_CCBRAM(bram)
    //Now the thing is XADC is
    //slow asf so its gonna take about 200us which normaly is horrendous but
    //since it is 1 time operation on boot it doesn't matter.
    //PS: I was considering adding temp sensor but I don't trust it - in 200us
    //seed is gonna run temp sensor wouldn't even update, there is suppose to
    //be some garbage nontheless due to ADC's stuff but nah I don't really trust it.

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] xadc_do; //Only 4bits are used
    /* verilator lint_on UNUSEDSIGNAL */
    logic [6:0]  xadc_addr;
    logic        xadc_den, xadc_drdy, xadc_eos, seed_grab, finish_seed;
    logic [31:0] inject_rng;
    logic [6:0]  inject_counter;

    typedef enum logic [1:0] {
        WAIT,
        IDLE,
        SMPL,
        DONE
    } seed_states;

    seed_states rng_state;

    //Inject zero extended 4bits that are read from XADC. This works because
    //xoshiro128** would just shuffle those 4bits around while fsm waits for
    //another xadc_rdy.
    assign inject_rng = seed_grab ? {28'b0, xadc_do[7:4]} : 32'd0;
    assign seed_grab = (rng_state == WAIT) && xadc_drdy;
    assign finish_seed = seed_grab && (inject_counter == 127);

    always_ff @(posedge clk or posedge reset) begin : XADC_FSM
        if (reset) begin
            rng_state <= IDLE;
            xadc_addr <= 7'b01; //Would actually read 7'h02 on first time
            //But honest the more chaos in this the better entropy is
            inject_counter <= 0;
            xadc_den <= 0;
        end else begin
            xadc_den <= 0; //So it stays high only for 1 cycle
            unique case (rng_state)
                IDLE: begin
                    if (xadc_eos) //finally can read
                        rng_state <= SMPL;
                    else
                        rng_state <= IDLE;
                end
                SMPL: begin
                    if (xadc_addr == 7'h06)
                        xadc_addr <= 7'h01;
                    else if (xadc_addr == 7'h02)
                        xadc_addr <= 7'h06;
                    else //xadc_addr == 7'h01
                        xadc_addr <= 7'h02;

                    xadc_den <= 1; //data enable
                    rng_state <= WAIT;
                end
                WAIT: begin
                    if (xadc_drdy) begin
                        if (xadc_addr == 7'h06)
                            rng_state <= IDLE;
                        else
                            rng_state <= SMPL;
                    end
                end
                DONE: begin
                    //Stuck here forever
                end
            endcase
            if (seed_grab) begin
                if (finish_seed) //inject 128 times for the full 128bit inject
                    rng_state <= DONE;
                else
                    inject_counter <= inject_counter + 1;
            end
        end
    end : XADC_FSM

    //This is the call to XADC there isn't actually anything phenomenal here
    //Similar to regular files includes
    /* verilator lint_off PINCONNECTEMPTY */
    XADC #(
        .INIT_40(16'h0000), //default mode is fine
        .INIT_41(16'h2000), //No averaging thus higher entropy
        .INIT_42(16'h0800),
        .INIT_48(16'h4600)
    ) xadc_rng (
        .DCLK(clk),
        .RESET(reset),
        .DADDR(xadc_addr), //Read specified register
        .DEN(xadc_den),
        .DWE(1'b0),
        .DI(16'h0),
        .DO(xadc_do), //Data Out(actually its not just a nice way to remember)
        .DRDY(xadc_drdy),
        .EOS(xadc_eos),
        //Some bs we don't care about
        .VP(1'b0), .VN(1'b0), .VAUXP(16'h0), .VAUXN(16'h0),
        .CONVST(1'b0), .CONVSTCLK(1'b0),
        .EOC(), .BUSY(), .CHANNEL(), .OT(), .ALM(), .MUXADDR(),
        .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    //== VER(Verify) ==//
    //Work with memory - load, store
    logic [31:0] VER_result;
    logic [31:0] VER_PC;
    logic [31:0] VER_memTarget;
    logic VER_memRead, VER_memWrite;
    logic [31:0] VER_ram_data_in;
    logic [1:0]  VER_mem_size;

    logic [7:0]  VER_gpr_dest;
    logic        VER_gpr_write;
    logic        VER_kernelMode;
    logic        isVER_valid, isVER_valid_ff, isWB_valid, isWB_valid_ff, D_miss_ff;

    logic        VER_EPCWrite;
    logic        VER_irq;
    logic [31:0] VER_PCNext;

    logic VER_is_lomul, VER_is_himul;
    logic VER_is_load, VER_ram_cs, VER_io_cs, VER_vram_cs;

    logic VER_zeroDiv;

    //I moved the decision on whether branch is taken or not to VER in order
    //to decrease critical path. This would increase the CPI but from my
    //testings not that much, at most + 0.03CPI which is the price im willing
    //to pay.
    //Even more VER FFs... shouldn't matter though bc im using only like 2k
    //out of 150k or so
    logic        VER_demolish, VER_branch, VER_predicted_taken;
    logic [31:0] VER_redirect_pc, VER_early_target;
    logic [4:0]  VER_branch_op;
    logic [31:0] VER_branch_x, VER_branch_y, VER_branch_xs, VER_branch_ys, VER_branch_mask;
    logic [13:0] VER_pht_idx;
    logic [1:0]  VER_pht_val;

    //Moving SPRs stuff into VER
    logic VER_SPRWrite;
    logic [31:0] VER_rx0_val, VER_activeSP;
    logic [31:0] VER_spr_result;
    logic [2:0]  VER_SPRSrc;
    logic [1:0]  VER_spr_target_sel;
    logic VER_is_call;

    logic VER_irq_timer;
    logic VER_irq_key;

    always_ff @(posedge clk or posedge reset) begin : VER_rst
        if (reset) begin
            isVER_valid_ff <= 0;
        end else if (!mem_stall) begin
            isVER_valid_ff <= isEX_valid & !stall & !VER_fault & !VER_redirect;
        end
    end : VER_rst

    //So I treat cache miss kinda like branch mispredict, by default CPU
    //assumes cache hits, but if it doesn't, which is indicated by D_miss_ff,
    //It immediately kills WB and VER instruction. That way there wouldn't be
    //a massive miss path with fanout and other nasty stuff.
    //You might think.
    assign isVER_valid = isVER_valid_ff && !D_miss_ff;
    assign isWB_valid  = isWB_valid_ff  && !D_miss_ff;
    //That it costs 5cycle, but yeah it does. But it doesn't matter bc refill
    //takes 20+ cycle and they happen simoultaniosely so its fine.

    always_ff @(posedge clk) begin : VER_main
        if (!mem_stall) begin
            //That many variables are actually harmless, because they live in
            //FFs which are free, there are a lot of unused FFs in logic slices.
            VER_result      <= GPRs_data_in;
            VER_PC          <= EX_PC;

            VER_memTarget   <= memTarget;
            VER_memRead     <= memRead;
            VER_memWrite    <= memWrite;
            VER_ram_data_in <= store_val;
            VER_mem_size  <= mem_size;

            VER_EPCWrite    <= EPCWrite;
            VER_irq         <= irq_taken;
            VER_PCNext      <= EX_PC_next;

            VER_gpr_write   <= GPRsWrite;
            VER_gpr_dest    <= gpr_rw0_sel;
            VER_kernelMode  <= EX_kernel_mode;
            VER_is_lomul    <= (opcode == 6'b000111);
            VER_is_himul    <= (opcode == 6'b001101);
            VER_zeroDiv     <= ZeroDivException && !irq_taken;

            VER_demolish        <= demolish;
            VER_redirect_pc     <= PCNext;
            VER_branch          <= EX_branch;
            VER_predicted_taken <= EX_predicted_taken;
            VER_early_target    <= EX_early_target;
            VER_branch_op       <= branch_op;
            VER_branch_x        <= branch_x;
            VER_branch_y        <= branch_y;
            VER_branch_xs       <= branch_xs;
            VER_branch_ys       <= branch_ys;
            VER_branch_mask     <= branch_mask;
            VER_pht_idx         <= EX_pht_idx;
            VER_pht_val         <= EX_pht_val;

            VER_is_load     <= (GPRsSrc == 3'b001);

            VER_SPRWrite    <= SPRWrite;
            VER_SPRSrc      <= SPRSrc;
            VER_spr_target_sel <= spr_target_sel;
            //Active is kinda a weird word, looks kinda strange
            VER_rx0_val     <= FWD_rx0;
            VER_spr_result  <= spr_result;
            VER_is_call     <= isCallState && (opcode ==6'b111000); //CALL

            VER_irq_timer <= timer_interrupt_taken;
            VER_irq_key   <= key_interrupt_taken;

            VER_lanes     <= EX_lanes;
            VER_base      <= EX_base;
        end
    end : VER_main

    logic [31:0] VER_vram_addr;
    assign VER_vram_addr = {12'b0, VER_memTarget[19:0]};

    //Moving the memFault from CU to here, because CU runs only in EX and
    //since im moving mem stuff into VER this is the only way
    logic  memFault;
    assign memFault = isVER_valid && (VER_memRead || VER_memWrite) && memViolation;

    logic  divFault, VER_fault; //zeroDiv and memFault can never fire on the same cycle
    assign divFault = isVER_valid && VER_zeroDiv;
    assign VER_fault = memFault || divFault;

    //MMIO cs but basically in VER
    logic  VER_mmio_cs;
    assign VER_mmio_cs = (VER_memTarget[31:8] == 24'hFFFFFF);
    assign VER_io_cs   = (VER_memTarget[31:8] == 24'h101000);

    //Well well well its that time when D_mem_rdy is finally alive
    logic  D_mem_rdy;
    logic  mem_stall;

    logic  mdsx_banked;
    assign mdsx_banked = (EX_IR_2[26:23] == 4'b0000);

    logic  mdsx_mem_hit, mdsx_kwb_hit;
    assign mdsx_mem_hit = isVER_valid && VER_gpr_write && (VER_gpr_dest[7:3] == EX_IR_2[26:22]) &&
                          (!mdsx_banked || VER_kernelMode == EX_kernel_mode);
    assign mdsx_kwb_hit = isWB_valid && WB_gpr_write && mdsx_banked && WB_kernelMode && EX_kernel_mode &&
                          (WB_gpr_dest[7:3] == EX_IR_2[26:22]);

    logic  [31:0] mdsx_reg;
    assign mdsx_reg = (mdsx_banked && EX_kernel_mode) ? (EX_IR_2[22] ? KGPR1 : KGPR0) : GA_rx2_val;

    logic [31:0] mdsx_full;
    logic [1:0]  mdsx_rel;
    always_comb begin
        for (int lane = 0; lane < 4; lane++) begin
            mdsx_rel = 2'(lane) - VER_base;
            if (mdsx_mem_hit && VER_lanes[lane]) mdsx_full[8*lane +: 8] = VER_result[8*mdsx_rel +: 8];
            else if (mdsx_kwb_hit && WB_lanes[lane]) mdsx_full[8*lane +: 8] = WB_val_aligned[8*lane +: 8];
            else mdsx_full[8*lane +: 8] = mdsx_reg[8*lane +: 8];
        end
    end

    logic [31:0] mdsx_data;
    assign mdsx_data = fwd_slice(EX_IR_2[21:19], mdsx_full);

    //Alright so memRead is not quite 1 atm, we've got another hazard here,
    //since new read at the start of VER and write at the start of VER happens
    //at the same clock edge, the read seems the old memory, and that's no good.
    //To detect this I check the proximit between read and write if they are
    //not within 4bytes of each other(because of fragmented registers), well
    //nothing happens, but if they are we wait for it to write, and only then
    //read
    logic  store_load_overlap;
    assign store_load_overlap = isVER_valid && VER_memRead && isWB_valid && WB_memWrite &&
                                ((VER_memTarget[31:2] == WB_word) ||
                                (VER_memTarget[31:2] == WB_word_plus1) ||
                                (VER_memTarget[31:2] == WB_word_minus1));

    logic  VER_reread;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) VER_reread <= 1'b0;
        else VER_reread <= mem_stall;
    end


    assign mem_stall = isVER_valid && (VER_memRead || VER_memWrite) && !(D_mem_rdy && !(store_load_overlap && VER_vram_cs && !VER_reread)); //Writes are gates by memViolation anyways

    logic [31:0] mem_read_data;
    logic [31:0] vram_data_read;

    //Big endian
    logic [31:0] vram_data_sized;
    always_comb begin
        unique case (VER_mem_size)
            2'b00: begin
                vram_data_sized = {24'h0, vram_data_read[31:24]};
            end
            2'b01: begin
                vram_data_sized = {16'h0, vram_data_read[31:16]};
            end
            default: begin //2'b10
                vram_data_sized = vram_data_read;
            end
        endcase
    end

    always_comb begin
        if (VER_ram_cs)
            mem_read_data = ram_data_out;
        else if (VER_io_cs)
            mem_read_data = io_data_out;
        else if (VER_vram_cs)
            mem_read_data = vram_data_sized;
        else
            mem_read_data = 32'd0;
    end

    logic [1:0]  VER_base;
    logic [3:0]  VER_lanes;
    assign EX_lanes   = fwd_lanes(gpr_rw0_sel[2:0]);
    assign EX_base    = frag_base(gpr_rw0_sel[2:0]);

    //Specifically for mul, actually no - not anymore for loads too, actually
    //no not even for mul anymore, specifically for loads now
    logic [31:0] VER_val;
    always_comb begin
        if (VER_is_load)
            VER_val = mem_read_data;
        else
            VER_val = VER_result;
    end

    //== Comparator ==//
    //Moved the compare module from ALU to here, for 1) shorten critical path,
    //2) convinience
    //Now I moved it from EX to VER reason above
    logic [31:0] branch_x, branch_y;
    logic        branch_eq, branch_less_unsigned, branch_less_signed;

    assign branch_x = FWD_rx0;
    //2 opcodes for every branch - the one that uses imm, and other uses register
    //That way we don't have to add imm every time on branch, in fact we never
    //have to add imm if we are comparing to the varibale, which shortens
    //critical path, and as a bonus compiler wouldn't need to use rx31 as
    //a buffer and add imm to it, we can just use big imm19
    logic [31:0] branch_imm19;
    //Nice way to sign ext
    assign branch_imm19 = {{13{rx1[7]}}, rx1, EX_IR[4:0], EX_IR_2[31:26]};

    assign branch_y = (branch_op[4]) ? branch_imm19 : FWD_rx1;

    logic [31:0] branch_mask;
    always_comb begin
        unique case (rx0[2:0])
            3'b001, 3'b010:                 branch_mask = 32'h0000FFFF;
            3'b011, 3'b100, 3'b101, 3'b110: branch_mask = 32'h000000FF;
            default:                        branch_mask = 32'hFFFFFFFF;
        endcase
    end

    //fwd_slice zero extends so signed compares on rz/ry need re extending, as
    //usual troubles with fragmented, but I love them nontheless
    function automatic [31:0] br_sext(input [2:0] off, input [31:0] v); //branch sign extend
        unique case (off)
            3'b001, 3'b010:                 br_sext = {{16{v[15]}}, v[15:0]};
            3'b011, 3'b100, 3'b101, 3'b110: br_sext = {{24{v[7]}},  v[7:0]};
            default:                        br_sext = v;
        endcase
    endfunction

    logic [31:0] branch_xs, branch_ys;
    assign branch_xs = br_sext(rx0[2:0], branch_x);
    assign branch_ys = (branch_op[4]) ? branch_imm19 : br_sext(rx1[2:0], FWD_rx1);

    assign branch_eq = (((VER_branch_x ^ VER_branch_y) & VER_branch_mask) == 32'b0);
    assign branch_less_unsigned = (VER_branch_x < VER_branch_y);
    assign branch_less_signed = ($signed(VER_branch_xs) < $signed(VER_branch_ys));

    logic branch_cond_met;

    always_comb begin : Comparator
        case (VER_branch_op)
            5'b00001, 5'b10001: branch_cond_met = branch_eq;  //BEQ/IBEQ
            5'b00010, 5'b10010: branch_cond_met = !branch_eq; //BNE/IBNE

            5'b00011, 5'b10111: branch_cond_met = !branch_less_unsigned && !branch_eq; // BGU/IBGU
            5'b00100, 5'b11000: branch_cond_met = branch_less_unsigned;                // BSU/IBSU
            5'b00111, 5'b11001: branch_cond_met = !branch_less_unsigned;               // BGEU/IBGEU
            5'b01000, 5'b11010: branch_cond_met = branch_less_unsigned || branch_eq;   // BSEU/IBSUE

            5'b00101, 5'b10011: branch_cond_met = !branch_less_signed && !branch_eq;   // BGS/IBG
            5'b00110, 5'b10100: branch_cond_met = branch_less_signed;                  // BSS/IBS
            5'b01001, 5'b10101: branch_cond_met = !branch_less_signed;                 // BGES/IBGE
            5'b01010, 5'b10110: branch_cond_met = branch_less_signed || branch_eq;     // BSES/IBSE

            default: branch_cond_met = 0;
        endcase
    end : Comparator

    logic  [31:0] VER_redirect_target;
    //Veril***r compains fsr idk
    logic  VER_mispredict /*verilator public_flat_rd*/;
    logic  VER_redirect;
    assign VER_mispredict = isVER_valid && VER_branch && !VER_irq && (branch_cond_met != VER_predicted_taken);
    assign VER_redirect   = D_miss_ff || VER_mispredict || (isVER_valid && VER_demolish);
    assign VER_redirect_target = D_miss_ff ? WB_PC : VER_demolish ? VER_redirect_pc : (branch_cond_met ? VER_early_target : VER_PCNext);

    //== WB(WriteBack) ==//
    logic [31:0] WB_result;
    logic [7:0]  WB_gpr_dest;

    logic WB_gpr_write;
    logic WB_kernelMode;
    logic WB_is_lomul, WB_is_himul;

    logic        WB_memWrite;
    logic [29:0] WB_word, WB_word_plus1, WB_word_minus1;

    logic [31:0] WB_aligned;
    logic [3:0]  WB_lanes;

    logic [31:0] WB_PC; //never thought i'd need it

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isWB_valid_ff <= 0;
        end else if (!mem_stall) begin
            isWB_valid_ff <= isVER_valid & !VER_fault;
        end
    end

    always_ff @(posedge clk) begin
        if (!mem_stall) begin
            WB_PC <= VER_PC;
            WB_result<= VER_val;
            WB_gpr_dest <= VER_gpr_dest;
            WB_gpr_write <= VER_gpr_write;
            WB_kernelMode <= VER_kernelMode;

            WB_is_lomul <= VER_is_lomul;
            WB_is_himul <= VER_is_himul;

            WB_memWrite <= VER_memWrite;
            WB_word       <= VER_memTarget[31:2];
            WB_word_plus1 <= VER_memTarget[31:2] + 30'd1;
            WB_word_minus1<= VER_memTarget[31:2] - 30'd1;

            WB_aligned  <= VER_aligned;
            WB_lanes    <= fwd_lanes(VER_gpr_dest[2:0]);
        end
    end

    //Now this is specifically for mul(prone to change as I already realized)
    logic [31:0] WB_val;
    always_comb begin
        if (WB_is_lomul)
            WB_val = mul_product[31:0];
        else if (WB_is_himul)
            WB_val = mul_product[63:32];
        else
            WB_val = WB_result;
    end

    (* keep = "true" *) logic [31:0] FWD_rx0, FWD_rx1, FWD_rxi; //keep so vivado maps the forwarding mux by itself

    //So yeah this is just verilator function, they are automatic because it
    //means that each call gets its own unique set of argumenst, like in
    //regular C stack allocation, regularly though, it gives everyone the same
    //argumetns. Best thing is that it costs nothing in hardware
    function automatic [31:0] fwd_slice(input [2:0] fragment, input [31:0] val);
        unique case (fragment)
            3'b001:  fwd_slice = {16'h0000,   val[15:0]};
            3'b010:  fwd_slice = {16'h0000,   val[31:16]};
            3'b011:  fwd_slice = {24'h000000, val[7:0]};
            3'b100:  fwd_slice = {24'h000000, val[15:8]};
            3'b101:  fwd_slice = {24'h000000, val[23:16]};
            3'b110:  fwd_slice = {24'h000000, val[31:24]};
            default: fwd_slice = val;
        endcase
    endfunction

    //So in order to save up 1 logic level instead of writing FWD to full registers
    //I write it to the byte lanes, same thing as in GPRs really. This should
    //decrease the mux to 1 LUT6 instead of 2 therby saving 1 logic level.
    //Why did I only think of the fragment name now, its genuis. Well better
    //late than never
    function automatic [31:0] fwd_align(input [2:0] fragment, input [31:0] val);
        unique case (fragment)
            3'b001:  fwd_align = {16'h0000, val[15:0]};          //ry0
            3'b010:  fwd_align = {val[15:0], 16'h0000};          //ry1
            3'b011:  fwd_align = {24'h000000, val[7:0]};         //rz0
            3'b100:  fwd_align = {16'h0000, val[7:0], 8'h00};    //rz1
            3'b101:  fwd_align = {8'h00, val[7:0], 16'h0000};    //rz2
            3'b110:  fwd_align = {val[7:0], 24'h000000};         //rz3
            default: fwd_align = val;                            //rx
        endcase
    endfunction

    function automatic [7:0] slice_pick(input [2:0] fragment);
        unique case (fragment)
            3'b001:  slice_pick = 8'b00_00_01_00;
            3'b010:  slice_pick = 8'b00_00_11_10;
            3'b011:  slice_pick = 8'b00_00_00_00;
            3'b100:  slice_pick = 8'b00_00_00_01;
            3'b101:  slice_pick = 8'b00_00_00_10;
            3'b110:  slice_pick = 8'b00_00_00_11;
            default: slice_pick = 8'b11_10_01_00;
        endcase
    endfunction

    function automatic [3:0] slice_keep(input [2:0] fragment);
        unique case (fragment)
            3'b001, 3'b010:                 slice_keep = 4'b0011;
            3'b011, 3'b100, 3'b101, 3'b110: slice_keep = 4'b0001;
            default:                        slice_keep = 4'b1111;
        endcase
    endfunction

    function automatic [1:0] frag_base(input [2:0] fragment);
        unique case (fragment)
            3'b010:  frag_base = 2'd2; //ry1
            3'b100:  frag_base = 2'd1; //rz1
            3'b101:  frag_base = 2'd2; //rz2
            3'b110:  frag_base = 2'd3; //rz3
            default: frag_base = 2'd0;
        endcase
    endfunction

    function automatic [3:0] fwd_lanes(input [2:0] fragment);
        unique case (fragment)
            3'b001:  fwd_lanes = 4'b0011;
            3'b010:  fwd_lanes = 4'b1100;
            3'b011:  fwd_lanes = 4'b0001;
            3'b100:  fwd_lanes = 4'b0010;
            3'b101:  fwd_lanes = 4'b0100;
            3'b110:  fwd_lanes = 4'b1000;
            default: fwd_lanes = 4'b1111;
        endcase
    endfunction

    logic  wb_writes_kgpr;
    assign wb_writes_kgpr = isWB_valid && WB_gpr_write && (WB_gpr_dest[7:3] <= 5'd1) && WB_kernelMode;

    logic [31:0] KGPR0_next, KGPR1_next;
    always_comb begin
        for (int lane = 0; lane < 4; lane++) begin
            KGPR0_next[8*lane +: 8] = (wb_writes_kgpr && !WB_gpr_dest[3] && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : KGPR0[8*lane +: 8];
            KGPR1_next[8*lane +: 8] = (wb_writes_kgpr &&  WB_gpr_dest[3] && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : KGPR1[8*lane +: 8];
        end
    end

    //Reading one cycle earier - introduces the similar hazard to when it was
    //in EX just gotta expand on that 1 cycle more.
    logic  wb_writes_array;
    assign wb_writes_array = isWB_valid && WB_gpr_write &&
                             !(WB_gpr_dest[7:3] <= 5'd1 && WB_kernelMode);
    assign GA_wb_hit0 = wb_writes_array && (WB_gpr_dest[7:3] == GA_rx0[7:3]);
    assign GA_wb_hit1 = wb_writes_array && (WB_gpr_dest[7:3] == GA_rx1[7:3]);
    assign GA_wb_hit2 = wb_writes_array && (WB_gpr_dest[7:3] == rr2_sel);

    //Do once
    logic [31:0] WB_val_aligned;
    assign WB_val_aligned = fwd_align(WB_gpr_dest[2:0], WB_val);

    //Apply several times
    always_comb begin
        for (integer lane = 0; lane < 4; lane++) begin
            GA_rx0_val[8*lane +: 8] = (GA_wb_hit0 && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : GPRs_data_out0[8*lane +: 8];
            GA_rx1_val[8*lane +: 8] = (GA_wb_hit1 && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : GPRs_data_out1[8*lane +: 8];
            GA_rx2_val[8*lane +: 8] = (GA_wb_hit2 && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : GPRs_data_out2[8*lane +: 8];
        end
    end

    logic [31:0] EX_gpr0, EX_gpr1, EX_gpr2;
    assign EX_gpr0 = EX_rx0_val;
    assign EX_gpr1 = EX_rx1_val;
    assign EX_gpr2 = EX_rx2_val;

    function automatic [31:0] fwd_mux(input from_mem, input [1:0] mem_byte, input [7:2] fwd_src, input [31:0] mem_val, input [31:0] ex_val);
        unique case ({mem_byte[1], from_mem, mem_byte[0]})
            3'b010:  fwd_mux[7:0] = mem_val[7:0];
            3'b011:  fwd_mux[7:0] = mem_val[15:8];
            3'b110:  fwd_mux[7:0] = mem_val[23:16];
            3'b111:  fwd_mux[7:0] = mem_val[31:24];
            default: fwd_mux[7:0] = ex_val[7:0];
        endcase
        unique case (fwd_src[3:2])
            2'd1:    fwd_mux[15:8] = mem_val[15:8];
            2'd2:    fwd_mux[15:8] = mem_val[31:24];
            2'd3:    fwd_mux[15:8] = mem_val[7:0];
            default: fwd_mux[15:8] = ex_val[15:8];
        endcase
        unique case (fwd_src[5:4])
            2'd1:    fwd_mux[23:16] = mem_val[23:16];
            2'd2:    fwd_mux[23:16] = mem_val[7:0];
            default: fwd_mux[23:16] = ex_val[23:16];
        endcase
        unique case (fwd_src[7:6])
            2'd1:    fwd_mux[31:24] = mem_val[31:24];
            2'd2:    fwd_mux[31:24] = mem_val[15:8];
            2'd3:    fwd_mux[31:24] = mem_val[7:0];
            default: fwd_mux[31:24] = ex_val[31:24];
        endcase
    endfunction

    assign FWD_rx0 = fwd_mux(EX_from_mem0, EX_mem_byte0, EX_fwd_src0, VER_result, EX_gpr0);
    assign FWD_rx1 = fwd_mux(EX_from_mem1, EX_mem_byte1, EX_fwd_src1, VER_result, EX_gpr1);
    assign FWD_rxi = fwd_mux(EX_from_mem2, EX_mem_byte2, EX_fwd_src2, VER_result, EX_gpr2);

    //Declarations
    logic [31:0] EPC;
    logic [31:0] EX_EPC, VER_EPC_val;
    logic        VER_EPC_write;
    assign VER_EPC_write = isVER_valid && VER_EPCWrite;
    assign VER_EPC_val   = VER_irq ? VER_PC : VER_PCNext;
    assign EX_EPC        = VER_EPC_write ? VER_EPC_val : EPC;

    logic  [31:0] SP, GP, KGP, KSP, LR, KScratch;
    logic  [31:0] EX_LR;
    assign EX_LR  = VER_LR_write  ? VER_LR_val : LR;

    logic [31:0] PCNext;
    logic [31:0] SPRNext;

    logic memRead, memWrite;
    logic SPRWrite;
    logic memViolation;
    logic isCallState;
    logic [31:0] memBase;
    logic [31:0] memLimit;
    logic [32:0] memEnd;
    logic [31:0] memTarget;
    logic [1:0] spr_target_sel;

    logic [3:0] PCSrc;
    logic [2:0] GPRsSrc;
    logic [2:0] SPRSrc;

    logic EPCWrite;
    logic irq_taken;
    logic isKernelMode;
    logic mod_state;

    logic [31:0] GPRs_data_out0, GPRs_data_out1, GPRs_data_out2;
    logic [31:0] KGPR0, KGPR1;
    logic [31:0] GPRs_data_in;
    logic [7:0]  gpr_rw0_sel;

    logic [31:0] AluMuxX;
    logic [31:0] AluMuxY;
    logic [63:0] mul_product;
    logic div_stall;

    logic [31:0] shift_result;
    logic [31:0] div_result;
    logic [31:0] add_result;
    logic [31:0] sub_result;
    logic [31:0] bitwise_result;

    logic [31:0] ram_data_out;

    logic [15:0] mmio_timer_reg;

    logic ZeroDivException;

    logic PCWrite, GPRsWrite;

    logic [1:0] mem_size;

    assign gpr_rw0_sel = isEX_mdx ? EX_IR_2[26:19] :
                //3 register ALU type
                (opcode == 6'b000001 || opcode == 6'b000011 || opcode == 6'b000111 || opcode == 6'b000101 || opcode == 6'b001011 || opcode == 6'b001001) ? rx2 :
                rx0;

    logic [2:0] push_pop_bytes;
    always_comb begin
        unique case (rx0[2:0])
            3'b011, 3'b100, 3'b101, 3'b110: push_pop_bytes = 3'd1; // rz - 8-bit
            3'b001, 3'b010:                 push_pop_bytes = 3'd2; // ry - 16-bit
            default:                        push_pop_bytes = 3'd4; // rx - 32-bit
        endcase
    end

    //Idk why it was in DSP like what was I thinking
    (* use_dsp = "no" *)
    logic [31:0] idx_addr;
    assign idx_addr = LDX_base + (isEX_mdx ? EX_mdx_product : LDX_imm29) + LDX_idx;

    logic [31:0] other_addr;
    always_comb begin
        unique case (opcode)
            6'b100100: other_addr = SelectedSPR; // PUSH
            6'b100101: other_addr = SelectedSPR - {29'd0, push_pop_bytes}; // POP
            //6'b100100: other_addr = SelectedSPR + push_pop_bytes; // PUSH
            //6'b100101: other_addr = SelectedSPR - push_pop_bytes; // POP
            6'b101000,
            6'b101001,
            6'b101101: other_addr = SelectedSPR + sign_ext_imm16;      // SPRLDR/SPRSTR/SPRLEA

            default: other_addr = rx1_plus_imm; //LDR/STR, anything else doesn't touch memory
        endcase
    end
    assign memTarget = (opcode == 6'b000000) ? idx_addr : other_addr; //STX/MDXs

    /* verilator lint_off UNUSEDSIGNAL */
    logic [14:0] idx16, oth16;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [14:5] memTarget16;
    assign idx16 = LDX_base[14:0] + ((isEX_mdx ? EX_mdx_product[14:0] : LDX_imm29[14:0]) + 15'd16) + LDX_idx[14:0];
    always_comb begin
        unique case (opcode)
            6'b100100: oth16 = SelectedSPR[14:0] + 15'd16;
            6'b100101: oth16 = SelectedSPR[14:0] + (15'd16 - {12'd0, push_pop_bytes});
            6'b101000,
            6'b101001,
            6'b101101: oth16 = SelectedSPR[14:0] + (sign_ext_imm16[14:0] + 15'd16);
            default: oth16 = FWD_rx1[14:0] + (EX_rx1_imm[14:0] + 15'd16);
        endcase
    end
    assign memTarget16 = (opcode == 6'b000000) ? idx16[14:5] : oth16[14:5];
    assign memViolation =   (!VER_kernelMode && (VER_memRead || VER_memWrite) &&
                            ((VER_memTarget < memBase) ||
                            (33'(VER_memTarget) >= memEnd)));

    assign spr_target_sel =
        (opcode == 6'b101000 || opcode == 6'b101001 || opcode == 6'b101010 ||
        opcode == 6'b101011 || opcode == 6'b101100 || opcode == 6'b101101) ? EX_IR[17:16] : 2'b00;

    logic [31:0] spr_reg, SelectedSPR;
    always_comb begin
        unique case (spr_target_sel)
            2'b00:   spr_reg = EX_kernel_mode ? KSP : SP;
            2'b01:   spr_reg = LR;
            2'b10:   spr_reg = EX_kernel_mode ? KGP : GP;
            default: spr_reg = 32'd0; // reserved
        endcase
    end
    assign SelectedSPR = (EX_spr_hit && isVER_valid) ? VER_LR_val : spr_reg;

    logic [31:0] spr_other;
    always_comb begin
        unique case (SPRSrc)
            //SP and KSP grows upward
            3'b100:  spr_other = SelectedSPR + {29'd0, push_pop_bytes}; // PUSH
            3'b101:  spr_other = SelectedSPR - {29'd0, push_pop_bytes}; // POP

            //3'b100:  spr_other = SelectedSPR + push_pop_bytes; // PUSH
            //3'b100:  spr_other = SelectedSPR - push_pop_bytes; // PUSH
            default: spr_other = SelectedSPR;
        endcase
    end

    logic [31:0] spr_add, spr_sub, spr_result;
    assign spr_add = SelectedSPR + FWD_rx0 + sign_ext_imm16;           // SPRADD
    assign spr_sub = SelectedSPR + ~FWD_rx0 + (32'd1 - sign_ext_imm16); // SPRSUB
    assign spr_result = (SPRSrc[2:1] == 2'b11) ? (SPRSrc[0] ? spr_sub : spr_add) : spr_other;

    //Muxes
    assign AluMuxX = FWD_rx0;

    //3 register ops never read y_imm (it only feeds bitwise), so it is the shared adder
    assign AluMuxY = rx1_plus_imm;

    always_comb begin : PC_MUX
        unique case (PCSrc)
            4'b0000: PCNext = EX_early_target;
            4'b0001: PCNext = EX_early_target;
            4'b0011: PCNext = EX_EPC;       // RETU
            4'b0101: PCNext = EX_LR;        // RET
            4'b0010: PCNext = 32'h00000064; // Syscall Vector
            4'b0100: PCNext = 32'h00000068; // Timer Vector
            4'b1000: PCNext = 32'h0000006C; // Key Interrupt Vector
            4'b0111: PCNext = FWD_rx0; // JR
            default: PCNext = EX_early_target;
        endcase
    end : PC_MUX

    assign VER_activeSP = VER_kernelMode ? KSP : SP;

    //This literally can be a 2:1 mux im dumb
    assign SPRNext = (VER_SPRSrc == 3'b011) ? VER_rx0_val : VER_spr_result; //SPRSET, else PUSH/POP/SPRADD/SPRSUB

    logic  VER_LR_write;
    logic  [31:0] VER_LR_val;
    assign VER_LR_write  = isVER_valid && (VER_is_call || (VER_SPRWrite && (VER_spr_target_sel == 2'b01)));
    assign VER_LR_val    = VER_is_call ? VER_PCNext : SPRNext;

    always_ff @(posedge clk or posedge reset) begin : SPR_ffs
        if (reset) begin
            SP <= 32'h00001FFF; //Jic itll be reset anyway
            KSP <= 32'h00000080; //4KB for Kernel operations
            LR  <= 32'd0;
            KScratch <= 32'd0;
            GP  <= 32'd0;
            KGP <= 32'd0;
            mod_state <= 0;

            memBase    <= 32'h0;
            memLimit   <= 32'hFFFFFFFF;
            mmio_timer_reg <= 16'd10000;

        end else begin
            mod_state <= ENC_10K_ModArr;

            if (VER_fault) begin
                EPC <= VER_PC;
            end else begin
                if (isVER_valid && !mem_stall) begin //Its now VER bounded because, again, mode switch happens in VER
                    if (VER_EPCWrite) EPC <= VER_irq ? VER_PC : VER_PCNext;

                    if (VER_is_call) begin
                        LR <= VER_PCNext;
                    end

                    if (VER_SPRWrite) begin
                        unique case (VER_spr_target_sel)
                            2'b00: begin
                                if (VER_kernelMode) KSP <= SPRNext;
                                else SP <= SPRNext;
                            end
                            2'b01: LR <= SPRNext;
                            2'b10: begin
                                if (VER_kernelMode) KGP <= SPRNext;
                                else GP <= SPRNext;
                            end
                            default: ; // reserved for later
                        endcase
                    end
                end

                if (isVER_valid && !mem_stall) begin //Moved to VER from EX
                    if (VER_memWrite && VER_mmio_cs && VER_kernelMode) begin
                        unique case (VER_memTarget[7:0])
                            8'h04: mmio_timer_reg <= VER_rx0_val[15:0];
                            8'h08: memBase        <= VER_rx0_val;
                            8'h0C: memLimit       <= VER_rx0_val;
                            8'h10: EPC            <= VER_rx0_val;
                            8'h14: SP             <= VER_rx0_val;
                            8'h18: KSP            <= VER_rx0_val;
                            8'h1C: KScratch       <= VER_rx0_val;
                            default: ;
                        endcase
                    end
                end
            end
        end
    end : SPR_ffs

    //memEnd was at always_ff block above and it was written to twice.
    //So I thought why not just compute it every cycle.
    //That does make it lag 1 cycle behind but according to my precise
    //Calculations: we dgaf
    always_ff @(posedge clk or posedge reset) begin
        if (reset) memEnd <= 33'h0FFFFFFFF;
        else memEnd <= 33'(memBase) + 33'(memLimit);
    end


    // Address Map:
    // 64MB System RAM : 0x00000000 - 0x03FFFFFF
    // 1MB VRAM        : 0x04000000 - 0x040FFFFF
    // MMIO Registers  : I/O stuff
    always_comb begin
        VER_ram_cs  = 0;
        VER_vram_cs = 0;

        if (VER_memTarget[31:28] == 4'b0) begin //A little optimizations
            VER_ram_cs = 1;
        end
        else if (VER_memTarget[31:20] == 12'h100) begin
            VER_vram_cs = 1;
        end
        //Else memFault, not really actually its either IO_cs or memFault,
        //I moved IO_cs to VER because it doesn't really gate anything earlier,
        //so its fine in VER, whilst its a lil more complicated for others,
        //and they aren't even in critical path so it doesn't matter anyway.
    end

    //Might be a little too much for just 1 instruction, but hey as long as
    //it doesn't touch critical path - it doesn't matter. I can also reuse it
    //If I ever want to make more 4reads instructions
    logic [2:0] store_frag;
    logic [31:0] store_val;
    assign store_frag = isEX_mdx ? EX_IR_2[21:19] : rx0[2:0];
    assign store_val  = isEX_mdsx ? mdsx_data     : FWD_rx0;

    always_comb begin : ram_d_in
        unique case (store_frag)
            //ram_data_in_aligned is obsolete bc L1 applies mask and zero
            //padding is effectively useless. mem_size is still fine tho.
            3'b011, 3'b100, 3'b101, 3'b110: begin // 8-bit
                mem_size = 2'b00;
            end
            3'b001, 3'b010: begin // 16-bit
                mem_size = 2'b01;
            end
            default: begin // 32-bit
                mem_size = 2'b10;
            end
        endcase
    end : ram_d_in

    logic [31:0] io_data_out;
    always_comb begin
        unique case (VER_memTarget[7:0]) //Upper 24bits are checked by chip select, this is just LUT optimization
            8'h00: io_data_out = {24'd0, ENC_10K_KeyIn};
            8'h04: io_data_out = {31'd0, mod_state};
            8'h08: io_data_out = {16'd0, mmio_timer_reg};
            8'h14: io_data_out = SP;
            8'h18: io_data_out = KSP;
            8'h1C: io_data_out = KScratch;
            8'h20: io_data_out = VER_activeSP;
            8'h24: io_data_out = LR;
            default:      io_data_out = 32'd0;
        endcase
    end

    //literally a early result at EX, moved it to separe MUX bc with sub_result
    //result_sel doesn't have avaliable bit combination for it, moving it here
    //Costs literally nothing so its technically better.
    logic [31:0] early_result;
    always_comb begin
        unique case (GPRsSrc)
            3'b011:  early_result = sign_ext_imm18; // LOAD
            3'b110:  early_result = EX_IR_2;        // LMA
            3'b111:  early_result = rng_result;
            default: early_result = div_result;     // DIV/MOD/SDIV
        endcase
    end

    //No 3'b001 arm anymore, VER fixes the load in one cycle later
    always_comb begin : GPRsMUX //thats a good ass feature
        unique case (result_sel)
            3'b000: GPRs_data_in = add_result;
            3'b001: GPRs_data_in = bitwise_result;
            3'b010: GPRs_data_in = shift_result;
            3'b011, 3'b111: GPRs_data_in = early_result;
            3'b100: GPRs_data_in = sub_result;
            3'b101: GPRs_data_in = idx_addr; //MDCX
            3'b110: GPRs_data_in = SelectedSPR + sign_ext_imm16;
        endcase
    end : GPRsMUX

    CU control_unit (
        .clk(clk),
        .reset(reset),
        .opcode(opcode),
        .op_64(op_64),
        .mmio_timer_reg(mmio_timer_reg),
        .current_kernel_mode(EX_kernel_mode),
        .key_in(ENC_10K_KeyIn),
        .isEX_valid(isEX_valid), //Split the check in 2
        .timer_interrupt_commit(isVER_valid && VER_irq_timer),
        .key_interrupt_commit(isVER_valid && VER_irq_key),
        .PCWrite(PCWrite),
        .GPRsWrite(GPRsWrite),
        .EPCWrite(EPCWrite),
        .irq_taken(irq_taken),
        .isKernelMode(isKernelMode),
        .timer_interrupt_taken(timer_interrupt_taken),
        .key_interrupt_taken(key_interrupt_taken),
        .memRead(memRead),
        .memWrite(memWrite),
        .PCSrc(PCSrc),
        .GPRsSrc(GPRsSrc),
        .isCallState(isCallState),
        .SPRWrite(SPRWrite),
        .SPRSrc(SPRSrc)
    );

    ALU cpu_alu (
        .clk(clk),
        .reset(reset),
        .x(AluMuxX),
        .y(FWD_rx1),
        .y_imm(AluMuxY),
        .opcode(opcode),
        .imm2(alu_imm2),
        .mul_y_in(mul_y_in),
        .x_fragment(rx0[2:0]),
        .y_fragment(rx1[2:0]),
        .isDiv_valid(isEX_valid), //Not demolish bc it has a long of irrelivant data that just slows it dow
        .mem_stall(mem_stall),
        .shift_amount(shift_amount),

        .add_result(add_result),
        .sub_result(sub_result),
        .bitwise_result(bitwise_result),
        .shift_result(shift_result),
        .div_result(div_result),
        .mul_product(mul_product),
        .div_stall(div_stall),

        .ZeroDivException(ZeroDivException)
    );

    GPRs all_gprs (
        .clk(clk),
        .reset(reset),
        .reg_write(WB_gpr_write && isWB_valid),
        .KernelModeWrite(WB_kernelMode),
        //offset forced to 000 so these come back as the raw 32bit register,
        //the forwarding block above does the slicing after it merges
        //Again - read in GA
        .rr0(GA_rx0[7:3]),
        .rr1(GA_rx1[7:3]), //Natevily base
        .rr2(rr2_sel), //Index selector
        .rw0(WB_gpr_dest),
        .data_in(WB_val),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1),
        .data_out2(GPRs_data_out2),
        .KGPR0(KGPR0),
        .KGPR1(KGPR1)
    );

    L1 cache (
        .clk(clk),
        .rst(reset),
        .D_advance(!stall),

        .I_addr(IF_PC_tofetch), //takes 1cycle for BRAM so fetching next
        .I_even_idx(IF_even_tofetch),
        .I_skip(IF_skip),
        .I_discard(IF_redir),
        .I_data_out(instr_fetch_duo),
        .I_mem_rdy(I_mem_rdy),
        .I_miss_ff(I_miss_ff),

        .Dread_addr(memTarget[27:0]),
        .Dread_even(memTarget16),
        .D_write_addr(VER_memTarget[14:0]), //Writes happen in VER
        .we(VER_memWrite && !memViolation && VER_ram_cs && isVER_valid),  //memWrite dgaf if mem is ready or not
        .re(VER_memRead && !memViolation && VER_ram_cs && isVER_valid), //same thing
        .ram_op(isVER_valid && VER_ram_cs && (VER_memRead || VER_memWrite)),

        .D_data_in(VER_ram_data_in),
        .mem_size(VER_mem_size),

        .D_data_out(ram_data_out),
        .D_mem_rdy(D_mem_rdy),
        .D_miss_ff(D_miss_ff),

        //From TOP that holds EMI
        .EMI_req(EMI_req),
        .EMI_req_we(EMI_req_we),
        .EMI_req_addr(EMI_req_addr),
        .EMI_req_wd(EMI_req_wd),
        .EMI_req_msk(EMI_req_msk),

        .EMI_req_awck(EMI_req_awck),
        .EMI_mem_done(EMI_mem_done),
        .EMI_rdata(EMI_rdata)
    );

    VRAM system_vram (
        .clk(clk),
        .addrRead(stall ? VER_vram_addr : ({12'b0, memTarget[19:0]})), //memTarget - 0x04000000 but much faster
        .addrWrite(vram_addr),
        .data_in(vram_data_out),
        .mem_size(VER_mem_size),
        .mem_write(vram_write),
        .mem_read(stall ? VER_memRead : memRead),
        .data_out(vram_data_read)
    );

    //I would have kept it in the file include, but sim_main(and debug) requires them and
    //it doesn't matte tbh
    assign vram_addr     = VER_vram_addr;
    assign vram_data_out = VER_ram_data_in;
    assign vram_write    = VER_memWrite && VER_vram_cs && isVER_valid;

endmodule
