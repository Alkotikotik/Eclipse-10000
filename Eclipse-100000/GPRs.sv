module GPRs (
    input logic clk,
    input logic reset,
    input logic reg_write,
    input logic KernelMode,
    input logic [4:0] rr0, 
    input logic [4:0] rr1,

    input logic [4:0] rw0, 
    input logic [31:0] data_in,
    output logic [31:0] data_out0,
    output logic [31:0] data_out1
);

    logic [31:0] GPRs [31:0]; //32 32bit registers 
    logic [31:0] k_tsp;
    logic [31:0] k_rx30;

    //If kernel mode swap rx30 k_rx30 and rx31 k_tsp
    always_comb begin
        if (rr0 == 5'd0)
            data_out0 = 32'b0;
        else if (rr0 == 5'd30  && KernelMode)
            data_out0 = k_rx30;
        else if (rr0 == 5'd31 && KernelMode)
            data_out0 = k_tsp;
        else
            data_out0 = GPRs[rr0];
    end

    always_comb begin
        if (rr1 == 5'd0)
            data_out1 = 32'b0;
        else if (rr1 == 5'd30  && KernelMode)
            data_out1 = k_rx30;
        else if (rr1 == 5'd31 && KernelMode)
            data_out1 = k_tsp;
        else
            data_out1 = GPRs[rr1];
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            k_tsp <= 32'd4092;
            k_rx30 <= 32'b0;
        end
        else if (reg_write && (rw0 != 5'b0)) begin
            if (rw0 == 5'd30 && KernelMode)
                k_rx30 <= data_in;
            else if (rw0 == 5'd31 && KernelMode)
                k_tsp <= data_in;
            else
                GPRs[rw0] <= data_in;
        end
    end

endmodule
