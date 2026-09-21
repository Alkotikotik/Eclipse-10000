module ALU (
    input  logic clk, //For DSP
    input  logic reset,
    input  logic [31:0] x,
    input  logic [31:0] y,
    input  logic [5:0] opcode,
    input  logic [31:0] imm2,
    input  logic [31:0] mul_y_in,
    input  logic [2:0] x_fragment,
    input  logic [2:0] y_fragment,
    input  logic isDiv_valid,
    input  logic mem_stall,
    input  logic [4:0] shift_amount, //separate input, should reduct logic levels

    output logic [31:0] add_result,
    output logic [31:0] bitwise_result,
    output logic [31:0] shift_result,
    output logic [31:0] div_result,
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
        if (!mem_stall) begin //vivado maps it onto DSP register input ports, meaning they freeze on mem_stall
            mul_x <= x;
            mul_y <= mul_y_in; //moved + imm2 to here this should reduce critical path
            mul_product <= mul_x * mul_y;
        end
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

    logic [31:0] add_imm;
    assign add_imm = is_sub_op ? (32'd1 - imm2) : imm2;

    assign add_result = x + add_y + add_imm; //Had to change it, because turns out it does have an effect
    //On the critical path, because instead of just chaining carry4 vivado
    //just added some bs there, eaasy fix though.

    //==Barrel==// 
    //A left shift is just a right shift with the bits flipped on both ends, and flipping is just writing,
    //actually no LUTs involved
    function automatic [31:0] rev32(input [31:0] v);
        for (int i = 0; i < 32; i++) rev32[i] = v[31-i];
    endfunction

    logic  is_shl, is_sra;
    assign is_shl = (opcode == 6'b001000);
    assign is_sra = (opcode == 6'b001010);

    function automatic [31:0] frag_sext(input [2:0] fragment, input [31:0] v);
        unique case (fragment)
            3'b001, 3'b010:                 frag_sext = {{16{v[15]}}, v[15:0]};
            3'b011, 3'b100, 3'b101, 3'b110: frag_sext = {{24{v[7]}},  v[7:0]};
            default:                        frag_sext = v;
        endcase
    endfunction

    logic [31:0] x_sext;
    assign x_sext = frag_sext(x_fragment, x);

    logic [31:0] sh_src;
    logic        sh_fill;
    assign sh_src  = is_shl ? rev32(x) : (is_sra ? x_sext : x);
    assign sh_fill = is_sra & x_sext[31];  //33rd bit carries the sign for SRA

    /* verilator lint_off UNUSEDSIGNAL */
    logic [32:0] sh_wide;
    /* verilator lint_on UNUSEDSIGNAL */ 

    //Split into separate bits might work might not
    logic signed [32:0] sh_s0, sh_s1, sh_s2, sh_s3, sh_s4;
    assign sh_s0   = $signed({sh_fill, sh_src});
    assign sh_s1   = shift_amount[0] ? sh_s0 >>> 1  : sh_s0;
    assign sh_s2   = shift_amount[1] ? sh_s1 >>> 2  : sh_s1;
    assign sh_s3   = shift_amount[2] ? sh_s2 >>> 4  : sh_s2;
    assign sh_s4   = shift_amount[3] ? sh_s3 >>> 8  : sh_s3;
    assign sh_wide = shift_amount[4] ? sh_s4 >>> 16 : sh_s4;

    assign shift_result = is_shl ? rev32(sh_wide[31:0]) : sh_wide[31:0];


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
    assign div_start = div_req && !div_working && !div_finished && !div_init && !div_init2 && !div_init3;
    assign div_stall = div_req && !div_finished;

    logic  is_signed_div;
    assign is_signed_div = (opcode == 6'b001001);

    logic  is_mod_op;
    assign is_mod_op = (opcode == 6'b001011);

    //Latch x and y on the start of div to basically half the critical path.
    //Thsi would add 1 cycle to every div, but quite frankly it doesn't matter
    logic [31:0] x_div, y_div;
    logic div_init, div_init2, div_init3;

    logic [31:0] x_nice, y_nice; //Idk how to name it, it basically just works for everything - 
    //Full registers, fragmeted, signed, unsigned etc
    assign x_nice = (is_signed_div && x_div[31]) ? (~x_div + 32'd1) : x_div;
    assign y_nice = (is_signed_div && y_div[31]) ? (~y_div + 32'd1) : y_div;

    logic [31:0] x_abs, y_abs;
    logic [33:0] y3_abs;

    //We split each signal into 8 4bit slices and check whether they are 0
    logic [4:0] clz_x;
    logic [4:0] clz_y;

    assign clz_x[4:2] = (|x_abs[31:28]) ? 3'b000 :
                        (|x_abs[27:24]) ? 3'b001 :
                        (|x_abs[23:20]) ? 3'b010 :
                        (|x_abs[19:16]) ? 3'b011 :
                        (|x_abs[15:12]) ? 3'b100 :
                        (|x_abs[11:8])  ? 3'b101 :
                        (|x_abs[7:4])   ? 3'b110 :
                        3'b111;

    assign clz_y[4:2] = (|y_abs[31:28]) ? 3'b000 :
                        (|y_abs[27:24]) ? 3'b001 :
                        (|y_abs[23:20]) ? 3'b010 :
                        (|y_abs[19:16]) ? 3'b011 :
                        (|y_abs[15:12]) ? 3'b100 :
                        (|y_abs[11:8])  ? 3'b101 :
                        (|y_abs[7:4])   ? 3'b110 :
                        3'b111;

    //veril***r checks for bits and a lot are unused in that design
    //So a considerable amount of link offs
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] sub_clz_x;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        unique case (clz_x[4:2])
            3'd0: sub_clz_x = x_abs[31:28];
            3'd1: sub_clz_x = x_abs[27:24];
            3'd2: sub_clz_x = x_abs[23:20];
            3'd3: sub_clz_x = x_abs[19:16];
            3'd4: sub_clz_x = x_abs[15:12];
            3'd5: sub_clz_x = x_abs[11:8];
            3'd6: sub_clz_x = x_abs[7:4];
            3'd7: sub_clz_x = x_abs[3:0];
        endcase
    end

    assign clz_x[1:0] = sub_clz_x[3] ? 2'd0 : sub_clz_x[2] ? 2'd1 : sub_clz_x[1] ? 2'd2 : 2'd3;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] sub_clz_y;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        unique case (clz_y[4:2])
            3'd0: sub_clz_y = y_abs[31:28];
            3'd1: sub_clz_y = y_abs[27:24];
            3'd2: sub_clz_y = y_abs[23:20];
            3'd3: sub_clz_y = y_abs[19:16];
            3'd4: sub_clz_y = y_abs[15:12];
            3'd5: sub_clz_y = y_abs[11:8];
            3'd6: sub_clz_y = y_abs[7:4];
            3'd7: sub_clz_y = y_abs[3:0];
        endcase
    end

    assign clz_y[1:0] = sub_clz_y[3] ? 2'd0 : sub_clz_y[2] ? 2'd1 : sub_clz_y[1] ? 2'd2 : 2'd3;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] div_shift;
    /* verilator lint_on UNUSEDSIGNAL */
    assign div_shift = {1'b0, clz_y} - {1'b0, clz_x}; //[5] if y > x

    logic [4:0] div_shift_r;


    //Thats a whole ass main logic
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] sub1, sub2, sub3;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0]  count_fits;

    assign sub1 = {3'b000, remainder} - {3'b000, sd}; //subtract sds from remainder
    assign sub2 = {3'b000, remainder} - {2'b00, sd, 1'b0}; //Thats sd2 btw
    assign sub3 = {3'b000, remainder} - {1'b0, sd3}; //My brother looking at that said that im sub 3...

    assign count_fits = ~sub3[34] ? 2'd3 : ~sub2[34] ? 2'd2 : ~sub1[34] ? 2'd1 : 2'd0;

    //Holy shit that looks scary didn't even realize while writing.
    //So lemme explain: the div is split into 4 main phases.
    //First 3phases are inits, I split them into 3 to reduce
    //critical path. Previosely it all happened in 1 init cycle
    //Fourth phase, though, is the actual divider loop I explained earlier.
    //That unfortunately means div would take 3cycle more than it would have
    //without inits, but its a worth price to pay for 6.5ns.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            div_working  <= 1'b0;
            div_finished <= 1'b0;
            div_init     <= 1'b0;
            div_init2    <= 1'b0;
            div_init3    <= 1'b0;
        end else if (mem_stall) begin //literally do nothing on mem_stall
        end else if ((div_init || div_init2 || div_init3 || div_working) && !div_req) begin
            div_init     <= 1'b0;
            div_init2    <= 1'b0;
            div_init3    <= 1'b0;
            div_working  <= 1'b0;
            div_finished <= 1'b0;
        end else if (div_start) begin
            div_init <= 1'b1;
        end else if (div_init) begin
            div_init <= 1'b0;
            div_init2 <= 1'b1;
        end else if (div_init2) begin
            div_init2 <= 1'b0;
            div_init3 <= 1'b1;
        end else if (div_init3) begin
            div_working <= !div_shift_r[4]; //Read above
            div_finished <= div_shift_r[4];
            div_init3 <= 1'b0;
        end else if (div_working) begin
            div_working <= (div_cycles_left != 0);
            div_finished <= (div_cycles_left == 0);
        end else begin
            div_finished <= 0;
        end
    end

    always_ff @(posedge clk) begin
        if (mem_stall) begin
        end else if ((div_init || div_init2 || div_init3 || div_working) && !div_req) begin
        end else if (div_start) begin
            x_div <= is_signed_div ? x_sext : x;
            y_div <= (is_signed_div ? frag_sext(y_fragment, y) : y) + imm2;
        end else if (div_init) begin
            x_abs <= x_nice;
            y_abs <= y_nice;
            is_neg_quotinent <= is_signed_div && (x_div[31] ^ y_div[31]);
            is_neg_remainder <= is_signed_div && x_div[31];
        end else if (div_init2) begin
            remainder <= x_abs;
            quotinent <= 32'b0;
            div_shift_r <= div_shift[5:1];
            y3_abs <= {2'b00, y_abs} + {1'b0, y_abs, 1'b0};
        end else if (div_init3) begin
            sd <= y_abs << {div_shift_r[3:0], 1'b0};
            sd3 <= y3_abs << {div_shift_r[3:0], 1'b0};
            div_cycles_left <= div_shift_r[3:0];
        end else if (div_working) begin
            remainder <=(count_fits == 2'd3) ? sub3[31:0] :
                        (count_fits == 2'd2) ? sub2[31:0] :
                        (count_fits == 2'd1) ? sub1[31:0] :
                        remainder;

            quotinent <= {quotinent[29:0], count_fits};
            sd <= {2'b00, sd[31:2]};
            sd3 <= {2'b00, sd3[33:2]};
            div_cycles_left <= div_cycles_left - 4'h1;
        end
    end

    logic [31:0] div_raw, div_out;
    assign div_result = (y_div == 32'b0) ? 32'b0 : div_out;
    assign ZeroDivException = is_div && (y_div == 32'b0);
    assign div_raw = is_mod_op ? remainder : quotinent;
    assign div_out = (is_mod_op ? is_neg_remainder : is_neg_quotinent) ? (~div_raw + 32'd1) : div_raw;


    //Doesn't care about clk
    always_comb begin
        unique case (opcode)
            6'b000010: bitwise_result = x ^ y;
            6'b000110: bitwise_result = x | y;
            6'b001110: bitwise_result = x & y;
            6'b001111: bitwise_result = ~x   ;
            default:   bitwise_result = y; //MOV
        endcase
    end

endmodule
