module RAM(
    input logic clk,
    input logic [31:0] address,
    input logic [31:0] data_in,

    input logic mem_write,
    input logic mem_read,

    output logic [31:0] data_out
);

    logic [31:0] ramm [0:16777215]; //64MB
    
    initial begin
        $readmemh("program.hex", ramm);
    end
    
    logic [7:0] unused_bits;
    assign unused_bits = {address[31:26], address[1:0]}; //So compiler wouldn't compain
    assign data_out = (mem_read) ? ramm[address[25:2]] : 32'b0; //Ignore bottom 2 bits

    always_ff @(posedge clk) begin
        if (mem_write) begin
            ramm[address[25:2]] <= data_in;
        end
    end

endmodule
