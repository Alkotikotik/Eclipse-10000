module GUCH (
    //GUCH - Graphical Unified Computing Heart
    //Well well finally starting the GPU im so excited for it.
    //So first one is ofc smallest core its the basic GPU contruct.
    //The heart is efp32 FMA that is done through 2DSPs, it also has integer mode,
    //16bit fma, float to int conversion and min/max/abs.
    input logic clk,
    input logic rst_n,

    //So my encoding/decoding scheme is pretty cool, ill explain it later prolly
    //First of all, all signals are computed in 1 SM because all GUCHes share them
    //But that I mean b becomes one or c becomes zero
    input logic efp_op, neg_p, neg_c, ffma16,
    input logic [1:0] cmp_code, //<=, <, ==, !=
    input logic [6:0] OPMODE,
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

    //== STRT (start) ==//
    //Register operands, calc sh and start DSPs
    logic [32:0] STRT_a, STRT_b, STRT_c;
    logic [8:0] shexp;
    logic [6:0] sh_exp;
    always_ff @(posedge clk) begin : STRT_EFP
        //unbias by inverting top bit, and put back hidden bit.
        //No need for reset, otherwise DSP wouldn't accept them immediately
        STRT_a <= {a[31], ~a[30], a[29:24], |a[30:24], a[23:0]};
        STRT_b <= {b[31], ~b[30], b[29:24], |b[30:24], b[23:0]};
        STRT_c <= {c[31], ~c[30], c[29:24], |c[30:24], c[23:0]};
    end : STRT_EFP

    //Basically sub_sel bits govern the sign of products and c result
    //add or subtract. Subtract magnitudes
    logic product_sign, c_sign, sub_mags;

    always_ff @(posedge clk or negedge rst_n) begin : signs
        if (!rst_n) begin
            product_sign <= 1'b0;
            c_sign <= 1'b0;
            sub_mags <= 1'b0;
        end else begin
            product_sign <= a[31] ^ b[31] ^ neg_p[0]; //FNMA... etc
            c_sign <= c[31] ^ neg_c[1]; //FMS... etc
            sub_mags <= efp_op & (a[31] ^ b[31] ^ c[31] ^ neg_p ^ neg_c); //Whether to add or sub magnitudes, only for efp, bc other are two's compliment
        end
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
    assign shexp = {{3{~a[30]}}, {a[29:25], a[24] | ~|a[30:24]}} + {{3{~b[30]}}, {b[29:25], b[24] | ~|b[30:24]}} - {{3{~c[30]}}, {c[29:25], c[24] | ~|c[30:24]}} + 9'd28;
    //clamp, if sign bit is 1(two's copmliment), don't move because shifter
    //can only move down. Then if 7th bit is 1, its between 128-256, and it
    //all is too high, so just set it to highest number within 7bits - 127.
    assign sh_exp = shexp[8] ? 0 : (shexp[7] ? 7'd127 : shexp[6:0]);

    //I need to align C to 77bits then add lower bits in first DSP, and rest
    //in fabric. I do it in 4 stages across 2 cycles parallel to first cycles of DSP so it
    //arrives just in time. The split is 2-2-2-1 bits per stage. I did it
    //because it saves LUT since 2shift bits plus shift fits just in LUT6
    //hence its the cheapest possible way to do it. And more bits before bc my
    //gut feeling tells me that its safer to it in DSAL0.
    logic [1:0] STRT_shexp_lo, STRT_shexp_lmid, STRT_shexp_hmid;
    logic STRT_shexp_hi;
    always_ff @(posedge clk or negedge rst_n) begin : STRT_SH
        if (!rst_n) begin
            STRT_shexp_lo <= 2'h0;
            STRT_shexp_lmid <= 2'h0;

            STRT_shexp_hmid <= 2'h0;
            STRT_shexp_hi <= 1'h0;
        end else begin
            STRT_shexp_lo <= sh_exp[1:0];
            STRT_shexp_lmid <= sh_exp[3:2];

            STRT_shexp_hmid <= sh_exp[5:4];
            STRT_shexp_hi <= sh_exp[6];
        end
    end : STRT_SH

    logic DSAL0_sub_mags;
    logic [76:0] C_alig2, C_alig3;
    logic [47:0] P1, PCOUT1;

    /* verilator lint_off PINCONNECTEMPTY */
    DSP48E1 #(
        // Feature Control Attributes: Data Path Selection
        .A_INPUT("DIRECT"),               // Selects A input source, "DIRECT" (A port) or "CASCADE" (ACIN port)
        .B_INPUT("DIRECT"),               // Selects B input source, "DIRECT" (B port) or "CASCADE" (BCIN port)
        .USE_DPORT("FALSE"),              // Select D port usage (TRUE or FALSE)
        .USE_MULT("DYNAMIC"), //For both floats and integer ops
        .USE_SIMD("ONE48"),               // SIMD selection ("ONE48", "TWO24", "FOUR12")
        // Pattern Detector Attributes: Pattern Detection Configuration
        .AUTORESET_PATDET("NO_RESET"),    // "NO_RESET", "RESET_MATCH", "RESET_NOT_MATCH" 
        .MASK(48'h3fffffffffff),          // 48-bit mask value for pattern detect (1=ignore)
        .PATTERN(48'h000000000000),       // 48-bit pattern match for pattern detect
        .SEL_MASK("MASK"),                // "C", "MASK", "ROUNDING_MODE1", "ROUNDING_MODE2" 
        .SEL_PATTERN("PATTERN"),          // Select pattern value ("PATTERN" or "C")
        .USE_PATTERN_DETECT("NO_PATDET"), // Enable pattern detect ("PATDET" or "NO_PATDET")
        // Register Control Attributes: Pipeline Register Configuration
        .ACASCREG(2),                     // Number of pipeline stages between A/ACIN and ACOUT (0, 1 or 2)
        .ADREG(1),                        // Number of pipeline stages for pre-adder (0 or 1)
        .ALUMODEREG(1),                   // Number of pipeline stages for ALUMODE (0 or 1)
        .AREG(2),                         // Number of pipeline stages for A (0, 1 or 2)
        .BCASCREG(1),                     // Number of pipeline stages between B/BCIN and BCOUT (0, 1 or 2)
        .BREG(2),                         // Number of pipeline stages for B (0, 1 or 2)
        .CARRYINREG(1),                   // Number of pipeline stages for CARRYIN (0 or 1)
        .CARRYINSELREG(1),                // Number of pipeline stages for CARRYINSEL (0 or 1)
        .CREG(1),                         // Number of pipeline stages for C (0 or 1)
        .DREG(1),                         // Number of pipeline stages for D (0 or 1)
        .INMODEREG(1),                    // Number of pipeline stages for INMODE (0 or 1)
        .MREG(1),                         // Number of multiplier pipeline stages (0 or 1)
        .OPMODEREG(1),                    // Number of pipeline stages for OPMODE (0 or 1)
        .PREG(1)                          // Number of pipeline stages for P (0 or 1)
    )
    SoItBegins (
        // Cascade: 30-bit (each) output: Cascade Ports
        .ACOUT(),                        // 30-bit output: A port cascade output
        .BCOUT(),                        // 18-bit output: B port cascade output
        .CARRYCASCOUT(),                 // 1-bit output: Cascade carry output
        .MULTSIGNOUT(),                  // 1-bit output: Multiplier sign cascade output
        .PCOUT(PCOUT1),                  // 48-bit output: Cascade output
        // Control: 1-bit (each) output: Control Inputs/Status Bits
        .OVERFLOW(),                     // 1-bit output: Overflow in add/acc output
        .PATTERNBDETECT(),               // 1-bit output: Pattern bar detect output
        .PATTERNDETECT(),                // 1-bit output: Pattern detect output
        .UNDERFLOW(),                    // 1-bit output: Underflow in add/acc output
        // Data: 4-bit (each) output: Data Ports
        .CARRYOUT(),                     // 4-bit output: Carry output
        .P(P1),                          // 48-bit output: Primary data output
        // Cascade: 30-bit (each) input: Cascade Ports
        .ACIN(30'h0),                    // 30-bit input: A cascade data input
        .BCIN(18'h0),                    // 18-bit input: B cascade input
        .CARRYCASCIN(1'b0),              // 1-bit input: Cascade carry input
        .MULTSIGNIN(1'b0),               // 1-bit input: Multiplier sign input
        .PCIN(48'h0),                    // 48-bit input: P cascade input
        //Btw this signal should theoretically be in DSAL1, however why don't
        //just delay it in SM? Thats what I thought too. It only saves ffs,
        //but hey, ill take it.
        .ALUMODE({ALUMODE[3:2], ALUMODE[1:0]} | {2{DSAL0_sub_mags}}),//Bc float isn't two's compliment
        .CARRYINSEL(3'b000),             // 3-bit input: Carry select input
        .CLK(clk),                       // 1-bit input: Clock input
        .INMODE(5'b00000),               // 5-bit input: INMODE control input
        .OPMODE(OPMODE),           // 7-bit input: Operation mode input
        //Its two's comlimetn so top bit gotta be 0
        .A({6'b0, a[23:0]}),                           // 30-bit input: A data input
        .B({1'b0, b[16:0]}),
        .C(C_alig3[47:0]), //we're gonna need it at the third DSP cycle
        .CARRYIN(1'b0),                  // 1-bit input: Carry input signal
        .D(25'h0),                       // 25-bit input: D data input
        // Reset/Clock Enable: 1-bit (each) input: Reset/Clock Enable Inputs
        .CEA1(1'b1),                     // 1-bit input: Clock enable input for 1st stage AREG
        .CEA2(1'b1),                     // 1-bit input: Clock enable input for 2nd stage AREG
        .CEAD(1'b1),                     // 1-bit input: Clock enable input for ADREG
        .CEALUMODE(1'b1),                // 1-bit input: Clock enable input for ALUMODE
        .CEB1(1'b1),                     // 1-bit input: Clock enable input for 1st stage BREG
        .CEB2(1'b1),                     // 1-bit input: Clock enable input for 2nd stage BREG
        .CEC(1'b1),                      // 1-bit input: Clock enable input for CREG
        .CECARRYIN(1'b1),                // 1-bit input: Clock enable input for CARRYINREG
        .CECTRL(1'b1),                   // 1-bit input: Clock enable input for OPMODEREG and CARRYINSELREG
        .CED(1'b1),                      // 1-bit input: Clock enable input for DREG
        .CEINMODE(1'b1),                 // 1-bit input: Clock enable input for INMODEREG
        .CEM(1'b1),                      // 1-bit input: Clock enable input for MREG
        .CEP(1'b1),                      // 1-bit input: Clock enable input for PREG
        .RSTA(1'b0),                     // 1-bit input: Reset input for AREG
        .RSTALLCARRYIN(1'b0),            // 1-bit input: Reset input for CARRYINREG
        .RSTALUMODE(1'b0),               // 1-bit input: Reset input for ALUMODEREG
        .RSTB(1'b0),                     // 1-bit input: Reset input for BREG
        .RSTC(1'b0),                     // 1-bit input: Reset input for CREG
        .RSTCTRL(1'b0),                  // 1-bit input: Reset input for OPMODEREG and CARRYINSELREG
        .RSTD(1'b0),                     // 1-bit input: Reset input for DREG and ADREG
        .RSTINMODE(1'b0),                // 1-bit input: Reset input for INMODEREG
        .RSTM(1'b0),                     // 1-bit input: Reset input for MREG
        .RSTP(1'b0)                      // 1-bit input: Reset input for PREG
    );
    /* verilator lint_on PINCONNECTEMPTY */

    //==DSAL0(Digital Signal Proccesing / Aligment)==//
    //The DSP is pipelined and will take total of 4cycles.
    //This is the second one. It also performs align stages 1+2
    logic [1:0] DSAL0_shexp_hmid;
    logic DSAL0_shexp_hi;
    logic [27:0] C_alig0;
    logic [39:0] C_alig1; // aligned C

    assign C_alig0 = {STRT_c[24:0], 3'h0} >> STRT_shexp_lo;
    always_ff @(posedge clk or negedge rst_n) begin : DSAL0
        if (!rst_n) begin
            DSAL0_shexp_hmid <= 2'h0;
            DSAL0_shexp_hi <= 1'h0;
            DSAL0_sub_mags <= 1'b0;
        end else begin
            DSAL0_shexp_hmid <= STRT_shexp_hmid;
            DSAL0_shexp_hi <= STRT_shexp_hi;
            DSAL0_sub_mags <= sub_mags;
        end
    end : DSAL0

    always_ff @(posedge clk) begin : DSAL0_C
        C_alig1 <= {C_alig0, 12'h0} >> {STRT_shexp_lmid, 2'h0};
    end : DSAL0_C


    //== DSAL1 (Digital Signal Proccesing / Aligment) ==//
    //Finishing alignment and starting second DSP
    assign C_alig2 = {C_alig1, 37'h0} >> {DSAL0_shexp_hmid, 4'h0};
    assign C_alig3 = C_alig2 >> {DSAL0_shexp_hi, 6'h0};

    //syntax drafts for flare
    //parallel [u32 i : arr.len<()>] {
    //  arr[i].rgbpck<(var0, var1)>;
    //}

endmodule
