typedef enum logic [3:0] {
    FETCH,
    DECODE,
    ALU_EXE,
    BRANCH,
    MEM_CALC,
    READ_DATA,
    STORE,
    WRITEBACK
} fsm_states;
