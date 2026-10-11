module VRAM(
    input logic clk,

    input logic [31:0] addrRead,
    input logic [31:0] addrWrite,
    input logic [31:0] data_in,
    input logic [1:0]  mem_size,
    input logic mem_write,
    input logic mem_read,
    output logic [31:0] data_out
);
    //1MB of VRAM, 480p RGBA4444, addrRead is already VRAM relative
    logic [7:0] vramm [0:1048575];
    logic [23:0] unused_bits;
    assign unused_bits = {addrRead[31:20], addrWrite[31:20]}; //So compiler wouldn't compain

    always_ff @(posedge clk) begin
        if (mem_read) begin
            data_out <= {vramm[addrRead[19:0]    ],
                         vramm[addrRead[19:0] + 1],
                         vramm[addrRead[19:0] + 2],
                         vramm[addrRead[19:0] + 3]};
        end

        if (mem_write) begin
            if (mem_size == 2'b10) begin
                vramm[addrWrite[19:0]    ] <= data_in[31:24];
                vramm[addrWrite[19:0] + 1] <= data_in[23:16];
                vramm[addrWrite[19:0] + 2] <= data_in[15:8];
                vramm[addrWrite[19:0] + 3] <= data_in[7:0];
            end else if (mem_size == 2'b01) begin
                vramm[addrWrite[19:0]    ] <= data_in[15:8];
                vramm[addrWrite[19:0] + 1] <= data_in[7:0];
            end else begin
                vramm[addrWrite[19:0]    ] <= data_in[7:0];
            end
        end
    end
endmodule
