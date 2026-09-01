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

    //Basically I previosely had several reduntant adders and shifters, same
    //results can be achieved with 1 shifter/adder and some really cool bit tricks.
    //Im doing this purely for LUT savings, as far as im aware it has to impact on the worst
    //critical path
    //==Adder==//
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

    //==Barrel==// 
    //A left shift is just a right shift with the bits flipped on both ends, and flipping is just writing,
    //actually no LUTs involved
    function automatic [31:0] rev32(input [31:0] v);
        for (int i = 0; i < 32; i++) rev32[i] = v[31-i];
    endfunction

    logic is_shl, is_sra;
    assign is_shl = (opcode == 6'b001000);
    assign is_sra = (opcode == 6'b001010);

    logic [31:0] sh_src;
    logic        sh_fill;
    assign sh_src  = is_shl ? rev32(x) : x;
    assign sh_fill = is_sra & x[31];  //33rd bit carries the sign for SRA

    /* verilator lint_off UNUSEDSIGNAL */
    logic [32:0] sh_wide;
    /* verilator lint_on UNUSEDSIGNAL */
    assign sh_wide = $signed({sh_fill, sh_src}) >>> y[4:0];

    logic [31:0] sh_result;
    assign sh_result = is_shl ? rev32(sh_wide[31:0]) : sh_wide[31:0];

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
            6'b001000: result = sh_result; //SHL
            6'b001100: result = sh_result; //SHR
            6'b001010: result = sh_result; //SRA for singed shift right iirc
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
