module XMU_T(
    //XMU-T - Xtended Math Unit - Transcendentals
    //I was about to start with SAM, but realized that I want XMU first
    input logic clk,

    input logic [31:0] a, //yup just a
    input logic [3:0]  opcode,
    input logic [7:0]  slot_base,
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

    logic  slot_op, arctan_op;
    assign slot_op   = opcode == 4'b0111;
    assign arctan_op = opcode == 4'b0101;

    //Imma just say it again: i had this idea of runtime programmable SFUs
    //long before starting GPU, and i finally get to implement it. Basically
    //you can just write any curve into 128 segment field in ROM and then use
    //it as a regular op. This also means range is programmable which creates
    //this mux right here.
    logic  [8:0] sh_diff;
    assign sh_diff = (slot_op ? {1'b0, slot_base} : 9'd23) - {{2{sexp[6]}}, sexp};

    //almost forgot about $signed
    logic  slot_over;
    assign slot_over = $signed(sh_diff) < $signed(9'd24 + {8'b0, slot_signed});

    logic [6:0] DECO_sexp;
    logic [5:0] sh_amt;
    logic [24:0] mant;
    logic [3:0] DECO_opcode;
    logic [2:0] prefix;
    logic zero, arctan_big1, arctan1, exp_V, neg, cos, massive, clamp_hi, clamp_lo;
    always_ff @(posedge clk) begin : DECO_DECO
        DECO_opcode <= opcode;
        DECO_sexp <= sexp;
        mant <= {1'b1, a[23:0]};
        sh_amt <= (sh_diff[8] | |sh_diff[7:6]) ? 6'd63 : sh_diff[5:0]; //shift by exp(saturate)
        massive <= sh_diff[8];

        //various flags for later
        zero <= ~|a[30:24];
        neg <= a[31];
        arctan_big1 <= a[30];
        arctan1 <= a[30:0] == 31'h40000000;

        //still remember something from logisim cpu or ig i had it at the first sv cpu
        //where branching was still done in two instructions, it was a long time ago
        exp_V <= a[30:24] >= 7'd70;
        clamp_hi <= slot_op & ~a[31] & slot_over;
        clamp_lo <= slot_op & a[31] & (slot_over | ~slot_signed);

        //nice encoding scheme, man do I love encoding stuff
        prefix <= (arctan_op & a[30]) ? 3'b001 : opcode[2:0];
        cos <= opcode == 4'b1100;
    end : DECO_DECO
endmodule
