module XMU_T(
    //XMU-T - Xtended Math Unit - Transcendentals
    //I was about to start with SAM, but realized that I want XMU first
    input logic clk,

    input logic [23:0] a_mant, //yup just a

    output logic [23:0] result
);
    //So I wrote a minimax script that generates .mem data that i will put
    //into my BRAM ROM and XMU_T is gonna read its transcendentals from it.

    //=> LKUP (Lookup) <=//
    //Initialize read fresh from the SAM.
    //2BRAM36s tiles per SAM, which is 2 read ports with no collision. Not
    //4BRAM18s because they can't provide 72bits of depth
    (* mem_style = "block" *) logic [1023:0] ROM [0:71];
    initial begin
        $readmemh("transcendentals.mem", ROM);
    end
    //top 7bits are address bits
    logic [71:0] minimax;
    logic [16:0] part;
    always_ff @(posedge clk) begin
        minimax <= ROM[a[24:17]];
        part <= {~a[16], a[15:0]};
    end

endmodule
