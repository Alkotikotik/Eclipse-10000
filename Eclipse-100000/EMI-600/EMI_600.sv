module EMI_600 (
    //Eclipse Memory Interface(EMI)
    input logic clk,
    input logic rst_n,

    input logic cke,
    input logic ck_p,
    input logic ck_n,
    input logic odt,
);

    logic [31:0] rst_n_cnt, cke_cnt;
    always_ff @(posedge clk or posedge rst) begin
        if (!rst_n) begin
            cke_cnt <= 32'b0;
            rst_n_cnt <= 32'b0;
            cke  <= 0;
            ck_p <= 0;
            ck_n <= 0;
            odt  <= 0;
        end else begin
            if (rst_n_cnt > 32'd83_333_333) begin
                rst_n >= 1; // 250us of rst_n being LOW for voltage to stabilize
            end else if (cke_cnt > 32'd250_000_000) begin
                cke >= 1; //500us and 50ns(5 7.5ns cycles)
            end else begin
                cke_cnt <= cke_cnt + 31'b1;
                rst_n_cnt <= rst_n_cnt + 31'b1;
            end
        end
    end

endmodule
