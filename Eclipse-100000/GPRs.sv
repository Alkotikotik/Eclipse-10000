module GPRs (
    input logic clk,
    input logic reset,
    input logic reg_write,
    input logic [6:0] rr0,
    input logic [6:0] rr1,

    input logic [6:0]  rw0,
    input logic [31:0] data_in,

    output logic [31:0] data_out0,
    output logic [31:0] data_out1
);

    logic [31:0] GPRs [15:0]; //16 32bit registers

    logic [3:0] base_id0 = rr0[6:3];
    logic [2:0] offset0  = rr0[2:0];

    logic [3:0] base_id1 = rr1[6:3];
    logic [2:0] offset1  = rr1[2:0];

    logic [31:0] raw_val_r0;
    assign raw_val_r0 = GPRs[base_id0];

    always_comb begin
        unique case (offset0)
            3'b000: data_out0 = raw_val_r0; //rx

            3'b001: data_out0 = {16'h0000, raw_val_r0[15:0]};  //ry0
            3'b010: data_out0 = {16'h0000, raw_val_r0[31:16]}; //ry1

            3'b011: data_out0 = {24'h000000, raw_val_r0[7:0]};   //rz0
            3'b100: data_out0 = {24'h000000, raw_val_r0[15:8]};  //rz1
            3'b101: data_out0 = {24'h000000, raw_val_r0[23:16]}; //rz2
            3'b110: data_out0 = {24'h000000, raw_val_r0[31:24]}; //rz3

            default: data_out0 = raw_val_r0;
        endcase
    end

    logic [31:0] raw_val_r1;
    assign raw_val_r1 = GPRs[base_id1];

    always_comb begin
        unique case (offset1)
            3'b000: data_out1 = raw_val_r1;

            3'b001: data_out1 = {16'h0000, raw_val_r1[15:0]};
            3'b010: data_out1 = {16'h0000, raw_val_r1[31:16]};

            3'b011: data_out1 = {24'h000000, raw_val_r1[7:0]};
            3'b100: data_out1 = {24'h000000, raw_val_r1[15:8]};
            3'b101: data_out1 = {24'h000000, raw_val_r1[23:16]};
            3'b110: data_out1 = {24'h000000, raw_val_r1[31:24]};

            default: data_out1 = raw_val_r1;
        endcase
    end

    logic [3:0] base_id_w0 = rw0[6:3];
    logic [2:0] offset_w0  = rw0[2:0];

    logic [31:0] write_mask;
    logic [31:0] shifted_data_in;

    always_comb begin
        unique case (offset_w0)
            3'b000: begin //rx
                write_mask      = 32'hFFFFFFFF;
                shifted_data_in = data_in;
            end
            3'b001: begin // ry0
                write_mask      = 32'h0000FFFF;
                shifted_data_in = {16'h0, data_in[15:0]};
            end
            3'b010: begin // ry1
                write_mask      = 32'hFFFF0000;
                shifted_data_in = {data_in[15:0], 16'h0};
            end
            3'b011: begin // rz0
                write_mask      = 32'h000000FF;
                shifted_data_in = {24'h0, data_in[7:0]};
            end
            3'b100: begin // rz1
                write_mask      = 32'h0000FF00;
                shifted_data_in = {16'h0, data_in[7:0], 8'h0};
            end
            3'b101: begin // rz2
                write_mask      = 32'h00FF0000;
                shifted_data_in = {8'h0, data_in[7:0], 16'h0};
            end
            3'b110: begin // rz3
                write_mask      = 32'hFF000000;
                shifted_data_in = {data_in[7:0], 24'h0};
            end
            default: begin
                write_mask      = 32'hFFFFFFFF;
                shifted_data_in = data_in;
            end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (integer i = 0; i < 16; i = i + 1) begin
                GPRs[i] <= 32'b0;
            end
        end
        else if (reg_write) begin //Bit masking to write only to required registers
            GPRs[base_id_w0] <= (GPRs[base_id_w0] & ~write_mask) | (shifted_data_in & write_mask);
        end
    end

endmodule
