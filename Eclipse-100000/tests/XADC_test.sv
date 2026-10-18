module XADCtest (
    //test of how truly random XADC values are
    input logic sys_clk,
    input logic sys_rst_n
);

    //It actually fits nicely - all 3samples per address
    (* ram_style = "block" *) logic [35:0] samples [65535:0];

    logic [35:0] sample;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] xadc_do; //Only 4bits are used
    /* verilator lint_on UNUSEDSIGNAL */
    logic [6:0]  xadc_addr;
    logic        xadc_den, xadc_drdy, xadc_eos, we;
    logic [15:0] samples_addr;
    logic [1:0]  cnt;
    logic        clk, clk_pll, CLKFB, LOCKED;

    typedef enum logic [1:0] {
        WAIT,
        IDLE,
        SMPL,
        DONE
    } seed_states;

    seed_states rng_state;

    //reusing my dearest fsm
    always_ff @(posedge clk or negedge sys_rst_n) begin : XADC_FSM
        if (!sys_rst_n) begin
            rng_state <= IDLE;
            xadc_addr <= 7'h06;
            xadc_den <= 0;
            samples_addr <= 16'h0;
            cnt <= 2'd0;
        end else begin
            xadc_den <= 0;
            unique case (rng_state)
                IDLE: begin
                    if (xadc_eos && LOCKED)
                        rng_state <= SMPL;
                    else
                        rng_state <= IDLE;
                end
                SMPL: begin
                    if (xadc_addr == 7'h06)
                        xadc_addr <= 7'h01;
                    else if (xadc_addr == 7'h02)
                        xadc_addr <= 7'h06;
                    else
                        xadc_addr <= 7'h02;

                    xadc_den <= 1;
                    rng_state <= WAIT;

                end
                WAIT: begin
                    if (xadc_drdy) begin
                        case (xadc_addr)
                            7'h01:   sample[4 * cnt + 0  +: 4] <= xadc_do[7:4];
                            7'h02:   sample[4 * cnt + 12 +: 4] <= xadc_do[7:4];
                            default: sample[4 * cnt + 24 +: 4] <= xadc_do[7:4];
                        endcase
                        if (xadc_addr == 7'h06) begin
                            rng_state <= IDLE;
                            cnt <= (cnt == 2'd2) ? 2'd0 : cnt + 2'd1;
                            if (cnt == 2'd2) begin
                                samples_addr <= samples_addr + 16'h1;
                                if (samples_addr == 16'hFFFF)
                                    rng_state <= DONE;
                            end
                        end else
                            rng_state <= SMPL;
                    end
                end
                DONE: begin
                    //Stuck here forever
                end
            endcase

        end
    end : XADC_FSM

    assign we = rng_state == WAIT && xadc_drdy && xadc_addr == 7'h06 && cnt == 2'd2;

    always_ff @(posedge clk) begin
        if (we) begin
            samples[samples_addr] <= {xadc_do[7:4], sample[31:0]};
        end
    end

    XADC #(
        .INIT_40(16'h0000), 
        .INIT_41(16'h2000), //No averaging thus higher entropy
        .INIT_42(16'h0800),
        .INIT_48(16'h4600)
    ) xadc_rng (
        .DCLK(clk),
        .RESET(!sys_rst_n),
        .DADDR(xadc_addr), //Read specified register
        .DEN(xadc_den),
        .DWE(1'b0),
        .DI(16'h0),
        .DO(xadc_do), //Data Out(actually its not just a nice way to remember)
        .DRDY(xadc_drdy),
        .EOS(xadc_eos),
        //Some bs we don't care about
        .VP(1'b0), .VN(1'b0), .VAUXP(16'h0), .VAUXN(16'h0),
        .CONVST(1'b0), .CONVSTCLK(1'b0),
        .EOC(), .BUSY(), .CHANNEL(), .OT(), .ALM(), .MUXADDR(),
        .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED()
    );

    PLLE2_BASE #( //base is fine, i don't need adv for emi
        .BANDWIDTH("OPTIMIZED"), //just standard optimized is fine
        .CLKFBOUT_MULT(24), //1200MHz to resemble my CPU
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(20.0),
        .CLKOUT0_DIVIDE(8), //150MHz
        .CLKOUT1_DIVIDE(3),
        .CLKOUT2_DIVIDE(12),
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
        .CLKOUT1(),
        .CLKOUT2(),
        .CLKOUT3(), //for IDELAYCTRL
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKFBOUT(CLKFB),
        .LOCKED(LOCKED),
        .CLKIN1(sys_clk),
        .PWRDWN(1'b0), //constantly on
        .RST(!sys_rst_n),
        .CLKFBIN(CLKFB) //wiriting it to each other, internal loop
    );

    BUFG bufg_clk    (.I(clk_pll),    .O(clk));
endmodule

