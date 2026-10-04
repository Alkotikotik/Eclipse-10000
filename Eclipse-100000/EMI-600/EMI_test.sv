module EMI_test (
    //Temp test for EMI, just to test if it works on actual board
    //Without doing cache
    input logic clkEMI,
    input logic rst_sync_n,
    input logic EMI_rdy,
    input logic mem_done,

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
    logic        writing;
    logic [127:0] expected;

    //Basically writing some value and then reading from that address and
    //checking whether its the same
    assign expected = {4{pass ^ 8'hFA, addr}};
    assign req      = EMI_rdy;
    assign req_we   = writing;
    assign req_addr = addr;
    assign req_wd   = expected;
    assign req_msk  = 16'h0;

    always_ff @(posedge clkEMI or negedge rst_sync_n) begin
        if (!rst_sync_n) begin
            addr <= 0;
            pass <= 0;
            writing <= 1;
            error_seen <= 0;
        end else if (mem_done) begin
            if (!writing && rdata != expected) error_seen <= 1;
            if (addr == 24'hFF_FFFF) begin //whole memory
                addr <= 0;
                writing <= !writing;
                if (!writing) pass <= pass + 1;
            end else
                addr <= addr + 1;
        end
    end

endmodule
