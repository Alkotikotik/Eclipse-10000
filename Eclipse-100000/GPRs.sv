module GPRs (
    input logic clk,
    input logic reset,
    input logic reg_write,
    input logic [4:0] rr0, 
    input logic [4:0] rr1,

    input logic [4:0] rw0, 
    input logic [31:0] data_in,
    output logic [31:0] data_out0,
    output logic [31:0] data_out1
);

    logic [31:0] GPRs [31:0]; //32 32bit registers

    always_comb begin
        data_out0 = GPRs[rr0];
    end

    always_comb begin
        data_out1 = GPRs[rr1];
    end

    integer i;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) begin
                GPRs[i] <= 32'b0;
            end
        end
        else if (reg_write) begin
            GPRs[rw0] <= data_in;
        end
    end

endmodule
