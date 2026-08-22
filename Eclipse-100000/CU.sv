module CU(
    input logic clk,
    input logic reset,

    input logic [5:0] opcode,

    input logic [3:0] flags, //4 flags(C, N, V, Z) compacted into 4bit variable
    input logic [15:0] mmio_timer_reg,

    input logic current_kernel_mode,
    input logic memViolation,

    output logic XWrite, //Temp registers
    output logic YWrite,

    input logic [7:0] key_in,

    output logic IRWrite,
    output logic PCWrite,
    output logic GPRsWrite,
    output logic EAWrite, //Effective address write (custom register, might be gone soon)

    output logic EPCWrite,
    output logic isKernelMode,

    output logic memRead,
    output logic memWrite,

    output logic aluSrcX, //X, PC
    output logic [1:0] aluSrcY, //fetch: 4, alu_exe/branch = y, mem_calc = spare
    output logic [3:0] PCSrc, //pc+4, effective address
    output logic [2:0] GPRsSrc, //alu result, memory, spare

    output logic [1:0] aluOpSel,
    output logic isCallState,
    output logic flagsWrite,

    output logic SPRWrite,
    output logic [2:0] SPRSrc

);

    //Pipilined 5 cycle CU, I chose 5 cycles because its perfect balance
    //between clock speed, which is higher because of shorter critical path, and
    //penatly for mispredicted branch which is 2 cycles for regular branches
    //and only 1 for unconditional ones.
    //The estimated CPI is ~=1.25 considering average instruction split
    //obviosely varies by program being executed.
    //That is about 2.5 times faster than my multi-cycle design(~= 2.9CPI) as
    //well as higher estimated clock frequency due to shorter critical path
    //3 cycles per instruction to 2

    //== IF(Instruction Fetch) ==//
    logic [31:0] PC_IF;
    logic [31:0] PC_IF_plus4;

    assign PC_IF_plus4 = PC_IF + 32'h4;  //Computing it here dynamically

    always_ff @(posedge clk or posedge reset) begin
        if (reset) PC_IF <= 32'h0;
        else if(squash) PC_IF <= PC_target;
        else if(!stall) PC_IF <= PC_IF_plus4;
        else PC_IF <= PC_IF;
    end

    //== That looks nice ==//
    //== Anyways ID(Instruction Decode) stage ==//
    logic [31:0] PC_ID, IR_ID; //Each stage gets into own IR and PC
    logic        isID_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset || squash) begin
            isID_valid <= 0;
        end else if (!stall) begin
            PC_ID <= PC_IF;
            IR_ID <= instr
    end



endmodule
