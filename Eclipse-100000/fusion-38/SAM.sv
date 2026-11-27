module SAM (
    //SAM - Scheduler and Arbiter Monolith
    input logic clk,
    input logic rst_n, //rst is back, idk how to feel about it

    //23bits for 32MB of SDRAM
    output logic [22:0] PC,
    output logic [4:0]  PACK_PC;
    //fixed 32bit instructions, i think its nice
    input  logic [31:0] MM_instr,
    input  logic new_instr //set to 1 when new instruction has been loaded
    output logic acc_instr; //accepted instr
);

    //Each GUCH(or XMUs) gets its own set of regs, 48 32bit regs to be precise.
    //They stored accross 3 banks of 16 registers
    //RF - register file
    logic [8:0]  RF_raddr [0:2];
    logic [8:0]  RF_waddr [0:2];
    logic [0:0]  RF_we    [0:2]; //holy moly its legal
    logic [11:0] RF_wmsk;
    logic [31:0] RF_wdata [0:11][0:2];
    logic [31:0] PACK_regs[0:11][0:2];

    genvar lane, bank;
    generate
        for (lane = 0; lane < 12; lane++) begin : LANE
            for (bank = 0; bank < 3; bank++) begin : BANK
                (* ram_style = "block" *) logic [31:0] mem [0:511];
                always_ff @(posedge clk) begin
                    if (RF_we[bank] & RF_wmsk[lane]) begin
                        mem[RF_waddr[bank]] <= RF_wdata[lane][bank]; //write
                    end
                    PACK_regs[lane][bank] <= mem[RF_raddr[bank]]; //read
                end : BANK
            end : LANE
        end
    endgenerate

    //So in SIMT PACKs can issue instruction even if previos issue of that
    //exact PACK hasn't finished. The only issue is the hazard of using
    //register that hasn't been written yet but should have been. Write-use or
    //whatever its called. I solve it by having a buffer of two rd registers
    //that are in the pipeline and if PACK wants to issue an instruction it
    //has to make sure they don't collide. 5 bits to address a PACK btw
    //My encoding is (85 total bits):
    logic [31:0] PACKs_instrs [4:0];
    logic [22:0] PACKs_PCs    [4:0];
    logic [11:0] PACKs_msks   [4:0];     //valid/invalid mask for each GUCH for divergence
    logic [1:0]  PACKs_sts    [4:0];    //states: free / needs fetch / instr buffered
    logic [1:0]  PACKs_used   [4:0];   //Whether rd register is valid or nah
    logic [11:0] PACKs_rds    [4:0];  //2 rds i've been talking about
    logic [1:0]  PACKs_blk    [4:0]; //2 per pack, whether instr was loaded or blocked

    //Simple round-robin fetching for now, gotta love randomely placed operands in the ISA
    //Also this is kinda expensive, but im afraid there is no way around it.
    logic  [4:0] PACK_cnt;
    assign PACKs_blk[PACK_cnt][0] = (
        (PACKs_rds [PACK_cnt][5:0] == instr_rd)
        |(PACKs_rds[PACK_cnt][5:0] == instr_ra)
        |(PACKs_rds[PACK_cnt][5:0] == instr_rb)
        |(PACKs_rds[PACK_cnt][5:0] == instr_rc)
    );
    assign PACKs_blk[PACK_cnt][1] = (
        (PACK_rds [PACK_cnt][11:6] == instr_rd)
        |(PACK_rds[PACK_cnt][11:6] == instr_ra)
        |(PACK_rds[PACK_cnt][11:6] == instr_rb)
        |(PACK_rds[PACK_cnt][11:6] == instr_rc)
    );
    always_ff @(posedge clk or negedge rst_n) begin : FETCHER
        if (!rst_n) begin //long time no see rst...
            PACK_cnt <= 5'h0;
        end else begin
            if (instr_new) begin
                PACK_cnt <= PACK_cnt + 5'h1;
                if (!PACKs_blk[PACK_cnt]) begin
                    PACKs_instrs[PACK_cnt] <= MM_instr;
                    new_instr <= 1'b0; //this is a prototype, alright?
                end
            end
        end
    end : FETCHER

    logic [4:0] PACK_isscomb;
    always_comb begin
        //i have a bad feeling about this
        for (int i = 0; i < 32; i++) begin
            if (~|(PACKs_blk[i] & PACKs_used)) begin
                PACK_isscomb = i;
            end
        end
    end

    logic [31:0] read_a, read_b, read_c;
    always_ff @(posedge clk) begin
        read_a <= PACK_regs[PACK_isscomb][areg];
        read_b <= PACK_regs[PACK_isscomb][breg];
        read_c <= PACK_regs[PACK_isscomb][creg];
    end

    logic [4:0] PACK_iss; //shout out big Nil
    always_ff @(posedge clk) begin : CRRY
        PACK_iss <= PACK_isscomb;
    end : CRRY

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
