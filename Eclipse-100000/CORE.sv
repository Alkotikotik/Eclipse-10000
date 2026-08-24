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
    //Pipilined 5 cycle CU, I chose 5 cycles because its perfect balance
    //between clock speed, which is higher because of shorter critical path, and
    //penatly for mispredicted branch which is 2 cycles for regular branches
    //and only 1 for unconditional ones.

    //The estimated CPI is ~=1.25 considering average instruction split
    //obviosely varies by program being executed.
    //That is about 2.5 times faster than my multi-cycle design(~= 2.9CPI) as
    //well as higher estimated clock frequency due to shorter critical path
    //3 cycles per instruction to 2
    //====//

    logic  demolish;   //Removes current instructions on the branch misprediction/branch
    logic  stall;     //Stalls on branch
    logic  bubble;   //for handling load-use hazard
    logic  [31:0] PC_target;

    assign demolish  = 0;
    assign stall     = 0;
    assign bubble    = 0;
    assign PC_target = 32'd0;

    //== IF(Instruction Fetch) ==//
    logic [31:0] IF_PC;
    logic [31:0] IF_PC_plus4;

    assign IF_PC_plus4 = IF_PC + 32'h4;  //Computing it here dynamically

    always_ff @(posedge clk or posedge reset) begin
        if (reset) IF_PC <= 32'h0;
        else if(demolish) IF_PC <= PC_target;
        else if(!stall) IF_PC <= IF_PC_plus4;
        else IF_PC <= IF_PC;
    end

    logic [31:0] instr_fetch_data; //from RAM's dedicated instruction port

    //== That looks nice ==//
    //== Anyways ID(Instruction Decode) stage ==//
    logic [31:0] ID_PC, ID_IR; //Each stage gets into own IR and PC
    logic        isID_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset || demolish) begin
            isID_valid <= 0;
        end else if (!stall) begin
            ID_PC <= IF_PC;
            ID_IR <= instr_fetch_data;
            isID_valid <= 1'b1;
        end
        //else: stall holds PC and IR as they are
    end

    //We need to compare those registers to EX's ones it case they
    //overlap - stall
    logic [7:0] ID_rx0, ID_rx1;
    assign ID_rx0 = ID_IR[25:18];
    assign ID_rx1 = ID_IR[17:10];

    logic load_use_hazard;
    assign load_use_hazard = isEX_valid && memRead && GPRsWrite &&
                          ((gpr_rw0_sel == ID_rx0) || (gpr_rw0_sel == ID_rx1));

    //== EX(Execute) ==//
    //A lot of things happen here, full enum in CU.sv
    logic [31:0] EX_PC, EX_IR;
    logic isEX_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset || demolish || bubble) begin
            isEX_valid <= 0;
        end else begin
            EX_PC <= ID_PC; //Handing instruction to the EX
            EX_IR <= ID_IR;
            isEX_valid <= isID_valid;
        end
    end

    //====//
    logic [5:0] opcode;
    logic [7:0] rx0;
    logic [7:0] rx1;
    logic [7:0] rx2;
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
    //
    logic [31:0] MEM_PC, MEM_result;
    logic [5:0] MEM_opcode;
    logic [7:0] MEM_gpr_dest;
    logic       MEM_gpr_write;
    logic       isMEM_valid;
 
    always_ff @(posedge clk or posedge reset) begin
        if (reset || squash) begin
            isMEM_valid <= 0;
        end else begin
            MEM_PC        <= EX_PC;
            MEM_result    <= GPRs_data_in;
            MEM_opcode    <= opcode;
            MEM_gpr_write <= GPRsWrite;
            MEM_gpr_dest  <= gpr_rw0_sel;
            isMEM_valid   <= isEX_valid;
        end
    end


    //== WB(WriteBack) ==//
    logic [31:0] WB_PC, WB_result;

    logic [5:0] WB_opcode;
    logic [7:0]  WB_gpr_dest;

    logic WB_gpr_write;
    logic isWB_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset || demolish) begin
            isWB_valid <= 0;
        end else begin
            WB_PC   <= MEM_PC;
            WB_result<= MEM_result;
            WB_opcode <= MEM_opcode;
            isWB_valid <= isMEM_valid;
            WB_gpr_dest <= MEM_gpr_dest;
            WB_gpr_write <= MEM_gpr_write;
        end
    end

    //== Forwarding ==//
    //So its a pretty interesting one, if instruction needs result(EX) that hasn't
    //been written to GPRs yet(end of WB), instead of stalling I check for this
    //condition, if its true I just use MEM/WB result, otherwise read from registers
    logic [31:0] FWD_rx0, fwd_rx1;
 
    always_comb begin
        if (isMEM_valid && MEM_gpr_write && (MEM_gpr_dest == rx0))
            FWD_rx0 = MEM_result;
        else if (isWB_valid && WB_gpr_write && (WB_gpr_dest == rx0))
            FWD_rx0 = WB_result;
        else
            FWD_rx0 = GPRs_data_out0;
    end
 
    always_comb begin
        if (isMEM_valid && MEM_gpr_write && (MEM_gpr_dest == rx1))
            FWD_rx1 = MEM_result;
        else if (isWB_valid && WB_gpr_write && (WB_gpr_dest == rx1))
            FWD_rx1 = WB_result;
        else
            FWD_rx1 = GPRs_data_out1;
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

    logic [31:0] GPRs_data_out0;
    logic [31:0] GPRs_data_out1;
    logic [31:0] GPRs_data_in;
    logic [7:0] gpr_rw0_sel;

    logic [31:0] AluMuxX;
    logic [31:0] AluMuxY;
    logic [31:0] AluResult;
    logic [1:0] aluOpSel;
    logic [5:0] AluOpcode;
    logic flagsWrite;
    logic OverflowFlag, NegativeFlag, ZeroFlag, CarryFlag;
    logic [3:0] compactedFlags;

    logic [31:0] ram_data_out;

    logic RAM_cs; //Chip select
    logic VRAM_cs;
    logic IO_cs;
    logic [31:0] cpu_mem_data_out; //unified data output
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
                    memTarget = GPRs_data_out1 + sign_ext_imm10;
                else
                    memTarget = GPRs_data_out1;
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
    assign AluMuxX = (aluSrcX == 1'b1) ? EX_PC : GPRs_data_out0;

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
                        AluMuxY = GPRs_data_out1 + sign_ext_imm2;

                    default:   AluMuxY = GPRs_data_out1 + zero_ext_imm10; // 2-operand logic
                endcase
            end

            2'b10: AluMuxY = j_imm_signed;
            2'b11: AluMuxY = { {20{immediate[11]}}, immediate };

            default: AluMuxY = GPRs_data_out1;
        endcase
    end

    always_comb begin
        unique case (PCSrc)
            4'b0000: PCNext = AluResult;
            4'b0001: PCNext = AluResult;
            4'b0011: PCNext = EPC;          // RETU
            4'b0101: PCNext = LR;           // RET
            4'b0010: PCNext = 32'h00000064; // Syscall Vector
            4'b0100: PCNext = 32'h00000068; // Timer Vector
            4'b1000: PCNext = 32'h0000006C; // Key Interrupt Vector
            4'b0110: PCNext = 32'h00000070; // Memory Protection Fault Vector
            4'b0111: PCNext = GPRs_data_out0; // JR
            default: PCNext = AluResult;
        endcase
        if (ZeroDivException) begin
            PCNext = 32'h00000074;
        end
    end

    always_comb begin
        unique case (SPRSrc)
            3'b000:  SPRNext = SelectedSPR;                        // hold
            3'b011:  SPRNext = GPRs_data_out0;                     // SPRSET
            3'b100:  SPRNext = ActiveSP - {29'd0, push_pop_bytes}; // PUSH
            3'b101:  SPRNext = ActiveSP + {29'd0, push_pop_bytes}; // POP
            3'b110:  SPRNext = SelectedSPR + (GPRs_data_out0 + sign_ext_imm16); // SPRADD
            3'b111:  SPRNext = SelectedSPR - (GPRs_data_out0 + sign_ext_imm16); // SPRSUB
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
                if (EPCWrite) EPC <= EX_PC;
                if (flagsWrite) compactedFlags <= {CarryFlag, NegativeFlag, OverflowFlag, ZeroFlag};
                KernelMode <= isKernelMode;

                if (isCallState && opcode == 6'b111000) begin
                    LR <= EX_PC;
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
                        32'hFFFFFF04: mmio_timer_reg <= GPRs_data_out0[15:0];
                        32'hFFFFFF08: memBase        <= GPRs_data_out0;
                        32'hFFFFFF0C: memLimit       <= GPRs_data_out0;
                        32'hFFFFFF10: EPC            <= GPRs_data_out0;
                        32'hFFFFFF14: SP             <= GPRs_data_out0;
                        32'hFFFFFF18: KSP            <= GPRs_data_out0;
                        32'hFFFFFF1C: KScratch       <= GPRs_data_out0;
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
                ram_data_in_aligned = {24'h0, GPRs_data_out0[7:0]};
            end
            3'b001, 3'b010: begin // 16-bit
                ram_byte_enable = 4'b0011;
                ram_data_in_aligned = {16'h0, GPRs_data_out0[15:0]};
            end
            default: begin // 32-bit
                ram_byte_enable = 4'b1111;
                ram_data_in_aligned = GPRs_data_out0;
            end
        endcase
    end

    always_comb begin
        if (RAM_cs) begin
            cpu_mem_data_out = ram_data_out;
        end else if (IO_cs) begin
            unique case (memTarget)
                32'h04100000: cpu_mem_data_out = {24'd0, ENC_10K_KeyIn};
                32'h04100004: cpu_mem_data_out = {31'd0, mod_state};
                32'h04100008: cpu_mem_data_out = {16'd0, mmio_timer_reg};
                32'h04100014: cpu_mem_data_out = SP;
                32'h04100018: cpu_mem_data_out = KSP;
                32'h0410001C: cpu_mem_data_out = KScratch;
                32'h04100020: cpu_mem_data_out = ActiveSP;
                32'h04100024: cpu_mem_data_out = LR;
                default:      cpu_mem_data_out = 32'd0;
            endcase
        end else begin
            cpu_mem_data_out = 32'd0; //fallback to unmapped space
        end
    end
    assign GPRs_data_in = (GPRsSrc == 3'b001) ? cpu_mem_data_out :
                  (GPRsSrc == 3'b010) ? EX_PC :
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
        .x(AluMuxX),
        .y(AluMuxY),
        .opcode(AluOpcode),
        .op_size(rx0[2:0]),
        .result(AluResult),
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
        .KernelMode(KernelMode),
        .rr0(rx0),
        .rr1(rx1),
        .rw0(WB_gpr_dest),
        .data_in(WB_result),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1)
    );

    RAM system_ram (
        .clk(clk),
        .address(memTarget),
        .data_in(ram_data_in_aligned),
        .byte_enable(ram_byte_enable),
        .mem_write(memWrite && !memViolation && RAM_cs),
        .mem_read(memRead && !memViolation && RAM_cs),
        .data_out(ram_data_out),

        .instr_address(IF_PC),
        .instr_data_out(instr_fetch_data)
    );

    assign vram_addr     = memTarget - 32'h04000000;
    assign vram_data_out = GPRs_data_out0;
    assign vram_write    = (memWrite && VRAM_cs);

endmodule
