//Codegen, lets see what's it about
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RegType {
    B16,
    B16,
    B32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Register {
    pub id: u8,
    pub type: RegType,
    pub sub_index: u8,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsmOperand {
    Reg(Register),
    SP,
    Imm22(i32),
    Imm12(i16),
}

#[derive(Debug, Clone)]
pub enum AsmInst {
    Mov(AsmOperand, AsmOperand),
    Add(AsmOperand, AsmOperand),
    Sub(AsmOperand, AsmOperand),
    Mul(AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand),
    Or (AsmOperand, AsmOperand),
    And(AsmOperand, AsmOperand),
    Not(AsmOperand),
}








}
