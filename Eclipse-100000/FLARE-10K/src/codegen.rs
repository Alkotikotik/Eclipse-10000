use crate::IR3AC::{IRInst}


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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Location {
    Register(PhysReg),
    StackOffset(usize),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BasicBlock {
    pub id: usize,
    pub label: Option<String>,
    pub body: Vec<IRInst>,
    pub predecessors: Vec<usize>,
    pub successors: Vec<usize>,
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

pub struct Codegen<'a> {
    ir_func: &'a IRFunction,
    cfg: Vec<BasicBlock>,
    allocations: HashMap<String, Location>,
    frame_size: usize,
    wait_for_the_final_result: Vec<TargetInst>,
}

impl<'a> Codegen<'a> {

    pub fn new(ir_func: &'a IRFunction) -> Self {
        let cfg = build_cfg(&ir_func.instructions);

        Self {
            ir_func,
            cfg,
            allocations: HashMap::new(),
            frame_size: 0,
            emitted_code: Vec::new(),
        }
    }

}

impl<'a> Codegen<'a> {

    pub fn build_bb(body: &IRInst) -> Vec<BasicBlock> { //basic blocks
        let mut leaders = std::collections::BTreeSet::new(); //Auto sort, plus uniqueness
        leaders.insert(0);

        for (idx, inst) in body.iter().enumerate() {
            match inst {
                IRInst::Label(_) => leaders.insert(idx),

                IRInst::JMP(_) | IRInst::Return(_) | IRInst::AntiEqual{..} | IRInst::Equal{..} | IRInst::AntiLess{..} | IRInst::AntiMore{..} => {
                    if idx + 1 = body.len() {
                        leaders.insert(idx + 1);
                    }
                }
                _ => {}

            }
        }
    }

}

