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
    //3 cycles per instruction to 5
    //====//

    logic  demolish;   //Removes current instructions on the branch misprediction/branch
    logic  stall;     //Stalls on branch
    logic  bubble;   //for handling load-use hazard
    logic  [31:0] PC_target;

    assign demolish  =  isEX_valid &&
                        ((PCWrite &&
                        !(opcode == 6'b111111 || opcode == 6'b111000) &&
                        !((opcode == 6'b010000 || opcode == 6'b111101) && (EX_early_target == PCNext)) &&
                        !(is_EX_cond_branch && EX_predicted_taken)) ||
                        (is_EX_cond_branch && (EX_predicted_taken != was_branch_taken)));

    assign stall     = 0;
    assign bubble    = 0;
    assign PC_target = (is_EX_cond_branch && EX_predicted_taken && !PCWrite) ? (EX_PC + 32'd4) : PCNext;

    //== IF(Instruction Fetch) ==//
    logic [31:0] IF_PC;
    logic [31:0] IF_PC_plus4;

    assign IF_PC_plus4 = IF_PC + 32'h4;  //Computing it here dynamically

    logic [31:0] IF_PC_next;
    assign IF_PC_next = (instr_fetch_data[31:26]==6'b111111 || instr_fetch_data[31:26]==6'b111000 || instr_fetch_data[31:26]==6'b010000 || instr_fetch_data[31:26]==6'b111101 || IF_predicted_taken) ? IF_redirect_target : IF_PC_plus4;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) IF_PC <= 32'h0;
        else if(demolish) IF_PC <= PC_target;
        else if(!stall) IF_PC <= IF_PC_next;
        else IF_PC <= IF_PC; //I just can't omit it
    end

    logic [31:0] instr_fetch_data; //from RAM's dedicated instruction port

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
    assign IF_redirect_target =
        (IF_op == 6'b111101) ? EPC :                          // RETU
        (IF_op == 6'b010000) ? LR  :                          // RET
        (IF_op == 6'b111111 || IF_op == 6'b111000) ?          // JMP / CALL
            {4'b0, instr_fetch_data[25:0], 2'b00} :           // absolute 28-bit
        (IF_PC + 32'd4 +                                      // cond branch, still PC-rel but not for long
            {{6{instr_fetch_data[25]}}, instr_fetch_data[25:0]});

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

    //PHT - pattern history table 1KB of BRAM. It actually doesn't store
    //saturing counters for each branch, it just stores saturating counters
    //without any inherit meaning associated with them.
    logic [1:0] PHT [0:4095];

    //GHR - Global history register 12 bits because its just enough to address
    //all 1KB
    logic [11:0] GHR;

    logic [11:0] pht_read_idx;
    //Last 12 bits of imm26 13:2 because last two bits are always 0 since labels are 4 byte aligned
    //IF_PC_next because BRAM read happens on the next clock cycle to the request
    assign pht_read_idx = IF_PC_next[13:2] ^ GHR;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0] pht_out; //Actual counter for particular branch, only lowest bit isn't really read
    /* verilator lint_off UNUSEDSIGNAL */
    always_ff @(posedge clk) begin
        pht_out <= PHT[pht_read_idx];
    end

    logic  is_IF_cond_branch;
    assign is_IF_cond_branch =  (instr_fetch_data[31:26] == 6'b110101) || (instr_fetch_data[31:26] == 6'b110011) ||
                                (instr_fetch_data[31:26] == 6'b110110) || (instr_fetch_data[31:26] == 6'b110001) ||
                                (instr_fetch_data[31:26] == 6'b111100) || (instr_fetch_data[31:26] == 6'b110100) ||
                                (instr_fetch_data[31:26] == 6'b111001) || (instr_fetch_data[31:26] == 6'b110010) ||
                                (instr_fetch_data[31:26] == 6'b111011) || (instr_fetch_data[31:26] == 6'b111010)  ;

    logic  is_EX_cond_branch;
    assign is_EX_cond_branch =  (opcode==6'b110101)||(opcode==6'b110011)||(opcode==6'b110110)||(opcode==6'b110001)||
                                (opcode==6'b111100)||(opcode==6'b110100)||(opcode==6'b111001)||(opcode==6'b110010)||
                                (opcode==6'b111011)||(opcode==6'b111010);

    //We gotta check whether branch was actually taken or not
    logic  was_branch_taken;
    assign was_branch_taken = PCWrite && (PCSrc == 4'b0000);

    //Simple table:
    //00 || 01 - predict not taken
    //10 || 11 - predict taken
    logic  IF_predicted_taken;
    assign IF_predicted_taken = is_IF_cond_branch && pht_out[1];

    function automatic [1:0] updated_pht(input [1:0] prev_pht, input taken);
        if (taken) begin
            updated_pht = (prev_pht == 2'b11) ? 2'b11 : prev_pht + 2'b01;
        end else begin
            updated_pht = (prev_pht == 2'b00) ? 2'b00 : prev_pht - 2'b01;
        end
    endfunction

    logic [11:0] pht_idx_r;
    always_ff @(posedge clk) begin
        pht_idx_r <= pht_read_idx;
    end

    //This all coming together
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            GHR <= 12'b0;
            //Default is weakly taken simply because branches are usually taken
            //then not, though if particular one isn't its just 1 time calibration
            for (integer i = 0; i < 4096; i = i + 1) PHT[i] <= 2'b10;
        end else if (isEX_valid && is_EX_cond_branch) begin
            PHT[EX_pht_idx] <= updated_pht(PHT[EX_pht_idx], was_branch_taken);
            GHR <= {GHR[10:0], was_branch_taken};
        end
    end


    //== That looks nice ==//
    //== Anyways ID(Instruction Decode) stage ==//
    logic [31:0] ID_PC, ID_IR; //Each stage gets into own IR and PC
    logic [31:0] ID_early_target;
    logic        isID_valid;
    logic [11:0] ID_pht_idx;
    logic        ID_predicted_taken;

    always_ff @(posedge clk or posedge reset) begin
        if (reset || demolish) begin
            isID_valid <= 0;
        end else if (!stall) begin
            ID_PC <= IF_PC;
            ID_IR <= instr_fetch_data;
            ID_early_target <= IF_redirect_target;
            isID_valid <= 1'b1;
            ID_pht_idx <= pht_idx_r;
            ID_predicted_taken <= IF_predicted_taken;
        end
        //else: stall holds PC and IR as they are
    end

    //We need to compare those registers to EX's ones it case they
    //overlap - stall
    //So the regfile read is moved to the ID, saves up on critical path and ID
    //is almost empty anyways so I might as well fill it as much as possible
    logic [7:0]  ID_rx0, ID_rx1; //Selector
    logic [31:0] ID_rx0_val, ID_rx1_val;
    assign ID_rx0 = ID_IR[25:18];
    assign ID_rx1 = ID_IR[17:10];

    logic ID_wb_hit0, ID_wb_hit1;

    //For later when memory would take actual clock cycles to reach
    /* verilator lint_off UNUSEDSIGNAL */
    logic  load_use_hazard;
    assign load_use_hazard = isEX_valid && memRead && GPRsWrite &&
                          ((gpr_rw0_sel == ID_rx0) || (gpr_rw0_sel == ID_rx1));
    /* verilator lint_on UNUSEDSIGNAL */


    //== EX(Execute) ==//
    //A lot of things happen here, full enum in CU.sv
    logic [31:0] EX_PC, EX_IR;
    logic [31:0] EX_early_target;
    logic [11:0] EX_pht_idx;
    logic [31:0] EX_rx0_val, EX_rx1_val;
    logic EX_predicted_taken;
    logic isEX_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset || demolish || bubble) begin
            isEX_valid <= 0;
        end else begin
            EX_PC <= ID_PC; //Handing instruction to the EX
            EX_IR <= ID_IR;
            EX_rx0_val <= ID_rx0_val;
            EX_rx1_val <= ID_rx1_val;

            EX_early_target <= ID_early_target;
            isEX_valid <= isID_valid;
            EX_pht_idx <= ID_pht_idx;
            EX_predicted_taken <= ID_predicted_taken;
        end
    end

    //====//
    logic [5:0] opcode;
    logic [7:0] rx0, rx1, rx2;
    logic [11:0] immediate;
    logic [31:0] j_imm_signed;

    assign opcode = EX_IR[31:26];
    assign rx0 = EX_IR[25:18];
    assign rx1 = EX_IR[17:10];
    assign rx2 = EX_IR[9:2];
    assign immediate = EX_IR[11:0];
    assign j_imm_signed = {{6{EX_IR[25]}}, EX_IR[25:0]};

    logic [31:0] sign_ext_imm10;
    assign sign_ext_imm10 = { {22{EX_IR[9]}}, EX_IR[9:0] };
    logic [31:0] zero_ext_imm10;
    assign zero_ext_imm10 = {22'h0, EX_IR[9:0]};

    logic [31:0] sign_ext_imm18;
    assign sign_ext_imm18 = { {14{EX_IR[17]}}, EX_IR[17:0] };

    logic [31:0] sign_ext_imm26;
    assign sign_ext_imm26 = { {6{EX_IR[25]}}, EX_IR[25:0] };

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

    //== MEM(memory) ==//
    //Work with memory - load, store
    logic [31:0] MEM_result;
    logic [7:0] MEM_gpr_dest;
    logic       MEM_gpr_write;
    logic       MEM_kernel_mode;
    logic       isMEM_valid;

    logic MEM_is_lomul, MEM_is_himul;
    logic MEM_is_load, MEM_ram_cs, MEM_io_cs, MEM_vram_cs;
    logic [31:0] MEM_io_data;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isMEM_valid <= 0;
        end else begin
            MEM_result      <= GPRs_data_in;
            MEM_gpr_write   <= GPRsWrite;
            MEM_gpr_dest    <= gpr_rw0_sel;
            MEM_kernel_mode <= KernelMode;
            isMEM_valid     <= isEX_valid;
            MEM_is_lomul    <= (opcode == 6'b000111);
            MEM_is_himul    <= (opcode == 6'b001101);

            MEM_is_load     <= (GPRsSrc == 3'b001);
            MEM_ram_cs      <= RAM_cs;
            MEM_io_cs       <= IO_cs;
            MEM_vram_cs     <= VRAM_cs;
            MEM_io_data     <= io_data_out;
        end
    end

    logic [31:0] mem_read_data;
    always_comb begin
        if (MEM_ram_cs)
            mem_read_data = ram_data_out;
        else if (MEM_io_cs)
            mem_read_data = MEM_io_data;
        else if (MEM_vram_cs)
            mem_read_data = vram_data_read;
        else
            mem_read_data = 32'd0;
    end

    //Specifically for mul, actually no - not anymore for loads too
    logic [31:0] MEM_val;
    always_comb begin
        if (MEM_is_lomul)
            MEM_val = mul_product[31:0];
        else if (MEM_is_himul)
            MEM_val = mul_product[63:32];
        else if (MEM_is_load)
            MEM_val = mem_read_data;
        else
            MEM_val = MEM_result;
    end


    //== WB(WriteBack) ==//
    logic [31:0] WB_result;
    logic [7:0]  WB_gpr_dest;

    logic WB_gpr_write;
    logic WB_kernel_mode;
    logic isWB_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            isWB_valid <= 0;
        end else begin
            WB_result<= MEM_val;
            isWB_valid <= isMEM_valid;
            WB_gpr_dest <= MEM_gpr_dest;
            WB_gpr_write <= MEM_gpr_write;
            WB_kernel_mode <= MEM_kernel_mode;
        end
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
    logic [31:0] FWD_rx0, FWD_rx1;
    logic MEM_fwd0, WB_fwd0, MEM_fwd1, WB_fwd1;

    //This checks whether the write in MEM/WB touches the register this read wants
    //Also account for rx0, rx1 banking
    assign MEM_fwd0 = isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == rx0[7:3]) &&
                      (rx0[7:3] > 5'd1 || MEM_kernel_mode == KernelMode);
    assign WB_fwd0  = isWB_valid  && WB_gpr_write  && (WB_gpr_dest[7:3]  == rx0[7:3]) &&
                      (rx0[7:3] > 5'd1 || WB_kernel_mode  == KernelMode);
    assign MEM_fwd1 = isMEM_valid && MEM_gpr_write && (MEM_gpr_dest[7:3] == rx1[7:3]) &&
                      (rx1[7:3] > 5'd1 || MEM_kernel_mode == KernelMode);
    assign WB_fwd1  = isWB_valid  && WB_gpr_write  && (WB_gpr_dest[7:3]  == rx1[7:3]) &&
                      (rx1[7:3] > 5'd1 || WB_kernel_mode  == KernelMode);


    //So yeah this is just verilator function, they are automatic because it
    //means that each call gets its own unique set of argumenst, like in
    //regular C stack allocation, regularly though, it gives everyone the same
    //argumetns. Best thing is that it costs nothing in hardware
    function automatic [31:0] fwd_merge(input [2:0] off, input [31:0] old, input [31:0] val);
        unique case (off)
            3'b001:  fwd_merge = {old[31:16], val[15:0]};             //ry0
            3'b010:  fwd_merge = {val[15:0],  old[15:0]};             //ry1
            3'b011:  fwd_merge = {old[31:8],  val[7:0]};              //rz0
            3'b100:  fwd_merge = {old[31:16], val[7:0], old[7:0]};    //rz1
            3'b101:  fwd_merge = {old[31:24], val[7:0], old[15:0]};   //rz2
            3'b110:  fwd_merge = {val[7:0],   old[23:0]};             //rz3
            default: fwd_merge = val;                                 //rx
        endcase
    endfunction

    function automatic [31:0] fwd_slice(input [2:0] off, input [31:0] v);
        unique case (off)
            3'b001:  fwd_slice = {16'h0000, v[15:0]};
            3'b010:  fwd_slice = {16'h0000, v[31:16]};
            3'b011:  fwd_slice = {24'h000000, v[7:0]};
            3'b100:  fwd_slice = {24'h000000, v[15:8]};
            3'b101:  fwd_slice = {24'h000000, v[23:16]};
            3'b110:  fwd_slice = {24'h000000, v[31:24]};
            default: fwd_slice = v;
        endcase
    endfunction

    //Reading one cycle earier - introduces the similar hazard to when it was
    //in EX just gotta expand on that 1 cycle more.
    logic  wb_writes_array;
    assign wb_writes_array = isWB_valid && WB_gpr_write &&
                             !(WB_gpr_dest[7:3] <= 5'd1 && WB_kernel_mode);
    assign ID_wb_hit0 = wb_writes_array && (WB_gpr_dest[7:3] == ID_rx0[7:3]);
    assign ID_wb_hit1 = wb_writes_array && (WB_gpr_dest[7:3] == ID_rx1[7:3]);

    always_comb begin
        ID_rx0_val = ID_wb_hit0 ? fwd_merge(WB_gpr_dest[2:0], GPRs_data_out0, WB_result) : GPRs_data_out0;
        ID_rx1_val = ID_wb_hit1 ? fwd_merge(WB_gpr_dest[2:0], GPRs_data_out1, WB_result) : GPRs_data_out1;
    end

    //So at ID we don't know if instruction should be executed in kernel mode
    //yet, so we always just get the KGPRs and then in EX deduce whether we
    //use GPRs or KGPRs
    logic [31:0] EX_gpr0, EX_gpr1;
    assign EX_gpr0 = (rx0[7:3] <= 5'd1 && KernelMode) ? (rx0[3] ? KGPR1 : KGPR0) : EX_rx0_val;
    assign EX_gpr1 = (rx1[7:3] <= 5'd1 && KernelMode) ? (rx1[3] ? KGPR1 : KGPR0) : EX_rx1_val;


    //Here automatic comes in play, function gets called more than ones in
    //always_comb block so its neccessery
    always_comb begin
        FWD_rx0 = EX_gpr0;
        if (WB_fwd0)  FWD_rx0 = fwd_merge(WB_gpr_dest[2:0],  FWD_rx0, WB_result);
        if (MEM_fwd0) FWD_rx0 = fwd_merge(MEM_gpr_dest[2:0], FWD_rx0, MEM_val);
        FWD_rx0 = fwd_slice(rx0[2:0], FWD_rx0);
    end

    always_comb begin
        FWD_rx1 = EX_gpr1;
        if (WB_fwd1)  FWD_rx1 = fwd_merge(WB_gpr_dest[2:0],  FWD_rx1, WB_result);
        if (MEM_fwd1) FWD_rx1 = fwd_merge(MEM_gpr_dest[2:0], FWD_rx1, MEM_val);
        FWD_rx1 = fwd_slice(rx1[2:0], FWD_rx1);
    end

    //Declarations
    logic [31:0] EPC;

    logic [31:0] SP, GP, KGP, KSP, LR, KScratch;
    logic [31:0] ActiveSP;
    logic [31:0] ActiveGP;
    assign ActiveSP = KernelMode ? KSP : SP;
    assign ActiveGP = KernelMode ? KGP : GP;

    logic [31:0] PCNext;
    logic [31:0] SPRNext;

    logic memRead, memWrite;
    logic SPRWrite;
    logic memViolation;
    logic isCallState;
    logic [31:0] memBase;
    logic [31:0] memLimit;
    logic [31:0] memTarget;
    logic [1:0] spr_target_sel;

    logic aluSrcX;
    logic [1:0] aluSrcY;
    logic [3:0] PCSrc;
    logic [2:0] GPRsSrc;
    logic [2:0] SPRSrc;

    logic KernelMode;
    logic EPCWrite;
    logic isKernelMode;
    logic mod_state;

    logic [31:0] GPRs_data_out0, GPRs_data_out1;
    logic [31:0] KGPR0, KGPR1;
    logic [31:0] GPRs_data_in;
    logic [7:0]  gpr_rw0_sel;

    logic [31:0] AluMuxX;
    logic [31:0] AluMuxY;
    logic [31:0] AluResult;
    logic [63:0] mul_product;
    logic [1:0] aluOpSel;
    logic [5:0] AluOpcode;
    logic flagsWrite;
    logic OverflowFlag, NegativeFlag, ZeroFlag, CarryFlag;
    logic [3:0] compactedFlags;

    logic [31:0] ram_data_out;

    logic RAM_cs; //Chip select
    logic VRAM_cs;
    logic IO_cs;
    logic [15:0] mmio_timer_reg;

    logic ZeroDivException;

    logic PCWrite, GPRsWrite;

    logic [3:0] ram_byte_enable;
    logic [31:0] ram_data_in_aligned;

    assign gpr_rw0_sel = (opcode == 6'b011111) ? (8'd31 << 3) : //LMA rx31
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

    always_comb begin
        unique case (opcode)
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

    assign memViolation = (!KernelMode && (memRead || memWrite) &&
                         ((memTarget < memBase) ||
                          (33'(memTarget) >= (33'(memBase) + 33'(memLimit)))));

    assign spr_target_sel =
        (opcode == 6'b101000 || opcode == 6'b101001 || opcode == 6'b101010 ||
        opcode == 6'b101011 || opcode == 6'b101100 || opcode == 6'b101101) ? EX_IR[17:16] : 2'b00;

    logic [31:0] SelectedSPR;
    always_comb begin
        unique case (spr_target_sel)
            2'b00:   SelectedSPR = ActiveSP;
            2'b01:   SelectedSPR = LR;
            2'b10:   SelectedSPR = ActiveGP;
            default: SelectedSPR = 32'd0; // reserved
        endcase
    end

    //Muxes
    assign AluMuxX = (aluSrcX == 1'b1) ? (EX_PC + 32'd4) : FWD_rx0;

    always_comb begin
        unique case (aluSrcY)
            2'b00: AluMuxY = 32'd4;

            2'b01: begin
                unique case (opcode)
                    6'b000001,
                    6'b000011,
                    6'b000111,
                    6'b000101,
                    6'b001001,
                    6'b001011:
                        AluMuxY = FWD_rx1 + sign_ext_imm2;

                    default:   AluMuxY = FWD_rx1 + zero_ext_imm10; // 2-operand logic
                endcase
            end

            2'b10: AluMuxY = j_imm_signed;
            2'b11: AluMuxY = { {20{immediate[11]}}, immediate };

            default: AluMuxY = FWD_rx1;
        endcase
    end

    always_comb begin
        unique case (PCSrc)
            4'b0000: PCNext = EX_early_target;
            4'b0001: PCNext = EX_early_target;
            4'b0011: PCNext = EPC;          // RETU
            4'b0101: PCNext = LR;           // RET
            4'b0010: PCNext = 32'h00000064; // Syscall Vector
            4'b0100: PCNext = 32'h00000068; // Timer Vector
            4'b1000: PCNext = 32'h0000006C; // Key Interrupt Vector
            4'b0110: PCNext = 32'h00000070; // Memory Protection Fault Vector
            4'b0111: PCNext = FWD_rx0; // JR
            default: PCNext = EX_early_target;
        endcase
        if (ZeroDivException) begin
            PCNext = 32'h00000074;
        end
    end

    always_comb begin
        unique case (SPRSrc)
            3'b000:  SPRNext = SelectedSPR;                        // hold
            3'b011:  SPRNext = FWD_rx0;                            // SPRSET
            3'b100:  SPRNext = ActiveSP - {29'd0, push_pop_bytes}; // PUSH
            3'b101:  SPRNext = ActiveSP + {29'd0, push_pop_bytes}; // POP
            3'b110:  SPRNext = SelectedSPR + (FWD_rx0 + sign_ext_imm16); // SPRADD
            3'b111:  SPRNext = SelectedSPR - (FWD_rx0 + sign_ext_imm16); // SPRSUB
            default: SPRNext = SelectedSPR;
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            KernelMode <= 0;
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

            compactedFlags <= 4'b0000;
        end else begin
            mod_state <= ENC_10K_ModArr;

            if (isEX_valid) begin
                if (EPCWrite) EPC <= EX_PC + 32'd4;
                if (flagsWrite) compactedFlags <= {CarryFlag, NegativeFlag, OverflowFlag, ZeroFlag};
                KernelMode <= isKernelMode;

                if (isCallState && opcode == 6'b111000) begin
                    LR <= EX_PC + 32'd4;
                end

                if (SPRWrite) begin
                    unique case (spr_target_sel)
                        2'b00: begin
                            if (KernelMode) KSP <= SPRNext;
                            else SP <= SPRNext;
                        end
                        2'b01: LR <= SPRNext;
                        2'b10: begin
                            if (KernelMode) KGP <= SPRNext;
                            else GP <= SPRNext;
                        end
                        default: ; // reserved for later
                    endcase
                end

                if (memWrite && IO_cs && KernelMode) begin
                    unique case (memTarget)
                        32'hFFFFFF04: mmio_timer_reg <= FWD_rx0[15:0];
                        32'hFFFFFF08: memBase        <= FWD_rx0;
                        32'hFFFFFF0C: memLimit       <= FWD_rx0;
                        32'hFFFFFF10: EPC            <= FWD_rx0;
                        32'hFFFFFF14: SP             <= FWD_rx0;
                        32'hFFFFFF18: KSP            <= FWD_rx0;
                        32'hFFFFFF1C: KScratch       <= FWD_rx0;
                        default: ;
                    endcase
                end
            end
        end
    end

    always_comb begin
        unique case (aluOpSel)
            2'b00: AluOpcode = 6'b000001; // PC + 4
            2'b01: AluOpcode = 6'b000011; // Sub for cmp
            2'b10: AluOpcode = opcode;    // IR opcode for regular ALUs

            default: AluOpcode = 6'b000001;
        endcase
    end

    // Address Map:
    // 64MB System RAM : 0x00000000 - 0x03FFFFFF
    // 1MB VRAM        : 0x04000000 - 0x040FFFFF
    // MMIO Registers  : I/O stuff
    always_comb begin
        RAM_cs  = 0;
        VRAM_cs = 0;
        IO_cs   = 0;

        if (memTarget <= 32'h03FFFFFF) begin
            RAM_cs = 1;
        end
        else if (memTarget >= 32'h04000000 && memTarget <= 32'h040FFFFF) begin
            VRAM_cs = 1;
        end
        else if (memTarget >= 32'h04100000 && memTarget <= 32'h041000FF) begin
            IO_cs = 1;
        end
        //Else memFault
    end

    always_comb begin
        unique case (rx0[2:0])
            3'b011, 3'b100, 3'b101, 3'b110: begin // 8-bit
                ram_byte_enable = 4'b0001;
                ram_data_in_aligned = {24'h0, FWD_rx0[7:0]};
            end
            3'b001, 3'b010: begin // 16-bit
                ram_byte_enable = 4'b0011;
                ram_data_in_aligned = {16'h0, FWD_rx0[15:0]};
            end
            default: begin // 32-bit
                ram_byte_enable = 4'b1111;
                ram_data_in_aligned = FWD_rx0;
            end
        endcase
    end

    logic [31:0] io_data_out;
    always_comb begin
        unique case (memTarget)
            32'h04100000: io_data_out = {24'd0, ENC_10K_KeyIn};
            32'h04100004: io_data_out = {31'd0, mod_state};
            32'h04100008: io_data_out = {16'd0, mmio_timer_reg};
            32'h04100014: io_data_out = SP;
            32'h04100018: io_data_out = KSP;
            32'h0410001C: io_data_out = KScratch;
            32'h04100020: io_data_out = ActiveSP;
            32'h04100024: io_data_out = LR;
            default:      io_data_out = 32'd0;
        endcase
    end

    //No 3'b001 arm anymore, MEM fixes the load in one cycle later
    assign GPRs_data_in = (GPRsSrc == 3'b010) ? EX_PC :
                  (GPRsSrc == 3'b011) ? sign_ext_imm18 :
                  (GPRsSrc == 3'b100) ? sign_ext_imm26 :
                  (GPRsSrc == 3'b101) ? memTarget : // SPLEA
                  AluResult;

    CU control_unit (
        .clk(clk),
        .reset(reset),
        .opcode(opcode),
        .flags(compactedFlags),
        .mmio_timer_reg(mmio_timer_reg),
        .current_kernel_mode(KernelMode),
        .memViolation(memViolation),
        .key_in(ENC_10K_KeyIn),
        .isEX_valid(isEX_valid),
        .PCWrite(PCWrite),
        .GPRsWrite(GPRsWrite),
        .EPCWrite(EPCWrite),
        .isKernelMode(isKernelMode),
        .memRead(memRead),
        .memWrite(memWrite),
        .aluSrcX(aluSrcX),
        .aluSrcY(aluSrcY),
        .PCSrc(PCSrc),
        .GPRsSrc(GPRsSrc),
        .aluOpSel(aluOpSel),
        .isCallState(isCallState),
        .flagsWrite(flagsWrite),
        .SPRWrite(SPRWrite),
        .SPRSrc(SPRSrc)
    );

    ALU cpu_alu (
        .clk(clk),
        .x(AluMuxX),
        .y(AluMuxY),
        .opcode(AluOpcode),
        .op_size(rx0[2:0]),

        .result(AluResult),
        .mul_product(mul_product),

        .OverflowFlag(OverflowFlag),
        .CarryFlag(CarryFlag),
        .NegativeFlag(NegativeFlag),
        .ZeroFlag(ZeroFlag),

        .ZeroDivException(ZeroDivException)
    );

    GPRs all_gprs (
        .clk(clk),
        .reset(reset),
        .reg_write(WB_gpr_write && isWB_valid),
        .KernelModeWrite(WB_kernel_mode),
        //offset forced to 000 so these come back as the raw 32bit register,
        //the forwarding block above does the slicing after it merges
        //Again - read in ID
        .rr0(ID_rx0[7:3]),
        .rr1(ID_rx1[7:3]),
        .rw0(WB_gpr_dest),
        .data_in(WB_result),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1),
        .KGPR0(KGPR0),
        .KGPR1(KGPR1)
    );

    RAM system_ram (
        .clk(clk),
        .address(memTarget),
        .data_in(ram_data_in_aligned),
        .byte_enable(ram_byte_enable),
        .mem_write(memWrite && !memViolation && RAM_cs && isEX_valid),
        .mem_read(memRead && !memViolation && RAM_cs),
        .data_out(ram_data_out),

        .instr_address(IF_PC),
        .instr_data_out(instr_fetch_data)
    );
    logic [31:0] vram_data_read;

    VRAM system_vram (
        .clk(clk),
        .address(vram_addr),
        .data_in(ram_data_in_aligned),
        .byte_enable(ram_byte_enable),
        .mem_write(memWrite && VRAM_cs && isEX_valid),
        .mem_read(memRead && VRAM_cs),
        .data_out(vram_data_read)
    );

    assign vram_addr     = memTarget - 32'h04000000;
    assign vram_data_out = FWD_rx0;
    assign vram_write = (memWrite && VRAM_cs && isEX_valid);

endmodule
