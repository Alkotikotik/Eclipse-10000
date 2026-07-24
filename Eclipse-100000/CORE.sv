module CORE(
    input logic clk,
    input logic reset,
    input logic [7:0] ENC_10K_KeyIn,

    output logic [31:0] vram_addr,
    output logic [31:0] vram_data_out,
    output logic vram_write
);

    //Declarations
    logic [31:0] PC, IR;
    logic [31:0] EA;
    logic [31:0] RegX, RegY;
    logic [31:0] EPC;

    logic [31:0] SP, KSP, LR, KScratch;
    logic [31:0] ActiveSP;
    assign ActiveSP = KernelMode ? KSP : SP;

    logic [31:0] PCNext;

    logic [5:0] opcode;
    logic [6:0] rx0;
    logic [6:0] rx1;
    logic [11:0] immediate;
    logic [31:0] j_imm_signed;

    logic XWrite, YWrite, IRWrite, PCWrite, GPRsWrite, EAWrite;
    logic memRead, memWrite;
    logic memViolation;
    logic isCallState;
    logic [31:0] memBase;
    logic [31:0] memLimit;
    logic [31:0] memTarget;

    logic aluSrcX;
    logic [1:0] aluSrcY;
    logic [2:0] PCSrc;
    logic [2:0] GPRsSrc;
    logic [31:0] sign_ext_imm;
    assign sign_ext_imm = { {20{immediate[11]}}, immediate };

    logic KernelMode;
    logic EPCWrite;
    logic isKernelMode;

    logic [31:0] GPRs_data_out0;
    logic [31:0] GPRs_data_out1;
    logic [31:0] GPRs_data_in;
    logic [6:0] gpr_rw0_sel;

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

    logic [31:0] active_address;

    logic [3:0] ram_byte_enable;
    logic [31:0] ram_data_in_aligned;

    logic [21:0] immediate_22;
    assign immediate_22 = IR[21:0];

    logic [31:0] sign_ext_imm22;
    assign sign_ext_imm22 = { {10{immediate_22[21]}}, immediate_22 };

    //Breaking instruction down
    assign opcode = IR[31:26];
    assign rx0 = IR[25:19];
    assign rx1 = IR[18:12];
    assign immediate = IR[11:0];
    assign j_imm_signed = {{6{IR[25]}}, IR[25:0]};
    assign gpr_rw0_sel = (opcode == 6'b011111) ? {IR[25:22], 3'b000} : rx0;

    assign active_address = (IRWrite) ? PC : memTarget;

    assign memTarget = (opcode[5:4] == 2'b10) ? (RegY + sign_ext_imm) : RegY;
    assign memViolation = (!KernelMode && (memRead || memWrite) &&
                          ((active_address < memBase) ||
                          (33'(active_address) >= (33'(memBase) + 33'(memLimit)))));

    //Muxes
    assign AluMuxX = (aluSrcX == 1'b1) ? PC : RegX;

    always_comb begin
        unique case (aluSrcY)
            2'b00: AluMuxY = 32'd4;
            2'b01: AluMuxY = RegY;
            2'b10: AluMuxY = j_imm_signed;
            2'b11: AluMuxY = { {20{immediate[11]}}, immediate };

            default: AluMuxY = RegY;
        endcase
    end

    always_comb begin
        unique case (PCSrc)
            3'b000: PCNext = EA;
            3'b001: PCNext = AluResult;
            3'b010: PCNext = 32'h00000064; // Syscall Vector
            3'b011: PCNext = EPC;          // RETU
            3'b100: PCNext = 32'h00000068; // Timer Vector
            3'b101: PCNext = LR;           // RET
            3'b110: PCNext = 32'h00000070; // Memory Protection Fault Vector
            3'b111: PCNext = GPRs_data_out0; // JR
            default: PCNext = AluResult;
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
            KernelMode <= 1;
            SP  <= 32'h03FFFFFC;
            KSP <= 32'h00000FFC;
            LR  <= 32'd0;
            KScratch <= 32'd0;

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

            if (isCallState && opcode == 6'b111000) begin
                LR <= PC + 32'd4; //Save pc + 4 on call
            end

            if (memWrite && IO_cs && KernelMode) begin
                unique case (memTarget)
                    32'hFFFFFF04: mmio_timer_reg <= RegX[15:0];
                    32'hFFFFFF08: memBase <= RegX;
                    32'hFFFFFF0C: memLimit <= RegX;
                    32'hFFFFFF10: EPC <= RegX;
                    32'hFFFFFF14: SP <= RegX;
                    32'hFFFFFF18: KSP <= RegX;
                    32'hFFFFFF1C: KScratch <= RegX;
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

    //First 2GB(0x00000000 - 0x00000000) - regular RAM
    //Next 1MB(0x80000000 - 0x800FFFFF) - VRAM
    //Then I/O registers
    //Starting with 64MB
    always_comb begin
        RAM_cs = 0;
        VRAM_cs = 0;
        IO_cs = 0;

        if (IRWrite) begin
            RAM_cs = 1;
        end
        else begin
            if (memTarget <= 32'h03FFFFFF) begin
                RAM_cs = 1;
            end 
            else if (memTarget >= 32'h80000000 && memTarget <= 32'h800FFFFF) begin
                VRAM_cs = 1;
            end 
            else if (memTarget >= 32'hFFFFFF00) begin
                IO_cs = 1;
            end
            //Else [Fatal errors: you are cooked buddy]
        end
    end

    always_comb begin
        if (IRWrite) begin
            ram_byte_enable = 4'b1111;
            ram_data_in_aligned = RegX;
        end else begin
            unique case (rx0[2:0])
                3'b011, 3'b100, 3'b101, 3'b110: begin // 8-bit
                    ram_byte_enable = 4'b0001 << memTarget[1:0];
                    ram_data_in_aligned = {4{RegX[7:0]}};
                end
                3'b001, 3'b010: begin // 16-bit
                    ram_byte_enable = 4'b0011 << memTarget[1:0];
                    ram_data_in_aligned = {2{RegX[15:0]}};
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
                32'hFFFFFF00: cpu_mem_data_out = {24'd0, ENC_10K_KeyIn};
                32'hFFFFFF04: cpu_mem_data_out = {16'd0, mmio_timer_reg};
                32'hFFFFFF14: cpu_mem_data_out = SP;
                32'hFFFFFF18: cpu_mem_data_out = KSP;
                32'hFFFFFF1C: cpu_mem_data_out = KScratch;
                32'hFFFFFF20: cpu_mem_data_out = ActiveSP;
                32'hFFFFFF24: cpu_mem_data_out = LR;
                default:      cpu_mem_data_out = 32'd0; 
            endcase
        end else begin
            cpu_mem_data_out = 32'd0; // VRAM read fallback or unmapped space
        end
    end

    assign GPRs_data_in = (GPRsSrc == 3'b001) ? cpu_mem_data_out :
                      (GPRsSrc == 3'b010) ? PC :
                      (GPRsSrc == 3'b011) ? sign_ext_imm :
                      (GPRsSrc == 3'b100) ? sign_ext_imm22 :
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
        .flagsWrite(flagsWrite)
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
        .ZeroFlag(ZeroFlag)
    );

    GPRs all_gprs (
        .clk(clk),
        .reset(reset),
        .reg_write(GPRsWrite),
        .rr0(rx0),
        .rr1(rx1),
        .rw0(gpr_rw0_sel),
        .data_in(GPRs_data_in),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1)
    );

    RAM system_ram (
        .clk(clk),
        .address((IRWrite) ? PC : (opcode[5:4] == 2'b10) ? (RegY + sign_ext_imm) : RegY),
        .data_in(ram_data_in_aligned),
        .byte_enable(ram_byte_enable),
        .mem_write(memWrite && !memViolation && RAM_cs),
        .mem_read(memRead && !memViolation && RAM_cs),
        .data_out(ram_data_out)
    );

    assign vram_addr = memTarget - 32'h80000000;
    assign vram_data_out = RegX;
    assign vram_write = (memWrite && VRAM_cs);

endmodule
