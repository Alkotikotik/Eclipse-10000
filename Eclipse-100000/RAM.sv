module RAM(
    input logic clk,
    input logic [31:0] address,
    input logic [31:0] data_in,

    input logic [3:0] byte_enable,
    input logic mem_write,
    input logic mem_read,

    output logic [31:0] data_out
);

    logic [7:0] ramm [0:67108863]; //64MB
    
    initial begin
        $readmemh("program.hex", ramm);
    end
    
    logic [5:0] unused_bits;
    assign unused_bits = address[31:26]; //So compiler wouldn't compain

    assign data_out = (mem_read) ? {ramm[address[25:0] + 3], 
                                    ramm[address[25:0] + 2], 
                                    ramm[address[25:0] + 1], 
                                    ramm[address[25:0]]} : 32'b0;

    always_ff @(posedge clk) begin
        if (mem_write) begin
            if (byte_enable[0]) ramm[address[25:0]]     <= data_in[7:0];
            if (byte_enable[1]) ramm[address[25:0] + 1] <= data_in[15:8];
            if (byte_enable[2]) ramm[address[25:0] + 2] <= data_in[23:16];
            if (byte_enable[3]) ramm[address[25:0] + 3] <= data_in[31:24];
        end
    end

endmodule
