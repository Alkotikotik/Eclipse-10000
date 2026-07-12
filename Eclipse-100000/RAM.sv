module RAM(
    input logic clk,
    input logic [31:0] address,
    input logic [31:0] data_in,

    input logic mem_write,
    input logic mem_read,

    output logic [31:0] data_out
);

    logic [31:0] ramm [0:4095];
    
    //Load program
    initial begin
        $readmemh("program.hex", ramm);
    end

    //So compiler wouldn't complain
    logic [19:0] unused_bits;
    assign unused_bits = {address[31:14], address[1:0]};

    assign data_out = (mem_read) ? ramm[address[13:2]] : 32'b0;

    always_ff @(posedge clk) begin
        if (mem_write) begin
            ramm[address[13:2]] <= data_in;
        end
    end

endmodule
