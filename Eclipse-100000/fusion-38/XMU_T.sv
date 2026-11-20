module XMU_T(
    //XMU-T - Xtended Math Unit - Transcendentals
    //I was about to start with SAM, but realized that I want XMU first
    input logic clk,

    input logic [31:0] a, //yup just a
    input logic [3:0]  opcode,
    input logic [7:0]  sh_base,
    input logic [6:0]  slot_thr,
    input logic        slot_signed,

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

    logic  slot_op, arctan_op, direct_op;
    assign slot_op   = opcode == 4'b0111;
    assign arctan_op = opcode == 4'b0101;
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
    logic zero, arctan1, exp_V, neg, cos, massive, clamp_hi, clamp_lo;
    always_ff @(posedge clk) begin : DECO_DECO
        DECO_opcode <= opcode;
        DECO_sexp <= sexp;
        mant <= {1'b1, a[23:0]};
        sh_amt <= direct_op ? 6'd23 : (sh_diff[8] | |sh_diff[7:6]) ? 6'd63 : sh_diff[5:0]; //shift by exp(saturate)
        massive <= sh_diff[8]; //same thing as in GUCH - shifter can't shift left

        //various flags for later
        zero <= ~|a[30:24];
        neg <= a[31];
        arctan1 <= a[30:0] == 31'h40000000;

        //still remember something from logisim cpu or ig i had it at the first sv cpu
        //where branching was still done in two instructions, it was a long time ago
        exp_V <= a[30:24] >= 7'd70;
        clamp_hi <= slot_op & ~a[31] & slot_over;
        clamp_lo <= slot_op & a[31] & (slot_over | ~slot_signed);

        //nice encoding scheme, man do I love encoding stuff
        //arctan needs rcp first if a is more than 1 and then arctan
        prefix <= (arctan_op & a[30]) ? 3'b001 : opcode[2:0];
        cos <= opcode == 4'b1100;
    end : DECO_DECO

    logic  [7:0] DECO_flags;
    assign DECO_flags = {zero, arctan1, exp_V, neg, cos, massive, clamp_hi, clamp_lo};

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

    logic [6:0] ALIG0_sexp;
    logic [3:0] ALIG0_opcode;
    logic [2:0] ALIG0_prefix;
    logic [1:0] ALIG0_sh_hi;
    logic [7:0] ALIG0_flags;
    always_ff @(posedge clk) begin : ALIG0_CRRY
        //CRRY everything
        ALIG0_sh_hi <= sh_amt[5:4];
        ALIG0_sexp <= DECO_sexp;
        ALIG0_opcode <= DECO_opcode;
        ALIG0_prefix <= prefix;
        ALIG0_flags <= DECO_flags;
    end : ALIG0_CRRY

    //=> ALIG1(Align 1) <=//
    //88bits where low ones are useless(sticky)
    //top ones are useless too(too much int bits), and only 34 are useful.
    logic [88:0] mant_final;
    assign mant_final = {alig1_mant, 48'h0} >> {ALIG0_sh_hi, 4'b0000};
    logic [33:0] Q6_27;
    logic sticky; //here we go again
    always_ff @(posedge clk) begin
        Q6_27 <= mant_final[71:38];
        sticky <= |mant_final[37:0];
    end

    logic [6:0] ALIG1_sexp;
    logic [3:0] ALIG1_opcode;
    logic [2:0] ALIG1_prefix;
    logic [7:0] ALIG1_flags;
    always_ff @(posedge clk) begin : ALIG1_CRRY
        ALIG1_sexp <= ALIG0_sexp;
        ALIG1_opcode <= ALIG0_opcode;
        ALIG1_prefix <= ALIG0_prefix;
        ALIG1_flags <= ALIG0_flags;
    end : ALIG1_CRRY

endmodule
