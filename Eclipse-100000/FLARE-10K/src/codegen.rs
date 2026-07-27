use crate::IR3AC::{IRInst, IRFunction};
use std::collections::HashMap;
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
    Register(Register),
    StackOffset(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
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
    Beq (String),
    Bne (String),
    Bgu (String), //unsigned
    Bsu (String),
    Bgs (String), //signed
    Bss (String),

    Jmp (String),
    Jr  (AsmOperand),
    Call(String),
    Ret,

}

pub struct Codegen<'a> {
    ir_func: &'a IRFunction,
    cfg: Vec<BasicBlock>,
    allocations: HashMap<String, Location>,
    frame_size: usize,
    wait_for_the_final_result: Vec<AsmInst>,
}

impl<'a> Codegen<'a> {

    pub fn new(ir_func: &'a IRFunction) -> Self {
        let mut codegen = Self {
            ir_func,
            cfg: Vec::new(),
            allocations: HashMap::new(),
            frame_size: 0,
            wait_for_the_final_result: Vec::new(),
        };

        codegen.build_cfg(&ir_func.instructions);
        codegen
    }

}

impl<'a> Codegen<'a> {

    //Building basics blocks of cfg, basic block is the largest code of block that doesn't contain branching
    //For example statements bodies without branching
    pub fn build_bbs(body: &[IRInst]) -> Vec<BasicBlock> { //basic blocks &[IRInst] is basically
        //reference to the vector of IRInst but we don't copy it we just know where it is
        let mut leaders = std::collections::BTreeSet::new(); //Vector with auto sort, plus uniqueness
        leaders.insert(0);

        for (idx, inst) in body.iter().enumerate() {
            match inst {
                IRInst::Label(_) => { leaders.insert(idx); }

                IRInst::JMP(_) | IRInst::Return(_) | IRInst::AntiEqual{..} | IRInst::Equal{..} | IRInst::AntiLess{..} | IRInst::AntiMore{..} => {
                    if idx + 1 < body.len() {
                        leaders.insert(idx + 1);
                    }
                }
                _ => {}

            }
        }

        let mut indices: Vec<usize> = leaders.into_iter().collect();
        indices.push(body.len());
        let mut blocks: Vec<BasicBlock> = Vec::new();

        for (id, window) in indices.windows(2).enumerate() { //Exactly what it sounds like we are
            //creating a window between 2 leaders
            let start = window[0];
            let end = window[1];

            let instructions = body[start..end].to_vec();

            let label = match instructions.first() {
                Some(IRInst::Label(lbl)) => Some(lbl.clone()),
                _ => None
            };

            blocks.push(BasicBlock{
                id,
                label,
                body: instructions,
                predecessors: Vec::new(),
                successors: Vec::new(),
            });

        }
        blocks
    }

    pub fn build_suc_prec(&mut self) {
        let mut label_to_block: HashMap<String, usize> = HashMap::new();

        //Building successors and predecessors, successors are the blocks that might come after one
        //of the blocks after branching or if falling through
        //predecessors are the blocks from which current block might have came through 
        //whether it is bracnhing or just falling through
        for block in &self.cfg {
            if let Some(ref label_name) = block.label {
                label_to_block.insert(label_name.clone(), block.id);
            }
        }

        let blocks_amount = self.cfg.len();

        for i in 0..blocks_amount {
            let last_inst = self.cfg[i].body.last();

            let mut raw_succ = Vec::new();

            if let Some(inst) = last_inst {
                match inst {
                    IRInst::JMP(target) => {
                        if let Some(&target_id) = label_to_block.get(target) {
                            raw_succ.push(target_id);
                        }
                    }
                    IRInst::AntiEqual{target, ..} | IRInst::Equal{target, ..} | IRInst::AntiLess{target, ..} | IRInst::AntiMore{target, ..} => {
                        if let Some(&target_id) = label_to_block.get(target) {
                            raw_succ.push(target_id);
                        }
                        if i + 1 < blocks_amount {
                            raw_succ.push(i + 1);
                        }
                    }
                    IRInst::Return(_) => {} // No successors
                    _ => {
                        if i + 1 < blocks_amount {
                            raw_succ.push(i + 1);
                        }
                    }
                }

            }
            self.cfg[i].successors = raw_succ;
        }

        let num_blocks = self.cfg.len();
        for src_id in 0..num_blocks { //predecessors are easy, if block B is successors of block A,
            //block A is predecessors of block B
            let succs = self.cfg[src_id].successors.clone();

            for dst_id in succs {
                self.cfg[dst_id].predecessors.push(src_id);
            }
        }
    }

    //Control Flow Grapth(CFG) don't confuse with Context Free Grammar(CFG too)
    //It is a graph representing the program where nodes are basic blocks and edges are ways of connecting basic
    //blocks usually branching or falling through
    fn build_cfg(&mut self, body: &[IRInst]) -> Vec<BasicBlock> {

        self.cfg = Self::build_bbs(body);
        self.build_suc_prec();
        self.cfg.clone()

    }
}
