//Codegen, lets see what's it about
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RegType {
    B8,
    B16,
    B32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Register {
    pub id: u8,
    pub reg_type: RegType,
    pub sub_index: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Reg {
    Virtual(usize, RegType),
    TheRealOne(Register),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsmOperand {
    Reg(Reg),
    SP,
    Imm22(i32),
    Imm12(i16),
    Label(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AsmOperand {
    Reg(Register),
    SP,
    Imm22(i32),
    Imm12(i16),
    Label(String),
}

#[derive(Debug, Clone)]
pub enum AsmInst {
    Mov(AsmOperand, AsmOperand),
    Add(AsmOperand, AsmOperand, AsmOperand),
    Sub(AsmOperand, AsmOperand, AsmOperand),
    Mul(AsmOperand, AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand),
    Or (AsmOperand, AsmOperand),
    And(AsmOperand, AsmOperand),
    Not(AsmOperand),
    Shl(AsmOperand, AsmOperand),
    Shr(AsmOperand, AsmOperand),
    Sra(AsmOperand, AsmOperand),

    Load(AsmOperand, AsmOperand),
    Lma (AsmOperand, AsmOperand), //Up to 25bits loads into rx15
    Ldr (AsmOperand, AsmOperand), //Loads from memory
    Str (AsmOperand, AsmOperand),

    Cmp (AsmOperand, AsmOperand),
    Beq (Label),
    Bne (Label),
    Bgu (Label), //unsigned
    Bsu (Label),
    Bgs (Label), //signed
    Bss (Label),

    Jmp (Label),
    Jr  (AsmOperand),
    Call (Label),
    Ret,

}

