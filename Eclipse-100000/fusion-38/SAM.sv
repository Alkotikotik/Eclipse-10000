module SAM (
    //SAM - Scheduler and Arbiter Monolith
    input logic clk,
    input logic rst_n, //rst is back, idk how to feel about it

    //22bits for 32MB of SDRAM
    output logic [22:0] PC,
    //fixed 32bit instructions, i think its nice
    input  logic [31:0] instr,
);

    //Each PACK gets its own set of regs, 48 32bit regs to be precise
    //didn't know sv had 2d array, and its fine here bc i only from one PACK per cycle
    (* ram_style = "block" *) logic [31:0] PACK_regs [0:31][0:47];

    //So in SIMT PACKs can issue instruction even if previos issue of that
    //exact PACK hasn't finished. The only issue is the hazard of using
    //register that hasn't been written yet but should have been. Write-use or
    //whatever its called. I solve it by having a buffer of two rd registers
    //that are in the pipeline and if PACK wants to issue an instruction it
    //has to make sure they don't collide.
    //My encoding is:
    logic [31:0] PACKs_instrs [31:0];
    logic [22:0] PACKs_PCs    [31:0];
    logic [11:0] PACKs_msks   [31:0]; //valid/invalid mask for each GUCH
    logic [1:0]  PACKs_states [31:0]; //free/needs fetch / instr buffered
    logic [1:0]  PACKs_used   [31:0]; //Whether rd register is valid or nah

    //Two BRAM36s in True dual port mode give two independent 72bit reads
    //per cycle, therefore allowing 2 XMU-Ts per SAM.
    (* ram_style = "block" *) logic [71:0] TBL [0:1023];
    initial begin
        $readmemh("transcendentals.mem", TBL);
    end
    logic [71:0] TBL_data0, TBL_data1;
    always_ff @(posedge clk) begin
        TBL_data0 <= TBL[rom_addr0];
        TBL_data1 <= TBL[rom_addr1];
    end


endmodule
