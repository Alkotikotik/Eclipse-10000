module GPRs (
    input logic clk,
    input logic reg_write,
    input logic [4:0] rr0, //Register Read
    input logic [4:0] rr1,

    input logic [4:0] rw0, //Register Write
    input logic [31:0] data_in,
    output logic [31:0] data_out0,
    output logic [31:0] data_out1
);

    logic [31:0] GPRs [31:0]; //32 32bit regs
    
    //Cares about clk
    always_ff @(posedge clk) begin
        if (reg_write && (rw0 != 5'b0)) begin //rx0 is 0
            GPRs[rw0] <= data_in;
        end
    end
    
    //Doesn't care about clk
    assign data_out0 = (rr0 == 5'b0) ? 32'b0 : GPRs[rr0];//rx0 is 0
    assign data_out1 = (rr1 == 5'b0) ? 32'b0 : GPRs[rr1];

endmodule
