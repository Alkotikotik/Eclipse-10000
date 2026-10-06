module EMI_test (
    //Temp test for EMI, just to test if it works on actual board
    //Without doing cache
    input logic clkEMI,
    input logic rst_sync_n,
    input logic EMI_rdy,
    input logic mem_done,
    input logic req_awck,

    output logic req,
    output logic req_we,
    output logic [23:0] req_addr,
    output logic [127:0] req_wd,
    output logic [15:0] req_msk,
    (* mark_debug = "true" *) output logic error_seen,

    input logic [127:0] rdata
);
    logic [23:0] addr;
    (* mark_debug = "true" *) logic [7:0]  pass;
    (* mark_debug = "true" *) logic [1:0]  mode;
    logic         writing;
    logic [23:0]  chk_addr;
    logic [7:0]   chk_pass;
    logic [31:0]  cyc;
    (* mark_debug = "true" *) logic [31:0] wr_cycles, rd_cycles;
    (* mark_debug = "true" *) logic [23:0] err_addr;
    (* mark_debug = "true" *) logic [127:0] err_data;
    (* mark_debug = "true" *) logic [1:0]  err_mode;
    logic         rd_wait;
    logic [15:0]  lat_cnt;
    (* mark_debug = "true" *) logic [15:0] rd_lat_min, rd_lat_max;
    (* mark_debug = "true" *) logic [47:0] rd_lat_sum;
    (* mark_debug = "true" *) logic [31:0] rd_lat_n;

    assign mode     = pass[1:0];
    assign req      = EMI_rdy && !rd_wait;
    assign req_we   = writing;
    assign req_addr = mode[1] ? {addr[16:3], addr[23:17], addr[2:0]} : addr; //fast row change
    assign req_wd   = {4{pass ^ 8'hFA, addr}};  //data from the logical address
    assign req_msk  = 16'h0;

    //A test for EMI, pipeling and reads after writing should cover pretty
    //much everything
    always_ff @(posedge clkEMI or negedge rst_sync_n) begin
        if (!rst_sync_n) begin
            addr <= 0; pass <= 0; writing <= 1; error_seen <= 0;
            chk_addr <= 0; chk_pass <= 0; cyc <= 0;
            wr_cycles <= 0; rd_cycles <= 0; err_addr <= 0;
            rd_wait <= 0; lat_cnt <= 0; rd_lat_min <= '1; rd_lat_max <= 0; rd_lat_sum <= 0; rd_lat_n <= 0;
        end else begin
            cyc <= cyc + 1;
            if (mode[0] && !writing && !rd_wait) lat_cnt <= lat_cnt + 1;
            if (req_awck && !req_we && mode[0]) rd_wait <= 1;
            if (rd_wait) lat_cnt <= lat_cnt + 1;
            if (mem_done && rd_wait) begin
                rd_wait <= 0;
                lat_cnt <= 0;
                rd_lat_n <= rd_lat_n + 1;
                rd_lat_sum <= rd_lat_sum + lat_cnt + 1;
                if (lat_cnt + 1 < rd_lat_min) rd_lat_min <= lat_cnt + 1;
                if (lat_cnt + 1 > rd_lat_max) rd_lat_max <= lat_cnt + 1;
            end
            if (req_awck) begin
                if (mode[0]) writing <= !writing; //fast switch
                if (!mode[0] || !writing) begin //regular mode
                    if (addr == 24'hFF_FFFF) begin
                        addr <= 0;
                        if (!mode[0]) writing <= !writing;
                            if (mode[0] || !writing) begin
                            pass <= pass + 1;
                            rd_cycles <= cyc;
                            cyc <= 0;
                        end else
                            wr_cycles <= cyc;
                    end else
                        addr <= addr + 1;
                end
            end
            if (mem_done) begin
                if (rdata != {4{chk_pass ^ 8'hFA, chk_addr}} && !error_seen) begin
                    error_seen <= 1;
                    err_addr <= chk_addr;
                    err_data <= rdata;
                    err_mode <= chk_pass[1:0];
                end
                if (chk_addr == 24'hFF_FFFF) begin
                    chk_addr <= 0;
                    chk_pass <= chk_pass + 1;
                end else
                    chk_addr <= chk_addr + 1;
            end
        end
    end
endmodule
