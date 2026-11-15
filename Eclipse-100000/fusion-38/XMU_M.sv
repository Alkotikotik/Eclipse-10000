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
    logic  less, more;
    assign less = norm_b < norm_a;
    assign more = norm_b > norm_c;

    logic [31:0] min, min_comb, max, clamp;
    assign min_comb = less ? a : b;
    always_ff @(posedge clk) begin : MINMAX
        min <= min_comb;
        if (more) begin
            max <= c;
            clamp <= c;
        end else begin
            max <= b;
            clamp <= min_comb;
        end
        //max   <= more ? c : b;
        //clamp <= more ? c : min_comb;
    end : MINMAX

    logic [2:0] cnt_L0 [5:0];
    logic [2:0] cnt_L1 [2:0];
    logic [5:0] cnt_L2;
    always_comb begin
        for (int i = 0; i < 5; i++) begin
            cnt_L0[i] = a[i*6 + 0] + a[i*6 + 1] + a[i*6 + 2] + a[i*6 + 3] + a[i*6 + 4] + a[i*6 + 5];
        end
        cnt_L0[5] = a[30] + a[31];
        for (int i = 0; i < 3; i++) begin
            cnt_L1[i] = cnt_L0[i*6 + 0] + cnt_L0[i*6 + 1] + cnt_L0[i*6 + 2] + cnt_L0[i*6 + 3] + cnt_L0[i*6 + 4] + cnt_L0[i*6 + 5];
        end
    end

    always_ff @(posedge clk) begin
        cnt_L2 <= cnt_L1[0] + cnt_L1[1] + cnt_L1[2];
    end

    logic [31:0] bitrev;
    always_ff @(posedge clk) begin : rev
        for (int i = 0; i < 32; i++) begin
            bitrev[31 - i] <= a[i];
        end
    end : rev

    //=> END <=//
    //Final clamp and result mux
    always_comb begin
        unique case (opcode)
            3'b000: result = min;
            3'b001: result = max;
            3'b010: result = cnt_L2;
            3'b011: result = bitrev;
            3'b111: result = clamp;
            default: result = 32'h0;
        endcase
    end
endmodule
