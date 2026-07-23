module ALU (
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic [5:0] opcode,
    input  logic [2:0] op_size,
    output logic [31:0] result,

    output logic OverflowFlag,
    output logic NegativeFlag,
    output logic ZeroFlag,
    output logic CarryFlag
);

    logic [63:0] mul_product;
    assign mul_product = x * y;
    
    /* verilator lint_off UNUSEDSIGNAL */
    logic [32:0] ext_result;
    logic is_sub_op;
    /* verilator lint_on UNUSEDSIGNAL */

    assign is_sub_op = (opcode == 6'b000011 || opcode == 6'b110000);

    //Doesn't care about clk
    always_comb begin
        result = 32'b0;

        case (opcode)
            6'b000001: result = x + y;
            6'b000011: result = x - y;
            6'b000111: result = mul_product[31:0];
            6'b001101: result = mul_product[63:32];
            6'b000010: result = x ^ y;
            6'b000110: result = x | y;
            6'b001110: result = x & y;
            6'b001111: result = ~x   ;
            6'b001000: result = x << y[4:0]; //lower 5
            6'b001100: result = x >> y[4:0];
            6'b001010: result = $signed($signed(x) >>> y[4:0]); //JIC
            6'b110000: result = x - y; //CMP

            default: result = 32'b0;
        endcase
    end

    always_comb begin
        if (is_sub_op) begin
            ext_result = {1'b0, x} + {1'b0, ~y} + 33'd1;
        end else begin
            ext_result = {1'b0, x} + {1'b0, y};
        end

        unique case (op_size)
            3'b011, 3'b100, 3'b101, 3'b110: begin //rz
                CarryFlag    = ext_result[8];
                ZeroFlag     = (result[7:0] == 8'b0);
                NegativeFlag = result[7];
                if (is_sub_op) begin
                    OverflowFlag = (x[7] != y[7]) && (result[7] != x[7]);
                end else begin
                    OverflowFlag = (x[7] == y[7]) && (result[7] != x[7]);
                end
            end
            3'b001, 3'b010: begin //ry
                CarryFlag    = ext_result[16];
                ZeroFlag     = (result[15:0] == 16'b0);
                NegativeFlag = result[15];
                if (is_sub_op) begin
                    OverflowFlag = (x[15] != y[15]) && (result[15] != x[15]);
                end else begin
                    OverflowFlag = (x[15] == y[15]) && (result[15] != x[15]);
                end
            end
            default: begin //rx
                CarryFlag    = ext_result[32];
                ZeroFlag     = (result == 32'b0);
                NegativeFlag = result[31];
                if (is_sub_op) begin
                    OverflowFlag = (x[31] != y[31]) && (result[31] != x[31]);
                end else begin
                    OverflowFlag = (x[31] == y[31]) && (result[31] != x[31]);
                end
            end
        endcase
    end

endmodule
