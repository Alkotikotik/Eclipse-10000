module CORE(
    input logic clk,
    input logic reset
);
    
    //Declarations
    logic [31:0] PC, IR;
    logic [31:0] EA;
    logic [31:0] RegX, RegY;

    logic [31:0] PCNext;

    logic [5:0] opcode;
    logic [4:0] rx0;
    logic [4:0] rx1;
    logic [15:0] immediate;

    logic XWrite, YWrite, IRWrite, PCWrite, GPRsWrite, EAWrite;
    logic memRead, memWrite;
    logic aluSrcX;
    logic [1:0] aluSrcY;
    logic PCSrc;
    logic [1:0] GPRsSrc;

    logic [31:0] GPRs_data_out0;
    logic [31:0] GPRs_data_out1;
    logic [31:0] GPRs_data_in;

    logic [31:0] AluMuxX;
    logic [31:0] AluMuxY;
    logic [31:0] AluResult;
    logic [1:0] aluOpSel;
    logic [5:0] AluOpcode;
    logic OverflowFlag, NegativeFlag, ZeroFlag;
    logic [2:0] CompactedFlags;

    logic [31:0] ram_data_out;
    
    //Breaking opcode down
    assign opcode = IR[31:26];
    assign rx0 = IR[25:21];
    assign rx1 = IR[20:16];
    assign immediate = IR[15:0];
    
    //Muxes
    assign AluMuxX = (aluSrcX == 1'b1) ? PC : RegX;
    assign CompactedFlags = {NegativeFlag, OverflowFlag, ZeroFlag};

    always_comb begin
        unique case (aluSrcY)
            2'b00: AluMuxY = 32'd4; 
            2'b01: AluMuxY = RegY; 
            2'b11: AluMuxY = { {16{immediate[15]}}, immediate }; 

            default: AluMuxY = RegY;
        endcase
    end

    assign GPRs_data_in = (GPRsSrc == 2'b01) ? ram_data_out : AluResult;
    assign PCNext = (PCSrc == 1) ? AluResult : EA;
    
    //SPRs
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            PC <= 32'd0;
            IR <= 32'd0;
            RegX <= 32'd0;
            RegY <= 32'd0;
            EA <= 32'd0;
        end else begin
            if (PCWrite) PC <= PCNext;
            if (IRWrite) IR <= ram_data_out;
            if (XWrite) RegX <= GPRs_data_out0;
            if (YWrite) RegY <= GPRs_data_out1;
            if (EAWrite) EA <= AluResult;
        end
    end

    always_comb begin
        unique case (aluOpSel)
            2'b00: AluOpcode = 6'b000001; // Force ADD (for PC+4 or Effective Address calculation)
            2'b01: AluOpcode = 6'b000011; // Force SUB (for PC-relative Branch comparison)
            2'b10: AluOpcode = opcode;    // Use raw Opcode from IR (for actual Instruction Execution)
            default: AluOpcode = 6'b000001;
        endcase
    end
    
    CU control_unit (
        .clk(clk),
        .reset(reset),
        .opcode(opcode),
        .flags(CompactedFlags),
        .XWrite(XWrite),
        .YWrite(YWrite),
        .IRWrite(IRWrite),
        .PCWrite(PCWrite),
        .GPRsWrite(GPRsWrite),
        .EAWrite(EAWrite),
        .memRead(memRead),
        .memWrite(memWrite),
        .aluSrcX(aluSrcX),
        .aluSrcY(aluSrcY),
        .PCSrc(PCSrc),
        .GPRsSrc(GPRsSrc),
        .aluOpSel(aluOpSel)
    );

    ALU cpu_alu (
        .x(AluMuxX),
        .y(AluMuxY),
        .opcode(AluOpcode),
        .result(AluResult),
        .OverflowFlag(OverflowFlag),
        .NegativeFlag(NegativeFlag),
        .ZeroFlag(ZeroFlag)
    );

    GPRs all_gprs (
        .clk(clk),
        .reg_write(GPRsWrite),
        .rr0(rx0),
        .rr1(rx1),
        .rw0(rx0),
        .data_in(GPRs_data_in),
        .data_out0(GPRs_data_out0),
        .data_out1(GPRs_data_out1)
    );

    RAM system_ram (
        .clk(clk),
        .address( (memRead && !memWrite && IRWrite) ? PC : EA ),
        .data_in(GPRs_data_out1),
        .mem_write(memWrite),
        .mem_read(memRead),
        .data_out(ram_data_out)
    );

endmodule
