module SAM (
    //SAM - Scheduler and Arbiter Monolith
    input logic clk,
    input logic rst_n, //rst is back, idk how to feel about it
);

    //Two BRAM36s in Simple dual port mode give two independent 72bit reads
    //per cycle, therefore allowing 2 XMU-Ts per SAM.
    (* ram_style = "block" *) logic [1023:0] TBL [0:71];
    initial begin
        $readmemh("transcendentals.mem", TBL);
    end
    logic [71:0] TBL_data0, TBL_data1;
    always_ff @(posedge clk) begin
        TBL_data0 <= TBL[rom_addr0];
        TBL_data1 <= TBL[rom_addr1];
    end


endmodule
