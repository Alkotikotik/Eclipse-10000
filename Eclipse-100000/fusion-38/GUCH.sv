module GUCH (
    //GUCH - Graphical Unified Computing Heart
    //Well well finally starting the GPU im so excited for it.
    //So first one is ofc smallest core its the basic GPU contruct.
    //The heart is efp32 FMA that is done through 2DSPs, it also has integer mode,
    //16bit fma, float to int conversion and min/max/abs.

    //Also I don't need resets here, bc its just pipeline computations
    //And it would give vivado jsut a little more room for placement
    input logic clk,

    //So my encoding/decoding scheme is pretty cool, ill explain it later prolly
    //First of all, all signals are computed in 1 SM because all GUCHes share them
    //But that I mean b becomes one or c becomes zero
    input logic efp_op, neg_p, neg_c, ffma16_op,
    input logic [1:0] cmp_code, //<=, <, ==, !=
    input logic [6:0] OPMODE1, OPMODE2,
    input logic [4:0] INMODE1, INMODE2,
    input logic [3:0] ALUMODE,

    input logic [31:0] a, b, c,

    output logic [31:0] result
);
    //So efp32 is Eclipsing Floating (Point/Precision word-play) 32bits
    //Its a custom floating format I designed, I actually spent a little while
    //invinting it from scratch, and I came up to a conclusion that main idea
    //behind float32 is undeniebely the best.
    //The implementation isn't the best tho thus I changed it.
    //First - one bit from exponent moved to mantissa. That halfs floating
    //point error by two, and exact integer is up to 33m. I did it bc I feel
    //like its more useful for 3d graphics, and also exp+sign bits into 1byte
    //and mantissa into 3bytes, and I think its pretty neat.
    //Second - it is 100% efficient now, no repeating patterns and massive
    //number of NaNs and stuff.
    //Third - + and - inf and 1 pattern for undef, also undef = undef.
    //1/0 is always undef dw.
    //It also implement subnormals. And bias exponent just 1 less bit.
    //a[31]    = sign
    //a[30:24] = exp
    //a[23:0]  = mantissa without hidden bit
    //Im planning to pipeline it like crazy, like 10-11 stages for GUCH
    //which means i've got like 1-2 logic levels per stage

    //Also after quite a big of testing I realized that my original format is
    //too heavy and doesn't have much use in graphic tasks. Therefore
    //I decided to reformat it into gefp32 which is graphical efp32.
    //The differences aren't huge, basically - flush subnormals(saves ~36LUTs
    //on every GUCH) and do a saturating arithmetic instead of inf/undef
    //stuff. This saves bunch of LUTs and doesn't really matter for graphics
    //Because the worst thing that can happen is pixel would turn black(or white)
    //Somewhere, which isn't a big deal.

    //=> PREA (Preamble) <=//
    //Moving longest stuff from STRT to here, for crit path ofc
    logic [32:0] PREA_a, PREA_b, PREA_c;
    logic [8:0]  PREA_shexp, PREA_cexp;
    logic PREA_a_zero, PREA_b_zero;
    always_ff @(posedge clk) begin : PREA_EFP
        //unbias by inverting top bit, and put back hidden bit.
        //No need for reset, otherwise DSP wouldn't accept them immediately
        PREA_a <= {a[31], ~a[30], a[29:24], |a[30:24], a[23:0]};
        PREA_b <= {b[31], ~b[30], b[29:24], |b[30:24], b[23:0]};
        PREA_c <= {c[31], ~c[30], c[29:24], |c[30:24], c[23:0]};

        PREA_shexp <= {{3{~a[30]}}, {a[29:25], a[24] | ~|a[30:24]}} + {{3{~b[30]}}, {b[29:25], b[24] | ~|b[30:24]}};
        //So basically subtracting a number from const should be a little better.
        PREA_cexp  <= 9'd28 - {{3{~c[30]}}, {c[29:25], c[24] | ~|c[30:24]}};

        PREA_a_zero <= ~|a[30:0];
        PREA_b_zero <= ~|b[30:0];
    end : PREA_EFP

    //=> STRT (Start) <=//
    //Calc sh and start DSPs
    logic [32:0] STRT_a, STRT_b, STRT_c;
    logic [8:0] STRT_abexp;
    logic [8:0] shexp;
    logic STRT_prod_zero, STRT_shexp_neg;

    logic [6:0] sh_exp;
    always_ff @(posedge clk) begin : STRT_CRRY
        STRT_a <= {PREA_a[32:25], PREA_a[24] & efp_op, PREA_a[23:0]};
        STRT_b <= PREA_b;
        STRT_c <= PREA_c;

        STRT_abexp <= PREA_shexp;

        STRT_prod_zero <= PREA_a_zero | PREA_b_zero;
        STRT_shexp_neg <= shexp[8];
    end : STRT_CRRY

    //Basically sub_sel bits govern the sign of products and c result
    //add or subtract. Subtract magnitudes
    logic c_sign, sub_mags;
    always_ff @(posedge clk) begin : signs
        c_sign <= PREA_c[32] ^ neg_c; //FMS... etc
        sub_mags <= efp_op & (PREA_a[32] ^ PREA_b[32] ^ PREA_c[32] ^ neg_p ^ neg_c); //Whether to add or sub magnitudes, only for efp, bc other are two's compliment
    end : signs

    //So exp(a) + exp(b) is self explanatory - we are multiplying them, but
    //what about - exp(c)? Well we aren't actually computing an exponent we
    //are computing a shift, more on that later. Also, only lower bits rn
    //28 is constant offset for efp 32, it is calculated by 76 - 48 which is
    //shifted C bit length minus bits of a*c product
    //And for subnormals, is it is a subnormal, which is exp 0_000_000 (bc of bias)
    //it actually shouldn't be -64, but instead -63. Because subnormals hidden
    //bit is actually 0 instead of 1, such as they are 0.ff * 2^exp instead of
    //1.ff * 2^exp for normals.
    assign shexp = PREA_shexp + PREA_cexp;
    //clamp, if sign bit is 1(two's copmliment), don't move because shifter
    //can only move down. Then if 7th bit is 1, its between 128-256, and it
    //all is too high, so just set it to highest number within 7bits - 127.
    //ALmost clamp of either a or b is 0, bc if they are result should just be
    //c, but, sh_exp still shifts c completely out of range sometimes, meaning
    //its result becomes just zero.
    assign sh_exp = (shexp[8] | PREA_a_zero | PREA_b_zero) ? 0 : (shexp[7] ? 7'd127 : shexp[6:0]);

    //I need to align C to 77bits then add lower bits in first DSP, and rest
    //in fabric. I do it in 4 stages across 2 cycles parallel to first cycles of DSP so it
    //arrives just in time. The split is 2-2-2-1 bits per stage.
    //So vivado assigned a reset to those guys without any permission ofc,
    //thus messing up the path, so it might fix it.
    (* extract_reset = "no" *) logic [1:0] STRT_shexp_lo, STRT_shexp_lmid, STRT_shexp_hmid;
    (* extract_reset = "no" *) logic STRT_shexp_hi;
    always_ff @(posedge clk) begin : STRT_SH
        STRT_shexp_lo <= sh_exp[1:0];
        STRT_shexp_lmid <= sh_exp[3:2];

        STRT_shexp_hmid <= sh_exp[5:4];
        STRT_shexp_hi <= sh_exp[6];
    end : STRT_SH

    logic DGAF0_sub_mags;
    logic [76:0] C_alig2, C_alig3;
    logic [47:0] P1, PCOUT0, P2;
    logic [29:0] ACOUT0;

    /* verilator lint_off PINCONNECTEMPTY */
    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("TRUE"),
        .USE_MULT("DYNAMIC"), //For both floats and integer ops
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
        .BREG(2),
        .CARRYINREG(1),
        .CARRYINSELREG(1),
        .CREG(0),
        .DREG(1),
        .INMODEREG(1),
        .MREG(1),
        .OPMODEREG(1),
        .PREG(1)
    )
    Welcome (
        .ACOUT(ACOUT0),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(PCOUT0),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(P1),
        .ACIN(30'h0),
        .BCIN(18'h0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(48'h0),
        //Btw this signal should theoretically be in DGAF1, however why don't
        //just delay it in SM? Thats what I thought too. It only saves ffs,
        //but hey, ill take it.
        .ALUMODE({ALUMODE[3:2], ALUMODE[1:0] | {2{DGAF0_sub_mags}}}),//Bc float isn't two's compliment
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(INMODE1),//One for float ops, one for FFMA
        .OPMODE(OPMODE1),
        //Its two's comlimetn so top bit gotta be 0
        .A({6'b0, PREA_a[23:0]}),
        .B({1'b0, PREA_b[16:0]}),
        .C({2'b00, C_alig3[45:0]}), //we're gonna need it at the third DSP cycle
        .CARRYIN(1'b0),
        //using D port here too, to save up some LUTs on mux for high bits
        //That whether it is ffma16_op or efp_op decide.
        .D({{9{PREA_a[15]}}, PREA_a[15:0]}),
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

    //=> DGAF0(Digital Signal Proccesing / Guard / Aligment / Float Prep) <=//
    //The DSP is pipelined and will take total of 4cycles.
    //This is the second one. It also performs align stage
    logic [1:0] DGAF0_shexp_lmid, DGAF0_shexp_hmid;
    logic DGAF0_shexp_hi;
    //The DSP works with two's compliment 25bit number and 18bit one.
    //To "Emulate" unsigned operations (what we need for mantissa multiply)
    //I set highest bit to zero thus allows only for 24x17 multiply.
    //And that's just one bit short of my a mantissa, so I have to carry it
    //To the point after DSP, and then add it. Its not as bad because I can simply
    //Add it along higher part of C, that I have to add in fabric nontheless.
    //That shreg thing, basically converts some ffs shifts to LUTs, and
    //usually its a good trade because it takes up quite a few ffs, and only
    //1LUT. However idgaf about ffs, and i gaf about LUTs, so i just don't do it.
    (* shreg_extract = "no" *) logic [24:0] DGAF0_ato_add;
    (* shreg_extract = "no" *) logic DGAF0_c_sign;
    logic [27:0] C_alig0;
    logic [6:0] in_grp; //any 1 in group
    logic [8:0] DGAF0_exp_base;

    always_ff @(posedge clk) begin : DGAF0_CRRY
        DGAF0_shexp_lmid <= STRT_shexp_lmid;
        DGAF0_shexp_hmid <= STRT_shexp_hmid;
        DGAF0_shexp_hi <= STRT_shexp_hi;
        DGAF0_sub_mags <= sub_mags;
        DGAF0_c_sign <= c_sign;
    end : DGAF0_CRRY

    always_ff @(posedge clk) begin : DGAF0_C
        C_alig0 <= {STRT_c[24:0], 3'h0} >> STRT_shexp_lo;
        //The exponent is c's biased exponent if c takes over, or just a+b+92 exp
        //if it doesn't. Takes over means that c is much bigger than a*b, and
        //its so large that sh_exp literally becomes negative, and because
        //this is impossible it sits at highest row. Whilst a*b power always
        //sits at row 48. So c's exponent would have much more value and would take over.
        //92 because field = exp + 64, top1_pos = 76 - lcz(shoudl be clear) and 
        //exp = base + (top1 pos - 48) bc each column above 48 doubles the value.
        DGAF0_exp_base <= ((STRT_shexp_neg | STRT_prod_zero) & STRT_c[24]) ? {2'b00, ~STRT_c[31], STRT_c[30:25]} : STRT_abexp + 9'd92;
        DGAF0_ato_add <= STRT_a[24] ? STRT_b[24:0] : 25'h0;
    end : DGAF0_C

    //So this is sticky computation, basically thats just for rounding, if we
    //shift out at least one 1, we round up, this is the same as regular rounding.
    //I mean not exactly there is also 1 more guard bit, which is first bit that gets shifted out
    //And it got named fsr and if its 1 but sticky isn't we round to even, if guard is zero, round down.
    //The cool part is that instead of doing expensive tz, i realized that we just need to know
    //If 52 + ith bit of STRT_c < sh_exp, if it is, it is sticky. I also compute it in groups
    //Of 4bits to compute groups in parallel and just fit each group into LUT6.
    logic [7:1] below_grp; //if 1 in group below, its 7:1 bc nothing can be below first group
    logic [2:0] which1; //which one falls out exactly

    always_comb begin : sticky_comb //indeed comb is sticky
        in_grp[6] = STRT_c[24];
        which1 = {&STRT_shexp_lo, STRT_shexp_lo[1], |STRT_shexp_lo};
        for (int i = 0; i < 6; i++) begin
            in_grp[i] = |STRT_c[i * 4 +: 4];
        end
        //sv doesn't accept dynaic range unfortunately so i can't do
        //below_grp[i+1] = |in_grp[i -: i + 1]; even tho i really wanted to
        below_grp[1] =  in_grp[0];
        below_grp[2] = |in_grp[1:0];
        below_grp[3] = |in_grp[2:0];
        below_grp[4] = |in_grp[3:0];
        below_grp[5] = |in_grp[4:0];
        below_grp[6] = |in_grp[5:0];
        below_grp[7] = |in_grp[6:0];
    end : sticky_comb

    //So if some group is shifted out, we need to check if there was actually
    //one, and register it for DGAF1, so this is what it is;
    logic [7:0] DGAF0_lost;
    always_ff @(posedge clk) begin
        DGAF0_lost[0] <= |(STRT_c[2:0] & which1);
        for (int i = 1; i < 6; i++) begin
            DGAF0_lost[i] <= below_grp[i] | |(STRT_c[4*i +: 3] & which1);
        end
        DGAF0_lost[6] <= below_grp[6]  | (STRT_c[24] & which1[0]);
        DGAF0_lost[7] <= below_grp[7];
    end

    //=> DGAF1 (Digital Signal Proccesing / Guard / Aligment / Float Prep) <=//
    //Finishing alignment(2-2-1) and starting second DSP
    logic [39:0] C_alig1; // aligned C
    logic [3:0]  DGAF1_ALUMODE;
    (* shreg_extract = "no" *) logic DGAF1_sticky;
    logic DGAF1_sticky_comb;
    (* shreg_extract = "no" *) logic [24:0] DGAF1_ato_add;
    (* shreg_extract = "no" *) logic DGAF1_c_sign, DGAF1_sub_mags;
    (* shreg_extract = "no" *) logic [8:0] DGAF1_exp_base;

    assign C_alig1 = {C_alig0, 12'h0} >> {DGAF0_shexp_lmid, 2'h0};
    assign C_alig2 = {C_alig1, 37'h0} >> {DGAF0_shexp_hmid, 4'h0};

    always_ff @(posedge clk) begin : DGAF1_C
        C_alig3 <= C_alig2 >> {DGAF0_shexp_hi, 6'h0};
        DGAF1_ALUMODE <= {ALUMODE[3:2], ALUMODE[1:0] | {2{DGAF0_sub_mags}}};
        DGAF1_sticky <= DGAF1_sticky_comb;
        DGAF1_ato_add <= DGAF0_ato_add;
        DGAF1_c_sign <= DGAF0_c_sign;
        DGAF1_sub_mags <= DGAF0_sub_mags;
        DGAF1_exp_base <= DGAF0_exp_base - 9'h1;
    end : DGAF1_C

    always_comb begin : sticky_check
        unique case ({DGAF0_shexp_hi, DGAF0_shexp_hmid, DGAF0_shexp_lmid}) //thats just sh_exp[6:2];
            5'd13: DGAF1_sticky_comb = DGAF0_lost[0];
            5'd14: DGAF1_sticky_comb = DGAF0_lost[1];
            5'd15: DGAF1_sticky_comb = DGAF0_lost[2];
            5'd16: DGAF1_sticky_comb = DGAF0_lost[3];
            5'd17: DGAF1_sticky_comb = DGAF0_lost[4];
            5'd18: DGAF1_sticky_comb = DGAF0_lost[5];
            5'd19: DGAF1_sticky_comb = DGAF0_lost[6];
            //if below 52, its zero, if above 72 or whatever one
            default: DGAF1_sticky_comb = DGAF0_shexp_hi & DGAF0_lost[7];
        endcase
    end : sticky_check


    //=> DSFSH0 (DSP Finish 0) <=//
    //Second DSP starts here
    (* shreg_extract = "no" *) logic [21:0] DSFSH0_ato_add;
    (* shreg_extract = "no" *) logic [31:0] DSFSH0_acto_add;
    (* shreg_extract = "no" *) logic [31:0] DSFSH0_acto_ff;
    (* shreg_extract = "no" *) logic DSFSH0_c_sign;
    (* shreg_extract = "no" *) logic DSFSH0_sub_mags;
    (* shreg_extract = "no" *) logic [8:0] DSFSH0_exp_base;
    (* shreg_extract = "no" *) logic DSFSH0_sticky;

    always_ff @(posedge clk) begin : DSFSH0_CRRY
        DSFSH0_ato_add <= DGAF1_ato_add[21:0];
        DSFSH0_c_sign <= DGAF1_c_sign;
        DSFSH0_sub_mags <= DGAF1_sub_mags;
        DSFSH0_exp_base <= DGAF1_exp_base;
        DSFSH0_sticky <= DGAF1_sticky;
    end : DSFSH0_CRRY

    //DSP can't fully add C to the product, and it can't multiply last bit of
    //a too(bc efp32 has one more mantissa bit). I solve this by a fabric
    //adder after DSP, and since ato_add and hi c is known rn, i just add them here.
    //Add c_hi to sub_mags(sign) extended last bit of ato_add basically just its top bit.
    assign DSFSH0_acto_add = {1'b0, C_alig3[76:46]} + {{29{DGAF1_sub_mags}}, DGAF1_sub_mags ^ DGAF1_ato_add[24], DGAF1_ato_add[23:22] ^ {2{DGAF1_sub_mags}}};
    always_ff @(posedge clk) begin
        DSFSH0_acto_ff <= DSFSH0_acto_add;
    end

    logic [47:0] PCOUT1, P3;
    /* verilator lint_off PINCONNECTEMPTY */
    DSP48E1 #(
        .A_INPUT("CASCADE"), //from prev
        .B_INPUT("DIRECT"),
        .USE_DPORT("TRUE"),
        .USE_MULT("DYNAMIC"), //For both floats and integer ops
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
        .BREG(2),
        .CARRYINREG(1),
        .CARRYINSELREG(1),
        .CREG(0),
        .DREG(1),
        .INMODEREG(1),
        .MREG(1),
        .OPMODEREG(1),
        .PREG(1)
    )
    intense_wallop (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(PCOUT1),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(P2),
        .ACIN(ACOUT0),
        .BCIN(18'h0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(PCOUT0),
        .ALUMODE(DGAF1_ALUMODE),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(INMODE2),
        .OPMODE(OPMODE2),
        //Its two's comlimetn so top bit gotta be 0
        .A(30'h0),
        .B({10'h0, STRT_b[24:17]}),
        .C(), //we're gonna need it at the third DSP cycle
        .CARRYIN(1'b0),
        .D({{9{STRT_a[32]}}, STRT_a[32], ~STRT_a[31], STRT_a[30:25], STRT_a[23:16]}), //for FFMA16
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

    //=> DSFSH1 (DSP Finish 1) <=//
    //Just waiting for the DSP result, while carrying operands for backend
    (* shreg_extract = "no" *) logic DSFSH1_sub_mags;
    (* shreg_extract = "no" *) logic [21:0] DSFSH1_ato_add;
    (* shreg_extract = "no" *) logic [31:0] DSFSH1_acto_add;
    (* shreg_extract = "no" *) logic DSFSH1_c_sign;
    (* shreg_extract = "no" *) logic [16:0] DSFSH1_P1_lo;
    (* shreg_extract = "no" *) logic [8:0] DSFSH1_exp_base;
    (* shreg_extract = "no" *) logic DSFSH1_sticky;

    always_ff @(posedge clk) begin : DSFSH1_CRRY
        DSFSH1_ato_add <= DSFSH0_ato_add[21:0]; //last bit already added
        DSFSH1_c_sign <= DSFSH0_c_sign;
        DSFSH1_sub_mags <= DSFSH0_sub_mags;
        DSFSH1_P1_lo <= P1[16:0];
        DSFSH1_acto_add <= DSFSH0_acto_ff;
        DSFSH1_exp_base <= DSFSH0_exp_base;
        DSFSH1_sticky <= DSFSH0_sticky;
    end : DSFSH1_CRRY

    //=> FIAD (Final Add) <=//
    //I've finally settled on 48GUCHes total for the GPU, per 4SMs(ill give SM
    //name later). That means 12GUCHes per SM, and 144Read ports for the sustained
    //FMA. That is really good because 144Read ports is plausible using
    //BRAM18s which i've got 270 of. It does reduce the theoretical peak
    //performance, but the thing is those 38.4GEOFLOPS were just theoretical,
    //With 2read ports per stage it just wouldn't work out. However it does
    //increase the average performance of sustained FMA, to about
    //25.6GEOFLOPS. Additionally it of course saves LUTs that im really
    //limited on. And also that allows me to use one more DSP per GUCH.
    //So I use it here to do the final add of c_hi and a's highest bit.
    //unfortunately im still just short so I gotta have a small adder after.
    //And also ill use pattern detect here, which skips like 1check stage.
    logic FIAD_ptrn_zeros, FIAD_ptrn_ones;
    logic [12:0] FIAD_hi, FIAD_hi_crry;
    logic [13:0] FIAD_hi_crry_sum;
    logic [3:0] FIAD_crry;
    (* shreg_extract = "no", dont_touch = "true" *) logic [16:0] FIAD_P1_lo;
    (* shreg_extract = "no", dont_touch = "true" *) logic [8:0] FIAD_exp_base;
    (* shreg_extract = "no", dont_touch = "true" *) logic FIAD_c_sign, FIAD_sticky;


    //3rd dsp still can't quite reach hi bits still, so still gotta have
    //a fabric adder, a small one, but nontheless.
    //If Goodbye passes a carry - we already are ready, with FIAD_hi_crry.
    assign FIAD_hi_crry_sum = {DSFSH1_acto_add[31:19], 1'b1} + {{13{P2[47]}}, 1'b1};
    always_ff @(posedge clk) begin
        FIAD_hi <= DSFSH1_acto_add[31:19] + {13{P2[47]}};
        FIAD_hi_crry <= FIAD_hi_crry_sum[13:1];
    end

    always_ff @(posedge clk) begin : FIAD_CRRY
        FIAD_P1_lo <= DSFSH1_P1_lo;
        FIAD_exp_base <= DSFSH1_exp_base;
        FIAD_c_sign <= DSFSH1_c_sign;
        FIAD_sticky <= DSFSH1_sticky;
    end : FIAD_CRRY

    /* verilator lint_off PINCONNECTEMPTY */
    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"),
        .USE_MULT("NONE"),
        .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"),
        .MASK(48'h00000FFFFFFF),
        .PATTERN(48'h000000000000),
        .SEL_MASK("MASK"),
        .SEL_PATTERN("PATTERN"),
        //I really do wonder what is xilinx doing? They are actually wasting
        //so much letters right here. It can easily be something like:
        //PTRNDET_E(1).
        .USE_PATTERN_DETECT("PATDET"),
        .ACASCREG(0),
        .ADREG(0),
        .ALUMODEREG(0),
        .AREG(0),
        .BCASCREG(0),
        .BREG(0),
        .CARRYINREG(1),
        .CARRYINSELREG(0),
        .CREG(1),
        .DREG(0),
        .INMODEREG(0),
        .MREG(0),
        .OPMODEREG(0),
        .PREG(1)
    )
    Goodbye (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(),
        .OVERFLOW(),
        //The pattern detect literally checks for patterns after ALU.
        //The lower port(holy letter waste btw) is checking for whether
        //Unamsked result bits are eq to the PATTERN, which is top bits
        //Being zero, and upper port checked whether it eqs to ~ptrn
        //Which means its all ones. Thus it works for both positive and neg results
        .PATTERNBDETECT(FIAD_ptrn_ones),
        .PATTERNDETECT(FIAD_ptrn_zeros),
        .UNDERFLOW(),
        .CARRYOUT(FIAD_crry),
        .P(P3),
        .ACIN(30'h0),
        .BCIN(18'h0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(PCOUT1),
        .ALUMODE(4'b0000),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(5'b00000),
        .OPMODE(7'b001_11_00),
        //Its two's comlimetn so top bit gotta be 0
        .A(30'h0),
        .B(18'h0),
        //Also if sub_mags we have to negate the ato_add, negating is flipping bits + 1.
        //Flipping bits is xoring with all 1s, and xoring with 0s does nothing, so
        //here we are, with this beautiful expression
        .C({DSFSH0_acto_ff[18:0], DSFSH0_ato_add[21:0] ^
                {22{DSFSH0_sub_mags}}, {7{DSFSH0_sub_mags}}}),
        .CARRYIN(DSFSH0_sub_mags), //thats so nice actually
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

    //=> PRENRM (Pre-Normalization) <=//
    //So initially I thought that I had ~16 stages for the whole GPU. But now
    //when I expanteded number of 'Warps' to 32, im not bounded by that number
    //anymore. Also from my ultra scientific calculations im going to be
    //memory bandwidth bounded, instead of latency bounded. So yeah this
    //virtually removes any bounds from pipeline stages I can have. And so NORM0
    //doesn't fit into 1 stage from my testing, so this one mainly registers operands
    //And runs some hi checks.

    //crry - as i said.
    logic  [12:0] res_hi;
    logic  res_neg;
    assign res_hi = FIAD_crry[3] ? FIAD_hi_crry : FIAD_hi;
    assign res_neg = res_hi[12];
    //results, assemble
    logic  [76:0] raw_res;
    assign raw_res = {res_hi, P3, FIAD_P1_lo};

    //I actually lied a lil bit I don't just do lzc, I do either lcz is lco
    //Based on the sign of th result
    logic  top32, next32.
    assign top32 = res_neg ? (FIAD_ptrn_ones  &  &res_hi[11:0])
                           : (FIAD_ptrn_zeros & ~|res_hi[11:0]);

    assign next32  = neg ? &{P3[27:0], FIAD_P1_lo[16:13]}
                         : ~|{P3[27:0], FIAD_P1_lo[16:13]};

    logic  sh64, sh32;
    assign sh64 = top32 & next32;
    assign sh32 = top32 & ~next32;

    //Just a check - I don't have much time here.
    logic  PRENRM_sh64, PRENRM_sh32;
    assign PRENRM_sh64 = 





    //=> NORM0 (Normalization 0) <=//
    //Finally a normalization. Basically since this is FMA, there is no way to
    //know where the result will land in the 76bit window. And normalization's
    //purpose is to shift it so highest bit is at bit 76(highest field). I do
    //it without a dedicated lzc btw, which I find kinda cool. I do it by just shifting until top1 hits 76th bit.
    //Also 77th bit is sign if ure wondering where it is, and 76th is hidden bit.

    //=> NORM1 (Normalization 1) <=//
    //Did you really expect the 76big ass shifter to fit into 1 stage?

    //=> NORM2 (Normalization 1) <=//
    //Did you really expect the 76big ass shifter to fit into 2 stages?

    //=> NORM3 (Normalization 1) <=//
    //Did you really expect the 76big ass shifter to fit into 3 stages?
    //Worst part is that I can't really do anything with unnormalized value.
    //To be frank it isn't even a worst part, it isn't really even bad, im
    //fine with it. It still just fits into 3.33ns




    //syntax drafts for flare
    //parallel [u32 i : arr.len<()>] {
    //  arr[i].rgbpck<(var0, var1)>;
    //}

endmodule
