`timescale 1ps/1ps
module tb;
    //Formally test-bench, but rather init of the EMI
    logic clk = 0;
    always #1500 clk = ~clk; // 3000 ps period = 333 MHz clock


    logic rst_n, ck_p, ck_n, cke, odt;
    logic cs_n, ras_n, cas_n, we_n;
    logic [2:0]  ba;
    logic [13:0] a; //don't ask me, its their names

    initial #1000 rst_n = 1;

    //Wire is, well a wire main difference is that it can be multi-driven
    wire  [1:0]  dm;
    wire  [15:0] dq;
    wire  [1:0]  dqs_p, dqs_n;

    EMI_600 emi (
        .clk(clk),
        .rst_n(rst_n),
        .cke(cke),
        .ck_p(ck_p),
        .ck_n(ck_n),
        .odt(odt)

        .cs_n(cs_n),
        .ras_n(ras_n),
        .cas_n(cas_n),
        .we_n(we_n)
        .ba(ba)
        .a(a)
    );

    ddr3_model mem (
        .rst_n(rst_n), .ck(ck_p), .ck_n(ck_n), .cke(cke), .cs_n(cs_n),
        .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .dm_tdqs(dm), .ba(ba),
        .addr(addr), .dq(dq), .dqs(dqs_p), .dqs_n(dqs_n), .tdqs_n(), .odt(odt)
    );

    initial #1_000_000_000 $finish;   //I have exactly 1ms
endmodule
