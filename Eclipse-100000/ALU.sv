module ALU (
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic [5:0] opcode,
    output logic [31:0] result,

    output logic OverflowFlag,
    output logic NegativeFlag,
    output logic ZeroFlag
);
    //Doesn't care about clk
    always_comb begin
        result = 32'b0;

        case (opcode)
            6'b000001: result = x + y;
            6'b000011: result = x - y;
            6'b000111: result = x * y;
            6'b000010: result = x ^ y;
            6'b000110: result = x | y;
            6'b001110: result = x & y;
            6'b011110: result = ~x   ;
            6'b010000: result = x << y;
            6'b011000: result = x >> y;

            default: result = 32'b0;
        endcase
    end
    
    always_comb begin
        ZeroFlag = (result == 32'b0);

        NegativeFlag = result[31];

        if (opcode == 6'b000011) begin
            OverflowFlag = (x[31] != y[31]) && (result[31] != x[31]);
        end else if (opcode == 6'b000010) begin
            OverflowFlag = (x[31] == y[31]) && (result[31] != x[31]);
        end else begin
            OverflowFlag = 1'b0;
        end
    end


endmodule
