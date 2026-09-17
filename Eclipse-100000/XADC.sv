/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module XADC #(parameter [15:0] INIT_40 = 0, INIT_41 = 0, INIT_42 = 0) (
    //Unfortunately verilator doesn't accept XADC so I gotta hand write it
    input               DCLK, RESET, DEN, DWE,
    input        [6:0]  DADDR,
    input        [15:0] DI,
    output logic [15:0] DO,
    output logic        DRDY, EOS, EOC, BUSY, OT,
    output logic        JTAGBUSY, JTAGLOCKED, JTAGMODIFIED,
    output logic [4:0]  CHANNEL, MUXADDR,
    output logic [7:0]  ALM,
    input               VP, VN, CONVST, CONVSTCLK,
    input        [15:0] VAUXP, VAUXN
);

    logic [9:0] eos_cnt;

    always_ff @(posedge DCLK or posedge RESET) begin
        if (RESET) begin
            DO      <= 16'h0;
            DRDY    <= 1'b0;
            EOS     <= 1'b0;
            eos_cnt <= 10'd0;
        end else begin
            eos_cnt <= eos_cnt + 1;
            EOS     <= (eos_cnt == 10'd1023);
            DRDY    <= DEN;
            if (DEN) begin
                case (DADDR) //The numbers are fixed but that doesn't matter its just artificial seed
                    7'h01:   DO <= 16'b0101_1000_0010_0000; //1.0324795 V
                    7'h02:   DO <= 16'b0101_0110_0110_0000; //1.0123794 V
                    7'h06:   DO <= 16'b0100_1111_1110_0000;
                    default: DO <= 16'h0;
                endcase
            end
        end
    end

    assign EOC          = 1'b0;
    assign BUSY         = 1'b0;
    assign OT           = 1'b0;
    assign JTAGBUSY     = 1'b0;
    assign JTAGLOCKED   = 1'b0;
    assign JTAGMODIFIED = 1'b0;
    assign CHANNEL      = 5'd0;
    assign MUXADDR      = 5'd0;
    assign ALM          = 8'd0;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
