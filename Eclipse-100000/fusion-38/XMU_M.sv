module XMU_M (
    //XMU-M - Xtended Math Unit - Misc
    //XMU-M performs min/max and clamp along with popcount and bitrev.
    //XMU-M utilizes 114LUTs, 217FFs, has median worst critical path of 2.9ns
    //and total of 3pipeline stages.
    input logic clk,

    input logic efp_op, signed_op,
    input logic [2:0] opcode,
    input logic [31:0] a, b, c,

    output logic [31:0] result
);
    //=> MINMAX <=//
    //min and max are computed in parallel, i clamp b between a and c bc
    //i think its neat. And yeah its split between 2 cycles for timing
    logic  lt_ba, gt_bc;
    assign lt_ba = b < a;
    assign gt_bc = b > c;

    logic  mix_ab, mix_bc, flip_b;
    assign mix_ab = (efp_op | signed_op) & (a[31] ^ b[31]);
    assign mix_bc = (efp_op | signed_op) & (b[31] ^ c[31]);
    assign flip_b = efp_op & b[31];

    logic [31:0] bitrev;
    always_comb begin : rev
        for (int i = 0; i < 32; i++) begin
            bitrev[31 - i] = a[i];
        end
    end : rev

    logic  rev_op;
    assign rev_op = opcode == 3'b011;

    logic MINMAX_lt_ba, MINMAX_gt_bc;
    logic MINMAX_mix_ab, MINMAX_mix_bc, MINMAX_flip_b;
    logic [2:0]  MINMAX_op;
    logic [31:0] MINMAX_a, MINMAX_b, MINMAX_c;
    always_ff @(posedge clk) begin : MINMAX
        //nice tech btw
        {MINMAX_lt_ba, MINMAX_gt_bc} <= {lt_ba, gt_bc};
        {MINMAX_mix_ab, MINMAX_mix_bc, MINMAX_flip_b} <= {mix_ab, mix_bc, flip_b};
        MINMAX_op <= opcode;
        MINMAX_a  <= rev_op ? bitrev : a;
        MINMAX_b  <= b;
        MINMAX_c  <= c;
    end : MINMAX

    //thats a popcount, it counts how many bits does a number has, prolly
    //useful and certainly cool. I compute it in stages using something called
    //6:3 counter it counts ones in 6bits and outputs 3bit value. Count in
    //several passes across two cycles.
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

    //=> MID <=//
    //Finishes every minmax's calculations to be ready for a final mux its
    //more like finish stage but i like mid more
    logic [5:0] cnt_L2;
    assign cnt_L2 = {3'b000, cnt_L1[0]} + {2'b00, cnt_L1[1], 1'b0} + {1'b0, cnt_L1[2], 2'b00};

    //so in MINMAX it compares just straight up raw bits as a unsigned it,
    //and its wrong obviosely. So now i actually consider the signs and change
    //the result depending on whether its efp, or signed, or negative just
    //read the code.
    logic  less, more;
    assign less = MINMAX_mix_ab ?  MINMAX_b[31] : (MINMAX_lt_ba ^ MINMAX_flip_b);
    assign more = MINMAX_mix_bc ? ~MINMAX_b[31] : (MINMAX_gt_bc ^ MINMAX_flip_b);

    logic [1:0] sel;
    always_comb begin : MUX //its a mux
        unique case (MINMAX_op)
            3'b000:  sel = less ? 2'b01 : 2'b00; //min
            3'b001:  sel = more ? 2'b01 : 2'b10; //max
            3'b011:  sel = 2'b00;
            3'b111:  sel = more ? 2'b10 : (less ? 2'b00 : 2'b01); //clamp
            default: sel = 2'b00; //a on the wrong opcode but it shouldn't matter
        endcase
    end : MUX

    logic [1:0]  MID_sel;
    logic [5:0]  MID_cnt;
    logic [31:0] MID_a, MID_b, MID_c;
    always_ff @(posedge clk) begin : MID_CRRY
        MID_sel <= sel;
        MID_cnt <= cnt_L2;
        MID_a   <= MINMAX_a;
        MID_b   <= MINMAX_b;
        MID_c   <= MINMAX_c;
    end : MID_CRRY

    //=> END <=//
    //final result mux
    always_comb begin : END
        unique case (MID_sel)
            2'b00: result = MID_a;
            2'b01: result = MID_b;
            2'b10: result = MID_c;
            2'b11: result = {26'b0, MID_cnt};
        endcase
    end : END
endmodule
