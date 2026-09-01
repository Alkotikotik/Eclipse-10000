module ALU (
    input  logic clk, //For DSP
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic [5:0] opcode,
    input  logic [2:0] op_size,

    output logic [31:0] result,
    output logic [63:0] mul_product,

    output logic OverflowFlag,
    output logic NegativeFlag,
    output logic ZeroFlag,
    output logic CarryFlag,

    output logic ZeroDivException

);

    //== DSP ==// 
    //DSP is kinda sick so I just wanna highlight it, its basically a built-in
    //board multipliers
    (* use_dsp = "yes" *)
    always_ff @(posedge clk) begin //No reset :(
        mul_product <= x * y;
    end

    //Basically had 5 adders, now only 1, somewhat big LUT save
    logic is_sub_op;
    assign is_sub_op = (opcode == 6'b000011 || opcode == 6'b110000);
    logic [31:0] add_y;
    assign add_y = is_sub_op ? ~y : y;

    logic [8:0]  add_s0;  //rz0, [8] is the rz carry
    logic [8:0]  add_s1;  //rz1, [8] is the ry carry
    logic [16:0] add_s2;  //ry1, [16] is the rx carry

    assign add_s0 = {1'b0, x[7:0]}   + {1'b0, add_y[7:0]}   + {8'b0,  is_sub_op};
    assign add_s1 = {1'b0, x[15:8]}  + {1'b0, add_y[15:8]}  + {8'b0,  add_s0[8]};
    assign add_s2 = {1'b0, x[31:16]} + {1'b0, add_y[31:16]} + {16'b0, add_s1[8]};

    logic [31:0] add_result;
    assign add_result = {add_s2[15:0], add_s1[7:0], add_s0[7:0]};


    //Doesn't care about clk
    always_comb begin
        result = 32'b0;
        ZeroDivException = 0;

        case (opcode)
            6'b000001: result = add_result; //Add
            6'b000011: result = add_result; //sub
            6'b000010: result = x ^ y;
            6'b000110: result = x | y;
            6'b001110: result = x & y;
            6'b001111: result = ~x   ;
            6'b001000: result = x << y[4:0]; //lower 5
            6'b001100: result = x >> y[4:0];
            6'b001010: result = $signed($signed(x) >>> y[4:0]); //Signed shift right iirc
            6'b110000: result = add_result; //CMP
            6'b000100: result = y; //MOV
            //Replace later for FPGA
            6'b000101: begin // DIV
                if (y == 32'b0) begin
                    ZeroDivException = 1;
                    result = 32'b0;
                end else begin
                    result = x / y;
                end
            end

            6'b001011: begin // MOD
                if (y == 32'b0) begin
                    ZeroDivException = 1'b1;
                    result = 32'b0;
                end else begin
                    result = x % y;
                end
            end
            6'b001001: begin // SDIV (signed)
                if (y == 32'b0) begin
                    ZeroDivException = 1;
                    result = 32'b0;
                end else begin
                    result = $signed(x) / $signed(y);
                end
            end
            default: result = 32'b0;
        endcase
    end

    always_comb begin
        unique case (op_size)
            3'b011, 3'b100, 3'b101, 3'b110: begin //rz
                CarryFlag = add_s0[8];
                ZeroFlag     = (result[7:0] == 8'b0);
                NegativeFlag = result[7];
                if (is_sub_op) begin
                    OverflowFlag = (x[7] != y[7]) && (result[7] != x[7]);
                end else begin
                    OverflowFlag = (x[7] == y[7]) && (result[7] != x[7]);
                end
            end
            3'b001, 3'b010: begin //ry
                CarryFlag = add_s1[8];
                ZeroFlag     = (result[15:0] == 16'b0);
                NegativeFlag = result[15];
                if (is_sub_op) begin
                    OverflowFlag = (x[15] != y[15]) && (result[15] != x[15]);
                end else begin
                    OverflowFlag = (x[15] == y[15]) && (result[15] != x[15]);
                end
            end
            default: begin //rx
                CarryFlag = add_s2[16];
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
