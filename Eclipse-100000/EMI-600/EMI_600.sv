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
    logic clk333, clk90, clkEMI;
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
        ACCESS
    } run_states;
    run_states EMI_run_state;

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

    logic [31:0] cke_cnt;
    logic [11:0] tMRD_cnt, tREFI_cnt;
    logic [7:0]  tACC_cnt;
    logic tREFI_pending;
    logic rd_run;
    logic we_lat;
    logic [15:0]  msk_lat;
    logic [127:0] wd_lat;
    logic dqs_md, dq_md; //dq Manipulation disable 1 = (z), 0 = EMI drives
    logic [7:0]  dqs_ds;
    logic [2:0]  beat;
    logic cke_r;

    logic LOCKED;
    logic logic_rst_n;
    assign logic_rst_n = rst_n && LOCKED;
    //Main FSM logic runs on 83.3Mhz because 333.3/83.3 = 4 full cycles, thus
    //8edges and hence those 128bit burst in 1 83.3clk cycle
    always_ff @(posedge clkEMI or negedge logic_rst_n) begin : main_FSM
        if (!logic_rst_n) begin
            cke_cnt <= 32'b0;
            tMRD_cnt <= 6'b0;
            tACC_cnt <= 8'b0;
            EMI_rst_n <= 0;
            for (integer i = 0; i <= 3; i++) begin
                cmd[i] <= '{cs_n: 1, ras_n: 1, cas_n: 1, we_n: 1, ba: 3'b0, a: 14'b0, cke: 0, odt: 0};
            end
            cke_r <= 0;
            mem_done <= 0;
            rd_run <= 0;
            we_lat <= 0;
            dqs_md <= 1;
            dq_md <= 1;
            dqs_ds <= 8'b0000_0000;
            rdata <= 128'h0;

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

                        tREFI_pending <= 0;
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
            if (tREFI_cnt > 625) begin //7.8us
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
                        cmd[0].cs_n <= 0;
                        cmd[0].ras_n <= 0;
                        cmd[0].cas_n <= 0;
                        cmd[0].we_n <= 1;
                        tREFI_pending <= 0;
                    end else if (tREFI_cnt > 55 && req && !mem_done) begin //160ns tRFC
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
                    if (!(|tACC_cnt)) begin
                        //ACTIVATE(ACT)
                        //It goes into third slot of cmd, so it would be 5cycles apart
                        //From RD/WR, bc that's some t i forgot
                        cmd[2].cs_n <= 0;
                        cmd[2].ras_n <= 0;
                        cmd[2].cas_n <= 1;
                        cmd[2].we_n <= 1;

                        cmd[2].a[13:0] <= req_addr[23:10]; //row
                        cmd[2].ba <= req_addr[9:7]; //bank

                        we_lat <= req_we; //latching jic, 25cycles afterall
                        msk_lat <= req_msk;
                        wd_lat <= req_wd;

                    end else if (tACC_cnt == 8'h1) begin
                        //READ/WRITE
                        //On the last one so its aligned and 5cycles apart
                        cmd[3].cs_n <= 0;
                        cmd[3].ras_n <= 1;
                        cmd[3].cas_n <= 0;
                        cmd[3].we_n <= !we_lat; //WE# = 0 on write

                        cmd[3].ba <= req_addr[9:7];
                        cmd[3].a <= {3'b000, 1'b1, req_addr[6:0], 3'b000}; //a[10] = auto-precharge(auto-close row), a[9:0] = col

                        rd_run <= !we_lat;

                    end else if (tACC_cnt == (we_lat ? 8'd7 : 8'd5)) begin // 17 for read, 24 for write
                        tACC_cnt <= 8'b0;
                        mem_done <= 1;
                        EMI_run_state <= IDLE;
                    end else begin
                        if (we_lat) begin //writing on read would short circuit btw
                            case (tACC_cnt)
                                8'd3: begin //Preamble
                                    dqs_md <= 0;
                                    dqs_ds <= 8'b0000_0000;
                                end //DQS manipulations enable, meaning EMI is driving DQ, not ddr3 or someone else
                                8'd4: begin //DQS now switching every 1.5ns(every edge of clk90)
                                    dqs_ds <= 8'b1010_1010;
                                    dq_md <= 0;
                                end
                                8'd5: begin //Done postassemble
                                    dqs_ds <= 8'b0000_0000;
                                    dq_md <= 1;
                                end
                                8'd6: dqs_md  <= 1; //Now whatever can drive dqs
                            endcase
                        end
                        if (tACC_cnt == 15)
                            rd_run <= 0;
                    end
                end
                endcase
            end
        end : main_FSM

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
    //I am driving it on rising, and falling edge of the clock and thats sick
    always @(posedge clk90 or negedge clk90 or negedge logic_rst_n) begin : clk90_always
        //Always bc both edges, otherwise it complains
        if (!logic_rst_n) begin
        end else if (rd_run && !(tACC_cnt == 15 && !clk90)) begin //gating last bad write
            beat = {2'(tACC_cnt - 8'd11), ~clk90} - 1'h1; //-1 bc it starts 1 edge later fsr
            //The read is opposite of write, the chip itsels sets dq and dqs.
            //And I just read the dq
            rdata[16*beat +: 16] <= dq; //Just write to rdata 16bits on every edge for 8edges(4cycles)
        end
    end : clk90_always

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
        .CLKOUT3_DIVIDE(1),
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
        .CLKOUT3(),
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

    logic ck_temp;
    full_oserder ck (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
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
        full_oserder u (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
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
        full_oserder u (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
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

    full_oserder cs_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds({cmd[3].cs_n, cmd[3].cs_n, cmd[2].cs_n, cmd[2].cs_n,
                 cmd[1].cs_n, cmd[1].cs_n, cmd[0].cs_n, cmd[0].cs_n}),
            .trie(1'b0), .oq(cs_n), .tq());

    full_oserder ras_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds({cmd[3].ras_n, cmd[3].ras_n, cmd[2].ras_n, cmd[2].ras_n,
                 cmd[1].ras_n, cmd[1].ras_n, cmd[0].ras_n, cmd[0].ras_n}),
            .trie(1'b0), .oq(ras_n), .tq());

    full_oserder cas_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds({cmd[3].cas_n, cmd[3].cas_n, cmd[2].cas_n, cmd[2].cas_n,
                 cmd[1].cas_n, cmd[1].cas_n, cmd[0].cas_n, cmd[0].cas_n}),
            .trie(1'b0), .oq(cas_n), .tq());

    full_oserder we_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds({cmd[3].we_n, cmd[3].we_n, cmd[2].we_n, cmd[2].we_n,
                 cmd[1].we_n, cmd[1].we_n, cmd[0].we_n, cmd[0].we_n}),
            .trie(1'b0), .oq(we_n), .tq());

    full_oserder cke_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds({cmd[3].cke, cmd[3].cke, cmd[2].cke, cmd[2].cke,
                 cmd[1].cke, cmd[1].cke, cmd[0].cke, cmd[0].cke}),
            .trie(1'b0), .oq(cke), .tq());

    full_oserder odt_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds({cmd[3].odt, cmd[3].odt, cmd[2].odt, cmd[2].odt,
                 cmd[1].odt, cmd[1].odt, cmd[0].odt, cmd[0].odt}),
            .trie(1'b0), .oq(odt), .tq());

    //More OSERDESes now for actual dqs, dq and mask
    logic [15:0] dq_oq, dq_tq, dq_in; //tq is tri-state out switcher
    for (genvar i = 0; i < 16; i++) begin : dq_ser
        //That literally like beats i had previosely, 8writes of 16bits for 4clk
        full_oserder dq_ser (.clk333(clk90), .clkEMI(clkEMI), .rst_n(logic_rst_n),
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
        full_oserder dqs_ser (.clk333(clk333), .clkEMI(clkEMI), .rst_n(logic_rst_n),
            .ds(dqs_ds), .trie(dqs_md), .oq(dqs_oq[i]), .tq(dqs_tq[i])
        );

        //differential IOBUF
        IOBUFDS #(.IOSTANDARD("DEFAULT"), .SLEW("FAST"), .IBUF_LOW_PWR("FALSE")) dqs_buf (
        .I(dqs_oq[i]), .T(dqs_tq[i]), .O(dqs_in[i]), .IO(dqs_p[i]), .IOB(dqs_n[i]));
    end : dqs_ser

    //dm doesn't need any buffer since its 1way pin
    for (genvar i = 0; i < 2; i++) begin : dm_ser
        full_oserder dm_ser (.clk333(clk90), .clkEMI(clkEMI), .rst_n(logic_rst_n),
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


endmodule
