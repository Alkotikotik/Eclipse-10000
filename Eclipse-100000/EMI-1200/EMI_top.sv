module EMI_board_top (
    //EMI top, so top is like the outermost layer of everything.
    //Eg this pin
    //The vivado project is outside this repo btw bc its heavy asf and very
    //bloated so its better to keep it out. Same with main CPU btw
    input  logic        sys_clk,        //50MHz crystal, M21, is an actual quartz
    input  logic        sys_rst_n,      //button, H7, active low
    output logic [1:0]  led,            //G21, G20

    //Actual ddr3 ports
    output logic        ddr3_reset_n,
    output logic        ddr3_ck_p, ddr3_ck_n,
    output logic        ddr3_cke, ddr3_odt,
    output logic        ddr3_ras_n, ddr3_cas_n, ddr3_we_n,
    output logic [2:0]  ddr3_ba,
    output logic [13:0] ddr3_addr,
    output logic [1:0]  ddr3_dm,

    inout  wire  [15:0] ddr3_dq,
    inout  wire  [1:0]  ddr3_dqs_p, ddr3_dqs_n
);
    logic         clkEMI, rst_sync_n;
    logic         req, req_we, mem_done, req_awck, EMI_rdy, calib_failed, error_seen;
    logic [23:0]  req_addr;
    logic [127:0] req_wd, rdata;
    logic [15:0]  req_msk;

    EMI_1200 EMI (
        .clk_crystal(sys_clk),
        .rst_n(sys_rst_n),

        .req(req),
        .req_we(req_we),
        .req_addr(req_addr),
        .req_wd(req_wd),
        .req_msk(req_msk),

        .rdata(rdata),
        .mem_done(mem_done),
        .req_awck(req_awck),
        .EMI_rdy(EMI_rdy),

        .EMI_rst_n(ddr3_reset_n),
        .calib_failed(calib_failed),

        .cke(ddr3_cke),
        .ck_p(ddr3_ck_p),
        .ck_n(ddr3_ck_n),
        .odt(ddr3_odt),

        .dm(ddr3_dm),
        .dq(ddr3_dq),
        .dqs_p(ddr3_dqs_p),
        .dqs_n(ddr3_dqs_n),

        .cs_n(), //for soome reason my board just doesn't have cs#??
        .ras_n(ddr3_ras_n),
        .cas_n(ddr3_cas_n),
        .we_n(ddr3_we_n),
        .ba(ddr3_ba),
        .a(ddr3_addr),

        .clkEMI(clkEMI),
        .rst_sync_n(rst_sync_n)

    );

    EMI_test test(
        .clkEMI(clkEMI),
        .rst_sync_n(rst_sync_n),
        .EMI_rdy(EMI_rdy),
        .mem_done(mem_done),
        .req_awck(req_awck),

        .req(req),
        .req_we(req_we),
        .req_addr(req_addr),
        .req_wd(req_wd),
        .req_msk(req_msk),
        .rdata(rdata),

        .error_seen(error_seen)
    );

    assign led[1] = !calib_failed;
    assign led[0] = !error_seen;

endmodule
