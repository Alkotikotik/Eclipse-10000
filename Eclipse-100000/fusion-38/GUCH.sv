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
    input logic efp_op, int_op, int_mul, neg_p, neg_c,
    input logic [1:0] cmp_code, //<=, <, ==, !=
    input logic [5:0] int_sh,
    input logic [6:0] OPMODE1, OPMODE2, OPMODE3,
    input logic [4:0] INMODE1, INMODE2,
    input logic [3:0] ALUMODE, ALUMODE3,

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
    logic PREA_prod_zero, PREA_efp_op;

    //flush subnormals immediately
    logic  PREA_a_fld0, PREA_b_fld0, PREA_c_fld0;
    assign PREA_a_fld0 = ~|a[30:24];
    assign PREA_b_fld0 = ~|b[30:24];
    assign PREA_c_fld0 = ~|c[30:24];
    (* shreg_extract = "no" *) logic PREA_int;
    (* shreg_extract = "no" *) logic [5:0] PREA_int_sh;
    always_ff @(posedge clk) begin : PREA_EFP
        //Put back hidden bit. No unbias here: only shexp/cexp need the
        //unbiased value and they unbias themselfs. Rhe rest reads the field as is
        //No need for reset, otherwise DSP wouldn't accept them immediately
        //As for B, we need it for int op in intense wallop
        PREA_a <= {a[31:24], ~PREA_a_fld0, (efp_op & PREA_a_fld0) ? 24'h0 : a[23:0]};
        PREA_b <= {b[31:24], efp_op ? ~PREA_b_fld0 : b[24], (efp_op & PREA_b_fld0) ? 24'h0 : b[23:0]};
        PREA_c <= {c[31:24], ~PREA_c_fld0, (efp_op & PREA_c_fld0) ? 24'h0 : c[23:0]};

        PREA_shexp <= {{3{~a[30]}}, a[29:24]} + {{3{~b[30]}}, b[29:24]};
        //So basically subtracting a number from const should be a little better.
        PREA_cexp  <= 9'd28 - {{3{~c[30]}}, c[29:24]};

        PREA_prod_zero <= PREA_a_fld0 | PREA_b_fld0;
        PREA_efp_op <= efp_op;
        PREA_int <= int_op;
        PREA_int_sh <= int_sh;
    end : PREA_EFP

    //=> STRT (Start) <=//
    //Calc sh and start DSPs
    logic [32:0] STRT_a, STRT_b, STRT_c;
    logic [6:0]  STRT_b_hi;
    logic [8:0]  STRT_abexp;
    logic [8:0]  shexp;
    logic STRT_prod_zero, STRT_shexp_neg;

    logic [6:0] sh_exp;
    (* shreg_extract = "no" *) logic STRT_int;
    (* shreg_extract = "no" *) logic [5:0] STRT_int_sh;
    always_ff @(posedge clk) begin : STRT_CRRY
        STRT_a <= {PREA_a[32:25], PREA_a[24] & PREA_efp_op, PREA_a[23:0]};
        STRT_b_hi <= PREA_efp_op ? 7'h0 : PREA_b[32:26];
        STRT_b <= PREA_b;
        STRT_c <= PREA_c;

        STRT_abexp <= PREA_shexp;

        STRT_prod_zero <= PREA_prod_zero;
        STRT_shexp_neg <= shexp[8];
        STRT_int <= PREA_int;
        STRT_int_sh <= PREA_int_sh;
    end : STRT_CRRY

    //Basically sub_sel bits govern the sign of products and c result
    //add or subtract. Subtract magnitudes
    //Also dedicated signs always_ff is p funny
    logic c_sign, sub_mags, STRT_b_sign;
    always_ff @(posedge clk) begin : signs
        c_sign <= PREA_c[32] ^ neg_c; //FMS... etc
        sub_mags <= PREA_efp_op & (PREA_a[32] ^ PREA_b[32] ^ PREA_c[32] ^ neg_p ^ neg_c); //Whether to add or sub magnitudes, only for efp, bc other are two's compliment
        STRT_b_sign <= ~PREA_efp_op & PREA_b[32];
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
    assign sh_exp = (shexp[8] | PREA_prod_zero) ? 0 : (shexp[7] ? 7'd127 : shexp[6:0]);

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
        .D({17'h0, PREA_a[32:25]}),
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

    (* shreg_extract = "no" *) logic DGAF0_int;
    (* shreg_extract = "no" *) logic [5:0] DGAF0_int_sh;
    always_ff @(posedge clk) begin : DGAF0_CRRY
        DGAF0_shexp_lmid <= STRT_shexp_lmid;
        DGAF0_shexp_hmid <= STRT_shexp_hmid;
        DGAF0_shexp_hi <= STRT_shexp_hi;
        DGAF0_sub_mags <= sub_mags;
        DGAF0_c_sign <= c_sign;
        DGAF0_int <= STRT_int;
        DGAF0_int_sh <= STRT_int_sh;
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
        DGAF0_exp_base <= ((STRT_shexp_neg | STRT_prod_zero) & STRT_c[24]) ? {2'b00, STRT_c[31:25]} : STRT_abexp + 9'd92;
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

    //So int ops are almost, just almost free. In the essence I just reuse
    //existing datapath - DSPs, shifters, adders etc, and add some muxes before them.
    //ull see.
    (* shreg_extract = "no" *) logic [31:0] DGAF0_int_a, DGAF0_int_b;
    always_ff @(posedge clk) begin
        DGAF0_int_a <= {STRT_a[32:25], STRT_a[23:0]};
        DGAF0_int_b <= {STRT_b[32:25], STRT_b[23:0]};
    end

    //=> DGAF1 (Digital Signal Proccesing / Guard / Aligment / Float Prep) <=//
    //Finishing alignment(2-2-1) and starting second DSP
    logic [39:0] C_alig1; // aligned C
    logic [3:0]  DGAF1_ALUMODE;
    (* shreg_extract = "no" *) logic DGAF1_sticky;
    logic DGAF1_sticky_comb;

    assign C_alig1 = {C_alig0, 12'h0} >> {DGAF0_shexp_lmid, 2'h0};
    assign C_alig2 = {C_alig1, 37'h0} >> {DGAF0_shexp_hmid, 4'h0};

    always_ff @(posedge clk) begin : DGAF1_C
        C_alig3 <= C_alig2 >> {DGAF0_shexp_hi, 6'h0};
        DGAF1_ALUMODE <= {ALUMODE[3:2], ALUMODE[1:0] | {2{DGAF0_sub_mags}}};
        DGAF1_sticky <= DGAF1_sticky_comb;
    end : DGAF1_C

    (* shreg_extract = "no" *) logic [24:0] DGAF1_ato_add;
    (* shreg_extract = "no" *) logic DGAF1_c_sign, DGAF1_sub_mags;
    (* shreg_extract = "no" *) logic [17:0] DGAF1_mul_op;
    (* shreg_extract = "no" *) logic [8:0] DGAF1_exp_base;
    (* shreg_extract = "no" *) logic [31:0] DGAF1_int_a;
    (* shreg_extract = "no" *) logic [31:15] DGAF1_int_b; //only hi is needed for Goodbye
    (* shreg_extract = "no" *) logic DGAF1_int;
    (* shreg_extract = "no" *) logic [5:0] DGAF1_int_sh;
    always_ff @(posedge clk) begin : DGAF1_CRRY
        DGAF1_ato_add  <= DGAF0_ato_add;
        DGAF1_c_sign   <= DGAF0_c_sign;
        DGAF1_sub_mags <= DGAF0_sub_mags;
        DGAF1_exp_base <= DGAF0_exp_base - 9'h1;
        DGAF1_int_a    <= DGAF0_int_a;
        DGAF1_int_b    <= DGAF0_int_b[31:15];
        DGAF1_int      <= DGAF0_int;
        DGAF1_int_sh   <= DGAF0_int_sh;
        //its mul_operands btw - im a god of unreadable code. int_op is
        //delayed to DGAF0 in SM btw
        DGAF1_mul_op   <= int_mul ? {{3{DGAF0_int_a[31]}}, DGAF0_int_a[31:24], 7'h0} : {DGAF0_int_b[14:0], 3'h0};
    end : DGAF1_CRRY

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

    (* shreg_extract = "no" *) logic DSFSH0_int;
    (* shreg_extract = "no" *) logic [5:0] DSFSH0_int_sh;
    always_ff @(posedge clk) begin : DSFSH0_CRRY
        DSFSH0_ato_add <= DGAF1_ato_add[21:0];
        DSFSH0_c_sign <= DGAF1_c_sign;
        DSFSH0_sub_mags <= DGAF1_sub_mags;
        DSFSH0_exp_base <= DGAF1_exp_base;
        DSFSH0_sticky <= DGAF1_sticky;
        DSFSH0_int <= DGAF1_int;
        DSFSH0_int_sh <= DGAF1_int_sh;
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
        .CREG(1),
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
        //Im doing integer mul through 3DSPs to get lower 48bit of the
        //product. And the SM's existing int_sh can govern which 32bit window
        //gets written to a register. theoretically its useful for various
        //Fixed point formats like Q16.16 or Q24.8, however atp im just doing
        //stuff because i like doing it. Also not atp im always doing stuff
        //because I like doing it.
        .B({{3{STRT_b_sign}}, STRT_b_hi, STRT_b[24:17]}),
        .C({13'h0, DGAF1_int_a, 3'h0}), //int op
        .CARRYIN(1'b0),
        .D({17'h0, STRT_a[32:25]}),
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

    (* shreg_extract = "no" *) logic DSFSH1_int;
    (* shreg_extract = "no" *) logic [5:0] DSFSH1_int_sh;
    always_ff @(posedge clk) begin : DSFSH1_CRRY
        DSFSH1_ato_add <= DSFSH0_ato_add[21:0]; //last bit already added
        DSFSH1_c_sign <= DSFSH0_c_sign;
        DSFSH1_sub_mags <= DSFSH0_sub_mags;
        DSFSH1_P1_lo <= P1[16:0];
        DSFSH1_acto_add <= DSFSH0_acto_ff;
        DSFSH1_exp_base <= DSFSH0_exp_base;
        DSFSH1_sticky <= DSFSH0_sticky;
        DSFSH1_int <= DSFSH0_int;
        DSFSH1_int_sh <= DSFSH0_int_sh;
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
    (* shreg_extract = "no" *) logic [16:0] FIAD_P1_lo;
    (* shreg_extract = "no" *) logic [8:0] FIAD_exp_base;
    (* shreg_extract = "no" *) logic FIAD_c_sign, FIAD_sticky;


    //3rd dsp still can't quite reach hi bits still, so still gotta have
    //a fabric adder, a small one, but nontheless.
    //If Goodbye passes a carry - we already are ready, with FIAD_hi_crry.
    assign FIAD_hi_crry_sum = {DSFSH1_acto_add[31:19], 1'b1} + {{13{P2[47]}}, 1'b1};
    always_ff @(posedge clk) begin
        FIAD_hi <= DSFSH1_acto_add[31:19] + {13{P2[47]}};
        FIAD_hi_crry <= FIAD_hi_crry_sum[13:1];
    end

    (* shreg_extract = "no" *) logic FIAD_int;
    (* shreg_extract = "no" *) logic [5:0] FIAD_int_sh;
    always_ff @(posedge clk) begin : FIAD_PASS
        FIAD_P1_lo <= DSFSH1_P1_lo;
        FIAD_exp_base <= DSFSH1_exp_base;
        FIAD_c_sign <= DSFSH1_c_sign;
        FIAD_sticky <= DSFSH1_sticky;
        FIAD_int <= DSFSH1_int;
        FIAD_int_sh <= DSFSH1_int_sh;
    end : FIAD_PASS

    /* verilator lint_off PINCONNECTEMPTY */
    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("TRUE"),
        .USE_MULT("DYNAMIC"),
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
        //Those regs set how much ffs for each operand sit at DSP, so how many
        //cycles it takes. The way I set it would make result arrive at FIAD.
        .ACASCREG(2),
        .ADREG(1),
        .ALUMODEREG(1),
        .AREG(2),
        .BCASCREG(2),
        .BREG(2),
        .CARRYINREG(1),
        .CARRYINSELREG(0),
        .CREG(1),
        .DREG(1),
        .INMODEREG(0),
        .MREG(1),
        .OPMODEREG(1),
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
        //ALUMODE and OPMODE set what operations are actually performed by the
        //DSP, they are sent by SM, because every GUCH performs same one on
        //every lane.
        .ALUMODE(ALUMODE3),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(5'b10110),
        .OPMODE(OPMODE3),
        //Its two's comlimetn so top bit gotta be 0
        .A({13'h0, DGAF1_int_b[31:15]}),
        .B(DGAF1_mul_op),
        //Also if sub_mags we have to negate the ato_add, negating is flipping bits + 1.
        //Flipping bits is xoring with all 1s, and xoring with 0s does nothing, so
        //here we are, with this beautiful expression
        .C({DSFSH0_acto_ff[18:0], DSFSH0_ato_add[21:0] ^
                {22{DSFSH0_sub_mags}}, {7{DSFSH0_sub_mags}}}),
        .CARRYIN(DSFSH0_sub_mags), //thats so nice actually
        .D({1'b0, DGAF0_int_b[23:0]}),
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
    assign res_hi = FIAD_crry[3] ? FIAD_hi_crry : FIAD_hi;
    //results, assemble
    logic  [77:0] raw_res;
    assign raw_res = {res_hi, P3, FIAD_P1_lo};

    //I actually lied a lil bit I don't just do lzc, I do either lcz is lco
    //Based on the sign of th result. And im doing this check here instead of
    //first NORM, just because I can, everything is known early here. I don't
    //do anything more because other results arrive pretty late
    logic  top32_c0, top32_c1, next32_z, next32_o;
    assign top32_c0 = FIAD_hi[12] ? (FIAD_ptrn_ones  &  &FIAD_hi[11:0])
                                  : (FIAD_ptrn_zeros & ~|FIAD_hi[11:0]);
    assign top32_c1 = FIAD_hi_crry[12] ? (FIAD_ptrn_ones  &  &FIAD_hi_crry[11:0])
                                       : (FIAD_ptrn_zeros & ~|FIAD_hi_crry[11:0]);

    assign next32_z = ~|{P3[27:0], FIAD_P1_lo[16:13]};
    assign next32_o = &{P3[27:0], FIAD_P1_lo[16:13]};

    //thats basically a lookahead for NORM0, PRENRM checks bits are eq.
    //Then in NORM1 I check whether its sign or not, if it is - good shift, if
    //it isn't - don't shift. Actually I can check it rn after fix I made.
    //It was in NORM0 previosely, but NORM0 didn't pass, and I realized it can
    //be moved here. Yeah so I moved bunch more stuff in here, but its
    //essentially the same
    logic  [2:1] eq16, eq8hi;
    logic  [2:0] eq8lo;
    logic  eq16_c0, eq16_c1, eq8hi_c0, eq8hi_c1;
    assign eq16_c0  = &{FIAD_hi[11:0], P3[47:44]} | ~|{FIAD_hi[11:0], P3[47:44]};
    assign eq16_c1  = &{FIAD_hi_crry[11:0], P3[47:44]} | ~|{FIAD_hi_crry[11:0], P3[47:44]};
    assign eq8hi_c0 = &FIAD_hi[11:4] | ~|FIAD_hi[11:4];
    assign eq8hi_c1 = &FIAD_hi_crry[11:4] | ~|FIAD_hi_crry[11:4];
    assign eq16  = {raw_res[12:0] == 13'h0,
                    &raw_res[44:29] | ~|raw_res[44:29]};
    assign eq8hi = {&raw_res[12:5]  | ~|raw_res[12:5],
                    &raw_res[44:37] | ~|raw_res[44:37]};
    assign eq8lo = {1'b1,
                    &raw_res[29:21] | ~|raw_res[29:21],
                    &raw_res[61:53] | ~|raw_res[61:53]};

    logic PRENRM_top32_c0, PRENRM_top32_c1, PRENRM_next32_z, PRENRM_next32_o, PRENRM_cout;
    logic [2:1] PRENRM_eq16, PRENRM_eq8hi;
    logic [2:0] PRENRM_eq8lo;
    logic PRENRM_eq16_c0, PRENRM_eq16_c1, PRENRM_eq8hi_c0, PRENRM_eq8hi_c1;
    logic [77:0] PRENRM_raw_res;
    (* shreg_extract = "no" *) logic PRENRM_c_sign, PRENRM_sticky;
    (* shreg_extract = "no" *) logic [8:0] PRENRM_exp_base;

    (* shreg_extract = "no" *) logic PRENRM_int;
    (* shreg_extract = "no" *) logic [4:0] PRENRM_int_sh;
    always_ff @(posedge clk) begin : PRENRM_CRRY
        PRENRM_top32_c0 <= (FIAD_int & ~FIAD_int_sh[5]) ? 1'b0 : top32_c0 | FIAD_int_sh[5];
        PRENRM_top32_c1 <= (FIAD_int & ~FIAD_int_sh[5]) ? 1'b0 : top32_c1 | FIAD_int_sh[5];
        PRENRM_next32_z <= FIAD_int ? 1'b0 : next32_z;
        PRENRM_next32_o <= FIAD_int ? 1'b0 : next32_o;
        PRENRM_cout     <= FIAD_crry[3];
        PRENRM_eq16     <= eq16;
        PRENRM_eq16_c0  <= eq16_c0;
        PRENRM_eq16_c1  <= eq16_c1;
        PRENRM_eq8hi_c0 <= eq8hi_c0;
        PRENRM_eq8hi_c1 <= eq8hi_c1;
        PRENRM_eq8hi    <= eq8hi;
        PRENRM_eq8lo    <= eq8lo;
        PRENRM_raw_res  <= raw_res;
        PRENRM_c_sign   <= FIAD_c_sign;
        PRENRM_sticky   <= FIAD_sticky;
        PRENRM_exp_base <= FIAD_exp_base;
        PRENRM_int      <= FIAD_int;
        PRENRM_int_sh   <= FIAD_int_sh[4:0];
    end : PRENRM_CRRY


    //=> NORM0 (Normalization 0) <=//
    //Finally a normalization. Basically since this is FMA, there is no way to
    //know where the result will land in the 76bit window. And normalization's
    //purpose is to shift it so highest bit is at bit 76(highest field). I do
    //it without a dedicated lzc btw, which I find kinda cool. I do it by just shifting until top1 hits 76th bit.
    //Also 77th bit is sign if ure wondering where it is, and 76th is hidden bit.
    logic  NORM0_top32, NORM0_next32, NORM0_sh64, NORM0_sh32;
    always_comb begin
        NORM0_top32  = PRENRM_cout ? PRENRM_top32_c1 : PRENRM_top32_c0;
        NORM0_next32 = PRENRM_raw_res[77] ? PRENRM_next32_o : PRENRM_next32_z;
        //also im reusing that NORM shifter for left shift, in similar way
        //I reuse C_alig for right shift, int_sh is all zeros if its not shift
        //left, so i should be good. Those calculations already use LUTs too,
        //so that mux is basically free.
        NORM0_sh64 = NORM0_top32 & NORM0_next32;
        NORM0_sh32 = NORM0_top32 & ~NORM0_next32;
    end

    logic  [76:0] NORM0_sh;
    //Thats really is a nice line.
    assign NORM0_sh = PRENRM_raw_res[76:0] << {NORM0_sh64, NORM0_sh32, 5'b00000};

    //check continues
    logic  [2:0] NORM0_eq16, NORM0_eq8hi, NORM0_eq8lo, NORM0_still_sh;
    assign NORM0_still_sh = {PRENRM_raw_res[12], PRENRM_raw_res[44], PRENRM_raw_res[76]} ~^ {3{PRENRM_raw_res[77]}};

    assign NORM0_eq16  = {PRENRM_eq16, PRENRM_cout ? PRENRM_eq16_c1 : PRENRM_eq16_c0} & NORM0_still_sh;
    assign NORM0_eq8hi = {PRENRM_eq8hi, PRENRM_cout ? PRENRM_eq8hi_c1 : PRENRM_eq8hi_c0} & NORM0_still_sh;

    //eq8lo doesn't need it bc its already checked in eq16
    assign NORM0_eq8lo = PRENRM_eq8lo;

    logic  NORM0_pk16, NORM0_pk8hi, NORM0_pk8lo;
    assign NORM0_pk16  = NORM0_sh64 ? NORM0_eq16[2]  : NORM0_sh32 ? NORM0_eq16[1]  : NORM0_eq16[0];
    assign NORM0_pk8hi = NORM0_sh64 ? NORM0_eq8hi[2] : NORM0_sh32 ? NORM0_eq8hi[1] : NORM0_eq8hi[0];
    assign NORM0_pk8lo = NORM0_sh64 ? NORM0_eq8lo[2] : NORM0_sh32 ? NORM0_eq8lo[1] : NORM0_eq8lo[0];

    //1 fell - later for rounding.
    logic  NORM0_fell;
    assign NORM0_fell = ~NORM0_sh64 & ~NORM0_sh32 & |PRENRM_raw_res[19:0];

    //The so called "guard" bit is right after last mantissa bit, so at bit 51.
    //The shifter can shift max 31bits away, therefore 51-31 = 20 is the lowest it can get
    //Also I construct lcz bit by bit its kinda cool.
    //Also original sticky did its job, press f its no loner carried
    //Also for int ops shifter acts as a literal position shifter of 32bit
    //window. The problem is that it can be any window of the 48bit result, so
    //I have to consider that and expand NORM ffs
    (* extract_reset = "no" *) logic [76:14] NORM0_raw_res;
    (* shreg_extract = "no" *) logic [1:0]  NORM0_lzc;
    (* shreg_extract = "no" *) logic NORM0_fell_ff;
    always_ff @(posedge clk) begin : NORM0_REG
        NORM0_raw_res <= {NORM0_sh[76:20], PRENRM_raw_res[19:14]};
        NORM0_lzc <= {NORM0_sh64, NORM0_sh32};
        NORM0_fell_ff <= NORM0_fell | PRENRM_sticky;
    end : NORM0_REG

    (* shreg_extract = "no" *) logic NORM0_neg, NORM0_c_sign;
    (* shreg_extract = "no" *) logic [8:0] NORM0_exp_base;
    (* shreg_extract = "no" *) logic NORM1_sh16, NORM1_sh8;
    (* shreg_extract = "no" *) logic NORM0_int;
    (* shreg_extract = "no" *) logic [2:0] NORM0_int_sh;
    always_ff @(posedge clk) begin : NORM0_CRRY
        //Sometimes I like aligned <=, something i don't
        NORM0_neg      <= PRENRM_raw_res[77];
        NORM0_c_sign   <= PRENRM_c_sign;
        NORM0_exp_base <= PRENRM_exp_base;
        NORM1_sh16     <= (PRENRM_int & ~PRENRM_int_sh[4]) ? 1'b0 : NORM0_pk16 | PRENRM_int_sh[4]; //thats lil bit confusing
        NORM1_sh8      <= (PRENRM_int & ~PRENRM_int_sh[3]) ? 1'b0 : (NORM0_pk16 ? NORM0_pk8lo : NORM0_pk8hi) | PRENRM_int_sh[3];
        NORM0_int      <= PRENRM_int;
        NORM0_int_sh   <= PRENRM_int_sh[2:0];
    end : NORM0_CRRY

    //=> NORM1 (Normalization 1) <=//
    //Did you really expect the 76big ass shifter to fit into 1 stage?
    logic  [76:14] NORM1_sh;
    assign NORM1_sh = NORM0_raw_res << {NORM1_sh16, NORM1_sh8, 3'b000};

    logic  NORM1_fell;
    always_comb begin
        unique case ({NORM1_sh16, NORM1_sh8})
            2'b00:   NORM1_fell = |NORM0_raw_res[43:20];
            2'b01:   NORM1_fell = |NORM0_raw_res[35:20];
            2'b10:   NORM1_fell = |NORM0_raw_res[27:20];
            default: NORM1_fell = 1'b0;
        endcase
    end

    //51 - 7
    (* extract_reset = "no" *) logic [76:38] NORM1_raw_res;
    (* shreg_extract = "no" *) logic [3:0]   NORM1_lzc;
    (* shreg_extract = "no" *) logic NORM1_fell_ff;
    always_ff @(posedge clk) begin : NORM1_REG
        NORM1_raw_res[76:38] <= NORM1_sh[76:38];
        NORM1_lzc <= {NORM0_lzc, NORM1_sh16, NORM1_sh8};
        NORM1_fell_ff <= NORM1_fell | NORM0_fell_ff;
    end : NORM1_REG

    (* shreg_extract = "no" *) logic NORM1_neg, NORM1_c_sign;
    (* shreg_extract = "no" *) logic [8:0] NORM1_exp_base;
    (* shreg_extract = "no" *) logic NORM1_int;
    (* shreg_extract = "no" *) logic [1:0] NORM1_int_sh;
    always_ff @(posedge clk) begin : NORM1_CRRY
        NORM1_neg      <= NORM0_int ? NORM0_int_sh[2] : NORM0_neg;
        NORM1_c_sign   <= NORM0_c_sign;
        NORM1_exp_base <= NORM0_exp_base;
        NORM1_int      <= NORM0_int;
        NORM1_int_sh   <= NORM0_int_sh[1:0];
    end : NORM1_CRRY

    //=> NORM2 (Normalization 1) <=//
    //Did you really expect the 76big ass shifter to fit into 2 stages?
    //NORM2 is also clean bc it doesn't inherit and doesn't initialize any
    //lookahead shenanigans. Simply bc it doesn't need to.
    logic  NORM2_sh4, NORM2_sh2;
    assign NORM2_sh4 = NORM1_int ? NORM1_neg : NORM1_raw_res[76:73] == {4{NORM1_neg}};
    assign NORM2_sh2 = NORM1_int ? NORM1_int_sh[1] : NORM2_sh4 ? NORM1_raw_res[72:71] == {2{NORM1_neg}} : NORM1_raw_res[76:75] == {2{NORM1_neg}};

    logic  [76:38] NORM2_sh;
    assign NORM2_sh = NORM1_raw_res << {NORM2_sh4, NORM2_sh2, 1'b0};

    logic NORM2_fell;
    always_comb begin
        unique case ({NORM2_sh4, NORM2_sh2})
            2'b00: NORM2_fell = |NORM1_raw_res[49:44];
            2'b01: NORM2_fell = |NORM1_raw_res[47:44];
            2'b10: NORM2_fell = |NORM1_raw_res[45:44];
            default: NORM2_fell = 1'b0;
        endcase
    end

    logic [76:44] NORM2_raw_res;
    logic NORM2_fell_ff;
    (* shreg_extract = "no" *) logic [5:0]   NORM2_lzc;
    always_ff @(posedge clk) begin : NORM2_REG
        NORM2_raw_res <= NORM2_sh[76:44];
        NORM2_fell_ff <= NORM1_fell_ff | NORM2_fell;
        NORM2_lzc <= {NORM1_lzc, NORM2_sh4, NORM2_sh2};
    end : NORM2_REG

    (* shreg_extract = "no" *) logic NORM2_neg, NORM2_c_sign;
    (* shreg_extract = "no" *) logic [8:0] NORM2_exp_base;
    (* shreg_extract = "no" *) logic NORM2_int, NORM2_int_sh;
    always_ff @(posedge clk) begin : NORM2_CRRY
        NORM2_neg      <= NORM1_neg;
        NORM2_c_sign   <= NORM1_c_sign;
        NORM2_exp_base <= NORM1_exp_base;
        NORM2_int      <= NORM1_int;
        NORM2_int_sh   <= NORM1_int_sh[0];
    end : NORM2_CRRY

    //=> NORM3 (Normalization 1) <=//
    //Did you really expect the 76big ass shifter to fit into 3 stages?
    //Worst part is that I can't really do anything with unnormalized value.
    //To be frank it isn't even a worst part, it isn't really even bad, im
    //fine with it. It still just fits into 3.33ns.
    //Last shift btw
    logic  NORM3_sh1;
    assign NORM3_sh1 = NORM2_int ? NORM2_int_sh : NORM2_raw_res[76] == NORM2_neg;

    //The final difference, in short before that moment exp assumed its
    //the highest one, but for each bit shifted it decreases by 1, thats
    //the reason we even need lcz. 2'b00 is for Wall to not complain
    logic [8:0] norm_diff;
    assign norm_diff = NORM2_exp_base - {2'b00, NORM2_lzc, NORM3_sh1};

    logic [76:45] norm_res; //hell yeahhhhh
    logic norm_fell;
    logic [8:0] norm_exp;
    always_ff @(posedge clk) begin : NORM3_REG
        norm_res  <= NORM3_sh1 ? NORM2_raw_res[75:44] : NORM2_raw_res[76:45]; //saves up lil bit of LUTs
        norm_fell <= NORM2_fell_ff | (~NORM3_sh1 & NORM2_raw_res[50]);
        norm_exp  <= norm_diff[8:0];
    end : NORM3_REG

    (* shreg_extract = "no" *) logic norm_neg, norm_c_sign;
    //max fanout would make vivado duplicate ffs and put them closer to
    //a reader. that path failed btw
    (* shreg_extract = "no" *) (* max_fanout = 12 *) logic NORM3_int;
    always_ff @(posedge clk) begin : NORM3_CRRY
        norm_neg    <= NORM2_neg;
        norm_c_sign <= NORM2_c_sign;
        NORM3_int   <= NORM2_int;
    end : NORM3_CRRY

    //=> RND (Round) <=//
    //Undo two's compliment, and round
    logic  [23:0] RND_mant;
    assign RND_mant = norm_res[75:52] ^ {24{norm_neg}};

    logic  RND_guard, RND_lsb, RND_hidden, RND_zero;
    assign RND_guard  = norm_res[51] ^ norm_neg;
    assign RND_lsb    = norm_res[52] ^ norm_neg;
    assign RND_hidden = norm_res[76] ^ norm_neg;

    //So this is the flush i've talked before, it works bc norm_exp is exp-1,
    //Thats why i carried norm_exp -1 all the way through. And yeah [8] works
    //because flush test does exp <= 0, which is the same as exp - 1 <= which
    //is msb in two's compliment. Also if I didn't do ~NORM3_int there it
    //would have been kinda funny, imagine debugging a random zero int result
    //for several hours.
    assign RND_zero = ~NORM3_int & (norm_exp[8] | ~RND_hidden);

    //final, whether to round up or down, all this rounding stuff just for list sig bit
    //If it reaches the guard and goes beyond, we round up, if it doesn't but reaches sticky, round down
    //If it just reaches the guard, i do LSB meaning if LSB is one I round up,
    //if its zero i round down. Its how ties to even works you might think
    //thats its kinda unfair, but in reality 50% of the times it would round
    //up and 50% round down so error averages out.
    logic  RND_inc;
    assign RND_inc = RND_guard  ? (norm_fell | RND_lsb | norm_neg)
                                : (norm_neg & ~norm_fell & RND_lsb);

    logic [31:0] RND_a, RND_b;
    logic [31:0] RND_res, RND_res_ff;
    logic RND_sign, RND_int;

    assign RND_a = NORM3_int ? norm_res[76:45] : {norm_exp[7:0], RND_mant}; //all zero on flush
    assign RND_b = {7'h0, RND_hidden & ~NORM3_int, 23'h0, RND_inc & ~NORM3_int};
    //Add that 1 to exp back and inc if round up.
    assign RND_res = RND_a + RND_b;
    always_ff @(posedge clk) begin
        RND_res_ff <= RND_zero ? 32'h0 : RND_res;
        RND_int <= NORM3_int;
        //So that elimitates -0 whatsoever, -0 just becomes regular zero, because I hate -0. Its like complete nonsense
        RND_sign <= RND_zero ? 1'b0 : norm_neg ^ norm_c_sign;
    end

    //=> PCK (Pack) <=//
    //Well well well and so here we are - final stage
    logic [31:0] FINALE;
    always_ff @(posedge clk) begin
        FINALE <= {RND_int ? RND_res_ff[31] : RND_sign, (RND_res_ff[31] & ~RND_int) ? 31'h7FFFFFFF : RND_res_ff[30:0]};
    end
    assign result = FINALE;
endmodule
