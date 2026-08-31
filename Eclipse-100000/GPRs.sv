module GPRs (
    input logic clk,
    input logic reset,
    input logic reg_write,
    input logic [4:0] rr0,
    input logic [4:0] rr1,

    input logic [7:0]  rw0,
    input logic [31:0] data_in,

    input logic KernelModeWrite,

    output logic [31:0] data_out0,
    output logic [31:0] data_out1,

    //Just flip-flops
    output logic [31:0] KGPR0,
    output logic [31:0] KGPR1
);

    //Alright so I completely rewrote the GPRs file so it would go to the
    //LUTRAM of FPGA because its a massive LUT save bc there wouldn't be thing
    //horrible 32:1 mux
    (* ram_style = "distributed" *) logic [7:0] gpr0 [0:31];
    (* ram_style = "distributed" *) logic [7:0] gpr1 [0:31];
    (* ram_style = "distributed" *) logic [7:0] gpr2 [0:31];
    (* ram_style = "distributed" *) logic [7:0] gpr3 [0:31];

    logic [31:0] KGPRs [1:0]; //banked copies of rx0 and rx1

    //So this is init kinda like on reset, but only on init. This is because
    //LUTRAM doesn't accept any reset wires
    initial begin
        for (integer i = 0; i < 32; i = i + 1) begin
            gpr0[i] = 8'h0;
            gpr1[i] = 8'h0;
            gpr2[i] = 8'h0;
            gpr3[i] = 8'h0;
        end
    end

    logic  [4:0] base_id_w0;
    logic  [2:0] offset_w0;
    assign base_id_w0 = rw0[7:3];
    assign offset_w0  = rw0[2:0];

    logic [3:0]  lane_we;
    logic [31:0] write_mask;
    logic [31:0] shifted_data_in;

    //Pretty much the same thing as before
    always_comb begin
        unique case (offset_w0)
            3'b000: begin //rx
                lane_we         = 4'b1111;
                write_mask      = 32'hFFFFFFFF;
                shifted_data_in = data_in;
            end
            3'b001: begin // ry0
                lane_we         = 4'b0011;
                write_mask      = 32'h0000FFFF;
                shifted_data_in = {16'h0, data_in[15:0]};
            end
            3'b010: begin // ry1
                lane_we         = 4'b1100;
                write_mask      = 32'hFFFF0000;
                shifted_data_in = {data_in[15:0], 16'h0};
            end
            3'b011: begin // rz0
                lane_we         = 4'b0001;
                write_mask      = 32'h000000FF;
                shifted_data_in = {24'h0, data_in[7:0]};
            end
            3'b100: begin // rz1
                lane_we         = 4'b0010;
                write_mask      = 32'h0000FF00;
                shifted_data_in = {16'h0, data_in[7:0], 8'h0};
            end
            3'b101: begin // rz2
                lane_we         = 4'b0100;
                write_mask      = 32'h00FF0000;
                shifted_data_in = {8'h0, data_in[7:0], 16'h0};
            end
            3'b110: begin // rz3
                lane_we         = 4'b1000;
                write_mask      = 32'hFF000000;
                shifted_data_in = {data_in[7:0], 24'h0};
            end
            default: begin
                lane_we         = 4'b1111;
                write_mask      = 32'hFFFFFFFF;
                shifted_data_in = data_in;
            end
        endcase
    end

    logic  is_kgpr_w;
    logic  arr_we;
    assign is_kgpr_w = (base_id_w0 <= 5'd1) && KernelModeWrite;
    assign arr_we    = reg_write && !is_kgpr_w;

    always_ff @(posedge clk) begin
        if (arr_we && lane_we[0]) gpr0[base_id_w0] <= shifted_data_in[7:0];
        if (arr_we && lane_we[1]) gpr1[base_id_w0] <= shifted_data_in[15:8];
        if (arr_we && lane_we[2]) gpr2[base_id_w0] <= shifted_data_in[23:16];
        if (arr_we && lane_we[3]) gpr3[base_id_w0] <= shifted_data_in[31:24];
    end

    //Only two register krx0 and krx1 so 2:1 mux, which is fine
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            KGPRs[0] <= 32'b0;
            KGPRs[1] <= 32'b0;
        end
        else if (reg_write && is_kgpr_w) begin
            KGPRs[base_id_w0[0]] <= (KGPRs[base_id_w0[0]] & ~write_mask) | (shifted_data_in & write_mask);
        end
    end

    assign data_out0 = {gpr3[rr0], gpr2[rr0], gpr1[rr0], gpr0[rr0]};
    assign data_out1 = {gpr3[rr1], gpr2[rr1], gpr1[rr1], gpr0[rr1]};

    assign KGPR0 = KGPRs[0];
    assign KGPR1 = KGPRs[1];

endmodule
