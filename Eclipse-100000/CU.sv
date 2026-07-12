module CU(
    input logic clk,

    input logic [5:0] opcode,

    input logic [2:0] flags, //3 flags(Z, V, N) compacted into 3bit variable

    output logic XWrite, //Temp registers
    output logic YWrite,

    output logic IRWrite,
    output logic PCWrite,
    output logic GPRsWrite,

    output logic memRead,
    output logic memWrite,

);

    typedef enum logic [3:0] {
        FETCH,
        DECODE,
        ALU_EXE,
        BRANCH,
        MEM_CALC,
        LOAD,
        READ_DATA,
        STORE,
        WRITEBACK
    } fsm_states;

    fsm_states current_state, next_state;

    always comb begin
        
        next_state = FETCH;
        XWrite = 0; YWrite = 0;
        IRWrite = 0; PCWrite = 0; GPRsWrite = 0;
        memRead = 0; memWrite = 0;

        unique case (current_state) //allows for parralellization 
            FETCH: begin
                next_state = DECODE;
                IRWrite = 1;
                PCWrite = 1;
            end
            DECODE: begin
                unique case (opcode[5:4])
                    2'b00: next_state = ALU_EXE;
                    2'b11: next_state = BRANCH;
                    2'b10: next_state = MEM_CALC;
                    2'b01: next_state = LOAD; //Load instant from spare

                    default: next_state = ALU_EXE;
                endcase;
                XWrite = 1;
                YWrite = 1;
            end
            ALU_EXE: next_state = WRITEBACK;
            BRANCH: begin 
                next_state = FETCH;
                unique case (opcode)
                    6'b110000: PCWrite = (flags[0]) ? 0 : 1; //BEQ 
                    6'b110001: PCWrite = (flags[0]) ? 1 : 0; //BNE
                    6'b110011: PCWrite = (flags[1] ^ flags[2] == 1); //BS
                    6'b110111: PCWrite = (!(flags[1] ^ flags[2] || ! flags[0])) ? 1 : 0; //BG
                    6'b111111: PCWrite = 1;
                endcase;
            MEM_CALC: begin
                unique case(opcode)
                    6'b100111: next_state = STORE;
                    6'b100011: next_state = READ_DATA;

                    default: next_state = STORE; 
                endcase;
                XWrite = 1 //store result in X
            end 
            LOAD: begin
                next_state = FETCH;
                GPRsWrite = 1; //Load value into specified gpr
            end 
            READ_DATA: begin 
                next_state = WRITEBACK;
                memRead = 1;
            end 
            STORE: begin
                next_state = FETCH;
                memWrite = 1;
            end 
            WRITEBACK: begin 
                next_state = FETCH;
                GPRsWrite = 1;
            end
            default: next_state = FETCH;
        endcase
    end

endmodule

