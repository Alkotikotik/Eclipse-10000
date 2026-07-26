//Codegen, lets see what's it about

pub enum AsmOperand {
    rx0, rx1, rx2, rx3, rx4, rx5, rx6, rx7, rx8,
    rx9, rx10, rx11, rx12, rx13, rx14, rx15,

    ry00,  ry01,
    ry10,  ry11,
    ry20,  ry21,
    ry30,  ry31,
    ry40,  ry41,
    ry50,  ry51,
    ry60,  ry61,
    ry70,  ry71,
    ry80,  ry81,
    ry90,  ry91,
    ry100, ry101,
    ry110, ry111,
    ry120, ry121,
    ry130, ry131,
    ry140, ry141,
    ry150, ry151,

    rz00,  rz01,  rz02,  rz03,
    rz10,  rz11,  rz12,  rz13,
    rz20,  rz21,  rz22,  rz23,
    rz30,  rz31,  rz32,  rz33,
    rz40,  rz41,  rz42,  rz43,
    rz50,  rz51,  rz52,  rz53,
    rz60,  rz61,  rz62,  rz63,
    rz70,  rz71,  rz72,  rz73,
    rz80,  rz81,  rz82,  rz83,
    rz90,  rz91,  rz92,  rz93,
    rz100, rz101, rz102, rz103,
    rz110, rz111, rz112, rz113,
    rz120, rz121, rz122, rz123,
    rz130, rz131, rz132, rz133,
    rz140, rz141, rz142, rz143,
    rz150, rz151, rz152, rz153,

    SP,

    Imm22(i32),
    Imm12(i16),
    StackOffset(i16),
}

pub enum AsmInst {
    Mov(AsmOperand, AsmOperand),
    Add(AsmOperand, AsmOperand),
    Sub(AsmOperand, AsmOperand),
    Mul(AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand),
    Or (AsmOperand, AsmOperand),
    And(AsmOperand, AsmOperand),
    Not(AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand),








}
