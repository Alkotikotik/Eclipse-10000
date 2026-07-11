module ALU (
    input  logic [31:0] x,
    input  logic [31:0] y,
    output logic [31:0] result
);

    assign result = x + y;

endmodule
