module CU(
    input logic clk,
    input logic reset,

    input logic [5:0] opcode,

    input logic [2:0] flags, //3 flags(Z, V, N) compacted into 3bit variable

    output logic XWrite, //Temp registers
    output logic YWrite,

    output logic IRWrite,
    output logic PCWrite,
    output logic GPRsWrite,
    output logic EAWrite, //Effective address write (custom register)

    output logic memRead,
    output logic memWrite,

    output logic aluSrcX, //X, PC
    output logic [1:0] aluSrcY, //fetch: 4, alu_exe/branch = y, mem_calc = spare
    output logic PCSrc, //pc+4, effective address
    output logic [1:0] GPRsSrc //alu result, memory, spare

);

    typedef enum logic [3:0] {
        FETCH,
        DECODE,
        ALU_EXE,
        BRANCH,
        LOAD,
        READ_DATA,
        STORE,
        WRITEBACK
    } fsm_states;

    fsm_states current_state, next_state;
    

    //Update state if not reset
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) 
            current_state <= FETCH;
        else 
            current_state <= next_state;
    end

    always_comb begin
        
        next_state = FETCH;
        XWrite = 0; YWrite = 0;
        IRWrite = 0; PCWrite = 0; GPRsWrite = 0; EAWrite = 0;
        memRead = 0; memWrite = 0;
        aluSrcX = 0; aluSrcY = 2'b00;
        PCSrc = 0; GPRsSrc = 2'b00;

        unique case (current_state) //allows for parralellization 
            FETCH: begin
                next_state = DECODE;
                IRWrite = 1;
                PCWrite = 1;
                aluSrcX = 1;
                aluSrcY = 2'b00;
                PCSrc = 1;
            end
            DECODE: begin
                aluSrcX = 1;
                aluSrcY = 2'b11;
                EAWrite = 1;

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
            end
            ALU_EXE: begin
                next_state = WRITEBACK;
                aluSrcY = 2'b01;
                GPRsSrc = 2'b00;
                aluSrcX = 0;

            end 
            BRANCH: begin 
                next_state = FETCH;
                PCSrc = 0; 
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
            LOAD: begin
                next_state = FETCH;
                GPRsWrite = 1; //Load value into specified gpr
                GPRsSrc = 2'b11;
            end 
            READ_DATA: begin 
                next_state = WRITEBACK;
                memRead = 1;
                GPRsSrc = 2'b01; 
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
