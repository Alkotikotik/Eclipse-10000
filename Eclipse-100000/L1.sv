module L1 (
    //Cache arbiter
    //I skipped pre-fetch and other such optimizations for now, simply because
    //my program aren't even close to being 48KB, so cache misses happen only
    //on init.
    input logic clk,
    input logic rst,
    input logic D_advance,

    input logic [27:0] I_addr, //aka IF_PC_next
    input logic [8:0]  I_even_idx,
    input logic I_skip,
    input logic I_discard,
    output logic [63:0] I_data_out,
    output logic I_mem_rdy,
    output logic I_miss_ff,

    input logic [27:0] Dread_addr,
    input logic [9:0]  Dread_even,
    input logic [14:0] D_write_addr,
    input logic we,
    input logic re,

    input logic [31:0] D_data_in,
    input logic [1:0]  mem_size,

    output logic [31:0] D_data_out,
    output logic D_mem_rdy,
    output logic D_miss_ff,

    //From TOP that holds EMI
    output logic EMI_req, EMI_req_we,
    output logic [23:0] EMI_req_addr,
    output logic [127:0] EMI_req_wd,
    output logic [15:0] EMI_req_msk,

    input logic EMI_req_awck, EMI_mem_done,
    input logic [127:0] EMI_rdata
);

    //FIFO of who made reqs, so we woudln't get lost, cool part is that ptrs
    //are 3bits thus just cycle on overflow, so it never overflows bc max
    //possibles reqs at ones is 8.
    logic [2:0] front_ptr, back_ptr;
    logic [7:0] owner_queue;
    logic D_grant, owner, D_awck, I_awck;
    logic I_req, Dreq, Dreq_we;
    logic [23:0] I_req_addr, Dreq_addr;

    assign EMI_req = I_req || Dreq; //don't really need it but its 1ff
    assign EMI_req_we = D_grant ? Dreq_we : 1'b0; //alright read on I
    assign EMI_req_addr = D_grant ? Dreq_addr : I_req_addr;

    assign D_awck = EMI_req_awck && D_grant;
    assign I_awck = EMI_req_awck && !D_grant;

    assign D_grant = Dreq && (owner || !I_req); //if last was D and Dreq, or if Dreq and not I_req

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            front_ptr <= 3'b000;
            back_ptr <= 3'b000;
            owner_queue <= 8'h0;
            owner <= 1'b0;
        end else begin
            if (EMI_req_awck && !EMI_req_we) begin //mem_done doesn't active on writes so quining only reads
                owner_queue[back_ptr] <= D_grant; //1 - D cache, 0 - I cache
                back_ptr <= back_ptr + 1;
            end
            if (EMI_mem_done) begin
                front_ptr <= front_ptr + 1;
            end
            owner <= D_grant;
        end
    end

    L1_I instruction_cache (
        .clk(clk),
        .rst(rst),

        .I_addr(I_addr),
        .I_even_idx(I_even_idx),
        .I_skip(I_skip),
        .I_discard(I_discard),
        .I_data_out(I_data_out),

        .I_req(I_req),
        .I_req_addr(I_req_addr),
        .mem_rdy(I_mem_rdy),
        .miss_ff(I_miss_ff),

        .EMI_rdata(EMI_rdata),
        .req_awck(I_awck),
        .mem_done(EMI_mem_done && !owner_queue[front_ptr])
    );

    L1_D data_cache (
        .clk(clk),
        .rst(rst),
        .advance(D_advance),

        .Dread_addr(Dread_addr),
        .Dread_even(Dread_even),
        .D_write_addr(D_write_addr),
        .we(we),
        .re(re),

        .D_data_in(D_data_in),
        .mem_size(mem_size),

        .D_data_out(D_data_out),
        .mem_rdy(D_mem_rdy),
        .miss_ff(D_miss_ff),

        .Dreq(Dreq),
        .Dreq_we(Dreq_we),
        .Dreq_addr(Dreq_addr),
        .Dreq_wd_data(EMI_req_wd),
        .Dreq_msk(EMI_req_msk),

        .EMI_rdata(EMI_rdata),
        .req_awck(D_awck),
        .mem_done(EMI_mem_done && owner_queue[front_ptr])

    );

endmodule
