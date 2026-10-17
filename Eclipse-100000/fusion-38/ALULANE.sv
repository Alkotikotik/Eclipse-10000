module ALULANE (
    //Well well finally starting the GPU im so excited for it.
    //So first one is ofc ALULANE its the basic GPU contruct.
    //The heart is efp32 FMA that is done through 2DSPs, it also has integer mode,
    //16bit fma, float to int conversion and min/max/abs.
    input logic clk,
    input logic rst_n,

    input logic [31:0] a, b, c;

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
    //Im planning to pipeline it like crazy, like 10-11 stages for alulane
    //which means i've got like 1-2 logic levels per stage

    //== STRT (start) ==//
    //Register operands, calc sh and start DSPs
    logic [32:0] STRT_a, STRT_b, STRT_c;
    logic [8:0]  sh_exp;
    always_ff @(posedge clk) begin : STRT_EFP
        //unbias by inverting top bit, and put back hidden bit.
        //No need for reset, otherwise DSP wouldn't accept them immediately
        STRT_a <= {a[31], ~a[30], a[29:24], |a[30:24], a[23:0]};
        STRT_b <= {b[31], ~b[30], b[29:24], |b[30:24], b[23:0]};
        STRT_c <= {c[31], ~c[30], c[29:24], |c[30:24], c[23:0]};
    end : STRT_EFP

    //So exp(a) + exp(b) is self explanatory - we are multiplying them, but
    //what about - exp(c)? Well we aren't actually computing an exponent we
    //are computing a shift, more on that later. Also, only lower bits rn
    assign sh_exp = {~a[30], a[29:24]} + {~b[30], b[29:24]} - {~c[30], c[29:24]};

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
            sh_exp <= 8'h0;
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

    DSP48E1 #(
        // Feature Control Attributes: Data Path Selection
        .A_INPUT("DIRECT"),               // Selects A input source, "DIRECT" (A port) or "CASCADE" (ACIN port)
        .B_INPUT("DIRECT"),               // Selects B input source, "DIRECT" (B port) or "CASCADE" (BCIN port)
        .USE_DPORT("FALSE"),              // Select D port usage (TRUE or FALSE)
        .USE_MULT("MULTIPLY"),            // Select multiplier usage ("MULTIPLY", "DYNAMIC", or "NONE")
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
        .ACOUT(ACOUT),                   // 30-bit output: A port cascade output
        .BCOUT(BCOUT),                   // 18-bit output: B port cascade output
        .CARRYCASCOUT(CARRYCASCOUT),     // 1-bit output: Cascade carry output
        .MULTSIGNOUT(MULTSIGNOUT),       // 1-bit output: Multiplier sign cascade output
        .PCOUT(PCOUT),                   // 48-bit output: Cascade output
        // Control: 1-bit (each) output: Control Inputs/Status Bits
        .OVERFLOW(OVERFLOW),             // 1-bit output: Overflow in add/acc output
        .PATTERNBDETECT(PATTERNBDETECT), // 1-bit output: Pattern bar detect output
        .PATTERNDETECT(PATTERNDETECT),   // 1-bit output: Pattern detect output
        .UNDERFLOW(UNDERFLOW),           // 1-bit output: Underflow in add/acc output
        // Data: 4-bit (each) output: Data Ports
        .CARRYOUT(CARRYOUT),             // 4-bit output: Carry output
        .P(P),                           // 48-bit output: Primary data output
        // Cascade: 30-bit (each) input: Cascade Ports
        .ACIN(ACIN),                     // 30-bit input: A cascade data input
        .BCIN(BCIN),                     // 18-bit input: B cascade input
        .CARRYCASCIN(CARRYCASCIN),       // 1-bit input: Cascade carry input
        .MULTSIGNIN(MULTSIGNIN),         // 1-bit input: Multiplier sign input
        .PCIN(PCIN),                     // 48-bit input: P cascade input
        // Control: 4-bit (each) input: Control Inputs/Status Bits
        .ALUMODE(ALUMODE),               // 4-bit input: ALU control input
        .CARRYINSEL(CARRYINSEL),         // 3-bit input: Carry select input
        .CLK(CLK),                       // 1-bit input: Clock input
        .INMODE(INMODE),                 // 5-bit input: INMODE control input
        .OPMODE(OPMODE),                 // 7-bit input: Operation mode input
        //Its two's comlimetn so top bit gotta be 0
        .A(1'b0, STRT_a[23:0]),                           // 30-bit input: A data input
        .B(1'b0, STRT_b[16:0]),                           // 18-bit input: B data input
        .C(C_alig3), //we're gonna need it at the third DSP cycle
        .CARRYIN(CARRYIN),               // 1-bit input: Carry input signal
        .D(D),                           // 25-bit input: D data input
        // Reset/Clock Enable: 1-bit (each) input: Reset/Clock Enable Inputs
        .CEA1(CEA1),                     // 1-bit input: Clock enable input for 1st stage AREG
        .CEA2(CEA2),                     // 1-bit input: Clock enable input for 2nd stage AREG
        .CEAD(CEAD),                     // 1-bit input: Clock enable input for ADREG
        .CEALUMODE(CEALUMODE),           // 1-bit input: Clock enable input for ALUMODE
        .CEB1(CEB1),                     // 1-bit input: Clock enable input for 1st stage BREG
        .CEB2(CEB2),                     // 1-bit input: Clock enable input for 2nd stage BREG
        .CEC(CEC),                       // 1-bit input: Clock enable input for CREG
        .CECARRYIN(CECARRYIN),           // 1-bit input: Clock enable input for CARRYINREG
        .CECTRL(CECTRL),                 // 1-bit input: Clock enable input for OPMODEREG and CARRYINSELREG
        .CED(CED),                       // 1-bit input: Clock enable input for DREG
        .CEINMODE(CEINMODE),             // 1-bit input: Clock enable input for INMODEREG
        .CEM(CEM),                       // 1-bit input: Clock enable input for MREG
        .CEP(CEP),                       // 1-bit input: Clock enable input for PREG
        .RSTA(RSTA),                     // 1-bit input: Reset input for AREG
        .RSTALLCARRYIN(RSTALLCARRYIN),   // 1-bit input: Reset input for CARRYINREG
        .RSTALUMODE(RSTALUMODE),         // 1-bit input: Reset input for ALUMODEREG
        .RSTB(RSTB),                     // 1-bit input: Reset input for BREG
        .RSTC(RSTC),                     // 1-bit input: Reset input for CREG
        .RSTCTRL(RSTCTRL),               // 1-bit input: Reset input for OPMODEREG and CARRYINSELREG
        .RSTD(RSTD),                     // 1-bit input: Reset input for DREG and ADREG
        .RSTINMODE(RSTINMODE),           // 1-bit input: Reset input for INMODEREG
        .RSTM(RSTM),                     // 1-bit input: Reset input for MREG
        .RSTP(RSTP)                      // 1-bit input: Reset input for PREG
    );

    //==DSAL0(Digital Signal Proccesing / Aligment)==//
    //The DSP is pipelined and will take total of 4cycles.
    //This is the second one. It also performs align stages 1+2
    logic [1:0] DSAL0_shexp_hmid;
    logic DSAL0_shexp_hi;
    logic [35:0] C_alig0;
    logic [47:0] C_alig1; // aligned C
    logic [31:0] DSAL0_c;
    always_ff @(posedge clk or negedge rst_n) begin : DSAL0
        if (!rst_n) begin
            DSAL0_shexp_hmid <= 2'h0;
            DSAL0_shexp_hi <= 1'h0;
            DSAL0_c <= 1'h0;
        end else begin
            DSAL0_shexp_hmid <= STRT_shexp_hmid;
            DSAL0_shexp_hi <= STRT_shexp_hi;
            DSAL0_c <= STRT_c;
        end
    end : DSAL0

    assign C_alig0 = {STRT_c[24:0], 4'h0} >> STRT_shexp_lo;
    assign C_alig1 = {16'h0, C_alig0} >> {STRT_shexp_lmid, 2'h0};

    //== DSAL1 (Digital Signal Proccesing / Aligment) ==//
    //Finishing alignment and starting second DSP
    logic [76:0] C_alig2, C_alig3;

    assign C_alig2 = {20'h0, C_alig1} >> {DSAL0_shexp_hmid, 4'h0};
    assign C_alig3 = C_alig2 >> {DSAL0_shexp_hi, 6'h0};







endmodule
