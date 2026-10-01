module full_oserder (
    //Wrapper for OSERDES bc imma institate it 40 times.
    input logic clk333,
    input logic clkEMI,
    input logic rst_n,

    input logic [7:0] ds, //Ds all 8bits
    input logic       trie, //tri state enable 1 = z, 0 = EMI

    output logic oq, //Outputs of oser
    output logic tq //tri state output

);
    //OSERDES is something like parrallel serializer or something can't
    //recall the exact name its not important tho, its actaull very simple -
    //It takes 8 ds at clkDIV and just outputs them to oq in series every clk.
    //And thats it, no shenanigans or anything like that.
    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"),
        .DATA_RATE_TQ("SDR"),
        .DATA_WIDTH(8),
        .INIT_OQ(1'b0),
        .INIT_TQ(1'b0),
        .SERDES_MODE("MASTER"),
        .SRVAL_OQ(1'b0),
        .SRVAL_TQ(1'b0),
        .TBYTE_CTL("FALSE"),
        .TBYTE_SRC("FALSE"),
        .TRISTATE_WIDTH(1)
    )
    OSERDESE2_EMI (
        .OFB(),
        .OQ(oq), //Atm using it just to drive ck to be ~clk333
        .SHIFTOUT1(),
        .SHIFTOUT2(),
        .TBYTEOUT(),
        .TFB(),
        .TQ(tq),
        .CLK(clk333),
        .CLKDIV(clkEMI),
        .D1(ds[0]), //Just a clk pattern
        .D2(ds[1]),
        .D3(ds[2]),
        .D4(ds[3]),
        .D5(ds[4]),
        .D6(ds[5]),
        .D7(ds[6]),
        .D8(ds[7]),
        .OCE(1'b1),
        .RST(!rst_n),
        .SHIFTIN1(1'b0),
        .SHIFTIN2(1'b0),
        .T1(trie),
        .T2(1'b0),
        .T3(1'b0),
        .T4(1'b0),
        .TBYTEIN(1'b0),
        .TCE(1'b1)
    );

endmodule
