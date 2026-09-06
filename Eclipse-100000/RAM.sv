module RAM(
    input logic clk,

    input logic [31:0] address,
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
    initial begin
        $readmemh("program.hex", ramm);
    end
    logic [5:0] unused_bits;
    assign unused_bits = address[31:26]; //So compiler wouldn't compain

    //Sync read, was async previosely which obviosely is impossible on the
    //actual FPGA, unless LUTRAM ofc but its either BRAM or ddr3
    always_ff @(posedge clk) begin
        if (mem_read) data_out <= {ramm[address[25:0] + 3],
                                   ramm[address[25:0] + 2],
                                   ramm[address[25:0] + 1],
                                   ramm[address[25:0]]};
    end

    logic [31:0] ia4;
    assign ia4 = {6'h0, instr_address[25:2], 2'b00};   // 4-byte aligned
    //IF needs instruction every cycle so read enable isn't even needed
    assign instr_data_out = {ramm[ia4+7], ramm[ia4+6],
                            ramm[ia4+5], ramm[ia4+4],
                            ramm[ia4+3], ramm[ia4+2],
                            ramm[ia4+1], ramm[ia4]};

    always_ff @(posedge clk) begin
        if (mem_write) begin
            if (byte_enable[0]) ramm[address[25:0]]     <= data_in[7:0];
            if (byte_enable[1]) ramm[address[25:0] + 1] <= data_in[15:8];
            if (byte_enable[2]) ramm[address[25:0] + 2] <= data_in[23:16];
            if (byte_enable[3]) ramm[address[25:0] + 3] <= data_in[31:24];
        end
    end
endmodule
