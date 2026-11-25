module XMU_T(
    //XMU-T - Xtended Math Unit - Transcendentals
    //I was about to start with SAM, but realized that I want XMU first
    //XMU-T computes Transcendentals functions for pariticular input x, precisely:
    //rsqrt(x), rcp(x), log2(x), exp2(x), sqrt(x), arctan(x) plus sin(x), cos(x) taken in turns(360 degrees = 1turn)
    //and additionally fract(x). XMU-T's ROM has a free runtime programmable 128segment slot
    //Where user can write any possible function of x and use it as any other built-in function.
    //XMU-T utilizes 598LUTs, 818FFs and 3 DSPs as well as meets 300MHz criteria at total of 17pipeline stages.
    input logic clk,

    input logic [31:0] a, //yup just a
    input logic [3:0]  opcode,
    input logic [7:0]  sh_base,
    input logic [6:0]  slot_thr,
    input logic        slot_signed,
    input logic [7:0]  slot_oexp,
    //arctan takes 2 passes to compute in case |x| >= 1.0
    //bc i need to rcp x to compute arctan. This indicates this is second pass
    //of arctan
    input logic arctan_loop,

    //ROM lives in SAM bc its shared by all XMU-Ts within SAM
    output logic [9:0]  rom_addr,
    input  logic [71:0] rom_data,

    output logic [31:0] result
);
    //So I wrote a minimax script that generates .mem data that i will put
    //into my BRAM ROM and XMU_T is gonna read its transcendentals from it.

    //optbl:
    //0000 : rsq (000)
    //0001 : rcp (001)
    //0010 : log2(010)
    //0011 : exp2(011)
    //0100 : sin (100)
    //1100 : cos (100)
    //0101 : atan(101)
    //0110 : sqrt(110)
    //0111 : slot(111)
    //1110 : fract

    //=> DECO (Decode) <=//
    //Just quick decode of the flags for later stages, might end up
    //starting right here i don't know, who knows.
    logic  [6:0] sexp; //signed exp
    assign sexp = {~a[30], a[29:24]};

    logic  slot_op, arctan_op, direct_op, rsq_sqrt_op;
    assign slot_op   = opcode == 4'b0111;
    assign arctan_op = opcode == 4'b0101;
    assign rsq_sqrt_op = opcode == 4'b0000 | opcode == 4'b0110;
    //direct op doesn't need a shifter, refer to optbl
    assign direct_op = opcode == 4'b0000 | opcode == 4'b0001 | opcode == 4'b0010 | opcode == 4'b0110 | (arctan_op & a[30]);

    //Imma just say it again: i had this idea of runtime programmable SFUs
    //long before starting GPU, and i finally get to implement it. Basically
    //you can just write any curve into 128 segment field in ROM and then use
    //it as a regular op. This also means range is programmable which creates
    //this mux right here. Its in SAM now bc of precompute ofc.
    logic  [8:0] sh_diff;
    assign sh_diff = {1'b0, sh_base} - {{2{sexp[6]}}, sexp};

    //almost forgot about $signed
    logic  slot_over;
    assign slot_over = $signed(sexp) >= $signed(slot_thr);

    logic [6:0] DECO_sexp;
    (* extract_reset = "no" *) logic [5:0] sh_amt;
    logic [24:0] mant;
    logic [3:0] DECO_opcode;
    logic [2:0] prefix;
    //always helps
    (* shreg_extract = "no" *) logic zero, arctan1, exp_V, neg, cos, massive, clamp_hi, clamp_lo, negt, sh_sat, arctan_p2;
    logic  COMB_sgn, COMB_lb_sat;
    logic  [1:0]  COMB_spec;
    logic  [5:0]  COMB_lb_sh;
    logic  [24:0] COMB_lb_mant;
    always_ff @(posedge clk) begin : DECO_DECO
        DECO_opcode <= arctan_loop ? 4'b0101 : opcode;
        DECO_sexp   <= sexp;
        //mux everything mu-ha-ha-ha
        mant        <= arctan_loop ? COMB_lb_mant : {rsq_sqrt_op ? a[24] : 1'b1, a[23:0]};
        sh_amt      <= arctan_loop ? COMB_lb_sh : direct_op ? (rsq_sqrt_op ? 6'd24 : 6'd23) : sh_diff[5:0]; //shift by exp(saturate)
        sh_sat      <= arctan_loop ? COMB_lb_sat : ~direct_op & (sh_diff[8] | |sh_diff[7:6]);
        massive     <= ~arctan_loop & sh_diff[8]; //same thing as in GUCH - shifter can't shift left

        //various flags for later
        zero      <= ~arctan_loop & ~|a[30:24];
        neg       <= arctan_loop ? COMB_sgn : a[31];
        negt      <= ~arctan_loop & a[31] & (opcode == 4'b0011 | opcode == 4'b0100 | opcode == 4'b1100 | opcode == 4'b1110 | (slot_op & slot_signed));
        arctan1   <= arctan_loop ? COMB_spec == 2'b11 : a[30:0] == 31'h40000000;
        arctan_p2 <= arctan_loop;

        //still remember something from logisim cpu or ig i had it at the first sv cpu
        //where branching was still done in two instructions, it was a long time ago
        exp_V    <= ~arctan_loop & a[30:24] >= 7'd70;
        clamp_hi <= ~arctan_loop & slot_op & ~a[31] & slot_over;
        clamp_lo <= ~arctan_loop & slot_op & a[31] & (slot_over | ~slot_signed);

        //nice encoding scheme, man do I love encoding stuff
        //arctan needs rcp first if a is more than 1 and then arctan
        prefix <= arctan_loop ? 3'b101 : (arctan_op & a[30]) ? 3'b001 : opcode[2:0];
        cos    <= ~arctan_loop & opcode == 4'b1100;
    end : DECO_DECO

    //=> ALIG0(Align 0) <=//
    //good ol alig, was in the first version of GUCH.
    //Again this is most LUT efficient way of doing it that I figured out.
    //Shift it up to a Q6.28 should be good enough
    logic [28:0] alig0_mant;
    assign alig0_mant = {mant, 4'h0} >> sh_amt[1:0];

    logic [40:0] alig1_mant;
    always_ff @(posedge clk) begin
        alig1_mant <= {alig0_mant, 12'h0} >> {sh_amt[3:2], 2'b00};
    end

    //So computing output exp for varios cases
    //As for special cases
    //sqrt of negative flushes to zero
    //rsqrt of negative saturates, yes yes i know i know that you can't devide
    //by zero, or undefined, however i believe it best suits graphical
    //requirements of gefp32
    //and log2 saturates to negative maximum, same thing not a huge fan of it,
    //but decision had to be made.
    //Btw nvidia and amd set those cases to NaN, but first of all, i don't
    //even have NaN, and second i don't really like NaN, i feel like it would
    //corrupt stuff, like imagine value being NaN, then it gets into FMA, and
    //another value becomes NaN and suddentely your whole screen is filled
    //with NaNs.
    logic  [7:0] oexp; //output exp
    logic  [1:0] spec;
    logic  sgn, oexp_sub;
    always_comb begin : ALIG0_OEXP
        unique case (DECO_opcode)
            //rsq: out exp is -(exp>>>1), back end subtracts it
            //Bc we calculate rsq for only mant
            4'b0000: begin
                oexp = {{2{DECO_sexp[6]}}, DECO_sexp[6:1]};
                spec = (zero | neg) ? 2'b10 : 2'b00;
                sgn  = 1'b0;
                oexp_sub = 1'b1;
            end
            //rcp: out exp is -exp, back end subtracts it
            4'b0001: begin
                oexp = {DECO_sexp[6], DECO_sexp};
                spec = zero ? 2'b10 : 2'b00;
                sgn  = neg;
                oexp_sub = 1'b1;
            end
            //log2: exp is the integer part, added in fixed point
            4'b0010: begin
                oexp = {DECO_sexp[6], DECO_sexp};
                spec = (zero | neg) ? 2'b10 : 2'b00;
                sgn  = zero  | neg;
                oexp_sub = 1'b0;
            end
            //exp2: n comes from the window later overflow = max, underflow = 0
            4'b0011: begin
                oexp = 8'd0;
                spec = exp_V ? {~neg, neg} : 2'b00;
                sgn  = 1'b0;
                oexp_sub = 1'b0;
            end
            //arctan: table is x8 so -3 the exp if its 1 tho, result is 1/8,
            //otherwise its super inaccurate bc no cubic can represent such big
            //slope change
            4'b0101: begin
                oexp = prefix == 3'b001 ? {DECO_sexp[6], DECO_sexp} : 8'hFD;
                spec = arctan1 ? 2'b11 : 2'b00;
                sgn  = neg;
                oexp_sub = 1'b0;
            end
            //sqrt: out exp is +(exp>>>1)
            4'b0110: begin
                oexp = {{2{DECO_sexp[6]}}, DECO_sexp[6:1]};
                spec = (zero | neg) ? 2'b01 : 2'b00;
                sgn  = 1'b0;
                oexp_sub = 1'b0;
            end
            //slot: offset from config
            4'b0111: begin
                oexp = slot_oexp;
                spec = 2'b00;
                sgn  = 1'b0;
                oexp_sub = 1'b0;
            end
            //sin, cos and fract: table output is already good
            default: begin
                oexp = 8'd0;
                oexp_sub = 1'b0;
                spec = 2'b00;
                sgn  = 1'b0;
            end
        endcase
    end : ALIG0_OEXP

    logic [7:0] ALIG0_oexp;
    logic [2:0] ALIG0_prefix;
    logic [1:0] ALIG0_sh_hi, ALIG0_spec;
    logic [11:0] ALIG0_flags;
    always_ff @(posedge clk) begin : ALIG0_CRRY
        //CRRY everything
        ALIG0_sh_hi <= sh_amt[5:4];
        ALIG0_oexp <= oexp;
        ALIG0_spec <= spec;
        ALIG0_prefix <= prefix;
        ALIG0_flags <= {sh_sat, negt & ~massive, cos, clamp_hi, clamp_lo, DECO_opcode[2:0] == 3'b100, DECO_opcode == 4'b0011,
                        arctan_p2, DECO_opcode == 4'b0010, DECO_opcode == 4'b1110, oexp_sub, sgn};
    end : ALIG0_CRRY

    //=> ALIG1(Align 1) <=//
    //88bits where low ones are useless(sticky)
    //top ones are useless too(too much int bits), and only 34 are useful.
    //Btw it passed synth first attempt, not saying anything but yeah im
    //saying that i know something in computer engineering. And maybe a little
    //bit in jokes
    logic [88:0] mant_final;
    assign mant_final = {alig1_mant, 48'h0} >> {ALIG0_sh_hi, 4'b0000};
    logic [33:0] Q6_27;
    logic sticky; //here we go again
    always_ff @(posedge clk) begin
        Q6_27 <= mant_final[71:38];
        sticky <= |mant_final[37:0];
    end

    logic [7:0] ALIG1_oexp;
    logic [2:0] ALIG1_prefix;
    logic [1:0] ALIG1_spec;
    logic [11:0] ALIG1_flags;
    always_ff @(posedge clk) begin : ALIG1_CRRY
        ALIG1_oexp <= ALIG0_oexp;
        ALIG1_spec <= ALIG0_spec;
        ALIG1_prefix <= ALIG0_prefix;
        ALIG1_flags <= ALIG0_flags;
    end : ALIG1_CRRY

    //=> STCY (Sticky) <=//
    //Turns Q6_27 into two's compliment
    //Also it adds 1/4 to it if its cos bc well cos = sin + 1/4 turns simple as that
    logic [33:0] STCY_canddr; //canditate address
    always_ff @(posedge clk) begin : STCY_STCY
        //also saturate now
        STCY_canddr <= ((Q6_27 & {34{~ALIG1_flags[11]}}) ^ {34{ALIG1_flags[10]}}) + {6'b0, ALIG1_flags[9], 26'b0, ALIG1_flags[10] & ~sticky & ~ALIG1_flags[11]};
    end : STCY_STCY

    logic [7:0] STCY_oexp;
    logic [2:0] STCY_prefix;
    logic [1:0] STCY_spec;
    logic [8:0] STCY_flags;
    always_ff @(posedge clk) begin : STCY_CRRY
        STCY_oexp <= ALIG1_oexp;
        STCY_spec <= ALIG1_spec;
        STCY_prefix <= ALIG1_prefix;
        STCY_flags <= ALIG1_flags[8:0];
    end : STCY_CRRY

    //=> ADDR (Address) <=//
    //I like how address can be a noun and a verb
    //So sin is only in the domain of 0 -> 1/4 because its enough.
    //Imagine unit circle, its just well a circle so 1/4 is enough to repsent
    //a whole circle, you just need to mirror and or flip quarter
    logic  mirror, slot_flip;
    assign mirror    = STCY_flags[6] & STCY_canddr[27];
    assign slot_flip = STCY_prefix == 3'b111 & slot_signed;

    //either max or zero or address that we calculated
    logic  [24:0] seg_pos;
    assign seg_pos = STCY_flags[8] ? 25'h1FFFFFF : STCY_flags[7] ? 25'h0 : STCY_canddr[26:2] ^ {mirror ^ slot_flip, {24{mirror}}};

    logic [24:0] ADDR_seg_pos;
    logic [26:0] ADDR_fract;
    always_ff @(posedge clk) begin : ADDR_ADDR
        //read addr, register bc its a bram read
        rom_addr <= {STCY_prefix, seg_pos[24:18]};
        ADDR_seg_pos <= {seg_pos[24:18], ~seg_pos[17], seg_pos[16:0]};
        //and yup fract is just free like that
        ADDR_fract <= {seg_pos[24:0], STCY_canddr[1:0]};
    end : ADDR_ADDR

    logic [7:0] ADDR_oexp;
    logic [1:0] ADDR_spec;
    logic [4:0] ADDR_flags;
    logic [3:0] ADDR_dsign;
    always_ff @(posedge clk) begin : ADDR_CRRY
        ADDR_oexp  <= STCY_flags[5] ? {STCY_canddr[33], STCY_canddr[33:27]} : STCY_oexp;
        ADDR_spec  <= STCY_spec;
        ADDR_flags <= {STCY_flags[4:1], STCY_flags[6] ? STCY_canddr[28] : STCY_flags[0]};
        //Since signs are omitted on the actual ROM i have to figure them out
        //from here. They are just signs of derivatives of function which ofc
        //is constant. Its last two bits (stolen from d0 and d1) for slot btw.
        ADDR_dsign <= {STCY_prefix[2:1] == 2'b00,
                      STCY_prefix == 3'b010 | (STCY_prefix[2] & ~&STCY_prefix[1:0]),
                      STCY_prefix == 3'b000, STCY_prefix == 3'b111};
    end : ADDR_CRRY

    //=> LKUP0 (Lookup 0) <=//
    //Yeah two stages just for BRAM read, what did you expect from 300MHz tho?
    //Again configuration is: 4 cascaded BRAM18s, for 72bit depth and
    //8 128segments entries. In a true dual port mode, each BRAM18 gives
    //2 36bit read port, meaning two XMU-Ts can read simoltaneousely per cycle
    //Also i can compute seg_pos^2 during 2 lkup stages
    logic [47:0] seg_pos_sqrd;
    /* verilator lint_off PINCONNECTEMPTY */
    //should be good i think.
    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"), //don't think i need this
        .USE_MULT("MULTIPLY"),
        .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"),
        .MASK(48'h3fffffffffff),
        .PATTERN(48'h000000000000),
        .SEL_MASK("MASK"),
        .SEL_PATTERN("PATTERN"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .ACASCREG(1),
        .ADREG(0),
        .ALUMODEREG(0),
        .AREG(1),
        .BCASCREG(1),
        .BREG(1),
        .CARRYINREG(0),
        .CARRYINSELREG(0),
        .CREG(0),
        .DREG(0),
        .INMODEREG(0),
        .MREG(1),
        .OPMODEREG(0),
        .PREG(1)
    )
    HereWe_areAgain (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(seg_pos_sqrd),
        .ACIN(30'h0),
        .BCIN(18'h0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(48'h0),
        .ALUMODE(4'b0000),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(5'b00000),
        .OPMODE(7'b0000101),
        .A({{12{ADDR_seg_pos[17]}}, ADDR_seg_pos[17:0]}),
        .B(ADDR_seg_pos[17:0]),
        .C(48'h0),
        .CARRYIN(1'b0),
        .D(25'h0),
        .CEA1(1'b1),
        .CEA2(1'b1),
        .CEAD(1'b1),
        .CEALUMODE(1'b1),
        .CEB1(1'b1),
        .CEB2(1'b1),
        .CEC(1'b1),
        .CECARRYIN(1'b1),
        .CECTRL(1'b1),
        .CED(1'b1),
        .CEINMODE(1'b1),
        .CEM(1'b1),
        .CEP(1'b1),
        .RSTA(1'b0),
        .RSTALLCARRYIN(1'b0),
        .RSTALUMODE(1'b0),
        .RSTB(1'b0),
        .RSTC(1'b0),
        .RSTCTRL(1'b0),
        .RSTD(1'b0),
        .RSTINMODE(1'b0),
        .RSTM(1'b0),
        .RSTP(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic [26:0] LKUP0_fract;
    logic [7:0]  LKUP0_oexp;
    logic [4:0]  LKUP0_flags;
    logic [1:0]  LKUP0_spec;
    logic [17:0] LKUP0_seg_pos;
    logic [3:0]  LKUP0_dsign;
    always_ff @(posedge clk) begin : LKUP0_CRRY
        LKUP0_fract   <= ADDR_fract;
        LKUP0_oexp    <= ADDR_oexp;
        LKUP0_spec    <= ADDR_spec;
        LKUP0_flags   <= ADDR_flags;
        LKUP0_seg_pos <= ADDR_seg_pos[17:0];
        LKUP0_dsign   <= ADDR_dsign;
    end : LKUP0_CRRY

    //So i precompute all products of d3 here, and then apply then in later
    //stages. Yeah you guessed it for critical path
    logic signed [11:0] d3_x;
    assign d3_x = ADDR_dsign[1] ? {ADDR_seg_pos[17:8], 2'b00} : {{2{ADDR_seg_pos[17]}}, ADDR_seg_pos[17:8]};

    logic signed [11:0] LKUP0_x,  LKUP1_x;
    logic signed [12:0] LKUP0_xn, LKUP1_xn, LKUP0_x1, LKUP1_x1;
    logic signed [13:0] LKUP0_x2, LKUP1_x2, LKUP0_x3, LKUP1_x3;
    always_ff @(posedge clk) begin : LKUP0_D3X
        LKUP0_x  <= d3_x;
        LKUP0_xn <= -13'(d3_x);
        LKUP0_x1 <= 13'(d3_x) + 13'sd32;
        LKUP0_x2 <= 14'(d3_x) * 2 + 14'sd32;
        LKUP0_x3 <= 14'(d3_x) * 3;
    end : LKUP0_D3X

    //=> LKUP1 (Lookup 1) <=//
    //lookup was initialized already, and dsp is doing its thing, so just crry
    logic [26:0] LKUP1_fract;
    logic [7:0]  LKUP1_oexp;
    logic [4:0]  LKUP1_flags;
    logic [1:0]  LKUP1_spec;
    logic [17:0] LKUP1_seg_pos;
    logic [3:0]  LKUP1_dsign;
    always_ff @(posedge clk) begin : LKUP1_CRRY
        LKUP1_fract   <= LKUP0_fract;
        LKUP1_oexp    <= LKUP0_oexp;
        LKUP1_spec    <= LKUP0_spec;
        LKUP1_flags   <= LKUP0_flags;
        LKUP1_seg_pos <= LKUP0_seg_pos;
        LKUP1_dsign   <= LKUP0_dsign;
    end : LKUP1_CRRY

    always_ff @(posedge clk) begin : LKUP1_D3X
        LKUP1_x  <= LKUP0_x;
        LKUP1_xn <= LKUP0_xn;
        LKUP1_x1 <= LKUP0_x1;
        LKUP1_x2 <= LKUP0_x2;
        LKUP1_x3 <= LKUP0_x3 + 14'sd32;
    end : LKUP1_D3X

    //=> COMP0 (Compute 0) <=//
    //Now we are talking, compute the cubic in Herner or whatever form
    logic [7:0]  COMP0_oexp, COMP2_oexp;
    logic [4:0]  COMP0_flags, COMP1_flags, COMP2_flags;
    logic [1:0]  COMP0_spec;
    logic [30:0] COMP0_d0, COMP1_d0;
    logic [13:0] COMP0_d2;
    logic [2:0]  COMP0_dsign, COMP1_dsign, COMP2_dsign;
    logic [17:0] COMP1_seg_sqrd;
    logic [47:0] cubic_casc, COMP4_cubic;

    /* verilator lint_off PINCONNECTEMPTY */
    //should be good i think.
    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"), //don't think i need this
        .USE_MULT("MULTIPLY"),
        .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"),
        .MASK(48'h3fffffffffff),
        .PATTERN(48'h000000000000),
        .SEL_MASK("MASK"),
        .SEL_PATTERN("PATTERN"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .ACASCREG(2),
        .ADREG(0),
        .ALUMODEREG(1),
        .AREG(2),
        .BCASCREG(2),
        .BREG(2),
        .CARRYINREG(0),
        .CARRYINSELREG(0),
        .CREG(1),
        .DREG(0),
        .INMODEREG(0),
        .MREG(1),
        .OPMODEREG(1),
        .PREG(1)
    )
    Ernest_Hemingway (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(cubic_casc),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(),
        .ACIN(30'h0),
        .BCIN(18'h0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(48'h0),
        .ALUMODE({2'b00, {2{COMP1_dsign[2]}}}),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(5'b00000),
        .OPMODE(COMP1_flags[2] ? 7'b0110000 : 7'b0110101),
        //d0 + d1 * seg_pos
        .A({7'b0, rom_data[40:18]}),
        .B(LKUP1_seg_pos),
        .C({~COMP1_d0[30], COMP1_d0[29:0], 17'b0}),
        .CARRYIN(1'b0),
        .D(25'h0),
        .CEA1(1'b1),
        .CEA2(1'b1),
        .CEAD(1'b1),
        .CEALUMODE(1'b1),
        .CEB1(1'b1),
        .CEB2(1'b1),
        .CEC(1'b1),
        .CECARRYIN(1'b1),
        .CECTRL(1'b1),
        .CED(1'b1),
        .CEINMODE(1'b1),
        .CEM(1'b1),
        .CEP(1'b1),
        .RSTA(1'b0),
        .RSTALLCARRYIN(1'b0),
        .RSTALUMODE(1'b0),
        .RSTB(1'b0),
        .RSTC(1'b0),
        .RSTCTRL(1'b0),
        .RSTD(1'b0),
        .RSTINMODE(1'b0),
        .RSTM(1'b0),
        .RSTP(1'b0)
    );
    //the d3 is tiny, just 4bits so plain fabric multiply is fine, don't wanna
    //waste dsp on it, its just gonna take routing and stuff just don't feel
    //great doing it. And yeah there are precomputed results
    //Those aren't shifts btw, its just bit aligments for DSP
    logic signed [15:0] COMP0_t1, COMP0_t2;
    always_ff @(posedge clk) begin : COMP0_D3X
        unique case (rom_data[1:0])
            2'd0: COMP0_t1 <= 16'sd32;
            2'd1: COMP0_t1 <= 16'(LKUP1_x1);
            2'd2: COMP0_t1 <= 16'(LKUP1_x2);
            2'd3: COMP0_t1 <= 16'(LKUP1_x3);
        endcase
        unique case (rom_data[3:2])
            2'd0: COMP0_t2 <= 16'sd0;
            2'd1: COMP0_t2 <= 16'(LKUP1_x)  <<< 2;
            2'd2: COMP0_t2 <= 16'(LKUP1_xn) <<< 3;
            2'd3: COMP0_t2 <= 16'(LKUP1_xn) <<< 2;
        endcase
    end : COMP0_D3X

    always_ff @(posedge clk) begin : COMP0_CRRY
        COMP0_oexp   <= LKUP1_oexp;
        COMP0_spec   <= LKUP1_spec;
        COMP0_flags  <= LKUP1_flags;
        COMP0_d0     <= LKUP1_flags[2] ? {1'b0, LKUP1_fract, 3'b0} : rom_data[71:41];
        COMP0_d2     <= rom_data[17:4];
        COMP0_dsign  <= {LKUP1_dsign[0] ? rom_data[18] : LKUP1_dsign[3], LKUP1_dsign[0] ? rom_data[41] : LKUP1_dsign[2], LKUP1_dsign[1]};
    end : COMP0_CRRY

    //=> COMP1 (Compute 1) <=//
    //Second dsp start
    logic signed [15:0] d3_sum;
    assign d3_sum = COMP0_t1 + COMP0_t2;
    logic [9:0] d3xsegpos;
    assign d3xsegpos = d3_sum[15:6];
    /* verilator lint_off PINCONNECTEMPTY */
    //should be good i think.
    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("TRUE"), //don't think i need this
        .USE_MULT("MULTIPLY"),
        .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"),
        .MASK(48'h3fffffffffff),
        .PATTERN(48'h000000000000),
        .SEL_MASK("MASK"),
        .SEL_PATTERN("PATTERN"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .ACASCREG(1),
        .ADREG(1),
        .ALUMODEREG(1),
        .AREG(1),
        .BCASCREG(1),
        .BREG(1),
        .CARRYINREG(0),
        .CARRYINSELREG(0),
        .CREG(0),
        .DREG(1),
        .INMODEREG(1),
        .MREG(1),
        .OPMODEREG(1),
        .PREG(1)
    )
    Fjodor_Dostoevsky (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(COMP4_cubic),
        .ACIN(30'h0),
        .BCIN(18'h0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(cubic_casc),
        //So thats really sick, I invert fract and log2/arctan in here using
        //ALUMODE and INMODE and OPMODE configs to save up LUTs and FFs and
        //timing, its beutiful.
        .ALUMODE({2'b00, COMP2_dsign[1] ^ ((COMP2_flags[3] & COMP2_oexp[7]) | COMP2_flags[4]), COMP2_dsign[1]}),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE({1'b0, COMP0_dsign[1], 3'b100}),
        .OPMODE(COMP2_flags[2] ? 7'b0010000 : 7'b0010101),
        .A({5'b0, {15{d3xsegpos[9]}}, d3xsegpos}),
        .B(COMP1_seg_sqrd),
        .C(48'h0),
        .CARRYIN(1'b0),
        .D({10'b0, COMP0_d2, 1'b0}),
        .CEA1(1'b1),
        .CEA2(1'b1),
        .CEAD(1'b1),
        .CEALUMODE(1'b1),
        .CEB1(1'b1),
        .CEB2(1'b1),
        .CEC(1'b1),
        .CECARRYIN(1'b1),
        .CECTRL(1'b1),
        .CED(1'b1),
        .CEINMODE(1'b1),
        .CEM(1'b1),
        .CEP(1'b1),
        .RSTA(1'b0),
        .RSTALLCARRYIN(1'b0),
        .RSTALUMODE(1'b0),
        .RSTB(1'b0),
        .RSTC(1'b0),
        .RSTCTRL(1'b0),
        .RSTD(1'b0),
        .RSTINMODE(1'b0),
        .RSTM(1'b0),
        .RSTP(1'b0)
    );

    logic [7:0]  COMP1_oexp;
    logic [1:0]  COMP1_spec;
    always_ff @(posedge clk) begin : COMP1_CRRY
        COMP1_oexp   <= COMP0_oexp;
        COMP1_spec   <= COMP0_spec;
        COMP1_flags  <= COMP0_flags;
        COMP1_d0     <= COMP0_d0;
        COMP1_dsign  <= COMP0_dsign;
        COMP1_seg_sqrd <= seg_pos_sqrd[34] ? 18'h1FFFF : {1'b0, seg_pos_sqrd[33:17]}; //saturate
    end : COMP1_CRRY

    //=> COMP2 (Compute 2) <=//
    //waiting on dsps, just crry
    logic [1:0]  COMP2_spec;
    always_ff @(posedge clk) begin : COMP2_CRRY
        COMP2_oexp   <= COMP1_oexp;
        COMP2_spec   <= COMP1_spec;
        COMP2_flags  <= COMP1_flags;
        COMP2_dsign  <= COMP1_dsign;
    end : COMP2_CRRY

    //=> COMP3 (Compute 3) <=//
    logic [7:0]  COMP3_oexp;
    logic [4:0]  COMP3_flags;
    logic [1:0]  COMP3_spec;
    always_ff @(posedge clk) begin : COMP3_CRRY
        COMP3_oexp  <= COMP2_oexp;
        COMP3_spec  <= COMP2_spec;
        COMP3_flags <= COMP2_flags;
    end : COMP3_CRRY

    //=> COMP4 (Compute 4) <=//
    //finish the compute up. And holy spam was allat, but well this is what
    //you do at 300MHz.
    logic [7:0]  COMP4_oexp;
    logic [4:0]  COMP4_flags;
    logic [1:0]  COMP4_spec;
    always_ff @(posedge clk) begin : COMP4_CRRY
        COMP4_oexp  <= COMP3_oexp;
        COMP4_spec  <= COMP3_spec;
        COMP4_flags <= COMP3_flags;
    end : COMP4_CRRY

    //=> COMB (Combine) <=//
    //Every op lands in one 56bit fixed point frame: LSB 2^-47, bit 47 = 1.0,
    //bit 55 = 2^8. After this the back end doesn't care which op it was.
    //The DSP holds p - 1, flipping the top bit back gives p in [0, 2).
    logic  [47:0] cubic_p;
    assign cubic_p = {~COMP4_cubic[47], COMP4_cubic[46:0]};

    //log2: p is a pure fraction there, so {oexp, p} already is oexp + p in
    //two's complement. Negative ones get inverted instead of negated:
    //~v = -v - 2^-47. Bc the ROM error is max 2^-30, since mantissa has only
    //24 bits, so its already kinda overkill. And therefore adding 1 to
    //negated value is literally useless, so im saving some CARRY4s on that.
    //Its really nice actually.
    logic  [55:0] comb_raw;
    assign comb_raw = {1'b0, COMP4_flags[3] ? COMP4_oexp ^ {8{COMP4_oexp[7]}} : {7'b0, cubic_p[47]}, cubic_p[46:0]};

    //No carry chain above means the 16bit group checks fit in here, so NRM0's
    //select comes straight from a register same as PRENRM in GUCH.
    //Tbh its just gefp32 backend its so similar to GUCH.
    //COMB_lo is the part that can only ever end up in sticky.
    //COMB_exp is the output field - E + 64, as if the leading one was at bit 55,
    //so +64 bias +8 for bit 55 = 72, and each NRM stage takes its shift off it.
    //log2 already has oexp inside the value, so just 72. Others negate with
    //(oexp ^ sub) + sub, and that + sub rides along in the same add as 72.
    logic  [55:0] COMB_val;
    logic  [2:0]  COMB_grp;
    logic  COMB_lo;
    logic  [11:0] COMB_hex;
    logic  signed [9:0] COMB_exp;
    always_ff @(posedge clk) begin : COMB_COMB
        COMB_val <= comb_raw;
        COMB_grp <= {|comb_raw[55:40], |comb_raw[39:24], |comb_raw[23:8]};
        COMB_lo  <= |comb_raw[14:0];
        COMB_hex <= {|comb_raw[55:52], |comb_raw[51:48], |comb_raw[47:44],
                     |comb_raw[39:36], |comb_raw[35:32], |comb_raw[31:28],
                     |comb_raw[23:20], |comb_raw[19:16], |comb_raw[15:12],
                     |comb_raw[7:4],   |comb_raw[3:0],   1'b0};
        COMB_exp <= COMP4_flags[3] ? 10'sd72 : ({{2{COMP4_oexp[7]}}, COMP4_oexp} ^ {10{COMP4_flags[1]}}) + {9'd36, COMP4_flags[1]};
    end : COMB_COMB

    //log2 sign is the sign of oexp + p, which is just oexp's sign since p >= 0
    always_ff @(posedge clk) begin : COMB_CRRY
        COMB_sgn  <= COMP4_flags[0] | (COMP4_flags[3] & COMP4_oexp[7]);
        COMB_spec <= COMP4_spec;
        COMB_lb_mant <= cubic_p[47:23];
        COMB_lb_sh   <= COMP4_oexp[5:0] + 6'd23;
        COMB_lb_sat  <= COMP4_oexp[6:0] > 7'd40;
    end : COMB_CRRY

    //=> NRM0 (Normalize 0) <=//
    //Just a shift by 0/16/32/48 yk the drill from GUCH.
    logic  [1:0] NRM0_shamt;
    assign NRM0_shamt = COMB_grp[2] ? 2'd0 : COMB_grp[1] ? 2'd1 : COMB_grp[0] ? 2'd2 : 2'd3;

    //only the kept window is muxed, low bits that shift up get pulled in directly
    logic  [55:15] NRM0_sh;
    always_comb begin
        unique case (NRM0_shamt)
            2'd0: NRM0_sh = COMB_val[55:15];
            2'd1: NRM0_sh = {COMB_val[39:0], 1'b0};
            2'd2: NRM0_sh = {COMB_val[23:0], 17'b0};
            2'd3: NRM0_sh = {COMB_val[7:0], 33'b0};
        endcase
    end

    //thats NRM0_fell buuut the exponent loses the shift right away
    //instead of carrying a lzc like GUCH bc there simply is no need for it,
    //10bit add is short and keeps RND free.
    logic  [55:15] NRM0_val;
    logic  NRM0_fell;
    logic  [2:0] NRM0_hex;
    logic  signed [9:0] NRM0_exp;
    always_ff @(posedge clk) begin : NRM0_REG
        NRM0_val  <= NRM0_sh;
        NRM0_fell <= ~|NRM0_shamt & COMB_lo;
        NRM0_hex  <= NRM0_shamt[1] ? (NRM0_shamt[0] ? COMB_hex[2:0] : COMB_hex[5:3]) : (NRM0_shamt[0] ? COMB_hex[8:6] : COMB_hex[11:9]);
        NRM0_exp  <= COMB_exp - {4'b0, NRM0_shamt, 4'b0000};
    end : NRM0_REG

    logic  NRM0_sgn;
    logic  [1:0] NRM0_spec;
    always_ff @(posedge clk) begin : NRM0_CRRY
        NRM0_sgn  <= COMB_sgn;
        NRM0_spec <= COMB_spec;
    end : NRM0_CRRY

    //=> NRM1 (Normalize 1) <=//
    //Leading one is in the top 16, so find and shift by 0/4/8/12.
    logic  [1:0] NRM1_shamt;
    assign NRM1_shamt = NRM0_hex[2] ? 2'd0 : NRM0_hex[1] ? 2'd1 : NRM0_hex[0] ? 2'd2 : 2'd3;

    logic  [55:27] NRM1_sh;
    always_comb begin
        unique case (NRM1_shamt)
            2'd0: NRM1_sh = NRM0_val[55:27];
            2'd1: NRM1_sh = NRM0_val[51:23];
            2'd2: NRM1_sh = NRM0_val[47:19];
            2'd3: NRM1_sh = NRM0_val[43:15];
        endcase
    end

    logic  NRM1_drop;
    always_comb begin
        unique case (NRM1_shamt)
            2'd0: NRM1_drop = |NRM0_val[26:15];
            2'd1: NRM1_drop = |NRM0_val[22:15];
            2'd2: NRM1_drop = |NRM0_val[18:15];
            2'd3: NRM1_drop = 1'b0;
        endcase
    end

    logic  [55:27] NRM1_val;
    logic  NRM1_fell;
    logic  [1:0] NRM1_nxt;
    logic  signed [9:0] NRM1_exp;
    always_ff @(posedge clk) begin : NRM1_REG
        NRM1_val  <= NRM1_sh;
        NRM1_fell <= NRM0_fell | NRM1_drop;
        NRM1_nxt  <= NRM1_sh[55] ? 2'd0 : NRM1_sh[54] ? 2'd1 : NRM1_sh[53] ? 2'd2 : 2'd3;
        NRM1_exp  <= NRM0_exp - {6'b0, NRM1_shamt, 2'b00};
    end : NRM1_REG

    logic  NRM1_sgn;
    logic  [1:0] NRM1_spec;
    always_ff @(posedge clk) begin : NRM1_CRRY
        NRM1_sgn  <= NRM0_sgn;
        NRM1_spec <= NRM0_spec;
    end : NRM1_CRRY

    //=> NRM2 (Normalize 2) <=//
    //Last shift by 0..3, and every flag for RND is computed here
    logic  [1:0] NRM2_shamt;
    assign NRM2_shamt = NRM1_nxt;

    logic  [55:27] NRM2_sh;
    assign NRM2_sh = NRM1_val << NRM2_shamt;

    //hidden at 55, mantissa [54:31], guard 30, rest is sticky. Ties to even as usual
    logic  NRM2_inc;
    assign NRM2_inc = NRM2_sh[30] & (NRM2_sh[31] | |NRM2_sh[29:27] | NRM1_fell);

    //Final field = NRM1_exp - shamt, but the range checks compare the register
    //against a constant per shamt instead, so they don't wait on that subtract.
    //big: field >= 128, flush: field <= 0 (field 0 is zero in gefp32 field is unbias exp).
    //top: field 127, an all ones mantissa rounding up there would carry into 128, which is just saturate.
    //sd is signed decimal in case you don't know, yeah bro like someone is gonna read it
    logic  NRM2_big, NRM2_top, NRM2_flush;
    always_comb begin
        unique case (NRM2_shamt)
            2'd0: begin NRM2_big = NRM1_exp > 10'sd127; NRM2_top = NRM1_exp == 10'sd127; NRM2_flush = NRM1_exp < 10'sd1; end
            2'd1: begin NRM2_big = NRM1_exp > 10'sd128; NRM2_top = NRM1_exp == 10'sd128; NRM2_flush = NRM1_exp < 10'sd2; end
            2'd2: begin NRM2_big = NRM1_exp > 10'sd129; NRM2_top = NRM1_exp == 10'sd129; NRM2_flush = NRM1_exp < 10'sd3; end
            2'd3: begin NRM2_big = NRM1_exp > 10'sd130; NRM2_top = NRM1_exp == 10'sd130; NRM2_flush = NRM1_exp < 10'sd4; end
        endcase
    end

    logic  NRM2_ones, NRM2_hid, NRM2_none;
    always_comb begin
        unique case (NRM2_shamt)
            2'd0: NRM2_ones = &NRM1_val[54:31];
            2'd1: NRM2_ones = &NRM1_val[53:30];
            2'd2: NRM2_ones = &NRM1_val[52:29];
            2'd3: NRM2_ones = &NRM1_val[51:28];
        endcase
    end
    assign NRM2_hid  = NRM2_sh[55];
    assign NRM2_none = NRM1_spec == 2'b00;

    //specials have the highest priority(spec)
    logic  [6:0]  NRM2_field;
    logic  [23:0] NRM2_mant;
    logic  NRM2_up, NRM2_sat, NRM2_1over8, NRM2_zero, NRM2_sgn, NRM2_ovf_top, NRM2_ovf_inc, NRM2_ovf_ones;
    always_ff @(posedge clk) begin : NRM2_REG
        NRM2_field    <= NRM1_exp[6:0] - {5'b0, NRM2_shamt};
        NRM2_mant     <= NRM2_sh[54:31];
        NRM2_up       <= NRM2_none & NRM2_hid & ~NRM2_flush & NRM2_inc;
        NRM2_sat      <= NRM1_spec == 2'b10 | (NRM2_none & NRM2_hid & NRM2_big);
        NRM2_ovf_top  <= NRM2_none & NRM2_top;
        NRM2_ovf_inc  <= NRM2_inc;
        NRM2_ovf_ones <= NRM2_ones;
        NRM2_zero     <= NRM1_spec == 2'b01 | (NRM2_none & (~NRM2_hid | NRM2_flush));
        NRM2_1over8   <= NRM1_spec == 2'b11; //looks like lover 8 lmao
        NRM2_sgn      <= NRM1_sgn;
    end : NRM2_REG

    //=> RND (Round) <=//
    //Pack and add the round bit. Result is never -0 again
    logic  [30:0] rnd_word;
    assign rnd_word = NRM2_zero ? 31'h0 : NRM2_1over8 ? 31'h3D000000 : {NRM2_field, NRM2_mant};

    logic  rnd_sat;
    assign rnd_sat = NRM2_sat | (NRM2_ovf_top & NRM2_ovf_inc & NRM2_ovf_ones);

    logic  [31:0] RND_res;
    always_ff @(posedge clk) begin : RND_RND
        RND_res[31] <= NRM2_sgn & ~NRM2_zero;
        if (rnd_sat) RND_res[30:0] <= 31'h7FFFFFFF;
        else         RND_res[30:0] <= rnd_word + {30'b0, NRM2_up};
    end : RND_RND
    assign result = RND_res;

endmodule
