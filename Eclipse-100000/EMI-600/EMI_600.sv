module EMI_600 (
    //Eclipse Memory Interface(EMI)
    input logic clk_crystal,
    input logic rst_n,

    input logic req, //CPU requests data
    input logic req_we, //1 - write, 0 - read
    input logic [23:0] req_addr, //address 16byte addressible
    input logic [127:0] req_wd, //16byte write data
    input logic [15:0] req_msk, //which of 16bytes to mask

    output logic [127:0] rdata, //read data
    output logic mem_done,
    output logic req_awck, // read acknowledged
    (* mark_debug = "true" *) output logic EMI_rdy,

    output logic EMI_rst_n,
    (* mark_debug = "true" *) output logic calib_failed,

    output logic cke,
    output logic ck_p,
    output logic ck_n,
    output logic odt,

    output logic [1:0]  dm,
    inout wire [15:0] dq, //literally in or out, can go both ways
    inout wire [1:0]  dqs_p,
    inout wire [1:0]  dqs_n,

    output logic cs_n,
    output logic ras_n,
    output logic cas_n,
    output logic we_n,
    output logic [2:0] ba,
    output logic [13:0] a,

    output logic clkEMI,
    output logic rst_sync_n

);

    //Alright so memory, memory, memory the micron ddr3 btw.
    //So lemme explain it:
    //The actual bits are stored in the capacitors, each one holding
    //About 100 000 electrons, next to each capacitor is transistor
    //That enables reads and writes. This RAM is structured by having
    //Rows and colums accross 8 banks. While you can access any
    //colum you want at any time, its a little harder with rows
    //Rows are 2KB and at the end of each one are set of amplifiers
    //They are needed because capacitors by themselfs can't really get
    //A full charge to the destination, they can only like provide
    //0.1V, and amplifiers catch those tiny 0.1V differences in the electron
    //Flow and based on that output 1 or 0. The problem is switching between rows
    //(amplifiers) takes some time, and ofc we want to minimize it.
    //There are 1024 columns and 16384 rows per bank(yes each one has separate set).
    //Each bank can open only 1row at a time, when it accesses currently opened one
    //Its a hit, if it needs to open another one, its a miss. So I not only should
    //Deal with L1 cache misses but also with ddr3 row misses, they aren't as
    //bad tho. Thus a nice optimization comes in mind: its generally better to
    //evenely scatter data accross all the banks. And memory is accessed using
    //27bit address 3bits for bank, 14for row, 10for column, technically memory
    //is 2byte addressible, however in reality I am going to read/write in
    //bursts of 16bytes. There is also one cool thing I thought i'd mention
    //because capacitors store that few electrons they literally wear off
    //after at least 64ms(per row) by thet I mean their charge becomes
    //ambigous, so you have to refresh them using amplifiers every 64ms.
    //However they "wear off" independently so on average you need to referesh
    //either of rows each 64ms / 8192 = 7.8us. That doesnt' affect performance
    //as much, only about 2% max. That is the main principle of how memory
    //works. Also hence each bank can open 1row 16KB of rows
    //can be opened at ones.


    //It might look that im a little crazy but if you think about it
    //It actually makes sense
    logic clk333, clk90, clk200;
    logic clk_pll, clk90_pll, clkEMI_pll;

    //So init is actually pretty cool, and as silly as it sounds writing it
    //was like playing ktane. That micron datasheet is so similar to ktane
    //instruction lmao.
    //Anyways its a literal init of memory, it is done via first delaying stuff
    //To wait for voltage to stabilize, then writing config info into
    //internal(MR) registers and then calling ZQCL that just finishes
    //everything.
    typedef enum logic [3:0] {
        INIT_INIT,
        MR2,
        MR3,
        MR1,
        MR0,
        ZQCL,
        ALMOST_FINISH,
        FINISH
    } init_states;
    init_states EMI_init_state;

    typedef enum logic [3:0] {
        IDLE,
        REF,
        ACCESS,
        INIT_CALIB,
        LOAD_CALIB,
        JUDGE_CALIB,
        EXIT_CALIB,
        READ_OFF,
        JUDGE_OFF
    } run_states;
    (* mark_debug = "true" *) run_states EMI_run_state;

    //Struct just syntehzises into wires.
    //Basically in 1EMI clk imma send 4 packed commands to OSERDES
    //And it will output them 1by one to ddr3 controller that is gonna
    //Run all of them. In practice tho, its gonna be 1 command and 3nops
    //Most of the times
    typedef struct packed {
        logic cs_n, ras_n, cas_n, we_n;
        logic [2:0]  ba;
        logic [13:0] a;
        logic cke, odt;
    } cmd_t;

    cmd_t cmd [4];

    //Btw micron chip works kinda similar to the CPU but not really.
    //CS#, RAS#, CAS# and WE# act kinda as 4bits of opcode. And a and ba
    //Act as immediates of some kind

    logic [31:0] cke_cnt; //cke init
    logic [11:0] tMRD_cnt, tREFI_cnt; //tREFI - refresh, tMRD - I use it alot tbh
    logic [7:0]  tACC_cnt; //Access counter, for RD/WR
    logic [23:0] tZQCS_cnt; //small recallibration every 128ms
    logic [3:0] ref_owed; //refreshes owed, DDR3 allows postponing up to 8
    logic [4:0] tRFC_cnt; //cycles since last REF
    logic ref_tick, tRFC_ok;
    logic [13:0] row_lat;
    logic [2:0]  bank_lat;
    logic new_req, nxt_req_miss, nxt_req_closed;
    logic [2:0]  nxt_bnk;
    logic [13:0] nxt_row;
    assign ref_tick = (tREFI_cnt > 625);
    assign tRFC_ok  = (tRFC_cnt > 14);
    logic tZQCS_pending;
    logic rd_run;
    logic we_lat;
    logic [15:0]  msk_lat;
    logic [127:0] wd_lat;
    logic [6:0]   col_lat;
    logic [127:0] dq_q; //thats a funny word
    logic [127:0] dq_q_prev; //temp imma change it later
    logic dqs_md, dq_md; //dq Manipulation disable 1 = (z), 0 = EMI drives
    logic [7:0]  dqs_ds;
    logic [2:0]  beat;
    logic cke_r;

    logic [7:0] open_banks;
    //LUTRAM
    (* ram_style = "distributed" *) logic [13:0] open_bank_rows [8];
    logic tbl_we;
    logic impaccable_hit;
    logic rdwd_rdy, issue_rw, rw_we;
    logic [6:0]  rw_col;
    logic [13:0] rw_a;
    logic [2:0]  rw_ba;

    logic [15:0] dq_dly; //delayed dq
    logic [15:0] dly_e; //dly enable for each DQ
    logic [79:0] dly_tap_cnt; //dly for every IDELAY(5bits each * 16 = 80)
    logic [79:0] dly_tap_out; //for debugging rn
    logic        idelay_rdy; //whether idelay is ready
    logic calibrating;
    (* mark_debug = "true" *) logic [15:0] s0, s1; //dq is actually split into 2
    logic [14:0] t0, t1;
    logic clean0_now, clean1_now;
    (* mark_debug = "true" *) logic clean0_r, clean1_r;
    logic [8:0] m0, m1;
    logic sig0_now, sig1_now;
    (* mark_debug = "true" *) logic sig0_r, sig1_r;
    logic acc_clean0, acc_clean1, acc_sig0, acc_sig1, run_sig0, run_sig1;
    logic tap_clean0, tap_clean1, tap_sig0, tap_sig1;
    logic [1:0] cal_rd_cnt;
    //Literally debug so vivado tracks it
    (* mark_debug = "true" *) logic [4:0] tap0, tap1;
    logic [4:0] start_cur0, start_cur1, start_best0, start_best1;
    logic [5:0] eye_len_cur0, eye_len_cur1;
    (* mark_debug = "true" *) logic [5:0] eye_len_best0, eye_len_best1;
    logic offcalib, init_offcalib;
    logic bitslip0, bitslip1, ok0, ok1;
    (* mark_debug = "true" *) logic done0, done1, ok0_r, ok1_r;
    logic [63:0] lane0_bytes, lane1_bytes;


    //Just for debug
    (* mark_debug = "true" *) logic [15:0] hit_cnt, closed_cnt, miss_cnt, early_pre_cnt, early_act_cnt;


    logic LOCKED;
    logic logic_rst_n;
    assign logic_rst_n = rst_n && LOCKED;
    logic rst_s1;
    //Basically there is no way to know where system goes out of reset, and
    //this just fixes it, 2ffs and rst_sunc_n is the clean rst_n
    always_ff @(posedge clkEMI or negedge logic_rst_n) begin
        if (!logic_rst_n) begin
            rst_s1 <= 0;
            rst_sync_n <= 0;
        end else begin
            rst_s1 <= 1;
            rst_sync_n <= rst_s1;
        end
    end
    //Main FSM logic runs on 83.3Mhz because 333.3/83.3 = 4 full cycles, thus
    //8edges and hence those 128bit burst in 1 83.3clk cycle
    always_ff @(posedge clkEMI or negedge rst_sync_n) begin : main_FSM
        if (!rst_sync_n) begin
            EMI_rdy <= 0;
            open_banks <= 8'b0;
            calib_failed <= 0;
            cke_cnt <= 32'b0;
            tMRD_cnt <= 6'b0;
            tACC_cnt <= 8'b0;
            EMI_rst_n <= 0;
            for (integer i = 0; i <= 3; i++) begin
                cmd[i] <= {cs_n: 1, ras_n: 1, cas_n: 1, we_n: 1, ba: 3'b0, a: 14'b0, cke: 0, odt: 0};
            end
            cke_r <= 0;
            mem_done <= 0;
            rd_run <= 0;
            we_lat <= 0;
            col_lat <= 0;
            dqs_md <= 1;
            dq_md <= 1;
            dqs_ds <= 8'b0000_0000;
            rdata <= 128'h0;

            hit_cnt <= 0;
            closed_cnt <= 0;
            miss_cnt <= 0;
            early_pre_cnt <= 0;
            early_act_cnt <= 0;

            dly_e <= 0;
            tap0 <= 0;
            tap1 <= 0;
            start_cur0 <= 0;
            start_cur1 <= 0;
            start_best0 <= 0;
            start_best1 <= 0;
            eye_len_cur0 <= 0;
            eye_len_cur1 <= 0;
            eye_len_best0 <= 0;
            eye_len_best1 <= 0;
            tZQCS_cnt <= 0;
            tZQCS_pending <= 0;
            ref_owed <= 0;
            tRFC_cnt <= 5'd31;
            row_lat <= 0;
            wd_lat <= 0;
            msk_lat <= 0;
            dq_q_prev <= 0;
            tREFI_cnt <= 0;
            bank_lat <= 0;

            calibrating <= 1;
            offcalib <= 0;
            init_offcalib <= 0;
            bitslip0 <= 0;
            bitslip1 <= 0;
            done0 <= 0;
            done1 <= 0;
            ok0_r <= 0;
            clean0_r <= 0;
            clean1_r <= 0;
            sig0_r <= 0;
            sig1_r <= 0;
            acc_clean0 <= 0;
            acc_clean1 <= 0;
            acc_sig0 <= 0;
            acc_sig1 <= 0;
            run_sig0 <= 0;
            run_sig1 <= 0;
            cal_rd_cnt <= 0;
            ok1_r <= 0;

            EMI_init_state <= INIT_INIT;
            EMI_run_state <= IDLE;
        end else if (EMI_init_state != FINISH) begin
            for (integer i = 0; i <= 3; i++) begin
                cmd[i].cs_n  <= 0;
                cmd[i].ras_n <= 1;
                cmd[i].cas_n <= 1;
                cmd[i].we_n  <= 1;
                cmd[i].cke   <= cke_r;
                cmd[i].odt   <= 0;
            end
            case (EMI_init_state)
                INIT_INIT: begin //idk what to say here
                    if (cke_cnt > 32'd17_500)
                        EMI_rst_n <= 1;
                    if (cke_cnt > 32'd62_750) begin
                        cke_r <= 1; //500us and 50ns(5 7.5ns cycles) it also holds 250us for rst but it doesn't matter 
                        EMI_init_state <= MR2;
                    end else begin
                        cke_cnt <= cke_cnt + 31'b1;
                    end
                end
                MR2: begin
                    if (tMRD_cnt > 13'd15) begin //15 cycles tXPR (170ns)
                        tMRD_cnt <= 6'b0;
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 0;
                        cmd[0].cas_n <= 0;
                        cmd[0].we_n <= 0;
                        cmd[0].ba <= 3'b010; //MR2
                        //Thats just a lucky combination for my exact FPGA
                        //Usually its different, it might even be different
                        //but just later when I get to actual PHY
                        cmd[0].a <= 14'b0;
                        EMI_init_state <= MR3;

                        ref_owed <= 0;
                        tREFI_cnt <= 0;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                MR3: begin
                    if (tMRD_cnt > 6'b00101) begin //5 cycles
                        tMRD_cnt <= 6'b0;
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 0;
                        cmd[0].cas_n <= 0;
                        cmd[0].we_n <= 0;
                        cmd[0].ba <= 3'b011; //MR3
                        //Coincedence again
                        cmd[0].a <= 14'b0;
                        EMI_init_state <= MR1;

                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                MR1: begin
                    if (tMRD_cnt > 6'b00101) begin
                        tMRD_cnt <= 6'b0;
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 0;
                        cmd[0].cas_n <= 0;
                        cmd[0].we_n <= 0;
                        cmd[0].ba <= 3'b001; //MR1
                        //Now we are talking tho
                        //The interesting thing is that it acually enables
                        //DLL which is !m0, and enables output(!m12)
                        cmd[0].a <= 14'b0;
                        //Output drive strengh = 01(m5, m1), 34Omhs
                        cmd[0].a[1] <= 1;
                        //RTT_nom = 011(m9, m6, 2), it is value of echo
                        //absorbing resistor, 011 is 40 Omhs, I wasn't sure
                        //What to set, so I just used MIG's value which
                        //Is this one.
                        cmd[0].a[6] <= 1;
                        cmd[0].a[2] <= 1;
                        EMI_init_state <= MR0;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                MR0: begin
                    if (tMRD_cnt > 6'b00101) begin
                        tMRD_cnt <= 6'b0;
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 0;
                        cmd[0].cas_n <= 0;
                        cmd[0].we_n <= 0;
                        cmd[0].ba <= 3'b000; //MR0


                        cmd[0].a <= 14'b0;
                        //DLL reset
                        cmd[0].a[8] <= 1;
                        //CAS latency 001: 5 cycles(15ns)
                        cmd[0].a[4] <= 1;

                        //Write recovery = 5(in cycles)
                        //just enough for amplifiers to set electrons
                        cmd[0].a[9] <= 1;
                        EMI_init_state <= ZQCL;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                ZQCL: begin
                    if (tMRD_cnt > 6'b01110) begin //14 cycles(need 12 2more jic)
                        tMRD_cnt <= 6'b0;
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 1;
                        cmd[0].cas_n <= 1;
                        cmd[0].we_n <= 0;

                        cmd[0].a <= 14'b0;
                        //Long ZQCL because its required on init
                        //Regular one can be used anytime for a
                        //small calibration. Long one is 512cycles whilst
                        //short one is 64cycles.
                        cmd[0].a[10] <= 1;

                        EMI_init_state <= ALMOST_FINISH;

                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                ALMOST_FINISH: begin
                    if (tMRD_cnt > 128) begin
                        tMRD_cnt <= 13'b0;
                        EMI_init_state <= FINISH;
                        EMI_run_state  <= INIT_CALIB;
                    end else
                        tMRD_cnt <= tMRD_cnt + 12'h1;
                end
            endcase
        end else begin
            for (integer i = 0; i <= 3; i++) begin
                cmd[i].cs_n  <= 0;
                cmd[i].ras_n <= 1;
                cmd[i].cas_n <= 1;
                cmd[i].we_n  <= 1;
                cmd[i].cke   <= cke_r;
                cmd[i].odt   <= 0;
            end
            mem_done <= 0;
            bitslip0 <= 0;
            bitslip1 <= 0;
            dq_q_prev <= dq_q; //again - temp var
            if (ref_tick) begin //7.8us
                tREFI_cnt <= 12'b0;
                //you can't refresh while MPR is on, however micron allows up
                //to 5 delayed, or rather owed refreshes, so I just count how
                //much I owed then give it back at REF. 5 should be plenty tho
                ref_owed <= ref_owed + 1;
            end else begin
                tREFI_cnt <= tREFI_cnt + 12'b1;
            end
            if (tRFC_cnt != 5'd31) tRFC_cnt <= tRFC_cnt + 1;
            if (tZQCS_cnt > 10_666_600) begin
                tZQCS_cnt <= 24'b0;
                tZQCS_pending <= 1;
            end else if (!tZQCS_pending) begin
                tZQCS_cnt <= tZQCS_cnt + 24'b1;
            end
            case (EMI_run_state)
                IDLE: begin
                    if (ref_owed != 0 && tRFC_ok) begin
                        if (|open_banks) begin
                            //PREA
                            cmd[0].ras_n <= 0;
                            cmd[0].cas_n <= 1;
                            cmd[0].we_n  <= 0;
                            cmd[0].a[10] <= 1; //PREA
                            open_banks <= 3'b0;
                        end else begin
                            //REF(resh)
                            //As I mentioned, I have to manually refresh
                            //Either of rows every 7.8us. The thing is tho
                            //I just need to initiate a REF command every 7.8us
                            //Because the ddr3's internal counter increases
                            //On every REF and point to the next row within the
                            //bank. Hence in 64ms it would refresh every row.
                            cmd[2].cs_n <= 0;
                            cmd[2].ras_n <= 0;
                            cmd[2].cas_n <= 0;
                            cmd[2].we_n <= 1;
                            ref_owed <= ref_owed - 1 + ref_tick;
                            tRFC_cnt <= 0;
                        end
                    end else if (tZQCS_pending && tRFC_ok) begin
                        if (|open_banks) begin
                            cmd[0].ras_n <= 0;
                            cmd[0].cas_n <= 1;
                            cmd[0].we_n  <= 0;
                            cmd[0].a[10] <= 1;
                            open_banks <= 3'b0;
                        end else begin
                            //ZQCS recallibres drivers, mainly based on temp.
                            //It has to be done about every 128ms.
                            cmd[2].cs_n <= 0;
                            cmd[2].ras_n <= 1;
                            cmd[2].cas_n <= 1;
                            cmd[2].we_n <= 0;
                            cmd[2].a[10] <= 0; //JIC
                            tZQCS_pending <= 0;
                        end
                    end else if (rdwd_rdy) begin //160ns tRFC
                        //Hit - very very good, we can straight up write
                        if (impaccable_hit) begin
                            tACC_cnt <= 2;
                            hit_cnt <= hit_cnt + 1;
                        //Closed - gotta open bank through ACT
                        end else if (!open_banks[req_addr[9:7]]) begin
                            //Moving ACT to here to save up 12ns of latency on each access
                            //ACTIVATE(ACT)
                            //It goes into third slot of cmd, so it would be 5cycles apart
                            //From RD/WR, bc that's some t i forgot
                            cmd[2].cs_n  <= 0; //So CS# is just harwired to 0 on my board???
                            cmd[2].ras_n <= 0;
                            cmd[2].cas_n <= 1;
                            cmd[2].we_n  <= 1;
                            cmd[2].a <= req_addr[23:10];
                            cmd[2].ba <= req_addr[9:7];
                            tACC_cnt <= 1;

                            open_banks[req_addr[9:7]] <= 1;
                            closed_cnt <= closed_cnt + 1;
                        //Complete miss - need to precharge(close) the bank and open another one
                        end else begin
                            //PRE, precharges open row within specified bank
                            cmd[0].cs_n  <= 0;
                            cmd[0].ras_n <= 0;
                            cmd[0].cas_n <= 1;
                            cmd[0].we_n  <= 0;
                            cmd[0].ba <= req_addr[9:7];
                            cmd[0].a[10] <= 0; //PRE
                            open_banks[req_addr[9:7]] <= 1;

                            row_lat <= req_addr[23:10];
                            bank_lat <= req_addr[9:7];
                            tACC_cnt <= 0;
                            miss_cnt <= miss_cnt + 1;
                        end

                        we_lat <= req_we; //latching jic, 25cycles afterall
                        msk_lat <= req_msk;
                        wd_lat <= req_wd;
                        col_lat <= req_addr[6:0];
                        bank_lat <= req_addr[9:7];
                        EMI_run_state <= ACCESS;
                    end
                end
                ACCESS: begin
                    //Both READ and WRITE start the same, activate, wait for
                    //5cycles init READ/WRITE and then the branch. After, they
                    //come back and finish
                    //What is really cool about it, is how
                    //that 24bit address is structured. In reality it is
                    //actually 27bit address(2byte aligned), however last
                    //3bits are always zero since the write happens in
                    //16bytes. So the CPU is gonna send a 26bit address to cache
                    //And cache is gonna drop last 2 bitsto get 24bit address.
                    //So im gonna encode this 24bit address like
                    //that: {row[23:10], bank[9:7], col[6:0]}. Why is this
                    //cool? bc col[9:3] is 2KB which is exactly size of one
                    //row within the bank. meaning increasing the address
                    //past, would actually just put me in another bank, which
                    //ofc reduces access speed.
                    tACC_cnt <= tACC_cnt + 1;
                    if (!(|tACC_cnt)) begin //This is purely for calib
                        if (calibrating | offcalib) begin
                            cmd[2].ras_n <= calibrating;

                            cmd[2].a[13:0] <= 14'h3FFF; //row
                            cmd[2].ba <= 3'b111; //bank

                            we_lat <= init_offcalib; //latching jic, 25cycles afterall
                            msk_lat <= 16'h0;
                            wd_lat <= 128'hFFFF_EEEE_DDDD_CCCC_BBBB_AAAA_9999_8888;
                        end else begin
                            cmd[2].ras_n <= 0;
                            cmd[2].a <= row_lat;
                            cmd[2].ba <= bank_lat;
                        end

                    //WRITE/READ happen below
                    end else if (tACC_cnt == (we_lat ? 8'd7 : 8)) begin
                        //the tri state was too fast, so solution is just to move all of them 1cycle later
                        dq_md <= 1;
                        if (!we_lat) rdata <= dq_q;
                        if (offcalib && !we_lat) begin
                            ok0_r <= ok0;
                            ok1_r <= ok1;
                        end
                        if (calibrating) begin
                            clean0_r <= clean0_now;
                            clean1_r <= clean1_now;
                            sig0_r <= sig0_now;
                            sig1_r <= sig1_now;
                        end
                        if (offcalib && we_lat) init_offcalib <= 0;
                            dqs_md <= 1;
                            tACC_cnt <= 8'b0;
                            mem_done <= !we_lat && !(calibrating | offcalib);
                            EMI_run_state <= calibrating ? JUDGE_CALIB : (offcalib ? (we_lat ? READ_OFF : JUDGE_OFF) : IDLE);
                    end else begin
                        if (we_lat) begin //writing on read would short circuit btw
                            case (tACC_cnt)
                                8'd2: begin
                                    dqs_ds <= 8'b0000_0000; //preamble
                                    cmd[0].odt <= 1; //odt should pulse for 6 clk333 cycles which is 6 cmd slots
                                    cmd[1].odt <= 1;
                                    cmd[2].odt <= 1;
                                    cmd[3].odt <= 1;
                                end
                                8'd3: begin
                                    dqs_ds <= 8'b1010_1010; //burst
                                    cmd[0].odt <= 1;
                                end
                                8'd4: begin //DQS manipulations enable, meaning EMI is driving DQ, not ddr3 or someone else
                                    dqs_ds <= 8'b0000_0000;
                                    dqs_md <= 0;
                                    dq_md <= 0;
                                end
                            endcase
                        end
                    end
                end
                INIT_CALIB: begin
                    //Calib basically calibrates the EMI for fpga's internal
                    //characteristics, such as wire lengths to a chip and
                    //maybe something else idk, but essentially it decides
                    //The delay of IODELAY for reads would land directly in
                    //the eye.
                    if (idelay_rdy) begin
                        if (!(|tMRD_cnt)) begin
                            cmd[0].cs_n <= 0;
                            cmd[0].ras_n <= 0;
                            cmd[0].cas_n <= 0;
                            cmd[0].we_n <= 0;
                            cmd[0].ba <= 3'b011; //MR3
                            cmd[0].a <= 14'b00_0000_0000_0100; //MPR
                            dly_e <= '1;
                            tMRD_cnt <= tMRD_cnt + 1;
                        end else if (tMRD_cnt > 4) begin //tMOD + tMRD
                            tMRD_cnt <= 0;
                            EMI_run_state <= LOAD_CALIB;
                        end else begin
                            tMRD_cnt <= tMRD_cnt + 1;
                        end
                    end
                end
                LOAD_CALIB: begin
                    //It does that by enabling MPR, which is a special
                    //register in the chip holding the bit sequence of
                    //1010101010101010 something like that. When it is enabled
                    //Any reads from ddr3 return that pattern. Considering that imma
                    //Test each cnt of taps and seeing where eye lands the
                    //best. Thats basically an actual memory training that happened
                    //On your PC when you first booted, in your CPU its cached tho.
                    if (tRFC_ok) begin
                        if (tMRD_cnt == 3) begin
                            tMRD_cnt <= 0;
                            EMI_run_state <= ACCESS;
                        end else begin
                            tMRD_cnt <= tMRD_cnt + 1;
                        end
                    end
                end
                JUDGE_CALIB: begin
                    //Check if pattern matches, if it doesn't like different
                    //pattern x, z or whatever else we've at the edge of an eye

                    if (cal_rd_cnt != 2'd3) begin
                        acc_clean0 <= tap_clean0;
                        acc_clean1 <= tap_clean1;
                        acc_sig0 <= tap_sig0;
                        acc_sig1 <= tap_sig1;
                        cal_rd_cnt <= cal_rd_cnt + 1;
                        EMI_run_state <= LOAD_CALIB;
                    end else begin
                        cal_rd_cnt <= 0;

                        //For each lane check whether its the best run so far
                        //It really is just that
                        if (tap_clean0) begin
                            if (eye_len_cur0 != 0 && tap_sig0 == run_sig0) begin
                                eye_len_cur0 <= eye_len_cur0 + 1;
                                if (eye_len_cur0 + 1 > eye_len_best0) begin
                                    eye_len_best0 <= eye_len_cur0 + 1;
                                    start_best0 <= start_cur0;
                                end
                            end else begin
                                start_cur0 <= tap0;
                                run_sig0 <= tap_sig0;
                                eye_len_cur0 <= 1;
                                if (eye_len_best0 == 0) begin
                                    eye_len_best0 <= 1;
                                    start_best0 <= tap0;
                                end
                            end
                        end else begin
                            eye_len_cur0 <= 0;
                        end

                        if (tap_clean1) begin
                            if (eye_len_cur1 != 0 && tap_sig1 == run_sig1) begin
                                eye_len_cur1 <= eye_len_cur1 + 1;
                                if (eye_len_cur1 + 1 > eye_len_best1) begin
                                    eye_len_best1 <= eye_len_cur1 + 1;
                                    start_best1 <= start_cur1;
                                end
                            end else begin
                                start_cur1 <= tap1;
                                run_sig1 <= tap_sig1;
                                eye_len_cur1 <= 1;
                                if (eye_len_best1 == 0) begin
                                    eye_len_best1 <= 1;
                                    start_best1 <= tap1;
                                end
                            end
                        end else begin
                            eye_len_cur1 <= 0;
                        end

                        if (tap0 == 5'd31) begin
                            tMRD_cnt <= 0;
                            EMI_run_state <= EXIT_CALIB;
                        end else begin
                            tap0 <= tap0 + 1;
                            tap1 <= tap1 + 1;
                            EMI_run_state <= LOAD_CALIB;
                        end
                    end
                end
                EXIT_CALIB: begin
                    if (!(|tMRD_cnt)) begin
                        //Just finilize the taps, set MR3 to regualr reads
                        //And exit to IDLE
                        tap0 <= start_best0 + eye_len_best0[5:1]; //<<1, which is /2 which is just average
                        tap1 <= start_best1 + eye_len_best1[5:1];
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 0;
                        cmd[0].cas_n <= 0;
                        cmd[0].we_n <= 0;
                        cmd[0].ba <= 3'b011; //MR3
                        cmd[0].a <= 14'b0;
                        tMRD_cnt <= tMRD_cnt + 1;
                    end else if (tMRD_cnt > 4) begin
                        tMRD_cnt <= 0;
                        calibrating <= 0;
                        EMI_run_state <= ACCESS;
                        init_offcalib <= 1;
                        offcalib <= 1;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 1;
                    end
                end
                READ_OFF: begin
                    //So i couldn't figure out for a while why it didn't work,
                    //until I realized that beats kinda overlap, if they have
                    //like different latency one if last beats of first
                    //8 beats might land at first beats of second 8beats. So
                    //this is next calib stage, I write some arbitary number
                    //To some arbitary address and then read it using
                    //different bit offsets. And the cool part is that this
                    //bit offset is a built-in feature of ISERDES called
                    //BITSLIP, so I just test each BITSLIP, figure out which value
                    //Reads the exact data.
                    EMI_run_state <= ACCESS; //READ
                end
                JUDGE_OFF: begin
                    //lane 0 = low byte of each beat, lane 1 = high byte
                    if (tMRD_cnt == 0) begin
                        if (!done0) begin
                            if (ok0_r) done0 <= 1;
                            else bitslip0 <= 1;
                        end
                        if (!done1) begin
                            if (ok1_r) done1 <= 1;
                            else bitslip1 <= 1;
                        end
                    end

                    if ((done0 | ok0_r) && (done1 | ok1_r)) begin //calib doneeee
                        tMRD_cnt <= 0;
                        offcalib <= 0;
                        EMI_rdy <= 1;
                        EMI_run_state <= IDLE;
                    end else if (tMRD_cnt > 3) begin
                        tMRD_cnt <= 0;
                        EMI_run_state <= READ_OFF;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 1;
                    end

                    if ((bitslip0 | bitslip1) > 9) begin
                        calib_failed <= 1;
                    end
                end
                endcase
                //Since both IDLE and ACCESS can write, and I don't want to
                //duplicate the code I just check it combinationally and write
                //here.
                if (issue_rw) begin
                    //READ/WRITE
                    //On the last one so its aligned and 5cycles apart
                    cmd[3].cs_n <= 0;
                    cmd[3].ras_n <= 1;
                    cmd[3].cas_n <= 0;
                    cmd[3].we_n <= !rw_we | calibrating;
                    cmd[3].ba <= rw_ba;
                    cmd[3].a <= rw_a;
                    cmd[3].odt <= rw_we;
                end
                if (nxt_req_miss && tACC_cnt == (we_lat ? 6 : 4)) begin
                    //4 for reads 6 for writes so just 6 ck cycles
                    //PRE
                    //Close bank early so IDLE can start with ACT saving 1 cycle
                    cmd[3].ras_n <= 0;
                    cmd[3].cas_n <= 1;
                    cmd[3].we_n  <= 0;
                    cmd[3].a[10] <= 0; //PRE
                    cmd[3].ba <= nxt_bnk;
                    open_banks[nxt_bnk] <= 0;
                    early_pre_cnt <= early_pre_cnt + 1;
                end else if (nxt_req_closed && tACC_cnt == 1) begin
                    //ACT
                    //So IDLE can just straight up read/write to that bank
                    cmd[2].cs_n  <= 0;
                    cmd[2].ras_n <= 0;
                    cmd[2].cas_n <= 1;
                    cmd[2].we_n  <= 1;
                    cmd[2].a <= nxt_row;
                    cmd[2].ba <= nxt_bnk;

                    open_banks[nxt_bnk] <= 1;
                    early_act_cnt <= early_act_cnt + 1;
                end
            end
        end : main_FSM

    //Row table in LUTRAM: no reset, one write port, async read
    assign tbl_we = (EMI_run_state == IDLE && rdwd_rdy && !impaccable_hit)   //closed or miss opens a new row
                 || (nxt_req_closed && tACC_cnt == 1);                       //early ACT
    always_ff @(posedge clkEMI) begin
        if (tbl_we) open_bank_rows[req_addr[9:7]] <= req_addr[23:10];
    end

    //Combinationally compute what goes into a for RD/WD bc it can go to both
    //IDLE and access and I hate duplicating code.
    always_comb begin : lookahead
        impaccable_hit = open_banks[req_addr[9:7]] && (open_bank_rows[req_addr[9:7]] == req_addr[23:10]);

        //basically a big checked moved from IDLE check
        rdwd_rdy = (ref_owed == 0)
             && !tZQCS_pending
             && tRFC_ok && tZQCS_cnt > 64
             && req && EMI_rdy;

        //read/write
        rw_col = (EMI_run_state == IDLE) ? req_addr[6:0]
                                        : (offcalib ? 7'h7F : col_lat); //req addr i idle lat in access

        rw_a = {3'b000, (calibrating | offcalib), rw_col, 3'b000};//auto precharge only during calib
        rw_ba = offcalib ? 3'b111 : (EMI_run_state == IDLE) ? req_addr[9:7] : bank_lat;
        rw_we = (EMI_run_state == IDLE) ? req_we : we_lat;

        issue_rw = (EMI_run_state == IDLE && rdwd_rdy && impaccable_hit)
                    || (EMI_run_state == ACCESS && tACC_cnt == 1);

        req_awck = (EMI_run_state == IDLE) && rdwd_rdy;

        nxt_bnk = req_addr[9:7];
        nxt_row = req_addr[23:10];

        //Actual lookahead logic it peeks at the next request and checks
        //whether its misses/hits or closed.
        new_req = (EMI_run_state == ACCESS) && req && !calibrating && !offcalib;
        //Miss within bank
        nxt_req_miss = new_req && (nxt_bnk == bank_lat) && (nxt_row != open_bank_rows[req_addr[9:7]]);
        //closed bank
        nxt_req_closed = new_req && (nxt_bnk != bank_lat) && !open_banks[nxt_bnk];
    end : lookahead

    //The MRP checks is position(bitsplit) independent.
    //So its clean, then we can glue it all together.
    assign dly_tap_cnt = {{8{tap1}}, {8{tap0}}};
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            s0[i]     = dq_q_prev[16*i + 0];
            s0[i + 8] = dq_q[16*i + 0];
            s1[i]     = dq_q_prev[16*i + 8];
            s1[i + 8] = dq_q[16*i + 8];
        end
    end
    //So there was this bug before that it would falsely accuse edge between
    //beats to be an eye, because between beats there is basically guaranteed
    //To be some valid data.
    assign t0 = s0[15:1] ^ s0[14:0];
    assign t1 = s1[15:1] ^ s1[14:0];
    always_comb begin
        for (int i = 0; i < 9; i++) begin
            m0[i] = (&t0[i +: 7]) & ~s0[i];
            m1[i] = (&t1[i +: 7]) & ~s1[i];
        end
    end
    assign clean0_now = |m0;
    assign clean1_now = |m1;
    assign sig0_now = |(m0 & 9'b0_1010_1010);
    assign sig1_now = |(m1 & 9'b0_1010_1010);
    assign tap_clean0 = (cal_rd_cnt == 0) ? clean0_r : (acc_clean0 & clean0_r & (sig0_r == acc_sig0));
    assign tap_clean1 = (cal_rd_cnt == 0) ? clean1_r : (acc_clean1 & clean1_r & (sig1_r == acc_sig1));
    assign tap_sig0 = (cal_rd_cnt == 0) ? sig0_r : acc_sig0;
    assign tap_sig1 = (cal_rd_cnt == 0) ? sig1_r : acc_sig1;

    //Gotta compute them combinationally and latch, bc on next cycle they are
    //a little bit outdated. Basically I check for every byte of the 2byte
    //burst read and align them as stated above.

    //Now I check if read value that I wrote matches, if it does - good it is
    //calibrated, if it isn't I increase BITSLIP to check for the next slip.
    //Regarding bitslip, its kinda like rotl but not really, it specifies
    //where read value starts, pulsing its value ones just increases it. Fun
    //fact about it on DDR mode, on first pulse it increases by shifts right
    //by 1, on second shifts left by 3, and so on. Idk why it is like that,
    //but I assume because it happens on every edge of a clock. Anyways it
    //doesn't matter bc if it goes out of bounds it just returns from other
    //side, so +1, -3 pattern eventually will cover every slip and find the
    //right one.
    assign lane0_bytes = {dq_q[119:112], dq_q[103:96], dq_q[87:80], dq_q[71:64],
                          dq_q[55:48],   dq_q[39:32],  dq_q[23:16], dq_q[7:0]};
    assign lane1_bytes = {dq_q[127:120], dq_q[111:104], dq_q[95:88], dq_q[79:72],
                          dq_q[63:56],   dq_q[47:40],   dq_q[31:24], dq_q[15:8]};
    assign ok0 = (lane0_bytes == 64'hFF_EE_DD_CC_BB_AA_99_88); //ok
    assign ok1 = (lane1_bytes == 64'hFF_EE_DD_CC_BB_AA_99_88);


    //This is outdated comment about writes, it was here before now its gone.
    //The main idea is still prolly there tho.
    //write, write, write, so as usual, all the data is in
    //micron datasheet, all those diagrams, instructions,
    //timings and all are there. Basically write happens in
    //bursts of 16bytes, you can either write all bytes or
    //mask some of them, you first need to activate the row
    //And after write you may or may not close it - that defines
    //Either closed-page or open-page design, each one has its
    //own benefits and drawback, for now ill write closed-page
    //Later planning to switch to look-ahead. Write takes about 10cycles
    //for actual write + 19cycles for varios waits, hence
    //about 25 cycles total, hence 75ns.
    //like about 30ns.
    //
    //Alright DQS, so DQS is a physical wire that is running from the
    //same place as data bus does, and its of the same length. Its
    //primary functino is to align data because it takes the exact
    //same time as memory does. And dqs_n and dqs_p further refines
    //that effect. I set the DQS accordingly to micron datasheet, as
    //I do for everything else tbh.

    //The burst(thats a big name for this) happens in 4 cycles, of 16bit writes
    //4 cycles bc on it happens on every clk90 edge

    logic CLKFB;
    //3 clock freqs(not domains) for EMI 333.3Mhz, 333.3Mhz 90degrees shifted and 83.3Mhz.
    //333.3Mhz because it is maximum possible frequency that my artix-7 FPGA allows
    //And 83.3 Just because 333.3/4 = 83.3Mhz. Not domains bc 333.3Mhz doesn't
    //run any logic.
    //Anyways clocks are pretty cool there are 2 types of primiteves
    //generating clock: PLL and MMCM, they are very similar actually.
    //So each one of them has VCO which is a series of inverters(2 transistors)
    //And they well invert the incoming signal. In my FPGA there are 8inverters
    //4 for _p and 4 for _n, and there is a crossover between them(swaps them).
    //They are wired in a loop, and becaues there is odd number of swaps, when 
    //Electrisity go to a loop again it swaps inverters, and then again and
    //again, essentially chasing its own tail and never reaching it. Now the
    //current can change how fast those inverters discharge, or something, and based
    //on that electrisity would flow faster there hence increasing the speed.
    //There is also a 1main quartz oscilator, it acts more as a reference,
    //each VCO compares itself to it, and ensures it acts where it should, and
    //re-callibrates if it acts at the wrong time. Eg 200Mhz clock every
    //4cycles checks whether it lines up with 50Mhz main clk333.
    PLLE2_BASE #( //base is fine, i don't need adv for emi
        .BANDWIDTH("OPTIMIZED"), //just standard optimized is fine
        .CLKFBOUT_MULT(20), //Base clock 50MHz * 20 = 1000
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(20.0), //50Mhz main quartz
        //The clock division works by activating a pariticular clk333 output
        //Only between pariticular amount of clock edges. E.g., 333.3Mhz toggles
        //Every 3rd edge of the clk333.
        .CLKOUT0_DIVIDE(3), //333.3Mhz
        .CLKOUT1_DIVIDE(3), //333.3Mhz 90degrees
        .CLKOUT2_DIVIDE(12), //83.3Mhz
        .CLKOUT3_DIVIDE(5),
        .CLKOUT4_DIVIDE(1),
        .CLKOUT5_DIVIDE(1),
        //Doesn't matter
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .CLKOUT2_DUTY_CYCLE(0.5),
        .CLKOUT3_DUTY_CYCLE(0.5),
        .CLKOUT4_DUTY_CYCLE(0.5),
        .CLKOUT5_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_PHASE(90.0), //90degreees
        .CLKOUT2_PHASE(0.0),
        .CLKOUT3_PHASE(0.0),
        .CLKOUT4_PHASE(0.0),
        .CLKOUT5_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .REF_JITTER1(0.010), //That purely for simulation 0.010 is just a plausible number
        .STARTUP_WAIT("FALSE")
    )
    PLLE2_EMI (
        .CLKOUT0(clk_pll),
        .CLKOUT1(clk90_pll),
        .CLKOUT2(clkEMI_pll),
        .CLKOUT3(clk200_pll), //for IDELAYCTRL
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKFBOUT(CLKFB),
        .LOCKED(LOCKED),
        .CLKIN1(clk_crystal),
        .PWRDWN(1'b0), //constantly on
        .RST(!rst_n),
        .CLKFBIN(CLKFB) //wiriting it to each other, internal loop
    );

    //BUFGs are buffers for clock, they are a clock tree driven by clock
    //backbone. They are placed kinda like that.
    //  BUFG-|-BUFG
    //  BUFG-|-BUFG
    //      clk333
    //The ensure clock arrives everywhere at the same time. Here the well, do
    //that exact thing
    BUFG bufg_clk    (.I(clk_pll),    .O(clk333)); //I think you know what those ports are
    BUFG bufg_clk90  (.I(clk90_pll),  .O(clk90));
    BUFG bufg_clkEMI (.I(clkEMI_pll), .O(clkEMI));
    BUFG bufg_clk200 (.I(clk200_pll), .O(clk200));

    logic ck_temp;
    full_oserder ck (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
                    .ds(8'b1010_1010), .trie(1'b0), .oq(ck_temp), .tq());

    OBUFDS #( //makes input differential, rn for ck_p and thus ck_n
        .IOSTANDARD("DEFAULT"),
        .SLEW("FAST")
    ) OBUFDS_ck (
        .O(ck_p),
        .OB(ck_n),
        .I(ck_temp)
    );

    //So that isn't your refular for loop its a loop that generates those
    //oser8bits instances on init, it basically is just syntax to insatante several
    //oser8bits.
    for (genvar i = 0; i < 14; i++) begin : a_ser //14address bits, one OSERDES for each bit
        full_oserder u (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
                .ds({
                    cmd[3].a[i],
                    cmd[3].a[i],
                    cmd[2].a[i],
                    cmd[2].a[i],
                    cmd[1].a[i],
                    cmd[1].a[i],
                    cmd[0].a[i],
                    cmd[0].a[i]
                }),
                .trie(1'b0), .oq(a[i]), .tq());
    end : a_ser

    //Just running every signal throught OSERDES to ddr3 chip
    //_ser is serializer btw
    for (genvar i = 0; i < 3; i++) begin : ba_ser
        full_oserder u (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
                .ds({
                    cmd[3].ba[i],
                    cmd[3].ba[i],
                    cmd[2].ba[i],
                    cmd[2].ba[i],
                    cmd[1].ba[i],
                    cmd[1].ba[i],
                    cmd[0].ba[i],
                    cmd[0].ba[i]
                }),
                .trie(1'b0), .oq(ba[i]), .tq());
    end : ba_ser

    //Alright so eye catching and taps and calib overall its a interesting one
    //idk if I already fully explained it but I will do it again. Basically
    //due to board's wire length and temp electrisity takes different time to
    //travel from fpga to ddr3. And Im p sure i explained taps, which is eye
    //catching. That introduces another problem tho - the beats get offset by
    //a different amount usually, and they might overlap. Like one beat is
    //giving output of the other one, kinda like that:
    // a b c d e f g h
    //               a b c d e f g h
    //h and a are overlapped, so this is where bitslip comes in, i explained
    //it below.

    full_oserder cs_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({cmd[3].cs_n, cmd[3].cs_n, cmd[2].cs_n, cmd[2].cs_n,
                 cmd[1].cs_n, cmd[1].cs_n, cmd[0].cs_n, cmd[0].cs_n}),
            .trie(1'b0), .oq(cs_n), .tq());

    full_oserder ras_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({cmd[3].ras_n, cmd[3].ras_n, cmd[2].ras_n, cmd[2].ras_n,
                 cmd[1].ras_n, cmd[1].ras_n, cmd[0].ras_n, cmd[0].ras_n}),
            .trie(1'b0), .oq(ras_n), .tq());

    full_oserder cas_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({cmd[3].cas_n, cmd[3].cas_n, cmd[2].cas_n, cmd[2].cas_n,
                 cmd[1].cas_n, cmd[1].cas_n, cmd[0].cas_n, cmd[0].cas_n}),
            .trie(1'b0), .oq(cas_n), .tq());

    full_oserder we_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({cmd[3].we_n, cmd[3].we_n, cmd[2].we_n, cmd[2].we_n,
                 cmd[1].we_n, cmd[1].we_n, cmd[0].we_n, cmd[0].we_n}),
            .trie(1'b0), .oq(we_n), .tq());

    full_oserder cke_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({cmd[3].cke, cmd[3].cke, cmd[2].cke, cmd[2].cke,
                 cmd[1].cke, cmd[1].cke, cmd[0].cke, cmd[0].cke}),
            .trie(1'b0), .oq(cke), .tq());

    full_oserder odt_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({cmd[3].odt, cmd[3].odt, cmd[2].odt, cmd[2].odt,
                 cmd[1].odt, cmd[1].odt, cmd[0].odt, cmd[0].odt}),
            .trie(1'b0), .oq(odt), .tq());

    //More OSERDESes now for actual dqs, dq and mask
    logic [15:0] dq_oq, dq_tq, dq_in; //tq is tri-state out switcher
    for (genvar i = 0; i < 16; i++) begin : dq_ser
        //That literally like beats i had previosely, 8writes of 16bits for 4clk
        full_oserder #(.TQ_MODE("BUF")) dq_ser (.clk333(clk90), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({
                wd_lat[i + 112],
                wd_lat[i + 96],
                wd_lat[i + 80],
                wd_lat[i + 64],
                wd_lat[i + 48],
                wd_lat[i + 32],
                wd_lat[i + 16],
                wd_lat[i + 00]
            }), .trie(dq_md), .oq(dq_oq[i]), .tq(dq_tq[i])
        );

        //IOBUF is a literally pin at the edge of FPGA that connectects to
        //a physical wires going into ddr3 chip. It is tri-state two way pin
        IOBUF #(.IOSTANDARD("DEFAULT"), .SLEW("FAST"), .IBUF_LOW_PWR("FALSE")) dq_iobuf (
            .I(dq_oq[i]), .T(dq_tq[i]), .O(dq_in[i]), .IO(dq[i]));
    end : dq_ser

    //dq
    logic [1:0] dqs_oq, dqs_tq, dqs_in;
    for (genvar i = 0; i < 2; i++) begin : dqs_ser
        full_oserder #(.TQ_MODE("BUF")) dqs_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds(dqs_ds), .trie(dqs_md), .oq(dqs_oq[i]), .tq(dqs_tq[i])
        );

        //differential IOBUF
        IOBUFDS #(.IOSTANDARD("DEFAULT"), .SLEW("FAST"), .IBUF_LOW_PWR("FALSE")) dqs_buf (
        .I(dqs_oq[i]), .T(dqs_tq[i]), .O(dqs_in[i]), .IO(dqs_p[i]), .IOB(dqs_n[i]));
    end : dqs_ser

    //dm doesn't need any buffer since its 1way pin
    for (genvar i = 0; i < 2; i++) begin : dm_ser
        full_oserder dm_ser (.clk333(clk90), .clkEMI(clkEMI), .rst_n(rst_sync_n),
            .ds({
                msk_lat[i + 14],
                msk_lat[i + 12],
                msk_lat[i + 10],
                msk_lat[i + 8],
                msk_lat[i + 6],
                msk_lat[i + 4],
                msk_lat[i + 2],
                msk_lat[i + 0]
            }), .trie(1'b0), .oq(dm[i]), .tq()
        );
    end : dm_ser

    //ISERDESE is an opposite of OSERDES, it takes serial input at clk and
    //outputs parralel at clkdiv. As you might have guessed its for reads.
    //Btw I already have IOBUF for it, bc IOBUF is two-way
    for (genvar i = 0; i < 16; i++) begin : dq_des
        ISERDESE2 #(
            .DATA_RATE("DDR"),
            .DATA_WIDTH(8),
            .DYN_CLKDIV_INV_EN("FALSE"),
            .DYN_CLK_INV_EN("FALSE"),

            .INIT_Q1(1'b0),
            .INIT_Q2(1'b0),
            .INIT_Q3(1'b0),
            .INIT_Q4(1'b0),

            .INTERFACE_TYPE("NETWORKING"),
            .IOBDELAY("IFD"),
            .NUM_CE(2),
            .OFB_USED("FALSE"),
            .SERDES_MODE("MASTER"),

            .SRVAL_Q1(1'b0),
            .SRVAL_Q2(1'b0),
            .SRVAL_Q3(1'b0),
            .SRVAL_Q4(1'b0)
        )
        ISERDESE2_reads (
            .O(), //outputs to rdata
            .Q1(dq_q[i + 112]),
            .Q2(dq_q[i + 96]),
            .Q3(dq_q[i + 80]),
            .Q4(dq_q[i + 64]),
            .Q5(dq_q[i + 48]),
            .Q6(dq_q[i + 32]),
            .Q7(dq_q[i + 16]),
            .Q8(dq_q[i + 00]),

            .SHIFTOUT1(),
            .SHIFTOUT2(),

            .BITSLIP(i < 8 ? bitslip0 : bitslip1),
            .CE1(1'b1),
            .CE2(1'b1),

            .CLKDIVP(1'b0),
            .CLK(clk333),
            .CLKB(~clk333),
            .CLKDIV(clkEMI),
            .OCLK(1'b0),

            .DYNCLKDIVSEL(1'b0),
            .DYNCLKSEL(1'b0),

            //Inputs from dq_in from IOBUF
            .D(1'b0),
            .DDLY(dq_dly[i]),
            .OFB(1'b0),
            .OCLKB(1'b0),

            .RST(!rst_sync_n),
            .SHIFTIN1(1'b0),
            .SHIFTIN2(1'b0)
        );

        //The thing is, in real world there isn't really a way
        //To tell where ddr3 data will arrive due to PCB wire lengths
        //Temprerature and other factors. IODELAY solves that problem
        //by delaying the signal so it lands on an eye. On my FPGA it does
        //That through a set of "taps" each one of them delays signal by exactly
        //78ps, and there are 32of them. They automatically callibrate based on
        //REFCLK that has to be 200Mhz.

        (* IODELAY_GROUP = "ddr3_grp" *)
        IDELAYE2 #(
            .CINVCTRL_SEL("FALSE"),
            .DELAY_SRC("IDATAIN"),
            .HIGH_PERFORMANCE_MODE("TRUE"), //yessir
            .IDELAY_TYPE("VAR_LOAD"), //just put it straight to the eye
            .IDELAY_VALUE(0),
            .PIPE_SEL("FALSE"),
            .REFCLK_FREQUENCY(200.0),
            .SIGNAL_PATTERN("DATA")
        )
        IDELAYE2_reads (
            .CNTVALUEOUT(dly_tap_out[i*5 +: 5]),
            .DATAOUT(dq_dly[i]),
            .C(clkEMI),
            .CE(1'b0),
            .CINVCTRL(1'b0),
            .CNTVALUEIN(dly_tap_cnt[i*5 +: 5]),
            .DATAIN(1'b0),
            .IDATAIN(dq_in[i]),
            .INC(1'b0),
            .LD(dly_e[i]),
            .LDPIPEEN(1'b0),
            .REGRST(!rst_sync_n)
        );
    end : dq_des

    (* IODELAY_GROUP = "ddr3_grp" *)
    IDELAYCTRL IDELAYCTRL_ddr3 (
        .RDY(idelay_rdy),
        .REFCLK(clk200),
        .RST(!LOCKED)
    );


endmodule
