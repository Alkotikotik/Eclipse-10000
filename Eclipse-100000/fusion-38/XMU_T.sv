module XMU_T(
    //XMU-T - Xtended Math Unit - Transcendentals
    //I was about to start with SAM, but realized that I want XMU first
    input logic clk,

    input logic [31:0] a, //yup just a
    input logic [3:0]  opcode,
    input logic [7:0]  sh_base,
    input logic [6:0]  slot_thr,
    input logic        slot_signed,
    input logic [7:0]  slot_oexp,

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
    logic zero, arctan1, exp_V, neg, cos, massive, clamp_hi, clamp_lo, negt;
    always_ff @(posedge clk) begin : DECO_DECO
        DECO_opcode <= opcode;
        DECO_sexp <= sexp;
        mant <= {rsq_sqrt_op ? a[24] : 1'b1, a[23:0]};
        sh_amt <= direct_op ? (rsq_sqrt_op ? 6'd24 : 6'd23) : (sh_diff[8] | |sh_diff[7:6]) ? 6'd63 : sh_diff[5:0]; //shift by exp(saturate)
        massive <= sh_diff[8]; //same thing as in GUCH - shifter can't shift left

        //various flags for later
        zero <= ~|a[30:24];
        neg <= a[31];
        negt <= a[31] & (opcode == 4'b0011 | opcode == 4'b0100 | opcode == 4'b1100 | opcode == 4'b1110 | (slot_op & slot_signed));
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
                oexp = 8'hFD;
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
    logic [10:0] ALIG0_flags;
    always_ff @(posedge clk) begin : ALIG0_CRRY
        //CRRY everything
        ALIG0_sh_hi <= sh_amt[5:4];
        ALIG0_oexp <= oexp;
        ALIG0_spec <= spec;
        ALIG0_prefix <= prefix;
        ALIG0_flags <= {negt & ~massive, cos, clamp_hi, clamp_lo, DECO_opcode[2:0] == 3'b100, DECO_opcode == 4'b0011,
                        DECO_opcode == 4'b0101 & prefix == 3'b001, DECO_opcode == 4'b0010, DECO_opcode == 4'b1110, oexp_sub, sgn};
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
    logic [10:0] ALIG1_flags;
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
        STCY_canddr <= (Q6_27 ^ {34{ALIG1_flags[10]}}) + {6'b0, ALIG1_flags[9], 26'b0, ALIG1_flags[10] & ~sticky};
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
    always_ff @(posedge clk) begin : ADDR_CRRY
        ADDR_oexp <= STCY_flags[5] ? {STCY_canddr[33], STCY_canddr[33:27]} : STCY_oexp;
        ADDR_spec <= STCY_spec;
        ADDR_flags <= {STCY_flags[4:1], STCY_flags[6] ? STCY_canddr[28] : STCY_flags[0]};
    end : ADDR_CRRY

endmodule
