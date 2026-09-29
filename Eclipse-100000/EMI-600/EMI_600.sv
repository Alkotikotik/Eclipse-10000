module EMI_600 (
    //Eclipse Memory Interface(EMI)
    input logic clk,
    input logic clk90,
    input logic rst_n,

    input logic req, //CPU requests data
    input logic req_we, //1 - write, 0 - read
    input logic [23:0] req_addr, //address 16byte addressible
    input logic [127:0] req_wd, //16byte write data
    input logic [15:0] req_msk, //which of 16bytes to mask


    output logic [127:0] rdata, //read data
    output logic mem_done,

    output logic EMI_rst_n,

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
    output logic [13:0] a

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
    //as much, only about 5% max. That is the main principle of how memory
    //works. Also hence each bank can open 1row 16KB of rows
    //can be opened at ones.


    //It might look that im a little crazy but if you think about it
    //It actually makes sense
    assign ck_p = ~clk;
    assign ck_n = clk;

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
        ACCESS
    } run_states;
    run_states EMI_run_state;

    logic [31:0] cke_cnt;
    logic [11:0] tMRD_cnt, tREFI_cnt;
    logic [7:0]  tACC_cnt;
    logic tREFI_pending;
    logic rd_run;
    logic we_lat;
    logic [15:0]  msk_lat;
    logic [127:0] wd_lat;
    logic dqs_me, dqs_run, dq_me;
    logic [1:0]  dqs_val;
    logic [2:0]  beat;
    logic [15:0] dq_out;
    logic [1:0]  dm_out;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cke_cnt <= 32'b0;
            tMRD_cnt <= 6'b0;
            tACC_cnt <= 8'b0;
            EMI_rst_n <= 0;
            ba <= 3'b0;
            a <= 14'b0;
            cke  <= 0;
            odt  <= 0;
            mem_done <= 0;
            rd_run <= 0;
            we_lat <= 0;
            dqs_me <= 0;
            dqs_run <= 0;
            rdata <= 128'h0;

            EMI_init_state <= INIT_INIT;
            EMI_run_state <= IDLE;
        end else if (EMI_init_state != FINISH) begin
            cs_n <= 0; ras_n <= 1; cas_n <= 1; we_n <= 1; //defualt NOP
            case (EMI_init_state)
                INIT_INIT: begin //idk what to say here
                    if (cke_cnt > 32'd70_000)
                        EMI_rst_n <= 1;
                    if (cke_cnt > 32'd251_000) begin
                        cke <= 1; //500us and 50ns(5 7.5ns cycles) it also holds 250us for rst but it doesn't matter 
                        EMI_init_state <= MR2;
                    end else begin
                        cke_cnt <= cke_cnt + 31'b1;
                    end
                end
                MR2: begin
                    if (tMRD_cnt > 13'd57) begin //57 cycles tXPR (170ns)
                        tMRD_cnt <= 6'b0;
                        cs_n <= 0;
                        ras_n <= 0;
                        cas_n <= 0;
                        we_n <= 0;
                        ba <= 3'b010; //MR2
                        //Thats just a lucky combination for my exact FPGA
                        //Usually its different, it might even be different
                        //but just later when I get to actual PHY
                        a <= 14'b0;
                        EMI_init_state <= MR3;

                        tREFI_pending <= 0;
                        tREFI_cnt <= 0;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                MR3: begin
                    if (tMRD_cnt > 6'b00101) begin //5 cycles
                        tMRD_cnt <= 6'b0;
                        cs_n <= 0;
                        ras_n <= 0;
                        cas_n <= 0;
                        we_n <= 0;
                        ba <= 3'b011; //MR3

                        //Coincedence again
                        a <= 14'b0;
                        EMI_init_state <= MR1;

                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                MR1: begin
                    if (tMRD_cnt > 6'b00101) begin
                        tMRD_cnt <= 6'b0;
                        cs_n <= 0;
                        ras_n <= 0;
                        cas_n <= 0;
                        we_n <= 0;
                        ba <= 3'b001; //MR1

                        //Now we are talking tho
                        //The interesting thing is that it acually enables
                        //DLL which is !m0, and enables output(!m12)
                        a <= 14'b0;

                        //Output drive strengh = 01(m5, m1), 34Omhs
                        a[1] <= 1;

                        //RTT_nom = 011(m9, m6, 2), it is value of echo
                        //absorbing resistor, 011 is 40 Omhs, I wasn't sure
                        //What to set, so I just used MIG's value which
                        //Is this one.
                        a[6] <= 1;
                        a[2] <= 1;
                        EMI_init_state <= MR0;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                MR0: begin
                    if (tMRD_cnt > 6'b00101) begin
                        tMRD_cnt <= 6'b0;
                        cs_n <= 0;
                        ras_n <= 0;
                        cas_n <= 0;
                        we_n <= 0;
                        ba <= 3'b000; //MR0


                        a <= 14'b0;
                        //DLL reset
                        a[8] <= 1;
                        //CAS latency 001: 5 cycles(15ns)
                        a[4] <= 1;

                        //Write recovery = 5(in cycles)
                        //just enough for amplifiers to set electrons
                        a[9] <= 1;
                        EMI_init_state <= ZQCL;
                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                ZQCL: begin
                    if (tMRD_cnt > 6'b01110) begin //14 cycles(need 12 2more jic)
                        tMRD_cnt <= 6'b0;
                        cs_n <= 0;
                        ras_n <= 1;
                        cas_n <= 1;
                        we_n <= 0;

                        a <= 14'b0;
                        //Long ZQCL because its required on init
                        //Regular one can be used anytime for a
                        //small calibration. Long one is 512cycles whilst
                        //short one is 64cycles.
                        a[10] <= 1;

                        EMI_init_state <= ALMOST_FINISH;

                    end else begin
                        tMRD_cnt <= tMRD_cnt + 6'h1;
                    end
                end
                ALMOST_FINISH: begin
                    if (tMRD_cnt > 512) begin
                        tMRD_cnt <= 13'b0;
                        EMI_init_state <= FINISH;
                    end else
                        tMRD_cnt <= tMRD_cnt + 12'h1;
                end
            endcase
        end else begin
            cs_n <= 0; ras_n <= 1; cas_n <= 1; we_n <= 1;
            mem_done <= 0;
            if (tREFI_cnt > 2500) begin //7.8us
                tREFI_cnt <= 12'b0;
                tREFI_pending <= 1;
            end else if (!tREFI_pending) begin
                tREFI_cnt <= tREFI_cnt + 12'b1;
            end
            case (EMI_run_state)
                IDLE: begin
                    if (tREFI_pending && !(|tREFI_cnt)) begin
                        //REF(resh)
                        //As I mentioned, I have to manually refresh
                        //Either of rows every 7.8us. The thing is tho
                        //I just need to initiate a REF command every 7.8us
                        //Because the ddr3's internal counter increases
                        //On every REF and point to the next row within the
                        //bank. Hence in 64ms it would refresh every row.
                        cs_n <= 0;
                        ras_n <= 0;
                        cas_n <= 0;
                        we_n <= 1;
                        tREFI_pending <= 0;
                    end else if (tREFI_cnt < 55) begin //160ns tRFC
                        cs_n <= 0; ras_n <= 1; cas_n <= 1; we_n <= 1;
                    end else begin
                        if (req && !mem_done) begin
                            EMI_run_state <= ACCESS;
                        end else begin
                            cs_n <= 0;
                            ras_n <= 1;
                            cas_n <= 1;
                            we_n <= 1;
                        end
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
                    if (!(|tACC_cnt)) begin
                        //ACTIVATE
                        cs_n <= 0;
                        ras_n <= 0;
                        cas_n <= 1;
                        we_n <= 1;

                        a[13:0] <= req_addr[23:10]; //row
                        ba <= req_addr[9:7]; //bank

                        we_lat <= req_we; //latching jic, 25cycles afterall
                        msk_lat <= req_msk;
                        wd_lat <= req_wd;

                    end else if (tACC_cnt == 8'h5) begin
                        //READ/WRITE
                        cs_n <= 0;
                        ras_n <= 1;
                        cas_n <= 0;
                        we_n <= !we_lat; //WE# = 0 on write

                        //ba is already bank
                        a <= {3'b000, 1'b1, req_addr[6:0], 3'b000}; //a[10] = auto-precharge(auto-close row), a[9:0] = col

                        rd_run <= !we_lat;

                    end else if (tACC_cnt == (we_lat ? 8'd24 : 8'd17)) begin // 17 for read, 24 for write
                        tACC_cnt <= 8'b0;
                        mem_done <= 1;
                        EMI_run_state <= IDLE;
                    end else begin
                        cs_n <= 0;
                        ras_n <= 1;
                        cas_n <= 1;
                        we_n <= 1;

                        if (we_lat) begin //writing on read would short circuit btw
                            case (tACC_cnt)
                                8'd9:  dqs_me  <= 1; //DQS manipulations enable, meaning EMI is driving DQ, not ddr3 or someone else
                                8'd10: dqs_run <= 1; //DQS now switching every 1.5ns(every edge of clk90)
                                8'd14: dqs_run <= 0; //Done
                                8'd15: dqs_me  <= 0; //Now whatever can drive dqs
                            endcase
                        end
                        if (tACC_cnt == 15)
                            rd_run <= 0;
                    end
                end
                endcase
            end
        end

    assign dqs_val = {2{dqs_run & ck_p}}; //dqs_val = ck_p if dqs_run basically
    assign dqs_p = dqs_me ? dqs_val  : 2'bzz; //bzz bzz, who's calling?
    assign dqs_n = dqs_me ? ~dqs_val : 2'bzz; //zz is any bits that I don't have a control over
    //And allat differential fluff _n and _p is basically for stability, bc if voltage of any
    //Would change, the voltage of other would too.

    assign dq = dq_me ? dq_out : 16'bzzzz_zzzz_zzzz_zzzz;
    assign dm = dq_me ? dm_out : 2'bzz;


    //I am driving it on rising, and falling edge of the clock and
    always @(posedge clk90 or negedge clk90 or negedge rst_n) begin //that's kinda sick ngl
        //Always bc both edges, otherwise it complains
        if (!rst_n) begin
            dq_me <= 0;
        end else if (we_lat && dqs_run) begin
            beat = {2'(tACC_cnt - 8'd11), ~clk90}; //blocking assignment actually, in always block
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

            dq_me <= 1;
            //The burst(thats a big name for this) happens in 4 cycles, of 16bit writes
            //4 cycles bc on it happens on every clk90 edge
            dq_out <= wd_lat [16*beat +: 16]; //dq is actual data bus btw
            dm_out <= msk_lat[2 *beat +: 2];
        end else if (rd_run && !(tACC_cnt == 15 && !clk90)) begin //gating last bad write
            beat = {2'(tACC_cnt - 8'd11), ~clk90} - 1'h1; //blocking assignment actually, in always block
            //The read is opposite of write, the chip itsels sets dq and dqs.
            //And I just read the dq
            rdata[16*beat +: 16] <= dq; //Just write to rdata 16bits on every edge for 8edges(4cycles)
        end else begin
            dq_me <= 0;
        end
    end
endmodule
