module XMU_T(
    //XMU-T - Xtended Math Unit - Transcendentals
    //I was about to start with SAM, but realized that I want XMU first
    input logic clk,

    input logic [31:0] a, //yup just a
    input logic [3:0]  opcode,

    //ROM lives in SAM bc its shared by all XMU-Ts within SAM
    output logic [9:0]  rom_addr,
    input  logic [71:0] rom_data,

    output logic [31:0] result
);
    //So I wrote a minimax script that generates .mem data that i will put
    //into my BRAM ROM and XMU_T is gonna read its transcendentals from it.

    //optbl:
    //0000 - rcp

    //=> DECO (Decode) <=//
    //Just quick decode of the flags for later stages, might end up
    //starting right here i don't know, who knows.
    logic  [7:0] sexp; //signed exp
    assign sexp = {~a[30], a[29:24]};

    logic [7:0] sexp_ff;
    logic [5:0] sh_amt;
    logic [23:0] mant;
    logic zero, arctan_big1, arctan1, exp_V, neg;
    always_ff @(posedge clk) begin : DECO_DECO
        sexp_ff <= sexp;
        mant <= {1'b1, a[23:0]};
        sh_amt <= 8'd23 - sexp; //shift by exp(saturate)

        //varios flags for later
        zero <= ~|a;
        arctan_big1 <= (a >= 1'b1);
        arctan1 <= (a == 1);
        exp_V <= (sexp >= 6);
    end : DECO_DECO

endmodule
