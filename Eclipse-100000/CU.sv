module CU(
    input logic clk,
    input logic reset,

    input logic [5:0] opcode,

    input logic [3:0] flags, //4 flags(C, N, V, Z) compacted into 4bit variable
    input logic [15:0] mmio_timer_reg,

    input logic current_kernel_mode,
    input logic memViolation,

    input logic [7:0] key_in,
    input logic isEX_valid,

    output logic PCWrite,
    output logic GPRsWrite,

    output logic EPCWrite,
    output logic isKernelMode,

    output logic memRead,
    output logic memWrite,

    output logic aluSrcX, //X, PC
    output logic [1:0] aluSrcY, //fetch: 4, alu_exe/branch = y, mem_calc = spare
    output logic [3:0] PCSrc, //pc+4, effective address
    output logic [2:0] GPRsSrc, //alu result, memory, spare

    output logic [1:0] aluOpSel,
    output logic isCallState,
    output logic flagsWrite,

    output logic SPRWrite,
    output logic [2:0] SPRSrc
);

    //== CU ==//
    //So since I got rid of FSM CU currentely acts as purely decoding circuit
    //It executes in the EX

    logic [15:0] counter;
    logic timer_interrupt_pending;

    logic C, N, V, Z;
    assign {C, N, V, Z} = flags;

    logic [7:0] prev_key_in;
    logic key_interrupt_pending;

    logic timer_interrupt_taken, key_interrupt_taken;

    //Just interrupt handling
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            counter <= 16'd10000;
            timer_interrupt_pending <= 0;
            prev_key_in <= 8'hFF;
            key_interrupt_pending <= 0;
        end else begin
            if (counter == 16'd0) begin
                counter <= mmio_timer_reg;
                timer_interrupt_pending <= 1;
            end else begin
                counter <= counter - 1;
            end

            if (timer_interrupt_taken)
                timer_interrupt_pending <= 0;

            prev_key_in <= key_in;
            if (key_interrupt_taken)
                key_interrupt_pending <= 0;
            if (key_in != 8'hFF && key_in != prev_key_in)
                key_interrupt_pending <= 1;
        end
    end

    always_comb begin
        GPRsWrite = 0;
        EPCWrite = 0; isKernelMode = current_kernel_mode;
        memRead = 0; memWrite = 0;
        aluSrcX = 0; aluSrcY = 2'b00;
        PCSrc = 4'b0000; GPRsSrc = 3'b000;
        aluOpSel = 2'b00;
        flagsWrite = 0;
        isCallState = 0;
        SPRWrite = 0; SPRSrc = 3'b000;
        PCWrite = 0;
        timer_interrupt_taken = 0;
        key_interrupt_taken = 0;

        unique case (opcode[5:4])
            2'b00: begin // ALU R/B-type default
                aluSrcY = 2'b01;
                aluOpSel = 2'b10;
                GPRsWrite = 1;
            end
            2'b11: begin // conditional branch default
                aluSrcX = 1;
                aluSrcY = 2'b10;
                aluOpSel = 2'b00;
                PCSrc = 4'b0000;
                unique case (opcode)
                    6'b110101: PCWrite = ((N == V) && !Z); // BGS
                    6'b110011: PCWrite = (C && !Z);       // BGU
                    6'b110110: PCWrite = (N != V);       // BSS
                    6'b110001: PCWrite = Z;             // BEQ
                    6'b111100: PCWrite = !Z;           // BNE
                    6'b110100: PCWrite = !C;          // BSU
                    6'b111001: PCWrite = (N == V);
                    6'b110010: PCWrite = C;
                    6'b111011: PCWrite = ((N != V) || Z);
                    6'b111010: PCWrite = (!C || Z);

                    default:   PCWrite = 0;         //Default(just need comment here)
                endcase
            end
            2'b01: begin // LOAD-imm / LMA
                if (opcode == 6'b010001 || opcode == 6'b011111) begin
                    GPRsWrite = 1;
                    GPRsSrc = (opcode == 6'b011111) ? 3'b100 : 3'b011; // LMA vs LOAD rx0,imm18
                end
            end
            2'b10: ;
            default: ;
        endcase

        //Basically stays the same
        unique case (opcode)
            6'b010010: begin //SYS
                EPCWrite = 1;
                isKernelMode = 1;
                PCSrc = 4'b0010;
                PCWrite = 1;
            end
            6'b111101: begin //RETU
                isKernelMode = 0;
                PCSrc = 4'b0011;
                PCWrite = 1;
            end
            6'b111000: begin //CALL
                aluSrcX = 1; aluSrcY = 2'b10; aluOpSel = 2'b00;
                PCSrc   = 4'b0001;
                PCWrite = 1;
                isCallState = 1;
            end
            6'b010000: begin //RET
                PCSrc   = 4'b0101;
                PCWrite = 1;
            end
            6'b110111: begin //JR
                PCSrc   = 4'b0111;
                PCWrite = 1;
            end
            6'b110000: begin // CMP
                aluSrcX = 0;
                aluSrcY = 2'b01; aluOpSel = 2'b10;
                flagsWrite = 1;
                GPRsWrite = 0;
            end
            6'b111111: begin //JMP
                aluSrcX = 1; aluSrcY = 2'b10; aluOpSel = 2'b00;
                PCSrc   = 4'b0001;
                PCWrite = 1;
            end
            6'b101010: begin // SPRSET
                SPRSrc = 3'b011;
                SPRWrite = 1;
            end
            6'b101011: begin // SPRADD
                SPRSrc = 3'b110;
                SPRWrite = 1;
            end
            6'b101100: begin // SPRSUB
                SPRSrc = 3'b111;
                SPRWrite = 1;
            end
            6'b100011: begin // LDR
                memRead = 1;
                GPRsSrc = 3'b001;
                GPRsWrite = 1;
            end
            6'b100111: begin // STR
                memWrite = 1;
            end
            6'b100100: begin // PUSH
                memWrite = 1;
                SPRSrc = 3'b100;
                SPRWrite = 1;
            end
            6'b100101: begin // POP
                memRead = 1;
                GPRsSrc = 3'b001;
                GPRsWrite = 1;
                SPRSrc = 3'b101;
                SPRWrite = 1;
            end
            6'b101000: begin // SPRLDR
                memRead = 1;
                GPRsSrc = 3'b001;
                GPRsWrite = 1;
            end
            6'b101001: begin // SPRSTR
                memWrite = 1;
            end
            6'b101101: begin // SPRLEA — computed value, no memory access
                GPRsSrc = 3'b101;
                GPRsWrite = 1;
            end
            default: ; //Should cover everything
        endcase

        //Interrupt override whatever was in the current EX now checking on
        //every cycle instead of only between states, also it is gated by
        //!PCWrite so in base of branch nothing would break
        if (isEX_valid && !isKernelMode && !PCWrite) begin
            if (timer_interrupt_pending) begin
                EPCWrite = 1; isKernelMode = 1; PCSrc = 4'b0100; PCWrite = 1;
                timer_interrupt_taken = 1;
            end else if (key_interrupt_pending) begin
                EPCWrite = 1; isKernelMode = 1; PCSrc = 4'b1000; PCWrite = 1;
                key_interrupt_taken = 1;
            end
        end


        if ((memRead || memWrite) && memViolation) begin
            EPCWrite = 1; isKernelMode = 1; PCSrc = 4'b0110; PCWrite = 1;
            GPRsWrite = 0; SPRWrite = 0;
        end

    end

    //== End of CU(god do I love that thing) ==//
endmodule
