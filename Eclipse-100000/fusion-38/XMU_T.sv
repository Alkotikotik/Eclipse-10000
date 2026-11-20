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

    //=> DECO (Decode) <=//
    //Just quick decode of the flags for later stages, might end up
    //starting right here i don't know, who knows.

    logic [7:0] sexp;
    logic [23:0] mant;
    always_ff @(posedge clk) begin : DECO_DECO
        sexp <= {~a[30], a[29:24]};

    end : DECO_DECO

endmodule
