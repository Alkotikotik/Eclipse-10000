module RAM(
    input logic clk,

    input logic [31:0] addrRead,
    input logic [31:0] addrWrite,
    input logic [31:0] data_in,
    input logic [3:0] byte_enable,
    input logic mem_write,
    input logic mem_read,
    output logic [31:0] data_out,

    //Driven by IF stage always active
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [31:0] instr_address, //8byte aligned, last bits aren't used
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] instr_data_out
);
    logic [7:0] ramm [0:67108863]; //64MB
    logic [11:0] unused_bits;
    assign unused_bits = {addrRead[31:26], addrWrite[31:26]};
    initial begin
        $readmemh("program.hex", ramm);
    end

    //Sync read, was async previosely which obviosely is impossible on the
    //actual FPGA, unless LUTRAM ofc but its either BRAM or ddr3
    //Reads give the whole word, MEM picks the fragment, so as usual
    always_ff @(posedge clk) begin
        if (mem_read) begin
            data_out <= {ramm[addrRead[25:0]    ],
                         ramm[addrRead[25:0] + 1],
                         ramm[addrRead[25:0] + 2],
                         ramm[addrRead[25:0] + 3]};
        end
    end

    logic [31:0] ia4;
    assign ia4 = {6'h0, instr_address[25:2], 2'b00};   // 4-byte aligned
    //IF needs instruction every cycle so read enable isn't even needed
    assign instr_data_out = {ramm[ia4+4], ramm[ia4+5],
                            ramm[ia4+6], ramm[ia4+7],
                            ramm[ia4],   ramm[ia4+1],
                            ramm[ia4+2], ramm[ia4+3]};

    always_ff @(posedge clk) begin
        if (mem_write) begin
            if (byte_enable == 4'b1111) begin
                ramm[addrWrite[25:0]    ] <= data_in[31:24];
                ramm[addrWrite[25:0] + 1] <= data_in[23:16];
                ramm[addrWrite[25:0] + 2] <= data_in[15:8];
                ramm[addrWrite[25:0] + 3] <= data_in[7:0];
            end else if (byte_enable == 4'b0011) begin
                ramm[addrWrite[25:0]    ] <= data_in[15:8];
                ramm[addrWrite[25:0] + 1] <= data_in[7:0];
            end else begin
                ramm[addrWrite[25:0]    ] <= data_in[7:0];
            end
        end
    end
endmodule
