module CORE(
    input logic clk,
    input logic reset,
    input logic [7:0] ENC_10K_KeyIn,
    input logic ENC_10K_ModArr, //for shifts/alts

    output logic [31:0] vram_addr,
    output logic [31:0] vram_data_out,
    output logic vram_write
);
    //====//
    //Pipilined 5 cycle CPU, I chose 5 cycles because its perfect balance
    //between clock speed, which is higher because of shorter critical path, and
    //penatly for mispredicted branch which is 2 cycles for regular branches
    //and literally 0 for unconditional ones. The penalty is 0 for correctly
    //predicted ones too.

    //The estimated CPI is ~=1.02-1.08 considering average instruction split
    //obviosely varies by program being executed.
    //That is about 2.8 times faster than my multi-cycle design(~= 2.9CPI) as
    //well as higher estimated clock frequency due to shorter critical path
    //3 cycles per instruction to 5, we'll see about that I gotta optimze it.
    //====//

    logic  demolish;   //Removes current instructions on the branch misprediction/branch
    logic  stall;     //Stalls on memory accesses in future but atm on divs
    logic  bubble;   //for handling load-use hazard

    logic  early_target_ok;
    assign early_target_ok = (opcode == 6'b010000) ? (EX_early_target == EX_LR) : (EX_early_target == EX_EPC);

    //Basically thats a massive check for unexpected PC change, like branch
    //misprediction, interrupt and JR maybe other but I forgot
    assign demolish  =  isEX_valid && !mem_stall && !MEM_redirect &&
                        (irq_taken ||
                        (PCWrite &&
                        !(opcode == 6'b111111 || opcode == 6'b111000) &&
                        !((opcode == 6'b010000 || opcode == 6'b111101) && early_target_ok)));

    assign stall     = div_stall || mem_stall;
    assign bubble    = (mul_use_hazard || load_use_hazard || rr2_conflict || mdx_idx_hazard) && !stall; //If we already stall no point in bubble, it also breaks div

    //== IF(Instruction Fetch) ==//
    logic [31:0] IF_PC;
    logic [31:0] IF_PC_plus4_or8;

    //Just a neat little bit trick to get rid of IF_PC_plus(4/8)
    assign IF_PC_plus4_or8 = IF_PC + {28'd0, (IF_64 || IF_branch), !(IF_64 || IF_branch), 2'b00};

    logic [31:0] IF_PC_next;
    assign IF_PC_next = (instr_fetch_data[31:26]==6'b111111 || instr_fetch_data[31:26]==6'b111000 || instr_fetch_data[31:26]==6'b010000 || instr_fetch_data[31:26]==6'b111101 || IF_predicted_taken) ? IF_redirect_target : IF_PC_plus4_or8;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) IF_PC <= 32'h0;
        else if(MEM_fault) IF_PC <= memFault ? 32'h00000070 : 32'h00000074;
        else if(MEM_redirect) IF_PC <= MEM_redirect_target;
        else if(!stall && !bubble) IF_PC <= IF_PC_next;
        else IF_PC <= IF_PC; //I just can't omit it
    end

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
    assign pht_read_idx = IF_PC_next[16:3] ^ GHR[13:0] ^ {5'b0, GHR[15:14], 7'b0};
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
    always_ff @(posedge clk) begin
        pht_out <= PHT[pht_read_idx];
        if (isMEM_valid && MEM_branch && !MEM_irq && !mem_stall)
            PHT[MEM_pht_idx] <= updated_pht(MEM_pht_val, branch_cond_met);
    end

    //GHR is still in flops though
    always_ff @(posedge clk or posedge reset) begin
        if (reset) GHR <= 16'b0;
        else if (isMEM_valid && MEM_branch && !MEM_irq && !mem_stall) GHR <= {GHR[14:0], branch_cond_met};
    end


    //== That looks nice ==//
    //== Anyways ID(Instruction Decode) stage ==//
    logic [31:0] ID_PC, ID_IR; //Each stage gets into own IR and PC
    logic [31:0] ID_early_target;
    logic [13:0] ID_pht_idx;
    logic [1:0]  ID_pht_val;

    logic isID_valid;
    logic ID_branch;
    logic ID_predicted_taken;
    logic [31:0] ID_IR_2;
    logic ID_64;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isID_valid <= 0;
            //Vivado started to complain when I added memFault, but whatever
            //I can just split it into to if blocks
        end else if (MEM_redirect || MEM_fault) begin
            isID_valid <= 0;
        end else if (!stall && !bubble) begin
            isID_valid <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!stall && !bubble) begin
            ID_PC <= IF_PC;
            ID_64 <= IF_64;
            ID_IR_2 <= IF_IR_2;
            ID_branch <= IF_branch;
            ID_IR <= instr_fetch_data;
            ID_early_target <= IF_redirect_target;
            ID_pht_idx <= pht_idx_r;
            ID_pht_val <= pht_out;
            ID_predicted_taken <= IF_predicted_taken;
        end
        //else: stall holds PC and IR as they are
    end

    //==Multi-dimensional operations - sounds cool asf
    logic isID_mdx;
    assign isID_mdx = ID_64 && (ID_IR[9:4] == 6'b011110 || ID_IR[9:4] == 6'b011101 || ID_IR[9:4] == 6'b011100);

    logic isID_mdsx;
    assign isID_mdsx = ID_64 && (ID_IR[9:4] == 6'b011100);

    logic ID_uses_rr2; //LDX, STX, MDLX, MDCX, MDSX
    assign ID_uses_rr2 = ID_64 && (ID_IR[9:4] == 6'b011111 || ID_IR[9:4] == 6'b010000 || isID_mdx);

    //DSP accepts signed and signed only
    logic signed [24:0] ID_mdx_ri;
    logic signed [13:0] ID_stride;
    logic signed [31:0] ID_imm13;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] ID_mdx_idx;
    /* verilator lint_on UNUSEDSIGNAL */ 
    //ri can be only up to 2^24 signed because its the limitation of one DSP
    //slice which is 18x25bits, unfornutely increasing it to 2 chained slices
    //leads to a critical path. Not a big deal tho im not gonna use arrays
    //past 16MB considering my whole memory is 256MB
    assign ID_mdx_idx = (ID_banked2 && EX_kernel_mode) ? (ID_IR_2[27] ? KGPR1_next : KGPR0_next) : ID_rx2_val;
    assign ID_mdx_ri  = ID_mdx_idx[24:0];
    assign ID_stride = {ID_IR[20:18], ID_IR[12:10], ID_IR[3:0], ID_IR_2[16:13]};
    assign ID_imm13  = {{19{ID_IR_2[12]}}, ID_IR_2[12:0]};

    //Finishes at the start of EX
    //So thats a cool one: DSP supports fused add multiply and I really love
    //fused add multiply. I remember first learning vfmadd231pd and I was
    //quite faschinated by it. Now I finally implement it myself
    logic [31:0] EX_mdx_product;
    (* use_dsp = "yes" *)
    always_ff @(posedge clk) begin
        if (!stall) EX_mdx_product <= 32'(ID_mdx_ri * ID_stride + ID_imm13);
    end

    //We need to compare those registers to EX's ones it case they
    //overlap - stall
    //So the regfile read is moved to the ID, saves up on critical path and ID
    //is almost empty anyways so I might as well fill it as much as possible
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0]  ID_rx0, ID_rx1; //Selector last 3bits are unused
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] ID_rx0_val, ID_rx1_val, ID_rx2_val;

    assign ID_rx0 = ID_IR[25:18];
    assign ID_rx1 = ID_IR[17:10];
    //No rx2 I just use ID_IR_2[something:something]

    logic ID_wb_hit0, ID_wb_hit1, ID_wb_hit2;
    logic ID_banked0, ID_banked1, ID_banked2;
    assign ID_banked0 = (ID_rx0[7:3] <= 5'd1);
    assign ID_banked1 = (ID_rx1[7:3] <= 5'd1);
    assign ID_banked2 = (ID_IR_2[31:27] <= 5'd1);

    //Ladies and gentlemen we are currentely wintessing a crime scene: EX steams ID's rr2!!!
    //In reality though: MDSX needs to read 4 registers and I don't feel like
    //adding 4th LUTRAM read port bc its gonna copy LUTRAM which i just don't
    //want to do. And because address only arrives at EX we can freely just
    //steal this read from ID.
    logic [4:0] rr2_sel;
    assign rr2_sel = (isEX_valid && isEX_mdsx) ? EX_IR_2[26:22] : ID_IR_2[31:27];

    //Not freely tho, if next instruction needs 3 read ports we gotta bubble.
    logic mdx_idx_hazard;
    assign mdx_idx_hazard = isID_valid && isID_mdx &&
                            ((isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == ID_IR_2[31:27])) ||
                             (isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == ID_IR_2[31:27])));

    logic rr2_conflict;
    assign rr2_conflict = isEX_valid && isEX_mdsx && isID_valid && ID_uses_rr2;

    //For later when memory would take actual clock cycles to reach
    //Well its later now
    //The load use-hazard creates a 1 cycle bubble if ID_uses_EX_dest in MEM
    //when dest hasn't been written and gets read. Now I used a forwarding up
    //until that point, but that wouldn't work now because if we forward from
    //the middle of the cycle, like with the mem read, it adds this half
    //a cycle to a critical path. So to avoid it just add this 1cycle bubble.
    //This would increase the CPI, but by a small amount, there is no way to
    //avoid it though, at least as far as im aware.
    logic  EX_is_load;
    assign EX_is_load = isEX_valid && memRead;

    logic  load_use_hazard;
    assign load_use_hazard = isID_valid && EX_is_load && ID_uses_EX_dest;

    //the CPU will get mul result only at the end of MEM, hence it introduces
    //mul-use hazard, if next instruction uses mul and we don't have the
    //result yet, we have to bubble, same as load use
    logic  EX_is_mul, MEM_is_mul;
    assign EX_is_mul  = isEX_valid && (opcode == 6'b000111 || opcode == 6'b001101);
    assign MEM_is_mul = isMEM_valid && (MEM_is_lomul || MEM_is_himul);

    //Alright I wrote this all for nothing bc the fix is literally just gate
    //it by ID_64 ill leave it here anyways bc why not.
    //Note: Sometimes by next instruction I mean next 2 instructions
    //Checking if either EX and MEM use the same registers as mul used
    //So I don't check for GPRsWrite is usual because that means it would have
    //to wait for this whole mem safety thing, which im gonna move to the MEM soon,
    //And hence keeps critical path short. However that does introduce
    //a problem, since I unconditionally check for ID_IR_2[31:27], if first
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
    logic  ID_uses_EX_dest, ID_uses_MEM_dest;
    assign ID_uses_EX_dest  = (gpr_rw0_sel[7:3]  == ID_rx0[7:3]) || (gpr_rw0_sel[7:3]  == ID_rx1[7:3]) || (ID_64 && (gpr_rw0_sel[7:3]  == ID_IR_2[31:27]));
    assign ID_uses_MEM_dest = (MEM_gpr_dest[7:3] == ID_rx0[7:3]) || (MEM_gpr_dest[7:3] == ID_rx1[7:3]) || (ID_64 && (MEM_gpr_dest[7:3] == ID_IR_2[31:27]));

    logic  mul_use_hazard;
    assign mul_use_hazard = isID_valid && ((EX_is_mul && ID_uses_EX_dest) || (MEM_is_mul && ID_uses_MEM_dest) ||
                                           (EX_is_mul && isID_mdsx && (gpr_rw0_sel[7:3] == ID_IR_2[26:22])));


    //== EX(Execute) ==//
    //A lot of things happen here, full enum in CU.sv
    logic [31:0] EX_PC, EX_IR;
    logic [31:0] EX_IR_2;
    logic [31:0] EX_early_target;
    logic [13:0] EX_pht_idx;
    logic [1:0]  EX_pht_val;
    logic [31:0] EX_rx0_val, EX_rx1_val, EX_rx2_val;
    logic EX_mem_hit0, EX_mem_hit1, EX_mem_hit2, EX_wb_hit0, EX_wb_hit1, EX_wb_hit2;
    logic EX_banked0, EX_banked1, EX_banked2;
    logic isEX_mdx, isEX_mdsx;
    logic [7:0] EX_pick0, EX_pick1, EX_pick2;
    logic [3:0] EX_keep0, EX_keep1, EX_keep2;
    logic EX_predicted_taken;
    logic isEX_valid;
    logic EX_branch;
    logic EX_64;
    logic [3:0] EX_lanes;
    logic [1:0] EX_base;

    //Alright so there was a big always_ff block here previousely, which
    //apparantely led to high fanout, so just splitting it into 2 always_ff
    //Should do the trick
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isEX_valid <= 0;
        end else if (MEM_redirect || bubble || MEM_fault) begin
            isEX_valid <= 0;
        end else if (!stall) begin
            isEX_valid <= isID_valid;
        end
    end

    always_ff @(posedge clk) begin
        if (!stall) begin
            EX_PC <= ID_PC; //Handing instruction to the EX
            EX_IR <= ID_IR;
            EX_64 <= ID_64;
            EX_IR_2 <= ID_IR_2;
            EX_rx0_val <= (ID_banked0 && kernel_mode_next) ? (ID_rx0[3]   ? KGPR1_next : KGPR0_next) : ID_rx0_val;
            EX_rx1_val <= (ID_banked1 && kernel_mode_next) ? (ID_rx1[3]   ? KGPR1_next : KGPR0_next) : ID_rx1_val;
            EX_rx2_val <= (ID_banked2 && kernel_mode_next) ? (ID_IR_2[27] ? KGPR1_next : KGPR0_next) : ID_rx2_val;
            EX_branch <= ID_branch;
            EX_early_target <= ID_early_target;
            EX_pht_idx <= ID_pht_idx;
            EX_pht_val <= ID_pht_val;
            EX_predicted_taken <= ID_predicted_taken;

            //The forwarding check moves to the ID now, only check forwarding itself
            //still stays in EX
            EX_banked0 <= ID_banked0;
            EX_banked1 <= ID_banked1;
            EX_banked2 <= ID_banked2;
            EX_pick0 <= slice_pick(isID_mdx ? 3'b000 : ID_rx0[2:0]);
            EX_pick1 <= slice_pick(ID_rx1[2:0]);
            EX_pick2 <= slice_pick(ID_IR_2[26:24]);
            EX_keep0 <= slice_keep(isID_mdx ? 3'b000 : ID_rx0[2:0]);
            EX_keep1 <= slice_keep(ID_rx1[2:0]);
            EX_keep2 <= slice_keep(ID_IR_2[26:24]);
            EX_mem_hit0 <= isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == ID_rx0[7:3]);
            EX_mem_hit1 <= isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == ID_rx1[7:3]);
            EX_mem_hit2 <= isEX_valid && GPRsWrite && (gpr_rw0_sel[7:3] == ID_IR_2[31:27]);
            EX_wb_hit0  <= isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == ID_rx0[7:3]);
            EX_wb_hit1  <= isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == ID_rx1[7:3]);
            EX_wb_hit2  <= isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == ID_IR_2[31:27]);

            isEX_mdx <= isID_mdx;
            isEX_mdsx <= isID_mdsx;
        end
    end

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

    logic [31:0] sign_ext_imm10;
    assign sign_ext_imm10 = { {22{EX_IR[9]}}, EX_IR[9:0] };
    logic [31:0] zero_ext_imm10;
    assign zero_ext_imm10 = {22'h0, EX_IR[9:0]};

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
            6'b000001, 6'b000011:            alu_sel = 3'd0; // ADD/SUB
            6'b001000, 6'b001100, 6'b001010: alu_sel = 3'd2; // SHL/SHR/SRA
            6'b000101, 6'b001011, 6'b001001: alu_sel = 3'd3; // DIV/MOD/SDIV
            default:                         alu_sel = 3'd1; // bitwise + MOV
        endcase
    end

    logic [2:0] result_sel;
    always_comb begin
        unique case (GPRsSrc)
            3'b011:  result_sel = 3'd4; // LOAD
            3'b101:  result_sel = 3'd5; // SPRLEA
            3'b110:  result_sel = 3'd6; // LMA
            3'b111:  result_sel = 3'd7; // RNG
            default: result_sel = alu_sel;
        endcase
    end

    logic [31:0] mul_imm, mul_y_in;
    assign mul_imm  = (opcode == 6'b001101) ? zero_ext_imm10 : alu_imm2; //HIMUL is rx1 + imm10, LOMUL is rx2 +- imm2
    assign mul_y_in = FWD_rx1 + mul_imm;

    logic[31:0] LDX_base, LDX_idx, LDX_imm29; //Just enough to cover all 256MB signed

    assign LDX_base = (rx1[7:3] == 5'd31) ? 32'b0 : FWD_rx1_full; //Theoretically it is base +- imm29, but usually base is 0 so rx31
    //I don't even know why Im making it that way because in case RAM would
    //become more than 256MB basically whole architecture would be cooked, but whatever. Oh wait I remembered - its for accesses 
    //That are unknown at the compile-time, literally thought of that like 4 hours ago
    assign LDX_idx = FWD_rxi << EX_IR_2[23:22];
    assign LDX_imm29 = {{3{EX_IR[12]}}, EX_IR[12:10], EX_IR[3:0], EX_IR_2[21:0]};

    //Same this as IF_PC_plus4_or8
    logic [31:0] EX_PC_next;
    assign EX_PC_next = EX_PC + {28'd0, (EX_64 || EX_branch), !(EX_64 || EX_branch), 2'b00};

    //This is forwarding too, EX needs to know the new mode immediately after
    //MEM made the change, becase kernel mode now changes in MEM
    //In always_ff bc its a flop
    logic  EX_kernel_mode, kernel_mode_next;
    assign kernel_mode_next = (!mem_stall && isEX_valid && !stall && !MEM_fault && !MEM_redirect) ? isKernelMode : (MEM_fault || EX_kernel_mode);

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

    always_comb begin
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

    end

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



    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rng_state <= IDLE;
            xadc_addr <= 7'b01; //Would actually read 7'h02 on first time
            //But honest the more chaos in this the better entropy is lol
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
    end

    //This is the call to XADC there isn't actually anything phenomenal here
    //Similar to regular files includes
    /* verilator lint_off PINCONNECTEMPTY */
    XADC #(
        .INIT_40(16'h0000), //default mode is fine
        .INIT_41(16'h0000), //defalt one too
        .INIT_42(16'h0800)
    ) xadc_i (
        .DCLK      (clk),
        .RESET     (reset),
        .DADDR     (xadc_addr), //Read specified register
        .DEN       (xadc_den),
        .DWE       (1'b0),
        .DI        (16'h0),
        .DO        (xadc_do), //Data Out(actually its not just a nice way to remember)
        .DRDY      (xadc_drdy),
        .EOS       (xadc_eos),
        //Some bs we don't care about
        .VP(1'b0), .VN(1'b0), .VAUXP(16'h0), .VAUXN(16'h0),
        .CONVST(1'b0), .CONVSTCLK(1'b0),
        .EOC(), .BUSY(), .CHANNEL(), .OT(), .ALM(), .MUXADDR(),
        .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    //== MEM(memory) ==//
    //Work with memory - load, store
    logic [31:0] MEM_result;
    logic [31:0] MEM_PC;
    logic [31:0] MEM_memTarget;
    logic MEM_memRead, MEM_memWrite;
    logic [31:0] MEM_ram_data_in;
    logic [3:0]  MEM_ram_byte_enable;

    logic [7:0]  MEM_gpr_dest;
    logic        MEM_gpr_write;
    logic        MEM_kernelMode;
    logic        isMEM_valid;

    logic        MEM_EPCWrite;
    logic        MEM_irq;
    logic [31:0] MEM_PCNext;

    logic MEM_is_lomul, MEM_is_himul;
    logic MEM_is_load, MEM_ram_cs, MEM_io_cs, MEM_vram_cs;

    logic MEM_zeroDiv;

    //I moved the decision on whether branch is taken or not to MEM in order
    //to decrease critical path. This would increase the CPI but from my
    //testings not that much, at most + 0.03CPI which is the price im willing
    //to pay.
    //Even more MEM FFs... shouldn't matter though bc im using only like 2k
    //out of 100k or so
    logic        MEM_demolish, MEM_branch, MEM_predicted_taken;
    logic [31:0] MEM_redirect_pc, MEM_early_target;
    logic [4:0]  MEM_branch_op;
    logic [31:0] MEM_branch_x, MEM_branch_y, MEM_branch_xs, MEM_branch_ys, MEM_branch_mask;
    logic [13:0] MEM_pht_idx;
    logic [1:0]  MEM_pht_val;

    //Moving SPRs stuff into MEM
    logic MEM_SPRWrite;
    logic [31:0] MEM_rx0_val, MEM_SelectedSPR, MEM_activeSP, MEM_activeGP;
    logic [31:0] MEM_spr_result;
    logic [2:0]  MEM_SPRSrc;
    logic [1:0]  MEM_spr_target_sel;
    logic MEM_is_call;

    logic MEM_irq_timer;
    logic MEM_irq_key;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isMEM_valid <= 0;
        end else if (!mem_stall) begin
            isMEM_valid     <= isEX_valid & !stall & !MEM_fault & !MEM_redirect;
        end
    end

    always_ff @(posedge clk) begin
        if (!mem_stall) begin
            //That many variables are actually harmless, because they live in
            //FFs which are free, there are a lot of unused FFs in logic slices.
            MEM_result      <= GPRs_data_in;
            MEM_PC          <= EX_PC;

            MEM_memTarget   <= memTarget;
            MEM_memRead     <= memRead;
            MEM_memWrite    <= memWrite;
            MEM_ram_data_in <= ram_data_in_aligned;
            MEM_ram_byte_enable <= ram_byte_enable;

            MEM_EPCWrite    <= EPCWrite;
            MEM_irq         <= irq_taken;
            MEM_PCNext      <= EX_PC_next;

            MEM_gpr_write   <= GPRsWrite;
            MEM_gpr_dest    <= gpr_rw0_sel;
            MEM_kernelMode  <= EX_kernel_mode;
            MEM_is_lomul    <= (opcode == 6'b000111);
            MEM_is_himul    <= (opcode == 6'b001101);
            MEM_zeroDiv     <= ZeroDivException && !irq_taken;

            MEM_demolish        <= demolish;
            MEM_redirect_pc     <= PCNext;
            MEM_branch          <= EX_branch;
            MEM_predicted_taken <= EX_predicted_taken;
            MEM_early_target    <= EX_early_target;
            MEM_branch_op       <= branch_op;
            MEM_branch_x        <= branch_x;
            MEM_branch_y        <= branch_y;
            MEM_branch_xs       <= branch_xs;
            MEM_branch_ys       <= branch_ys;
            MEM_branch_mask     <= branch_mask;
            MEM_pht_idx         <= EX_pht_idx;
            MEM_pht_val         <= EX_pht_val;

            MEM_is_load     <= (GPRsSrc == 3'b001);

            MEM_SPRWrite    <= SPRWrite;
            MEM_SPRSrc      <= SPRSrc;
            MEM_spr_target_sel <= spr_target_sel;
            //Active is kinda a weird word, looks kinda strange
            MEM_rx0_val     <= FWD_rx0;
            MEM_spr_result  <= spr_result;
            MEM_is_call     <= isCallState && (opcode ==6'b111000); //CALL

            MEM_irq_timer <= timer_interrupt_taken;
            MEM_irq_key   <= key_interrupt_taken;

            MEM_lanes     <= EX_lanes;
            MEM_base      <= EX_base;
        end
    end

    logic [31:0] MEM_vram_addr;
    assign MEM_vram_addr = {12'b0, MEM_memTarget[19:0]};

    //Moving the memFault from CU to here, because CU runs only in EX and
    //since im moving mem stuff into MEM this is the only way
    logic  memFault;
    assign memFault = isMEM_valid && (MEM_memRead || MEM_memWrite) && memViolation;

    logic  divFault, MEM_fault; //zeroDiv and memFault can never fire on the same cycle
    assign divFault = isMEM_valid && MEM_zeroDiv;
    assign MEM_fault = memFault || divFault;

    //MMIO cs but basically in MEM
    logic MEM_mmio_cs;
    assign MEM_mmio_cs = (MEM_memTarget[31:8] == 24'hFFFFFF);
    assign MEM_io_cs   = (MEM_memTarget[31:8] == 24'h041000);

    //MEM stalls when waiting for memory, soon when FPGA will arrive ill make
    //a MIG and SDRAM connection and that will govern mem_ready, however at
    //the moment there is no mem waiting so its just 1 atm.
    logic  mem_ready;
    logic  mem_stall;

    logic mdsx_banked;
    assign mdsx_banked = (EX_IR_2[26:23] == 4'b0000);

    logic mdsx_mem_hit, mdsx_kwb_hit;
    assign mdsx_mem_hit = isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == EX_IR_2[26:22]) &&
                          (!mdsx_banked || MEM_kernelMode == EX_kernel_mode);
    assign mdsx_kwb_hit = isWB_valid && WB_gpr_write && mdsx_banked && WB_kernelMode && EX_kernel_mode &&
                          (WB_gpr_dest[7:3] == EX_IR_2[26:22]);

    logic [31:0] mdsx_reg;
    assign mdsx_reg = (mdsx_banked && EX_kernel_mode) ? (EX_IR_2[22] ? KGPR1 : KGPR0) : ID_rx2_val;

    logic [31:0] mdsx_full;
    logic [1:0]  mdsx_rel;
    always_comb begin
        for (int lane = 0; lane < 4; lane++) begin
            mdsx_rel = 2'(lane) - MEM_base;
            if (mdsx_mem_hit && MEM_lanes[lane])      mdsx_full[8*lane +: 8] = MEM_val[8*mdsx_rel +: 8];
            else if (mdsx_kwb_hit && WB_lanes[lane])  mdsx_full[8*lane +: 8] = WB_val_aligned[8*lane +: 8];
            else                                      mdsx_full[8*lane +: 8] = mdsx_reg[8*lane +: 8];
        end
    end

    logic [31:0] mdsx_data;
    assign mdsx_data = fwd_slice(EX_IR_2[21:19], mdsx_full);

    //Alright so memRead is not quite 1 atm, we've got another hazard here,
    //since new read at the start of MEM and write at the start of MEM happens
    //at the same clock edge, the read seems the old memory, and that's no good.
    //To detect this I check the proximit between read and write if they are
    //not within 4bytes of each other(because of fragmented registers), well
    //nothing happens, but if they are we wait for it to write, and only then
    //read
    logic  store_load_overlap;
    assign store_load_overlap = isMEM_valid && MEM_memRead && isWB_valid && WB_memWrite &&
                                ((MEM_memTarget[31:2] == WB_word) ||
                                 (MEM_memTarget[31:2] == WB_word_plus1) ||
                                 (MEM_memTarget[31:2] == WB_word_minus1));

    logic  MEM_reread;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) MEM_reread <= 1'b0;
        else MEM_reread <= mem_stall;
    end

    assign mem_ready = !(store_load_overlap && !MEM_reread);

    assign mem_stall = isMEM_valid && (MEM_memRead || MEM_memWrite) && !mem_ready; //Writes are gates by memViolation anyways

    logic [31:0] mem_read_data;
    logic [31:0] vram_data_read;
    always_comb begin
        if (MEM_ram_cs)
            mem_read_data = ram_data_out;
        else if (MEM_io_cs)
            mem_read_data = io_data_out;
        else if (MEM_vram_cs)
            mem_read_data = vram_data_read;
        else
            mem_read_data = 32'd0;
    end

    logic [1:0]  MEM_base;
    logic [3:0]  MEM_lanes;
    assign EX_lanes   = fwd_lanes(gpr_rw0_sel[2:0]);
    assign EX_base    = frag_base(gpr_rw0_sel[2:0]);

    //Specifically for mul, actually no - not anymore for loads too, actually
    //no not even for mul anymore, specifically for loads now
    logic [31:0] MEM_val;
    always_comb begin
        if (MEM_is_load)
            MEM_val = mem_read_data;
        else
            MEM_val = MEM_result;
    end

    //== Comparator ==//
    //Moved the compare module from ALU to here, for 1) shorten critical path,
    //2) convinience
    //Now I moved it from EX to MEM reason above
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

    assign branch_eq = (((MEM_branch_x ^ MEM_branch_y) & MEM_branch_mask) == 32'b0);
    assign branch_less_unsigned = (MEM_branch_x < MEM_branch_y);
    assign branch_less_signed = ($signed(MEM_branch_xs) < $signed(MEM_branch_ys));

    logic branch_cond_met;

    always_comb begin
        case (MEM_branch_op)
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
    end

    logic  [31:0] MEM_redirect_target;
    //Veril***r compains fsr idk
    logic  MEM_mispredict /*verilator public_flat_rd*/;
    logic  MEM_redirect;
    assign MEM_mispredict = isMEM_valid && MEM_branch && !MEM_irq && (branch_cond_met != MEM_predicted_taken);
    assign MEM_redirect   = MEM_mispredict || (isMEM_valid && MEM_demolish);
    assign MEM_redirect_target = MEM_demolish ? MEM_redirect_pc : (branch_cond_met ? MEM_early_target : MEM_PCNext);



    //== WB(WriteBack) ==//
    logic [31:0] WB_result;
    logic [7:0]  WB_gpr_dest;

    logic WB_gpr_write;
    logic WB_kernelMode;
    logic isWB_valid;
    logic WB_is_lomul, WB_is_himul;

    logic        WB_memWrite;
    logic [29:0] WB_word, WB_word_plus1, WB_word_minus1;

    logic [31:0] WB_aligned;
    logic [3:0]  WB_lanes;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isWB_valid <= 0;
        end else if (!mem_stall) begin
            isWB_valid <= isMEM_valid & !MEM_fault;
        end
    end

    always_ff @(posedge clk) begin
        if (!mem_stall) begin
            WB_result<= MEM_val;
            WB_gpr_dest <= MEM_gpr_dest;
            WB_gpr_write <= MEM_gpr_write;
            WB_kernelMode <= MEM_kernelMode;

            WB_is_lomul <= MEM_is_lomul;
            WB_is_himul <= MEM_is_himul;

            WB_memWrite <= MEM_memWrite;
            WB_word       <= MEM_memTarget[31:2];
            WB_word_plus1 <= MEM_memTarget[31:2] + 30'd1;
            WB_word_minus1<= MEM_memTarget[31:2] - 30'd1;

            WB_aligned  <= fwd_align(MEM_gpr_dest[2:0], MEM_val);
            WB_lanes    <= fwd_lanes(MEM_gpr_dest[2:0]);
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

    //== Forwarding ==//
    //So its a pretty interesting one, if instruction needs result(EX) that hasn't
    //been written to GPRs yet(end of WB), instead of stalling I check for this
    //condition, if its true I just use MEM/WB result, otherwise read from registers

    //The problem is sub registers: a selector is {base_id[4:0], offset[2:0]} and the
    //offset picks which slice of the 32bit register you actually touch:
    //000 - rx, 001 - ry0, 010 - ry1, 011 - rz0, 100 - rz1, 101 - rz2, 110 - rz3
    //Two selectors that differ only in the offset still name the exact same physical
    //register, so comparing the whole 8bit selector breaks everything.
    //The fix is only match using base_id and apply offset only at the end
    logic [31:0] FWD_rx0, FWD_rx1, FWD_rxi;
    logic [31:0] FWD_rx1_full;
    logic MEM_fwd0, WB_fwd0, MEM_fwd1, WB_fwd1, MEM_fwd2, WB_fwd2;

    //This checks whether the write in MEM/WB touches the register this read wants
    //Also account for rx0, rx1 banking
    assign MEM_fwd0 = EX_mem_hit0 && (!EX_banked0 || MEM_kernelMode == EX_kernel_mode);
    assign WB_fwd0  = EX_wb_hit0  && (!EX_banked0 || WB_kernelMode  == EX_kernel_mode);
    assign MEM_fwd1 = EX_mem_hit1 && (!EX_banked1 || MEM_kernelMode == EX_kernel_mode);
    assign WB_fwd1  = EX_wb_hit1  && (!EX_banked1 || WB_kernelMode  == EX_kernel_mode);
    assign MEM_fwd2 = EX_mem_hit2 && (!EX_banked2 || MEM_kernelMode == EX_kernel_mode);
    assign WB_fwd2  = EX_wb_hit2  && (!EX_banked2 || WB_kernelMode  == EX_kernel_mode);

    //Just snuck up in here, so it previosely just zero extended fragmented registers
    //Now if opcode is one of where its vital, we just sign extend it,
    //precisely that fixed: SRA and SDIV


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
    assign ID_wb_hit0 = wb_writes_array && (WB_gpr_dest[7:3] == ID_rx0[7:3]);
    assign ID_wb_hit1 = wb_writes_array && (WB_gpr_dest[7:3] == ID_rx1[7:3]);
    assign ID_wb_hit2 = wb_writes_array && (WB_gpr_dest[7:3] == rr2_sel);

    //Do once
    logic [31:0] WB_val_aligned;
    assign WB_val_aligned = fwd_align(WB_gpr_dest[2:0], WB_val);

    //Apply several times
    always_comb begin
        for (integer lane = 0; lane < 4; lane++) begin
            ID_rx0_val[8*lane +: 8] = (ID_wb_hit0 && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : GPRs_data_out0[8*lane +: 8];
            ID_rx1_val[8*lane +: 8] = (ID_wb_hit1 && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : GPRs_data_out1[8*lane +: 8];
            ID_rx2_val[8*lane +: 8] = (ID_wb_hit2 && WB_lanes[lane]) ? WB_val_aligned[8*lane +: 8] : GPRs_data_out2[8*lane +: 8];
        end
    end

    //So at ID we don't know if instruction should be executed in kernel mode
    //yet, so we always just get the KGPRs and then in EX deduce whether we
    //use GPRs or KGPRs
    logic [31:0] EX_gpr0, EX_gpr1, EX_gpr2;
    assign EX_gpr0 = EX_rx0_val;
    assign EX_gpr1 = EX_rx1_val;
    assign EX_gpr2 = EX_rx2_val;


    //Here automatic comes in play, function gets called more than ones in
    //always_comb block so its neccessery
    //writing to exact lanes of fragmented registers
    logic [1:0] rel_full;
    always_comb begin
        for (int lane = 0; lane < 4; lane++) begin
            //This notation is pretty scary but its just 8 subsequent bits
            //after 8*lane
            rel_full = 2'(lane) - MEM_base;
            if (MEM_fwd1 && MEM_lanes[lane])     FWD_rx1_full[8*lane +: 8] = MEM_result[8*rel_full +: 8];
            else if (WB_fwd1 && WB_lanes[lane])  FWD_rx1_full[8*lane +: 8] = WB_aligned[8*lane +: 8];
            else                              FWD_rx1_full[8*lane +: 8] = EX_gpr1[8*lane +: 8];
        end
    end

    logic [1:0] pick0, pick1, pick2;
    logic [1:0] rel0, rel1, rel2;
    always_comb begin
        for (int b = 0; b < 4; b++) begin
            pick0 = EX_pick0[2*b +: 2];
            rel0  = pick0 - MEM_base;
            pick1 = EX_pick1[2*b +: 2];
            rel1  = pick1 - MEM_base;
            pick2 = EX_pick2[2*b +: 2];
            rel2  = pick2 - MEM_base;

            if (!EX_keep0[b])                        FWD_rx0[8*b +: 8] = 8'h0;
            else if (MEM_fwd0 && MEM_lanes[pick0])   FWD_rx0[8*b +: 8] = MEM_result[8*rel0 +: 8];
            else if (WB_fwd0 && WB_lanes[pick0])     FWD_rx0[8*b +: 8] = WB_aligned[8*pick0 +: 8];
            else                                     FWD_rx0[8*b +: 8] = EX_gpr0[8*pick0 +: 8];

            if (!EX_keep1[b])                        FWD_rx1[8*b +: 8] = 8'h0;
            else if (MEM_fwd1 && MEM_lanes[pick1])   FWD_rx1[8*b +: 8] = MEM_result[8*rel1 +: 8];
            else if (WB_fwd1 && WB_lanes[pick1])     FWD_rx1[8*b +: 8] = WB_aligned[8*pick1 +: 8];
            else                                     FWD_rx1[8*b +: 8] = EX_gpr1[8*pick1 +: 8];

            if (!EX_keep2[b])                        FWD_rxi[8*b +: 8] = 8'h0;
            else if (MEM_fwd2 && MEM_lanes[pick2])   FWD_rxi[8*b +: 8] = MEM_result[8*rel2 +: 8];
            else if (WB_fwd2 && WB_lanes[pick2])     FWD_rxi[8*b +: 8] = WB_aligned[8*pick2 +: 8];
            else                                     FWD_rxi[8*b +: 8] = EX_gpr2[8*pick2 +: 8];
        end
    end

    //Declarations
    logic [31:0] EPC;
    logic [31:0] EX_EPC, MEM_EPC_val;
    logic        MEM_EPC_write;
    assign MEM_EPC_write = isMEM_valid && MEM_EPCWrite;
    assign MEM_EPC_val   = MEM_irq ? MEM_PC : MEM_PCNext;
    assign EX_EPC        = MEM_EPC_write ? MEM_EPC_val : EPC;

    logic  [31:0] SP, GP, KGP, KSP, LR, KScratch;
    logic  [31:0] EX_SP, EX_KSP, EX_GP, EX_KGP, EX_LR;
    assign EX_SP  = MEM_SP_write  ? SPRNext : SP;
    assign EX_KSP = MEM_KSP_write ? SPRNext : KSP;
    assign EX_GP  = MEM_GP_write  ? SPRNext : GP;
    assign EX_KGP = MEM_KGP_write ? SPRNext : KGP;
    assign EX_LR  = MEM_LR_write  ? MEM_LR_val : LR;

    logic [31:0] ActiveSP;
    logic [31:0] ActiveGP;
    assign ActiveSP = EX_kernel_mode ? EX_KSP : EX_SP;
    assign ActiveGP = EX_kernel_mode ? EX_KGP : EX_GP;

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
    logic [31:0] bitwise_result;

    logic [31:0] ram_data_out;

    logic [15:0] mmio_timer_reg;

    logic ZeroDivException;

    logic PCWrite, GPRsWrite;

    logic [3:0] ram_byte_enable;
    logic [31:0] ram_data_in_aligned;

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

    logic [31:0] MDX_idx;
    assign MDX_idx = FWD_rx0 << EX_IR_2[18:17];

    logic [31:0] mdx_addr;
    assign mdx_addr = (LDX_base + EX_mdx_product) + MDX_idx;
    always_comb begin
        unique case (opcode)
            6'b000000: memTarget = (LDX_base + (isEX_mdx ? EX_mdx_product : LDX_imm29)) + (isEX_mdx ? MDX_idx : LDX_idx); //STX/MDX
            6'b100100: memTarget = (ActiveSP - {29'd0, push_pop_bytes}); // PUSH
            6'b100101: memTarget = ActiveSP;                            // POP
            6'b101000,
            6'b101001,
            6'b101101: memTarget = SelectedSPR + sign_ext_imm16;      // SPRLDR/SPRSTR/SPRLEA

            default: begin
                if (opcode[5:4] == 2'b10)
                    memTarget = FWD_rx1 + sign_ext_imm10;
                else
                    memTarget = FWD_rx1;
            end
        endcase
    end
    assign memViolation =   (!MEM_kernelMode && (MEM_memRead || MEM_memWrite) &&
                            ((MEM_memTarget < memBase) ||
                            (33'(MEM_memTarget) >= memEnd)));

    assign spr_target_sel =
        (opcode == 6'b101000 || opcode == 6'b101001 || opcode == 6'b101010 ||
        opcode == 6'b101011 || opcode == 6'b101100 || opcode == 6'b101101) ? EX_IR[17:16] : 2'b00;

    logic [31:0] SelectedSPR;
    always_comb begin
        unique case (spr_target_sel)
            2'b00:   SelectedSPR = ActiveSP;
            2'b01:   SelectedSPR = EX_LR;
            2'b10:   SelectedSPR = ActiveGP;
            default: SelectedSPR = 32'd0; // reserved
        endcase
    end

    logic [31:0] spr_result;
    always_comb begin
        unique case (SPRSrc)
            3'b100:  spr_result = ActiveSP - {29'd0, push_pop_bytes};    // PUSH
            3'b101:  spr_result = ActiveSP + {29'd0, push_pop_bytes};     // POP
            3'b110:  spr_result = SelectedSPR + FWD_rx0 + sign_ext_imm16; // SPRADD
            3'b111:  spr_result = SelectedSPR - FWD_rx0 - sign_ext_imm16; // SPRSUB
            default: spr_result = SelectedSPR;
        endcase
    end

    //Muxes
    assign AluMuxX = FWD_rx0;

    always_comb begin
        unique case (opcode)
            6'b000001,
            6'b000011,
            6'b000111,
            6'b000101,
            6'b001001,
            6'b001011:
                AluMuxY = FWD_rx1;

            default:   AluMuxY = FWD_rx1 + zero_ext_imm10; // 2-operand logic
        endcase
    end

    always_comb begin
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
    end

    assign MEM_activeSP = MEM_kernelMode ? KSP : SP;
    assign MEM_activeGP = MEM_kernelMode ? KGP : GP;

    always_comb begin
        unique case (MEM_spr_target_sel)
            2'b00:   MEM_SelectedSPR = MEM_activeSP;
            2'b01:   MEM_SelectedSPR = LR;
            2'b10:   MEM_SelectedSPR = MEM_activeGP;
            default: MEM_SelectedSPR = 32'd0;
        endcase
    end

    always_comb begin
        unique case (MEM_SPRSrc)
            3'b000:  SPRNext = MEM_SelectedSPR;                        // hold
            3'b011:  SPRNext = MEM_rx0_val;                            // SPRSET
            3'b100:  SPRNext = MEM_spr_result; // PUSH
            3'b101:  SPRNext = MEM_spr_result; // POP
            3'b110:  SPRNext = MEM_spr_result; // SPRADD
            3'b111:  SPRNext = MEM_spr_result; // SPRSUB
            default: SPRNext = MEM_SelectedSPR;
        endcase
    end

    //This does look kinda scary but trust me its just SPRs write and banking
    logic  MEM_SP_write, MEM_KSP_write, MEM_GP_write, MEM_KGP_write, MEM_LR_write;
    logic [31:0] MEM_LR_val;
    assign MEM_SP_write  = isMEM_valid && MEM_SPRWrite && (MEM_spr_target_sel == 2'b00) && !MEM_kernelMode;
    assign MEM_KSP_write = isMEM_valid && MEM_SPRWrite && (MEM_spr_target_sel == 2'b00) &&  MEM_kernelMode;
    assign MEM_GP_write  = isMEM_valid && MEM_SPRWrite && (MEM_spr_target_sel == 2'b10) && !MEM_kernelMode;
    assign MEM_KGP_write = isMEM_valid && MEM_SPRWrite && (MEM_spr_target_sel == 2'b10) &&  MEM_kernelMode;
    assign MEM_LR_write  = isMEM_valid && (MEM_is_call || (MEM_SPRWrite && (MEM_spr_target_sel == 2'b01)));
    assign MEM_LR_val    = MEM_is_call ? MEM_PCNext : SPRNext;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            SP <= 32'h03FFFFF0;
            KSP <= 32'h000000FC;
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

            if (MEM_fault) begin
                EPC <= MEM_PC;
            end else begin
                if (isMEM_valid && !mem_stall) begin //Its now MEM bounded because, again, mode switch happens in MEM
                    if (MEM_EPCWrite) EPC <= MEM_irq ? MEM_PC : MEM_PCNext;

                    if (MEM_is_call) begin
                        LR <= MEM_PCNext;
                    end

                    if (MEM_SPRWrite) begin
                        unique case (MEM_spr_target_sel)
                            2'b00: begin
                                if (MEM_kernelMode) KSP <= SPRNext;
                                else SP <= SPRNext;
                            end
                            2'b01: LR <= SPRNext;
                            2'b10: begin
                                if (MEM_kernelMode) KGP <= SPRNext;
                                else GP <= SPRNext;
                            end
                            default: ; // reserved for later
                        endcase
                    end
                end

                if (isMEM_valid && !mem_stall) begin //Moved to MEM from EX
                    if (MEM_memWrite && MEM_mmio_cs && MEM_kernelMode) begin
                        unique case (MEM_memTarget[7:0])
                            8'h04: mmio_timer_reg <= MEM_rx0_val[15:0];
                            8'h08: memBase        <= MEM_rx0_val;
                            8'h0C: memLimit       <= MEM_rx0_val;
                            8'h10: EPC            <= MEM_rx0_val;
                            8'h14: SP             <= MEM_rx0_val;
                            8'h18: KSP            <= MEM_rx0_val;
                            8'h1C: KScratch       <= MEM_rx0_val;
                            default: ;
                        endcase
                    end
                end
            end
        end
    end

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
        MEM_ram_cs  = 0;
        MEM_vram_cs = 0;

        if (MEM_memTarget[31:26] == 6'b0) begin //A little optimizations
            MEM_ram_cs = 1;
        end
        else if (MEM_memTarget[31:20] == 12'h040) begin
            MEM_vram_cs = 1;
        end
        //Else memFault, not really actually its either IO_cs or memFault,
        //I moved IO_cs to MEM because it doesn't really gate anything earlier,
        //so its fine in MEM, whilst its a lil more complicated for others,
        //and they aren't even in critical path so it doesn't matter anyway.
    end

    //Might be a little too much for just 1 instruction, but hey as long as
    //it doesn't touch critical path - it doesn't matter. I can also reuse it
    //If I ever want to make more 4reads instructions
    logic [2:0] store_frag;
    logic [31:0] store_val;
    assign store_frag = isEX_mdsx ? EX_IR_2[21:19] : rx0[2:0];
    assign store_val  = isEX_mdsx ? mdsx_data      : FWD_rx0;

    always_comb begin
        unique case (store_frag)
            3'b011, 3'b100, 3'b101, 3'b110: begin // 8-bit
                ram_byte_enable = 4'b0001;
                ram_data_in_aligned = {24'h0, store_val[7:0]};
            end
            3'b001, 3'b010: begin // 16-bit
                ram_byte_enable = 4'b0011;
                ram_data_in_aligned = {16'h0, store_val[15:0]};
            end
            default: begin // 32-bit
                ram_byte_enable = 4'b1111;
                ram_data_in_aligned = store_val;
            end
        endcase
    end

    logic [31:0] io_data_out;
    always_comb begin
        unique case (MEM_memTarget[7:0]) //Upper 24bits are checked by chip select, this is just LUT optimization
            8'h00: io_data_out = {24'd0, ENC_10K_KeyIn};
            8'h04: io_data_out = {31'd0, mod_state};
            8'h08: io_data_out = {16'd0, mmio_timer_reg};
            8'h14: io_data_out = SP;
            8'h18: io_data_out = KSP;
            8'h1C: io_data_out = KScratch;
            8'h20: io_data_out = MEM_activeSP;
            8'h24: io_data_out = LR;
            default:      io_data_out = 32'd0;
        endcase
    end

    //No 3'b001 arm anymore, MEM fixes the load in one cycle later
    always_comb begin
        unique case (result_sel)
            3'd0: GPRs_data_in = add_result; //self expanotory
            3'd1: GPRs_data_in = bitwise_result;
            3'd2: GPRs_data_in = shift_result;
            3'd3: GPRs_data_in = div_result;
            3'd4: GPRs_data_in = sign_ext_imm18;
            3'd5: GPRs_data_in = isEX_mdx ? mdx_addr : SelectedSPR + sign_ext_imm16; //MDCX/SPRLEA
            3'd6: GPRs_data_in = EX_IR_2;
            3'd7: GPRs_data_in = rng_result;
        endcase
    end

    CU control_unit (
        .clk(clk),
        .reset(reset),
        .opcode(opcode),
        .op_64(op_64),
        .mmio_timer_reg(mmio_timer_reg),
        .current_kernel_mode(EX_kernel_mode),
        .key_in(ENC_10K_KeyIn),
        .isEX_valid(isEX_valid), //Split the check in 2
        .timer_interrupt_commit(isMEM_valid && MEM_irq_timer),
        .key_interrupt_commit(isMEM_valid && MEM_irq_key),
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
        .y(AluMuxY),
        .opcode(opcode),
        .imm2(alu_imm2),
        .mul_y_in(mul_y_in),
        .x_fragment(rx0[2:0]),
        .y_fragment(rx1[2:0]),
        .isDiv_valid(isEX_valid), //Not demolish bc it has a long of irrelivant data that just slows it dow
        .mem_stall(mem_stall),
        .shift_amount(shift_amount),

        .add_result(add_result),
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
        //Again - read in ID
        .rr0(ID_rx0[7:3]),
        .rr1(ID_rx1[7:3]), //Natevily base
        .rr2(rr2_sel), //Index selector
        .rw0(WB_gpr_dest),
        .data_in(WB_val),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1),
        .data_out2(GPRs_data_out2),
        .KGPR0(KGPR0),
        .KGPR1(KGPR1)
    );

    RAM system_ram (
        .clk(clk),
        .addrRead(mem_stall ? MEM_memTarget : memTarget), //If mem_stall it reads MEM's instruction not EX's
        .addrWrite(MEM_memTarget), //Writes happen in MEM
        .data_in(MEM_ram_data_in),
        .byte_enable(MEM_ram_byte_enable),
        .mem_write(MEM_memWrite && !memViolation && MEM_ram_cs && isMEM_valid && mem_ready),
        .mem_read(mem_stall ? MEM_memRead : memRead), //Same thing
        .data_out(ram_data_out),

        .instr_address(IF_PC),
        .instr_data_out(instr_fetch_duo)
    );

    VRAM system_vram (
        .clk(clk),
        .addrRead(mem_stall ? MEM_vram_addr : ({12'b0, memTarget[19:0]})), //memTarget - 0x04000000 but much faster
        .addrWrite(vram_addr),
        .data_in(vram_data_out),
        .byte_enable(MEM_ram_byte_enable),
        .mem_write(vram_write),
        .mem_read(mem_stall ? MEM_memRead : memRead),
        .data_out(vram_data_read)
    );

    //I would have kept it in the file include, but sim_main(and debug) requires them and
    //it doesn't matte tbh
    assign vram_addr     = MEM_vram_addr;
    assign vram_data_out = MEM_ram_data_in;
    assign vram_write    = MEM_memWrite && MEM_vram_cs && isMEM_valid && mem_ready;

endmodule
