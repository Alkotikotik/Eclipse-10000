`timescale 1ps/1ps
module tb;
    //Formally test-bench, but rather init of the EMI
    //Clocks are 2 different outputs of one MMCM, so atm im using 3/7 slots
    logic clk_crystal = 0;
    always #10000 clk_crystal = ~clk_crystal; // 50Mhz quartz clk

    logic EMI_rst_n;

    logic rst_n, ck_p, ck_n, cke, odt;
    logic cs_n, ras_n, cas_n, we_n;
    logic [2:0]  ba;
    logic [13:0] a; //don't ask me, its their names
    logic req, req_we;
    logic [23:0] req_addr;
    logic [127:0] req_wd;
    logic [15:0]  req_msk;
    logic [127:0] rdata;
    logic mem_done;

    initial rst_n = 0;
    initial #1000 rst_n = 1;

    //Wire is, well a wire main difference is that it can be multi-driven
    wire  [1:0]  dm;
    wire  [15:0] dq;
    wire  [1:0]  dqs_p, dqs_n;

    //Thats a pretty cool syntax ngl
    initial begin
        req = 0; req_we = 0; req_msk = 16'h0000;
        req_addr = 24'hFF_AA_BA;
        req_wd   = 128'hDEAD_BEEF_CAFE_BABE_FEED_FACE_C0FFEE_01;

        #800_000_000;

        //write
        req_we = 1; req = 1;
        @(posedge mem_done); req = 0;
        repeat (5) @(posedge emi.clk333);

        //read it back
        req_we = 0; req = 1;
        @(posedge mem_done); req = 0;

        $display("rdata = %h", rdata);
        if (rdata == req_wd) $display("PASS");
        else                 $display("FAIL, expected %h", req_wd);
        $finish;
    end

    EMI_600 emi (
        .clk_crystal(clk_crystal),
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

        .dm(dm),
        .dq(dq),
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
