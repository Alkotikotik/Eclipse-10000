module XMU_M (
    //XMU-M - Xtended Math Unit - Misc
    //XMU is split into two modules, this one is fast and contains misc
    //functions and the other one is fairly slow and contains transendentals.
    input logic clk,

    input logic efp_op, signed_op,
    input logic [2:0] opcode,
    input logic [31:0] a, b, c,

    output logic [31:0] result
);

    //=> MINMAX <=//
    //Normalize all 3operands into unsigned integer form.
    //It works before gefp32 doesn't have any special patterns
    logic [31:0] norm_a, norm_b, norm_c;

    assign norm_a[31]   = a[31]   ^ (efp_op | signed_op);
    assign norm_a[30:0] = a[30:0] ^ {31{efp_op & a[31]}};

    assign norm_b[31]   = b[31]   ^ (efp_op | signed_op);
    assign norm_b[30:0] = b[30:0] ^ {31{efp_op & b[31]}};

    assign norm_c[31]   = c[31]   ^ (efp_op | signed_op);
    assign norm_c[30:0] = c[30:0] ^ {31{efp_op & c[31]}};

    //min and max are computed in parallel, i clamp b between a and c bc
    //i think its neat
    //Also compute half part and here and half part in the END
    logic  lt_hi, eq_ba, lt_lo, gt_hi, eq_bc, gt_lo;
    assign lt_hi = norm_b[31:16] <  norm_a[31:16];
    assign eq_ba = norm_b[31:16] == norm_a[31:16];
    assign lt_lo = norm_b[15:0]  <  norm_a[15:0];
    assign gt_hi = norm_b[31:16] >  norm_c[31:16];
    assign eq_bc = norm_b[31:16] == norm_c[31:16];
    assign gt_lo = norm_b[15:0]  >  norm_c[15:0];

    logic [31:0] bitrev;
    always_comb begin : rev
        for (int i = 0; i < 32; i++) begin
            bitrev[31 - i] = a[i];
        end
    end : rev

    logic  rev_op;
    assign rev_op = opcode == 3'b011;

    logic MINMAX_lt_hi, MINMAX_eq_ba, MINMAX_lt_lo, MINMAX_gt_hi, MINMAX_eq_bc, MINMAX_gt_lo;
    logic [2:0]  MINMAX_op;
    logic [31:0] MINMAX_a, MINMAX_b, MINMAX_c;
    always_ff @(posedge clk) begin : MINMAX
        //nice tech btw
        {MINMAX_lt_hi, MINMAX_eq_ba, MINMAX_lt_lo} <= {lt_hi, eq_ba, lt_lo};
        {MINMAX_gt_hi, MINMAX_eq_bc, MINMAX_gt_lo} <= {gt_hi, eq_bc, gt_lo};
        MINMAX_op <= opcode;
        MINMAX_a  <= rev_op ? bitrev : a;
        MINMAX_b  <= b;
        MINMAX_c  <= c;
    end : MINMAX

    logic [2:0] cnt_L0 [5:0];
    always_comb begin
        for (int i = 0; i < 5; i++) begin
            cnt_L0[i] = {2'b00, a[i*6 + 0]} + {2'b00, a[i*6 + 1]} + {2'b00, a[i*6 + 2]}
                      + {2'b00, a[i*6 + 3]} + {2'b00, a[i*6 + 4]} + {2'b00, a[i*6 + 5]};
        end
        cnt_L0[5] = {2'b00, a[30]} + {2'b00, a[31]};
    end
    logic [2:0] cnt_L1 [2:0];
    always_ff @(posedge clk) begin
        for (int k = 0; k < 3; k++) begin
            cnt_L1[k] <= {2'b00, cnt_L0[0][k]} + {2'b00, cnt_L0[1][k]} + {2'b00, cnt_L0[2][k]}
                       + {2'b00, cnt_L0[3][k]} + {2'b00, cnt_L0[4][k]} + {2'b00, cnt_L0[5][k]};
        end
    end

    //=> END <=//
    //More like step 2 of step 1
    logic [5:0] cnt_L2;
    assign cnt_L2 = {3'b000, cnt_L1[0]} + {2'b00, cnt_L1[1], 1'b0} + {1'b0, cnt_L1[2], 2'b00};

    logic  less, more;
    assign less = MINMAX_lt_hi | (MINMAX_eq_ba & MINMAX_lt_lo);
    assign more = MINMAX_gt_hi | (MINMAX_eq_bc & MINMAX_gt_lo);

    logic [1:0] sel;
    always_comb begin : MUX
        unique case (MINMAX_op)
            3'b000:  sel = less ? 2'b01 : 2'b00;
            3'b001:  sel = more ? 2'b01 : 2'b10;
            3'b011:  sel = 2'b00;
            3'b111:  sel = more ? 2'b10 : (less ? 2'b00 : 2'b01);
            default: sel = 2'b11;
        endcase
    end : MUX

    always_comb begin : END
        unique case (sel)
            2'b00: result = MINMAX_a;
            2'b01: result = MINMAX_b;
            2'b10: result = MINMAX_c;
            2'b11: result = {26'b0, cnt_L2};
        endcase
    end : END
endmodule
