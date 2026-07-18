module CU(
    input logic clk,
    input logic reset,

    input logic [5:0] opcode,

    input logic [2:0] flags, //3 flags(Z, V, N) compacted into 3bit variable
    input logic [15:0] mmio_timer_reg,

    input logic current_kernel_mode,
    input logic memViolation,

    output logic XWrite, //Temp registers
    output logic YWrite,

    output logic IRWrite,
    output logic PCWrite,
    output logic GPRsWrite,
    output logic EAWrite, //Effective address write (custom register)

    output logic EPCWrite,
    output logic isKernelMode,

    output logic memRead,
    output logic memWrite,

    output logic aluSrcX, //X, PC
    output logic [1:0] aluSrcY, //fetch: 4, alu_exe/branch = y, mem_calc = spare
    output logic [2:0] PCSrc, //pc+4, effective address
    output logic [1:0] GPRsSrc, //alu result, memory, spare
    
    output logic [1:0] aluOpSel

);

    typedef enum logic [3:0] {
        FETCH,
        DECODE,
        ALU_EXE,
        BRANCH,
        LOAD,
        READ_DATA,
        EXCEPTION,
        TIMER_INTERRUPT,
        MEM_FAULT,
        STORE
    } fsm_states;

    fsm_states current_state, next_state;

    logic [15:0] counter;
    logic timer_interrupt_pending;
    

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            current_state <= FETCH;
            counter <= 16'd10000;
            timer_interrupt_pending <= 0;
        end else begin
            current_state <= next_state;
            
            if (counter == 16'd0) begin
                counter <= mmio_timer_reg;
                timer_interrupt_pending <= 1;
            end else begin
                counter <= counter - 1;
            end

            if (current_state == TIMER_INTERRUPT)
                timer_interrupt_pending <= 1'b0;
        end
    end

    always_comb begin
        
        next_state = FETCH;
        XWrite = 0; YWrite = 0;
        IRWrite = 0; PCWrite = 0; GPRsWrite = 0; EAWrite = 0;
        EPCWrite = 0; isKernelMode = current_kernel_mode;
        memRead = 0; memWrite = 0;
        aluSrcX = 0; aluSrcY = 2'b00;
        PCSrc = 3'b000; GPRsSrc = 2'b00;
        aluOpSel = 2'b00;

        unique case (current_state) //allows for parralellization
            FETCH: begin
                next_state = DECODE;
                IRWrite = 1;
                PCWrite = 1;
                aluSrcX = 1;
                aluSrcY = 2'b00;
                PCSrc = 3'b001;
                aluOpSel = 2'b00;
                memRead = 1;
            end
            DECODE: begin
                aluSrcX = 1;
                aluSrcY = 2'b11;
                EAWrite = 1;
                aluOpSel = 2'b00;

                XWrite = 1;
                YWrite = 1;

                unique case (opcode[5:4])
                    2'b00: next_state = ALU_EXE;
                    2'b11: next_state = BRANCH;
                    2'b01: next_state = LOAD;
                    
                    2'b10: begin //Calculating effective address during decode bc otherwise ALU is just chilling
                        unique case(opcode)
                            6'b100111: next_state = STORE;
                            6'b100011: next_state = READ_DATA;
                            default:   next_state = STORE;
                        endcase
                    end
                    default: next_state = ALU_EXE;
                endcase
                if(opcode == 6'b111110) //SYS
                    next_state = EXCEPTION;
                if(opcode == 6'b111101) begin //RETU 
                    isKernelMode = 0;
                    PCSrc = 3'b011;
                    PCWrite = 1;
                    next_state = FETCH;
                end
            end
            ALU_EXE: begin
                next_state = FETCH;
                aluSrcY = 2'b01;
                GPRsSrc = 2'b00;
                aluSrcX = 0;
                aluOpSel = 2'b10;
                GPRsWrite = 1;
            end 
            BRANCH: begin 
                next_state = FETCH;
                PCSrc = 3'b000; 
                aluOpSel = 2'b01;
                unique case (opcode)
                    6'b110000: PCWrite = (flags[0] == 1); //BEQ 
                    6'b110001: PCWrite = (flags[0] == 0); //BNE
                    6'b110011: PCWrite = ((flags[1] ^ flags[2]) == 1); //BS
                    6'b110111: PCWrite = (!((flags[1] ^ flags[2]) || !flags[0])); //BG
                    6'b111111: PCWrite = 1;
                    default:   PCWrite = 0;
                endcase
                aluSrcY = 2'b01;
            end
            EXCEPTION: begin
                EPCWrite = 1;
                isKernelMode = 1;
                PCSrc = 3'b010;
                PCWrite = 1;
                next_state = FETCH;
            end
            TIMER_INTERRUPT: begin
                EPCWrite = 1;
                isKernelMode = 1;
                PCSrc = 3'b100;
                PCWrite = 1;
                next_state = FETCH;
            end
            MEM_FAULT: begin
                EPCWrite = 1;
                isKernelMode = 1;
                PCSrc = 3'b110;
                PCWrite = 1;
                next_state = FETCH;
            end
            LOAD: begin
                next_state = FETCH;
                GPRsWrite = 1; //Load value into specified gpr
                GPRsSrc = 2'b11;
            end 
            READ_DATA: begin 
                next_state = FETCH;
                memRead = 1;
                GPRsSrc = 2'b01; 
                GPRsWrite = 1;
            end
            STORE: begin
                next_state = FETCH;
                memWrite = 1;
            end 
            default: next_state = FETCH;
        endcase
    
        //Jump straight to exeption
        if (next_state == FETCH && timer_interrupt_pending && !current_kernel_mode && current_state != EXCEPTION)
            next_state = TIMER_INTERRUPT;
        if((current_state == LOAD || current_state == READ_DATA || current_state == STORE) && memViolation) begin
            next_state = MEM_FAULT;
        end
    end

endmodule
