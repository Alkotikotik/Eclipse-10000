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
    logic req_awck;

    initial rst_n = 0;
    initial #1000 rst_n = 1;

    //Wire is, well a wire main difference is that it can be multi-driven
    wire  [1:0]  dm;
    wire  [15:0] dq;
    wire  [1:0]  dqs_p, dqs_n;

    //Tb acts as PCB and just sets some delays for reads, that just for a test
    //tho
    localparam int D_LANE0 = 1200; //ps, dq[7:0]  + dqs[0]
    localparam int D_LANE1 = 100; //ps, dq[15:8] + dqs[1]
    wire  [15:0] mem_dq;
    wire  [1:0]  mem_dqs_p, mem_dqs_n;
    logic [15:0] mem_dq_d;
    logic [1:0]  mem_dqs_p_d, mem_dqs_n_d;

    //transport delays: every edge gets through, just later
    always @(mem_dq[7:0])     mem_dq_d[7:0]    <= #D_LANE0 mem_dq[7:0];
    always @(mem_dq[15:8])    mem_dq_d[15:8]   <= #D_LANE1 mem_dq[15:8];
    always @(mem_dqs_p[0])    mem_dqs_p_d[0]   <= #D_LANE0 mem_dqs_p[0];
    always @(mem_dqs_n[0])    mem_dqs_n_d[0]   <= #D_LANE0 mem_dqs_n[0];
    always @(mem_dqs_p[1])    mem_dqs_p_d[1]   <= #D_LANE1 mem_dqs_p[1];
    always @(mem_dqs_n[1])    mem_dqs_n_d[1]   <= #D_LANE1 mem_dqs_n[1];

    for (genvar i = 0; i < 16; i++) begin : pcb_dq
        assign mem_dq[i] = emi.dq_tq[i] ? 1'bz : dq[i];
        assign dq[i]     = emi.dq_tq[i] ? mem_dq_d[i] : 1'bz;
    end
    for (genvar j = 0; j < 2; j++) begin : pcb_dqs
        assign mem_dqs_p[j] = emi.dqs_tq[j] ? 1'bz : dqs_p[j];
        assign mem_dqs_n[j] = emi.dqs_tq[j] ? 1'bz : dqs_n[j];
        assign dqs_p[j]     = emi.dqs_tq[j] ? mem_dqs_p_d[j] : 1'bz;
        assign dqs_n[j]     = emi.dqs_tq[j] ? mem_dqs_n_d[j] : 1'bz;
    end

    //Thats a pretty cool syntax ngl
    initial begin
        req = 0; req_we = 0; req_msk = 16'h0000;
        req_addr = 24'hFF_AA_BA;
        req_wd   = 128'hDEAD_BEEF_CAFE_BABE_FEED_FACE_C0FFEE_01;

        #800_000_000;

        //write
        req_we = 1; req = 1;
        @(posedge req_awck); @(posedge emi.clkEMI); req = 0;
        repeat (5) @(posedge emi.clk333);

        //read it back
        req_we = 0; req = 1;
        @(posedge mem_done); @(negedge emi.clkEMI); req = 0;

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
        .req_awck(req_awck),

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
        .addr(a), .dq(mem_dq), .dqs(mem_dqs_p), .dqs_n(mem_dqs_n), .tdqs_n(), .odt(odt)
    );

    initial #1_000_000_000 $finish;   //I have exactly 1ms
endmodule
