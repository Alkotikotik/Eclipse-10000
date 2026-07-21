//3AC IR generator

#[derive(Debug, Clone, PartialEq)]
pub enum Insts {
    Add,
    Sub,
    Mul,
    Xor,
    Or,
    And,
    Not,
    Shl,
    Shr,
    Sra,
    Load,
    Ldr,
    Str,
    Beq,
    Bne,
    Bs,
    Bg,
    Jmp,
    Push,
    Pop,
}

#[derive(Debug, Clone, PartialEq)]
pub enum IROperand {
    Constant(i32),
    Variable(String),
    Temp(usize),
}

#[derive(Debug, Clone, PartialEq)]
pub enum IRInst {
    Add { dest: IROperand, left: IROperand, right: IROperand },
    Sub { dest: IROperand, left: IROperand, right: IROperand },
    Mul { dest: IROperand, left: IROperand, right: IROperand },
    Shl { dest: IROperand, left: IROperand, right: IROperand },
    Shr { dest: IROperand, left: IROperand, right: IROperand },
    Xor { dest: IROperand, left: IROperand, right: IROperand },
    Or  { dest: IROperand, left: IROperand, right: IROperand },
    And { dest: IROperand, left: IROperand, right: IROperand },
    Sra { dest: IROperand, left: IROperand, right: IROperand },

    Not { dest: IROperand, src: IROperand },
    Cpy { dest: IROperand, src: IROperand },

    LoadPtr  { dest: IROperand, ptr_addr: IROperand },
    StorePtr { ptr_addr: IROperand, src: IROperand },

    Label(String),
    Jump(String),
    JF { cond: IROperand, label: String },

    Call { dest: Option<IROperand>, name: String, args: Vec<IROperand> },
    Return(Option<IROperand>),
    InlineAsm(Vec<String>),
}

pub struct IR {
    instsBuffer: Vec<IRInst>,
    temp_counter: usize,
}

//Helpers
impl IR {
    pub fn new(){

    }
}

impl IR {
    fn 
}

















