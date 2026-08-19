module CORE(
    input logic clk,
    input logic reset,
    input logic [7:0] ENC_10K_KeyIn,
    input logic ENC_10K_ModArr, //for shifts/alts

    output logic [31:0] vram_addr,
    output logic [31:0] vram_data_out,
    output logic vram_write
);

    //Declarations
    logic [31:0] PC, IR;
    logic [31:0] EA;
    logic [31:0] RegX, RegY;
    logic [31:0] EPC;

    logic [31:0] SP, GP, KGP, KSP, LR, KScratch;
    logic [31:0] ActiveSP;
    logic [31:0] ActiveGP;
    assign ActiveSP = KernelMode ? KSP : SP;
    assign ActiveGP = KernelMode ? KGP : GP;

    logic [31:0] PCNext;
    logic [31:0] SPRNext;

    logic [5:0] opcode;
    logic [7:0] rx0;
    logic [7:0] rx1;
    logic [7:0] rx2;
    logic [11:0] immediate;
    logic [31:0] j_imm_signed;

    logic XWrite, YWrite, IRWrite, PCWrite, GPRsWrite, EAWrite;
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
    logic [31:0] sign_ext_imm10;
    assign sign_ext_imm10 = { {22{IR[9]}}, IR[9:0] };
    logic [31:0] zero_ext_imm10;
    assign zero_ext_imm10 = {22'h0, IR[9:0]};

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

    logic [31:0] active_address;

    logic [3:0] ram_byte_enable;
    logic [31:0] ram_data_in_aligned;

    logic [31:0] sign_ext_imm18;
    assign sign_ext_imm18 = { {14{IR[17]}}, IR[17:0] };

    logic [31:0] sign_ext_imm26;
    assign sign_ext_imm26 = { {6{IR[25]}}, IR[25:0] };

    logic [31:0] sign_ext_imm16;
    assign sign_ext_imm16 = { {16{IR[15]}}, IR[15:0] };

    //Is it useless? Absolutely not, imagine it for "for" loops
    logic [31:0] sign_ext_imm2;

    always_comb begin
        unique case (IR[1:0])
            2'b00: sign_ext_imm2 = 32'd0;
            2'b01: sign_ext_imm2 = 32'd1;
            2'b10: sign_ext_imm2 = 32'd2; //Here is a crazy idea for ya 0b10 signed is 2
            2'b11: sign_ext_imm2 = -32'sd1;
        endcase
    end

    //Breaking instruction down
    assign opcode = IR[31:26];
    assign rx0 = IR[25:18];
    assign rx1 = IR[17:10];
    assign rx2 = IR[9:2];
    assign immediate = IR[11:0];
    assign j_imm_signed = {{6{IR[25]}}, IR[25:0]};
    assign gpr_rw0_sel = (opcode == 6'b011111) ? (8'd31 << 3) : //LMA rx31
                //3 register ALU type
                (opcode == 6'b000001 || opcode == 6'b000011 || opcode == 6'b000111 || opcode == 6'b000101 || opcode == 6'b001011 || 001001) ? rx2 :
                rx0;

    logic [2:0] push_pop_bytes;
        always_comb begin
            unique case (rx0[2:0])
                3'b011, 3'b100, 3'b101, 3'b110: push_pop_bytes = 3'd1; // rz - 8-bit
                3'b001, 3'b010:                 push_pop_bytes = 3'd2; // ry - 16-bit
                default:                        push_pop_bytes = 3'd4; // rx - 32-bit
            endcase
        end

    assign active_address = (IRWrite) ? PC : memTarget;

    always_comb begin
        unique case (opcode)
            6'b100100: memTarget = (ActiveSP - {29'd0, push_pop_bytes}); // PUSH
            6'b100101: memTarget = ActiveSP;                            // POP
            6'b101000,
            6'b101001,
            6'b101101: memTarget = SelectedSPR + sign_ext_imm16;      // SPRLDR/SPRSTR/SPRLEA

            default: begin
                if (opcode[5:4] == 2'b10)
                    memTarget = RegY + sign_ext_imm10;
                else
                    memTarget = RegY;
            end
        endcase
    end

    assign memViolation = (!KernelMode && (memRead || memWrite) &&
                         ((active_address < memBase) ||
                          (33'(active_address) >= (33'(memBase) + 33'(memLimit)))));

    assign spr_target_sel =
        (opcode == 6'b101000 || opcode == 6'b101001 || opcode == 6'b101010 ||
        opcode == 6'b101011 || opcode == 6'b101100 || opcode == 6'b101101) ? IR[17:16] : 2'b00;

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
    assign AluMuxX = (aluSrcX == 1'b1) ? PC : RegX;

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
                        AluMuxY = RegY + sign_ext_imm2;

                    default:   AluMuxY = RegY + zero_ext_imm10; // 2-operand logic
                endcase
            end

            2'b10: AluMuxY = j_imm_signed;
            2'b11: AluMuxY = { {20{immediate[11]}}, immediate };

            default: AluMuxY = RegY;
        endcase
    end

    always_comb begin
        unique case (PCSrc)
            4'b0000: PCNext = EA;
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

    //SPRs
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            PC <= 32'd0;
            IR <= 32'd0;
            RegX <= 32'd0;
            RegY <= 32'd0;
            EA <= 32'd0;
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
            if (PCWrite) PC <= PCNext;
            if (IRWrite) IR <= ram_data_out;
            if (XWrite) RegX <= GPRs_data_out0;
            if (YWrite) RegY <= GPRs_data_out1;
            if (EAWrite) EA <= AluResult;
            if (EPCWrite) EPC <= PC;
            if (flagsWrite) compactedFlags <= {CarryFlag, NegativeFlag, OverflowFlag, ZeroFlag};
            KernelMode <= isKernelMode;
            mod_state <= ENC_10K_ModArr;

            if (isCallState && opcode == 6'b111000) begin
                LR <= PC;
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
                    32'hFFFFFF04: mmio_timer_reg <= RegX[15:0];
                    32'hFFFFFF08: memBase        <= RegX;
                    32'hFFFFFF0C: memLimit       <= RegX;
                    32'hFFFFFF10: EPC            <= RegX;
                    32'hFFFFFF14: SP             <= RegX;
                    32'hFFFFFF18: KSP            <= RegX;
                    32'hFFFFFF1C: KScratch       <= RegX;
                    default: ;
                endcase
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

        if (IRWrite) begin
            RAM_cs = 1;
        end
        else begin
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
    end

    always_comb begin
        if (IRWrite) begin
            ram_byte_enable = 4'b1111;
            ram_data_in_aligned = RegX;
        end else begin
            unique case (rx0[2:0])
                3'b011, 3'b100, 3'b101, 3'b110: begin // 8-bit
                    ram_byte_enable = 4'b0001;
                    ram_data_in_aligned = {24'h0, RegX[7:0]};
                end
                3'b001, 3'b010: begin // 16-bit
                    ram_byte_enable = 4'b0011;
                    ram_data_in_aligned = {16'h0, RegX[15:0]};
                end
                default: begin // 32-bit
                    ram_byte_enable = 4'b1111;
                    ram_data_in_aligned = RegX;
                end
            endcase
        end
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
                  (GPRsSrc == 3'b010) ? PC :
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
        .XWrite(XWrite),
        .YWrite(YWrite),
        .key_in(ENC_10K_KeyIn),
        .IRWrite(IRWrite),
        .PCWrite(PCWrite),
        .GPRsWrite(GPRsWrite),
        .EAWrite(EAWrite),
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
        .reg_write(GPRsWrite),
        .KernelMode(KernelMode),
        .rr0(rx0),
        .rr1(rx1),
        .rw0(gpr_rw0_sel),
        .data_in(GPRs_data_in),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1)
    );

    RAM system_ram (
        .clk(clk),
        .address(active_address),
        .data_in(ram_data_in_aligned),
        .byte_enable(ram_byte_enable),
        .mem_write(memWrite && !memViolation && RAM_cs),
        .mem_read(memRead && !memViolation && RAM_cs),
        .data_out(ram_data_out)
    );

    assign vram_addr     = memTarget - 32'h04000000;
    assign vram_data_out = RegX;
    assign vram_write    = (memWrite && VRAM_cs);

endmodule
