`timescale 1ps/1ps
module tb;
    //Formally test-bench, but rather init of the EMI
    //both clks come from one MMCM slot, they are just devided.
    //Later imma have even more devided MMCM outputs for EMI.
    logic clk = 0;
    always #1500 clk = ~clk; // 3000 ps period = 333 MHz clock

    logic clk90 = 0; //clk shifted 90 degrees, literally 90, its kinda funny ngl
    //But it actually makes a lot of sense.
    initial #1125 clk90 = 1;
    always #1500 clk90 = ~clk90;

    logic EMI_rst_n;

    logic rst_n, ck_p, ck_n, cke, odt;
    logic cs_n, ras_n, cas_n, we_n;
    logic [2:0]  ba;
    logic [13:0] a; //don't ask me, its their names
    logic req, req_we;
    logic [23:0] req_addr;
    logic [127:0] req_wd;

    initial rst_n = 0;
    initial #1000 rst_n = 1;

    //Wire is, well a wire main difference is that it can be multi-driven
    wire  [1:0]  dm;
    wire  [15:0] dq;
    wire  [1:0]  dqs_p, dqs_n;

    initial req = 0;
    initial #100_000_000_00 req = 1;
    initial req_addr = 24'hFF_AA_BA;
    initial req_wd = 128'hDEAD_BEEF_BEEF_DEAD_DEED_BEEF_FEED_BEED;

    EMI_600 emi (
        .clk(clk),
        .clk90(clk90),
        .rst_n(rst_n),
        .EMI_rst_n(EMI_rst_n),
        .cke(cke),
        .ck_p(ck_p),
        .ck_n(ck_n),
        .odt(odt),

        .req(req),
        .req_we(req_we),
        .req_addr(req_addr),
        .req_wd(req_wd),
        .req_msk(req_msk),

        .dm(dm)
        .dq(dq)
        .dqs_p(dqs_p),
        .dqs_n(dqs_n),

        .rdata(rdata),
        .mem_done(mem_done),

        .cs_n(cs_n),
        .ras_n(ras_n),
        .cas_n(cas_n),
        .we_n(we_n),
        .ba(ba),
        .a(a)
    );

    ddr3_model mem (
        .rst_n(EMI_rst_n), .ck(ck_p), .ck_n(ck_n), .cke(cke), .cs_n(cs_n),
        .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .dm_tdqs(dm), .ba(ba),
        .addr(a), .dq(dq), .dqs(dqs_p), .dqs_n(dqs_n), .tdqs_n(), .odt(odt)
    );

    initial #1_000_000_000 $finish;   //I have exactly 1ms
endmodule
