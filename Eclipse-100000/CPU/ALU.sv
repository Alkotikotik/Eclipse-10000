module ALU (
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic [5:0] opcode,
    output logic [31:0] result,

    output logic OverflowFlag,
    output logic NegativeFlag,
    output logic ZeroFlag
);

    logic [63:0] mul_product;
    assign mul_product = x * y;

    //Doesn't care about clk
    always_comb begin
        result = 32'b0;

        case (opcode)
            6'b000001: result = x + y;
            6'b000011: result = x - y;
            6'b000111: result = mul_product[31:0];
            6'b001111: result = mul_product[63:32];
            6'b000010: result = x ^ y;
            6'b000110: result = x | y;
            6'b001110: result = x & y;
            6'b001111: result = ~x   ;
            6'b001000: result = x << y[4:0]; //lower 5
            6'b001100: result = x >> y[4:0];
            6'b001110: result = $signed($signed(x) >>> y[4:0]); //JIC

            default: result = 32'b0;
        endcase
    end
    
    always_comb begin
        ZeroFlag = (result == 32'b0);

        NegativeFlag = result[31];

        if (opcode == 6'b000011) begin
            OverflowFlag = (x[31] != y[31]) && (result[31] != x[31]);
        end else if (opcode == 6'b000001) begin
            OverflowFlag = (x[31] == y[31]) && (result[31] != x[31]);
        end else if (opcode == 6'b000111) begin
            OverflowFlag = (mul_product[63:32] != 32'b0); //Later if opcode is mul and overflow run HIMUL
        end else begin
            OverflowFlag = 1'b0;
        end
    end

endmodule
