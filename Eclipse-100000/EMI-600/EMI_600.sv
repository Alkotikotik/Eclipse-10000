module EMI_600 (
    //Eclipse Memory Interface(EMI)
    input logic clk,
    input logic rst_n,

    output logic EMI_rst_n,

    output logic cke,
    output logic ck_p,
    output logic ck_n,
    output logic odt,

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

    logic [31:0] cke_cnt;
    logic [12:0] tMRD_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cke_cnt <= 32'b0;
            tMRD_cnt <= 6'b0;
            EMI_rst_n <= 0;
            ba <= 3'b0;
            a <= 14'b0;
            cke  <= 0;
            odt  <= 0;

            EMI_init_state <= INIT_INIT;
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
                    if (tMRD_cnt > 512)
                            EMI_init_state <= FINISH;
                    else
                        tMRD_cnt <= tMRD_cnt + 12'd1;
                end
            endcase
        end
   end

endmodule
