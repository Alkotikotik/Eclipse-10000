use crate::IR3AC::{IRInst, IRFunction, IROperand};
use std::collections::HashMap;
use std::collections::HashSet;
//Codegen, lets see what's it about
//Technically when I use "alive" its incorrect because the right term for it is just "live"
//But I don't like how plain "live" sound so ill use "alive"

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
    pub uevar: HashSet<IROperand>,
    pub varkill: HashSet<IROperand>,
    pub live_in: HashSet<IROperand>, //Alive at the start of the block
    pub live_out: HashSet<IROperand>, //Alive at the end of the block
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterferenceGraph {
    pub everything: HashMap<IROperand, HashSet<IROperand>>,
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

impl IRInst {
    pub fn is_var(&self) -> bool {
        matches!(self, IROperand::Var(_) | IROperand::Temp(_))
    }
    //If the value is being read
    pub fn uses(&self) -> Vec<IROperand> {
        let mut ls = Vec::new();

        match self {
            IRInst::Add { left, right, .. } 
            | IRInst::Sub { left, right, .. }
            | IRInst::Mul { left, right, .. }
            | IRInst::Div { left, right, .. }
            | IRInst::Mod { left, right, .. }
            | IRInst::Shl { left, right, .. }
            | IRInst::Shr { left, right, .. }
            | IRInst::Xor { left, right, .. }
            | IRInst::Or  { left, right, .. }
            | IRInst::And { left, right, .. }
            | IRInst::AntiEqual { left, right, .. }
            | IRInst::Equal { left, right, .. }
            | IRInst::AntiMore { left, right, .. }
            | IRInst::AntiLess { left, right, .. } => {
                if left.is_var() { ls.push(left.clone()); }
                if right.is_var() { ls.push(right.clone()); }
            }

            IRInst::Not { src, .. }
            | IRInst::Negate { src, .. }
            | IRInst::Cpy { src, .. }
            | IRInst::Cast { src, .. }
            | IRInst::LoadPtr { ptr_addr: src, .. } => {
                if src.is_var() { ls.push(src.clone()); }
            }

            IRInst::StorePtr { ptr_addr, src } => {
                if ptr_addr.is_var() { ls.push(ptr_addr.clone()); }
                if src.is_var() { ls.push(src.clone()); }
            }

            IRInst::Call { args, .. } => {
                for arg in args {
                    if arg.is_var() { ls.push(arg.clone()); }
                }
            }

            IRInst::Return(Some(val)) => {
                if val.is_var() { ls.push(val.clone()); }
            }

            _ => {}
        }
        ls
    }


    //If a value is being rewritten(killed)
    pub fn kills(&self) -> Vec<IROperand> {
        let mut ls = Vec::new();
        match self {
            IRInst::Add { dest, .. }
            | IRInst::Sub { dest, .. }
            | IRInst::Mul { dest, .. }
            | IRInst::Div { dest, .. }
            | IRInst::Mod { dest, .. }
            | IRInst::Shl { dest, .. }
            | IRInst::Shr { dest, .. }
            | IRInst::Xor { dest, .. }
            | IRInst::Or  { dest, .. }
            | IRInst::And { dest, .. }
            | IRInst::Not { dest, .. }
            | IRInst::Negate { dest, .. }
            | IRInst::Cpy { dest, .. }
            | IRInst::Cast { dest, .. }
            | IRInst::LoadPtr { dest, .. } => {
                if dest.is_var() { ls.push(dest.clone()); }
            }

            IRInst::Call { dest: Some(dest), .. } => {
                if dest.is_var() { ls.push(dest.clone()); }
            }

            _ => {}
        }
        ls
    }
}

//Calculating variable's liveless variable is alive if it is read from in any of the successors
//If it isn't being read though, it is dead. If value is overwritten before its being read from its
//dead too
impl BasicBlock {
    pub fn compute_uevar_varkill(&mut self){
        //Upward Exposed Variable meaning it is read in current
        //block but not declared so it relies on predecessors to declare it
        let mut uevar = HashSet::new();
        //If the variable is overwritten in the current block
        let mut varkill = HashSet::new();

        for inst in &self.body {
            //If variable is read before it has been varkilled(or not varkilled at all) in the current block it goes into uever
            for var in inst.uses() {
                if !varkill.contains(&var) {
                    uevar.insert(var);
                }
            }
            //If variable is killed in that block we insert it into varkill
            for var in inst.kills() {
                varkill.insert(var);
            }
        }

        self.uevar = uevar;
        self.varkill = varkill;
    }
}

impl InterferenceGraph {
    pub fn new() -> Self {
        Self {everything: HashMap::new()}
    }

    pub fn add_node(&mut self, node: IROperand) {
        //or_default returns &mut to current value if the
        //key exists or just inserts it if it doesn't
        self.everything.entry(node).or_default();
    }

    pub fn add_edge(&mut self, first: IROperand, second: IROperand) {
        if first != second {
            //This addsd undirected edge meaning its a two way interference, if A interferes with B 
            //B automatically interference with A which makes sense
            self.everything.entry(first.clone()).or_default().insert(second.clone());
            self.everything.entry(second).or_default().insert(first);
        }
    }
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

    fn compute_liveness(&mut self) {
        for block in &mut self.cfg {
            block.compute_uevar_varkill();
        }
        let mut changed = true;

        //Looping while live_in/live_out are changing
        while changed {
            changed = false;
            //Looping in reverse because i don't feel like explaining
            for i in (0..self.cfg.len()).rev() {

                //Computing new live_out
                //LiveOut = Union of LiveIn[succ] for all succs
                let mut new_live_out = HashSet::new();
                for &succ_id in &self.cfg[i].successors {
                    new_live_out.extend(self.cfg[succ_id].live_in.clone());
                }

                //Computing new live_in 
                //LiveIn = UEVar[current] union (LiveOut[current] minus VarKill[current])
                let mut new_live_in = self.cfg[i].uevar.clone();.
                for var in &new_live_out {
                    if !self.cfg[i].varkill.contains(var) { //Minus VarKill
                        new_live_in.insert(var.clone()); //Union with LiveOut
                    }
                }

                //Check if new_live_out or new_live_in have changed if yes, continue if no, break
                if new_live_out != self.cfg[i].live_out || new_live_in != self.cfg[i].live_in {
                    self.cfg[i].live_out = new_live_out;
                    self.cfg[i].live_in = new_live_in;
                    changed = true;
                }
            }
        }
    }
    //InterferenceGraph where nodes are Var or Temp representing data that needs to be somewhere
    //during execution, so in registers or memory. And edges represent Interference meaning they
    //live at the same time and physically cannot share the same register and technically memory
    //location too, but it doesn't even matter
    pub fn build_iterf_graph(&mut self) -> InterferenceGraph {
        let mut graph = InterferenceGraph::new();

        for block in &self.cfg {
            let mut live = block.live_out.clone();

            for var in &live {
                graph.add_node(var.clone());
            }

            for inst in block.body.iter().rev() {
                for definition in inst.kills() {
                    graph.add_node(definition.clone())
                    for live_var in &live {
                        graph.add_edge(definition.clone(), live_var.clone());
                    }
                    live.remove(&definition)
                }

                for use_var in inst.uses() {
                    graph.add_node(use_var.clone());
                    live.insert(use_var);
                }
            }
        }
        graph
    }
}
