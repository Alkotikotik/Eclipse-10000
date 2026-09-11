module ALU (
    input  logic clk, //For DSP
    input  logic reset,
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic [5:0] opcode,
    input  logic isDiv_valid,

    output logic [31:0] result,
    output logic [63:0] mul_product,
    output logic div_stall,

    output logic ZeroDivException

);

    //== DSP ==// 
    //DSP is kinda sick so I just wanna highlight it, its basically a built-in
    //board multipliers.
    //Internal DSP register to multi-cycle mul between EX and MEM which
    //supposedely should shorten a critical path according to my assumptions
    //Based on vivado's report
    logic [31:0] mul_x, mul_y;

    (* use_dsp = "yes" *)
    always_ff @(posedge clk) begin //No reset :(
        mul_x <= x;
        mul_y <= y;
        mul_product <= mul_x * mul_y;
    end

    //Basically I previosely had several reduntant adders and shifters, same
    //results can be achieved with 1 shifter/adder and some really cool bit tricks.
    //Im doing this purely for LUT savings, as far as im aware it has to impact on the worst
    //critical path
    //==Adder==//
    logic is_sub_op;
    assign is_sub_op = (opcode == 6'b000011);
    logic [31:0] add_y;
    assign add_y = is_sub_op ? ~y : y;

    logic [8:0]  add_s0;  //rz0, [8] is the rz carry
    logic [8:0]  add_s1;  //rz1, [8] is the ry carry
    /* verilator lint_off UNUSEDSIGNAL */
    logic [16:0] add_s2;  //ry1, [16] is the rx carry
    /* verilator lint_on UNUSEDSIGNAL */

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


    //== Quick-Radix-4 Div Unit ==//
    //So quick-div works similarly to long division: in the first iteration
    //CLZ(Count leading zeros) finds the bit amount of zeros between msb and first 1 of both divident and divisor
    //Then it subtracts CLZ(divisor) - CLZ(devidend) and shifts divisor by that amount to the left, rounding it down to even
    //Specifically for radix-4.
    //Btw its (dividend / divisor).
    //That's how we skip unneccesy calculatations of any regular radix div because of leading zeros.
    //
    //Then the actual loop starts, we take sd(Shifted divisor), sd2 which is
    //shifted additionlly left by 1, and sd3, which is further shifted by 2.
    //Then we compare all of sds to dividend to check the highest that fits.
    //Then we shift sds left by 2 and repeat the cycle. Btw we compare them by
    //subtracting largest sd that fits into dividend, from dividend and then
    //leaving dividend subtracted.
    //Now for remainder we first set it to the first largest sd that fits,
    //then we simply subtract subsequent largest sdas from it, so at the end
    //we will end up with just a nice remainder.
    //Now as for quotinent, again its similar to regular long division - we append,
    //to the left, the amount of sds that fit into divident
    //
    //Im explaining allat bc I didn't do divisor in logisim using gates.
    //We divide x/y meaning x is dividend and y is divisor
    logic  is_div;
    assign is_div = ((opcode == 6'b000101) || (opcode == 6'b001011) || (opcode == 6'b001001));

    logic [31:0] remainder;
    logic [31:0] quotinent;
    logic is_neg_remainder;
    logic is_neg_quotinent;

    logic [31:0] sd; //Shifted Divisor
    logic [33:0] sd3;

    logic [3:0] div_cycles_left; //Maximum 16 cycles
    logic       div_working;
    logic       div_finished;

    logic  div_req;
    assign div_req = is_div && isDiv_valid;

    logic  div_start;
    assign div_start = div_req && !div_working && !div_finished && !div_init;
    assign div_stall = div_req && !div_finished;

    logic  is_signed_div;
    assign is_signed_div = (opcode == 6'b001001);

    logic  is_mod_op;
    assign is_mod_op = (opcode == 6'b001011);

    //Latch x and y on the start of div to basically half the critical path.
    //Thsi would add 1 cycle to every div, but quite frankly it doesn't matter
    logic [31:0] x_div, y_div;
    logic div_init;

    logic [31:0] x_nice, y_nice; //Idk how to name it, it basically just works for everything - 
    //Full registers, fragmeted, signed, unsigned etc
    assign x_nice = (is_signed_div && x_div[31]) ? (~x_div + 32'd1) : x_div;
    assign y_nice = (is_signed_div && y_div[31]) ? (~y_div + 32'd1) : y_div;

    //We split each signal into 8 4bit slices and check whether they are 0
    logic [4:0] clz_x;
    logic [4:0] clz_y;

    assign clz_x[4:2] = (|x_nice[31:28]) ? 3'b000 :
                        (|x_nice[27:24]) ? 3'b001 :
                        (|x_nice[23:20]) ? 3'b010 :
                        (|x_nice[19:16]) ? 3'b011 :
                        (|x_nice[15:12]) ? 3'b100 :
                        (|x_nice[11:8])  ? 3'b101 :
                        (|x_nice[7:4])   ? 3'b110 :
                        3'b111;

    assign clz_y[4:2] = (|y_nice[31:28]) ? 3'b000 :
                        (|y_nice[27:24]) ? 3'b001 :
                        (|y_nice[23:20]) ? 3'b010 :
                        (|y_nice[19:16]) ? 3'b011 :
                        (|y_nice[15:12]) ? 3'b100 :
                        (|y_nice[11:8])  ? 3'b101 :
                        (|y_nice[7:4])   ? 3'b110 :
                        3'b111;

    //veril***r checks for bits and a lot are unused in that design
    //So a considerable amount of link offs
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] sub_clz_x;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        unique case (clz_x[4:2])
            3'd0: sub_clz_x = x_nice[31:28];
            3'd1: sub_clz_x = x_nice[27:24];
            3'd2: sub_clz_x = x_nice[23:20];
            3'd3: sub_clz_x = x_nice[19:16];
            3'd4: sub_clz_x = x_nice[15:12];
            3'd5: sub_clz_x = x_nice[11:8];
            3'd6: sub_clz_x = x_nice[7:4];
            3'd7: sub_clz_x = x_nice[3:0];
        endcase
    end

    assign clz_x[1:0] = sub_clz_x[3] ? 2'd0 : sub_clz_x[2] ? 2'd1 : sub_clz_x[1] ? 2'd2 : 2'd3;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] sub_clz_y;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        unique case (clz_y[4:2])
            3'd0: sub_clz_y = y_nice[31:28];
            3'd1: sub_clz_y = y_nice[27:24];
            3'd2: sub_clz_y = y_nice[23:20];
            3'd3: sub_clz_y = y_nice[19:16];
            3'd4: sub_clz_y = y_nice[15:12];
            3'd5: sub_clz_y = y_nice[11:8];
            3'd6: sub_clz_y = y_nice[7:4];
            3'd7: sub_clz_y = y_nice[3:0];
        endcase
    end

    assign clz_y[1:0] = sub_clz_y[3] ? 2'd0 : sub_clz_y[2] ? 2'd1 : sub_clz_y[1] ? 2'd2 : 2'd3;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] div_shift;
    /* verilator lint_on UNUSEDSIGNAL */
    assign div_shift = {1'b0, clz_y} - {1'b0, clz_x}; //[5] if y > x

    logic [31:0] sd_init;
    assign sd_init = y_nice << {div_shift[4:1], 1'b0};


    //Thats a whole ass main logic
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] sub1, sub2, sub3;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0]  count_fits;

    assign sub1 = {3'b000, remainder} - {3'b000, sd}; //subtract sds from remainder
    assign sub2 = {3'b000, remainder} - {2'b00, sd, 1'b0}; //Thats sd2 btw
    assign sub3 = {3'b000, remainder} - {1'b0, sd3}; //My brother looking at that said that im sub 3...

    assign count_fits = ~sub3[34] ? 2'd3 : ~sub2[34] ? 2'd2 : ~sub1[34] ? 2'd1 : 2'd0;

    

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            div_working  <= 1'b0;
            div_finished <= 1'b0;
            div_init     <= 1'b0;
        end else if (div_start) begin
            x_div <= x;
            y_div <= y;
            div_init <= 1'b1;
        end else if (div_init) begin
            remainder <= x_nice;
            quotinent <= 32'b0;
            is_neg_quotinent <= is_signed_div && (x_div[31] ^ y_div[31]);
            is_neg_remainder <= is_signed_div && x_div[31];
            sd <= sd_init;
            sd3 <= {2'b00, sd_init} + {1'b0, sd_init, 1'b0};
            div_cycles_left <= div_shift[4:1];
            div_working <= !div_shift[5]; //Read above
            div_finished <= div_shift[5];
            div_init <= 1'b0;
        end else if (div_working && !div_req) begin
            div_working  <= 1'b0;
            div_finished <= 1'b0;
        end else if (div_working) begin
            remainder <=(count_fits == 2'd3) ? sub3[31:0] :
                        (count_fits == 2'd2) ? sub2[31:0] :
                        (count_fits == 2'd1) ? sub1[31:0] :
                        remainder;

            quotinent <= {quotinent[29:0], count_fits};
            sd <= {2'b00, sd[31:2]};
            sd3 <= {2'b00, sd3[33:2]};
            div_cycles_left <= div_cycles_left - 4'h1;
            div_working <= (div_cycles_left != 0);
            div_finished <= (div_cycles_left == 0);
        end else begin
            div_finished <= 0;
        end
    end

    logic [31:0] div_raw, div_out;
    assign div_raw = is_mod_op ? remainder : quotinent;
    assign div_out = (is_mod_op ? is_neg_remainder : is_neg_quotinent) ? (~div_raw + 32'd1) : div_raw;


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
            6'b000100: result = y; //MOV
            //Replace later for FPGA for quick div gonna do it soon, already
            //did it dumbass
            6'b000101: begin // DIV
                if (y_div == 32'b0) begin
                    ZeroDivException = 1;
                    result = 32'b0;
                end else begin
                    result = div_out;
                end
            end

            6'b001011: begin // MOD
                if (y_div == 32'b0) begin
                    ZeroDivException = 1'b1;
                    result = 32'b0;
                end else begin
                    result = div_out;
                end
            end
            6'b001001: begin // SDIV (signed)
                if (y_div == 32'b0) begin
                    ZeroDivException = 1;
                    result = 32'b0;
                end else begin
                    result = div_out;
                end
            end
            //no SMOD unfortunately duo to the lack of encoding space
            default: result = 32'b0;
        endcase
    end

endmodule
