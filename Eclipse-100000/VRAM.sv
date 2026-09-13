module VRAM(
    input logic clk,

    input logic [31:0] addrRead,
    input logic [31:0] addrWrite,
    input logic [31:0] data_in,
    input logic [3:0] byte_enable,
    input logic mem_write,
    input logic mem_read,
    output logic [31:0] data_out
);
    //1MB of VRAM, 480p RGBA4444, addrRead is already VRAM relative
    logic [7:0] vramm [0:1048575];
    logic [23:0] unused_bits;
    assign unused_bits = {addrRead[31:20], addrWrite[31:20]}; //So compiler wouldn't compain

    always_ff @(posedge clk) begin
        if (mem_read) data_out <= {vramm[addrRead[19:0] + 3],
                                   vramm[addrRead[19:0] + 2],
                                   vramm[addrRead[19:0] + 1],
                                   vramm[addrRead[19:0]]};

        if (mem_write) begin
            if (byte_enable[0]) vramm[addrWrite[19:0]]     <= data_in[7:0];
            if (byte_enable[1]) vramm[addrWrite[19:0] + 1] <= data_in[15:8];
            if (byte_enable[2]) vramm[addrWrite[19:0] + 2] <= data_in[23:16];
            if (byte_enable[3]) vramm[addrWrite[19:0] + 3] <= data_in[31:24];
        end
    end
endmodule
