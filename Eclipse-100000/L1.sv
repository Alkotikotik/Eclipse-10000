module L1 (
    //cache arbiter
    input logic clk,
    input logic rst,
    input logic advance,

    input logic [27:0] I_addr, //aka IF_PC_next
    output logic [63:0] I_data_out,

    input logic [27:0] Dread_addr,
    input logic [14:0] D_write_addr,
    input logic we,
    input logic re,

    input logic [31:0] D_data_in,
    input logic [1:0]  mem_size,

    output logic [31:0] D_data_out,
    output logic mem_rdy,

    //From TOP that holds EMI
    output logic EMI_req, EMI_req_we,
    output logic [23:0] EMI_req_addr,
    output logic [127:0] EMI_req_wd,
    output logic [15:0] EMI_req_msk,

    input logic EMI_req_awck, EMI_mem_done,
    input logic [127:0] EMI_rdata
);

    //FIFO of who made reqs, so we woudln't get lost
    logic [7:0] owner_queue;

    logic EMI_req, EMI_req_we, D_awck, I_awck;
    logic [127:0] EMI_rdata;
    logic [23:0] EMI_req_addr;

    assign EMI_req = I_req || Dreq; //don't really need it but its 1ff
    assign EMI_req_we = Dreq ? Dreq_we : 1'b0; //alright read on I
    assign EMI_req_addr = Dreq ? Dreq_addr : I_req_addr;

    assign D_awck = req_awck && Dreq;
    assign I_awck = req_awck && !Dreq;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            owner_queue = 8'h0;

        end
        if (EMI_req_awck && !EMI_req_we) begin //mem_done doesn't active on writes so quining only reads
            owner_queue <= {owner_queue[7:1], 1'b1}; // i just love this, 8 is max tho so its good
        end
        if (EMI_mem_done) begin
            owner_queue <= {1'b0, owner_queue[6:0]};
        end
    end

    L1_I instruction_cache (
        .clk(clk),
        .rst(rst),
        .advance(advance),

        .I_addr(I_addr),
        .I_data_out(I_data_out),

        .I_req(I_req),
        .I_req_addr(I_req_addr),
        .mem_rdy(mem_rdy),

        .EMI_rdata(EMI_rdata),
        .req_awck(req_awck),
        .mem_done(mem_done),
    );

    L1_D data_cache (
        .clk(),
        .rst(),
        .advance(),

        .Dread_addr(),
        .D_write_addr(),
        .we(),
        .re(),

        .D_data_in(),
        .mem_size(),

        .D_data_out(),
        .mem_rdy(),

        .Dreq(),
        .Dreq_we(),
        .Dreq_addr(),
        .Dreq_wd_data(EMI_req_wd),
        .Dreq_msk(EMI_req_msk),

        .EMI_rdata(EMI_rdata),
        .req_awck(),
        .mem_done()

    );

endmodule
