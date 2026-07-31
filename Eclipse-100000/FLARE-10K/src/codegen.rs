//Codegen, lets see what's it about
//Technically when I use "alive" its incorrect because the right term for it is just "live"
//But I don't like how plain "live" sound so ill use "alive"

use crate::IR3AC::{IRInst, IRFunction, IROperand};
use crate::parser::{Type}
use std::collections::HashMap;
use std::collections::HashSet;

pub const REGS_BYTES: usize = 120; //rx31, rx30 is scratchpad/0

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

pub struct RegisterTracker {
    //31 registers made up of 4 bytes, bool indicates whether bytes are used or not
    slots: [[bool; 4]; 30],
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
    pub loop_depth: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterferenceGraph {
    pub adjacent: HashMap<IROperand, HashSet<IROperand>>,
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
    Imm26(i32),
    Imm18(i32)
    Imm10(i16),
    Label(String),
}

#[derive(Debug, Clone)]
pub enum AsmInst {
    Mov(AsmOperand, AsmOperand, AsmOperand),
    Add(AsmOperand, AsmOperand, AsmOperand), // 3 regisers
    Sub(AsmOperand, AsmOperand, AsmOperand),
    Mul(AsmOperand, AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand, AsmOperand), //2 register plus unsiged 10bit
    Or (AsmOperand, AsmOperand, AsmOperand),
    And(AsmOperand, AsmOperand, AsmOperand),
    Not(AsmOperand),
    Shl(AsmOperand, AsmOperand, AsmOperand),
    Shr(AsmOperand, AsmOperand, AsmOperand),
    Sra(AsmOperand, AsmOperand, AsmOperand),

    Load(AsmOperand, AsmOperand),
    Lma (AsmOperand, AsmOperand), //Up to 25bits loads into rx15
    Ldr(AsmOperand, AsmOperand, AsmOperand), // dest, base, offset
    Str(AsmOperand, AsmOperand, AsmOperand), // src, base, offset

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
    Inline(String),
    Label(String),
    Ret,

}

impl RegisterTracker {
    pub fn mark(&mut self, reg_id: u8, reg_type: RegType, sub_idx: u8) {
        let num_bytes = reg_type.get_size();
        let start = sub_idx as usize;
        let regidasusize = reg_id as usize;

        for i in start..(start + num_bytes) {
            self.slots[regidasusize][i] = true;
        }
    }

    pub fn find_free(&mut self, operand_type: Regtype) -> Opton<(u8, u8)> {
        for reg_id in 0..31 {
            match reg_type {
                Regtype::B8 => {
                    for sub_idx in 0..4 {
                        if !self.slots[reg_id][sub_idx] {
                            return Some((reg_id as u8, sub_idx as u8));
                        }
                    }
                }
                RegType::B16 => {
                    if !self.slots[reg_id][0] && !self.slots[reg_id][1] {
                        return Some((reg_id as u8, 0));
                    }
                    if !self.slots[reg_id][2] && !self.slots[reg_id][3] {
                        return Some((reg_id as u8, 2));
                    }
                }
                RegType::B32 => {
                    if self.slots[reg_id].iter().all(|&occupied| !occupied) {
                        return Some((reg_id as u8, 0));
                    }
                }
            }
        }
        None //You are cooked buddy, no avaliable slots
    }
}

impl RegType {
    pub fn get_size(&self) -> usize {
        match self {
            RegType::B8 => 1,
            RegType::B16 => 2,
            RegType::B32 => 4,
        }
    }
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
        Self {adjacent: HashMap::new()}
    }

    pub fn add_node(&mut self, node: IROperand) {
        //or_default returns &mut to current value if the
        //key exists or just inserts it if it doesn't
        self.adjacent.entry(node).or_default();
    }

    pub fn add_edge(&mut self, first: IROperand, second: IROperand) {
        if first != second {
            //This addsd undirected edge meaning its a two way interference, if A interferes with B 
            //B automatically interference with A which makes sense
            self.adjacent.entry(first.clone()).or_default().insert(second.clone());
            self.adjacent.entry(second).or_default().insert(first);
        }
    }
    //Weighted Degree is sum of neighbor's sizes in bytes
    pub fn get_weighted_degree(&self, node: &IROperand, active_nodes: &HashSet<IROperand>) -> usize {
        self.adjacent
            .get(node)
            .map(|neighbors| {
                neighbors
                    .iter()
                    .filter(|n| active_nodes.contains(n))
                    .map(|n| n.get_type().get_size())
                    .sum()
            })
            .unwrap_or(0)
    }
}

pub struct Codegen<'a> {
    ir_func: &'a IRFunction,
    cfg: Vec<BasicBlock>,
    allocations: HashMap<IROperand, Location>,
    frame_size: usize,
    slots: RegisterTracker,
    pins: HashMap<String, Register>,
    wait_for_the_final_result: Vec<AsmInst>,
}

impl<'a> Codegen<'a> {

    pub fn new(ir_func: &'a IRFunction) -> Self {
        let pins = Self::collect_pins(&ir_func.instructions);

        let mut codegen = Self {
            ir_func,
            cfg: Vec::new(),
            allocations: HashMap::new(),
            frame_size: 0,
            slots: RegisterTracker::new(),
            pins,
            wait_for_the_final_result: Vec::new(),
        };

        codegen.build_cfg(&ir_func.instructions);
        codegen
    }

    pub fn parse_pin_register(pin_str: &str) -> Register {
        let upper = pin_str.to_uppercase();

        let prefix = if upper.starts_with("RZ") { "RZ" }
            else if upper.starts_with("RY") { "RY" }
            else if upper.starts_with("RX") { "RX" }
            else if upper.starts_with('R')  { "R"  }
            else { panic!("Codegen Error: invalid pin register {}", pin_str) };

        let rest = &upper[prefix.len()..];
        let num: u32 = rest.parse().unwrap_or_else(|_| {
            panic!("Codegen Error: invalid pin register {}", pin_str)
        });

        match prefix {
            "RZ" => {
                let reg_id = (num / 10) as u8;
                let byte_sel = (num % 10) as u8;
                Register { id: reg_id, reg_type: RegType::B8, sub_index: byte_sel }
            }
            "RY" => {
                let reg_id = (num / 10) as u8;
                let half_sel = (num % 10) as u8;
                Register { id: reg_id, reg_type: RegType::B16, sub_index: half_sel * 2 }
            }
            _ => {
                let reg_id = num as u8;
                Register { id: reg_id, reg_type: RegType::B32, sub_index: 0 }
            }
        }
    }

}

impl<'a> Codegen<'a> {

    //Pins before cfg
    fn collect_pins(body: &[IRInst]) -> HashMap<String, Register> {
        let mut pins = HashMap::new();
        for inst in body {
            if let IRInst::Pin {var, register} = inst {
                pins.insert(var.clone(), parse_pin_register(register));
            }
        }
        pins
    }

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

            blocks.push(BasicBlock {
                id,
                label,
                body: instructions,
                predecessors: Vec::new(),
                successors: Vec::new(),
                uevar: HashSet::new(),
                varkill: HashSet::new(),
                live_in: HashSet::new(),
                live_out: HashSet::new(),
                loop_depth: 0,
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

    //Control Flow Graph(CFG) don't confuse with Context Free Grammar(CFG too)
    //It is a graph representing the program where nodes are basic blocks and edges are ways of connecting basic
    //blocks usually branching or falling through
    fn build_cfg(&mut self, body: &[IRInst]) -> Vec<BasicBlock> {
        self.cfg = Self::build_bbs(body);
        self.build_suc_prec();

        let depths = compute_loop_depths(&self.cfg);
        for block in &mut self.cfg {
            block.loop_depth = *depths.get(&block.id).unwrap_or(&0);
        }

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
                let mut new_live_in = self.cfg[i].uevar.clone();
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

    //This is Chaitin-Briggs Register Allocation algorithm I really like, problem is NP-Complete btw, so
    //I first constructed interference graph, now its time to color it, where each color represents
    //one physcial register and also isn't actually a color but just a number.
    //First step is coloring, each node(variable) has a degree and if degree is less than number of physical
    //registers then node will get into physical register no matter what, it is just common sense.
    //So we first find such as nodes and remove it from the graph by setting its degree to -1, thus
    //decreasing degree of every neighbor by 1 and then pushing it on the allocation stack.
    //However the problem arises: what if we are left with only registers who's degree is more than
    //number of physcial registers, well then we just remove any node from the graph and pushing it
    //on the stack. And later if there are no avaliable register in the time of that variable it
    //will be spilled, however if there is we will just put it in the register.
    pub fn color(&mut self, graph: InterferenceGraph) -> Vec<IROperand> {

        let mut active_nodes: HashSet<IROperand> = graph.adjacent.keys()
            .filter(|a| !self.allocations.contains_key(a))
            .cloned()
            .collect();
        let mut alloc_stack: Vec<IROperand> = Vec::new();

        while !active_nodes.is_empty() {
            let candidate = active_nodes //find node where Weighted degree is less than REGS_BYTES
                .iter()
                .find(|node| {
                    let neighbor_bytes = graph.get_weighted_degree(node, &active_nodes);
                    let node_bytes = node.get_type().get_size();

                    neighbor_bytes + node_bytes <= REGS_BYTES
                })
                .cloned();

            let chosen_node = match candidate {
                Some(node) => node,
                //Now if there isn't node with degree < REGS_BYTES we remove the node the node that
                //minimizes SpillCost/Degree it will be our optimistic candidate, and because we are
                //using spill cost which is 10^depth chances of optimistic candidate of getting
                //allocated are pretty high, but not 100%
                None => {
                    active_nodes
                        .iter()
                        .min_by(|a, b| {
                            let degree_a = graph.get_weighted_degree(a, &active_nodes) as f64;
                            let degree_b = graph.get_weighted_degree(b, &active_nodes) as f64;

                            let cost_a = spill_costs.get(a).unwrap_or(&1.0) / degree_a;
                            let cost_b = spill_costs.get(b).unwrap_or(&1.0) / degree_b;

                            cost_a.partial_cmp(&cost_b).unwrap_or(std::cmp::Ordering::Equal)
                        })
                        .cloned()
                        .unwrap()
                }
            };

            active_nodes.remove(&chosen_node);
            alloc_stack.push(chosen_node);
        }

        alloc_stack
    }

    //Actually allocate the registers, first check which registers are used up by neighbors and then
    //just put variable into first fitting register. If every register is used-up though, meaning
    //optimistic cadidate failed(RIP), spill it
    pub fn allocate(&mut self, mut alloc_stack: Vec<IROperand>, graph: &InterferenceGraph) {
        while let Some(operand) = alloc_stack.pop() {
            let mut tracker = RegisterTracker::new();

            if let Some(neighbors) = graph.adjacent.get(&operand) {
                for neighbor in neighbors {
                    if let Some(Location::Register(reg)) = self.allocations.get(neighbor) {
                        tracker.mark(reg.id, reg.reg_type, reg.sub_index);
                    }
                }

            }
            let operand_type = operand.get_type();
            if let Some((phys_reg_id, sub_index)) = tracker.find_free(operand_type) {
                let assigned_reg = Register{
                    id: phys_reg_id,
                    reg_type: operand_type,
                    sub_index,
                };
                self.allocations.insert(operand, Location::Register(assigned_reg));
            } else { //Spill
                let offset = self.frame_size;
                self.frame_size += operand_type.get_size();
                self.allocations.insert(operand, Location::StackOffset(offset));
            }
        }
    }

    //Final allocator step, it loops until all operations with spilled are modified
    //Since in 0.1% cases there might be not enough registers for spilled values
    pub fn run_allocator(&mut self) {
        let mut passes = 0;
        loop {
            self.compute_liveness();
            let graph = self.build_iterf_graph();

            self.seed_pins(&graph);

            let alloc_stack = self.color(graph.clone());
            self.allocate(alloc_stack, &graph);

            //Check for spilled
            let spilled: Vec<IROperand> = self.allocations.iter()
                .filter(|(_, loc)| matches!(loc, Location::StackOffset(_)))
                .map(|(op, _)| op.clone())
                .collect();

            if spilled.is_empty() { break; } //No spilled? Nice - break

            self.rewrite_spills(&spilled);
            self.allocations.clear();

            passes += 1;
            if passes > 10 {
                panic!("Codegen Error: More than 10 passes occured, there must be something wrong, can't help though");
            }
        }
    }

    //Check for pin conflicts
    fn seed_pins(&mut self, graph: &InterferenceGraph) {
        for (var_name, reg) in &self.pins {
            self.allocations.insert(IROperand::Var(var_name.clone()), Location::Register(*reg));
        }

        for (var_name, reg) in &self.pins {
            let node = IROperand::Var(var_name.clone());
            if let Some(neighbors) = graph.adjacent.get(&node) {
                for neighbor in neighbors {
                    if self.allocations.get(neighbor) == Some(&Location::Register(*reg)) {
                        panic!(
                            "Codegen Error: pinned variable {} conflicts with another live pinned variable in register {:?}",
                            var_name, reg
                        );
                    }
                }
            }
        }
    }

    //Basic block A dominates basic block B if every path to block B must pass through A, it doesn't
    //have to be predecessors though
    pub fn compute_dominators(cfg: &[BasicBlock]) -> HashMap<usize, HashSet<usize>> {
        let all_blocks: HashSet<usize> = cfg.iter().map(|b| b.id).collect();
        let mut doms: HashMap<usize, HashSet<usize>> = HashMap::new();
        //Basic block 0 dominates only itself
        doms.insert(0, HashSet::from([0]));

        for block in cfg.iter().skip(1) {
            doms.insert(block.id, all_blocks.clone());
        }

        let mut changed = true;
        while changed {
            changed = false;

            for block in cfg.iter().skip(1) {
                let mut new_dom = all_blocks.clone();

                for &pred in &block.predecessors {
                    if let Some(pred_dom) = doms.get(&pred) {
                        new_dom = new_dom.intersection(pred_dom).cloned().collect();
                    }
                }
                new_dom.insert(block.id);
                if doms.get(&block.id) != Some(&new_dom) {
                    doms.insert(block.id, new_dom);
                    changed = true;
                }
            }
        }
        doms
    }
    //Natural loop is a sequence of blocks that all have the same dominating block(header) so
    //usually loop declaration like while[true]
    pub fn find_loops( cfg: &[BasicBlock], doms: &HashMap<usize, HashSet<usize>>) -> Vec<HashSet<usize>> {
        let mut loops = Vec::new();

        //Looking for back edges which is edge between A and B where A dominates B
        //When such an edge is found, the natural loop consists of all nodes that can reach B
        //without passing through A
        for block in cfg {
            for &succ in &block.successors {
                if let Some(succ_doms) = doms.get(&block.id) {
                    if succ_doms.contains(&succ) {
                        let loop_nodes = populate_loop_body(cfg, succ, block.id);
                        loops.push(loop_nodes);
                    }
                }
            }
        }

        loops
    }

    //Move backwards from the end of the loop to the top and gather all the nodes that are in the loop
    //Latch is end of the loop
    fn populate_loop_body(cfg: &[BasicBlock], header: usize, latch: usize) -> HashSet<usize> {
        let mut loop_nodes = HashSet::from([header, latch]);
        let mut stack = vec![latch];

        while let Some(node) = stack.pop() {
            if node == header { continue; }

            if let Some(block) = cfg.iter().find(|b| b.id == node) {
                for &pred in &block.predecessors {
                    if loop_nodes.insert(pred) {
                        stack.push(pred);
                    }
                }
            }
        }

        loop_nodes
    }

    //Loop depth is the amount of natural loops that contains this nod
    //For example depth of simple loop is 1 because only 1 loop contains that node,
    //however in double nested loop depth is 2 becuause 2 loops contain that node
    pub fn compute_loop_depths(cfg: &[BasicBlock]) -> HashMap<usize, usize> {
        let doms = compute_dominators(cfg);
        let loops = find_loops(cfg, &doms);

        let mut depths: HashMap<usize, usize> = HashMap::new();

        for block in cfg {
            let depth = loops.iter().filter(|l| l.contains(&block.id)).count();
            depths.insert(block.id, depth);
        }

        depths
    }

    //Final spill cost computation, it is amount of usage * 10^depth
    pub fn compute_spill_costs(&self) -> HashMap<IROperand, f64> {
        let mut costs = HashMap::new();
        for block in &self.cfg {
            let weight = 10.0_f64.powi(block.loop_depth as i32);
            for inst in &block.body {
                for var in inst.uses().into_iter().chain(inst.kills().into_iter()) {
                    *costs.entry(var).or_insert(0.0) += weight;
                }
            }
        }
        costs
    }

    //Basically if there isn't enough registers, variable is spilled to the stack, and that changes
    //the IR because we need to add LDR, STR between operation
    //And we recompute coloring for them because its a new set of registers
    //It only changes individual blocks though, doesn't change successors, predecessors etc
    fn rewrite_spills(&mut self, spilled: &HashSet<IROperand>) {
        for block in &mut self.cfg {
            let mut new_body = Vec::new();

            for inst in &block.body {
                let mut inst = inst.clone();

                for used in inst.uses() {
                    if let Some(off) = self.spill_offset(&used, spilled) {
                        let val = self.new_scratch();
                        new_body.push(IRInst::LoadPtr { dest: val.clone(), ptr_addr: IROperand::FrameSlot(off) });
                        inst = substitute_operand(inst, &used, &val);
                    }
                }

                let mut store_backs = Vec::new();
                for def in inst.kills() {
                    if let Some(off) = self.spill_offset(&def, spilled) {
                        let tmp = self.new_scratch();
                        inst = substitute_operand(inst, &def, &tmp);
                        store_backs.push(IRInst::StorePtr { ptr_addr: IROperand::FrameSlot(off), src: tmp });
                    }
                }

                new_body.push(inst);
                new_body.extend(store_backs);
            }

            block.body = new_body;
        }
    }

    //Actual codegen time 
    fn lower_func(&mut self) -> Vec<AsmInst> {
        let mut compiled = Vec::new();

        if self.frame_size > 0 {
            compiled.push(AsmInst::Sub(AsmOperand::SP, AsmOperand::SP, imm(self.frame_size as i32)));
        }

        for block in &self.cfg {
            for inst in &block.body {
                self.lower_inst(inst, &mut out);
            }
        }
        out
    }

    fn operand_to_asm(&self, op: &IROperand) -> AsmOperand {
        match op {
            IROperand::SignedConstant(var) => AsmOperand::Imm22(*var),
            IROperand::UnsignedConstant(var) => AsmOperand::Imm22(*var as i32),
            IROperand::Var(_) | IROperand::Temp(_) => match self.allocations[op] {
                Location::Register(reg) => AsmOperand::Reg(Reg::TheRealOne(reg)),
                Location::StackOffset(_) => unreachable!("Spills already rewritten"),
            },
            IROperand::FrameSlot(_) => unreachable!("Only valid as ptr_addr"),

        }
    }

    //Minimal version of codegen for now

    fn rx31() -> AsmOperand { reg(31, RegType::B32, 0)} //Here is a cool trick
    fn rx30() -> AsmOperand { reg(30, RegType::B32, 0)} //Unfortunately we do in fact need second scratch

    fn reg_op(reg: Register) -> AsmOperand { AsmOperand::Reg(Reg::TheRealOne(reg)) }
    fn half_op(reg: Register, sub_index: u8) -> AsmOperand { reg_op(Register { id: reg.id, reg_type: RegType::B16, sub_index }) }

    fn is_const(op: &IROperand) -> bool {
        matches!(op, IROperand::SignedConstant(_) | IROperand::UnsignedConstant(_))
    }
    fn const_val(op: &IROperand) -> i32 {
        match op {
            IROperand::SignedConstant(value) => *value,
            IROperand::UnsignedConstant(value) => *value as i32,
            _ => panic!("not a constant"),
        }
    }


    fn fits(value: i64, bits: u32, signed: bool) -> bool { //Literally what it means
        if signed {
            let lo = -(1i64 << (bits - 1));
            let hi = (1i64 << (bits - 1)) - 1;
            value >= lo && value <= hi
        } else {
            value >= 0 && value < (1i64 << bits)
        }
    }

    fn load_const(dest: Register, value: i32, out: &mut Vec<AsmInst>) {
        match dest.reg_type {
            RegType::B32 if fits(value as i64, 18, true) => { //Fits into imm18
                out.push(AsmInst::Load(reg_op(dest), AsmOperand::Imm18(value)));
            }
            RegType::B32 if fits(value as i64, 26, true) => { //Fits into imm26, 
                out.push(AsmInst::Lma(AsmOperand::Imm26(value)));
                if dest.id != 31 { //If we actually wanted it in rx31, jic tbh tho
                    out.push(AsmInst::Mov(reg_op(dest), rx31()));
                    out.push(AsmInst::Xor(rx31(), rx31(), AsmOperand::Imm10(0)));
                }
            }
            RegType::B32 => {
                // If it doesn't fit even in 26 bits, we utilize register
                // fragmentation by loading lower 16 bits into ry310 higher into ry311 and result
                // will just be in rx31, genuis, love register fragmentation
                let lo = (value as u32 & 0xFFFF) as i32;
                let hi = ((value as u32 >> 16) & 0xFFFF) as i32;
                out.push(AsmInst::Load(half_op(dest, 0), AsmOperand::Imm18(lo)));
                out.push(AsmInst::Load(half_op(dest, 2), AsmOperand::Imm18(hi)));
            }
            _ => out.push(AsmInst::Load(reg_op(dest), Imm18(value))), // 16/8-bit value always fit in imm18
        }
    }

    //So we can load into stack, pointer, or raw address that function resolves that
    fn resolve_addr(&self, ptr_addr: &IROperand, out: &mut Vec<AsmInst>) -> (AsmOperand, i32, bool) {
        match ptr_addr {
            IROperand::FrameSlot(off) => (AsmOperand::SP, *off as i32, false),
            _ if is_const(ptr_addr) => {
                load_const(rx30(), const_val(ptr_addr), out);
                (rx31(), 0, true) //If its true, it means that rx31 got corrupted or sum, and we
                //gotta clean it up
            }
            _ => (self.operand_to_asm(ptr_addr), 0, false),
        }
    }


    //Lowest further, low load and store ptr 
    fn lower_mem(&self, dest_or_src: &IROperand, ptr_addr: &IROperand, is_load: bool, out: &mut Vec<AsmInst>) {
        let (base, off, used_rx31) = self.resolve_addr(ptr_addr, out);

        let value_operand = if is_load {
            self.operand_to_asm(dest_or_src)
        } else if is_const(dest_or_src) { //We have to actually load value into second scratch if it
            //isn't a variable
            let target = if used_rx31 { rx30() } else { rx30() };
            load_const(target, const_val(dest_or_src), out);
            reg_op(target)
        } else {
            self.operand_to_asm(dest_or_src)
        };

        out.push(if is_load { AsmInst::Ldr(value_operand, base, AsmOperand::Imm10(off as i16)) }
                else        { AsmInst::Str(value_operand, base, AsmOperand::Imm10(off as i16)) });

        if used_rx31 { out.push(AsmInst::Xor(rx31(), rx31(), AsmOperand::Imm10(0))); }
    }

    //R-type, so 2 operand like xor, or etc, its rx0 = rx0 OP (rx1 + imm10)
    fn lower_rtype_alu(&mut self, dest: &IROperand, left: &IROperand, right: &IROperand,
                        make: fn(AsmOperand, AsmOperand, AsmOperand) -> AsmInst, out: &mut Vec<AsmInst>) {
        let dest_asm = self.operand_to_asm(dest);
        let left_asm = self.operand_to_asm(left);

        if dest_asm != left_asm {
            out.push(AsmInst::Mov(dest_asm.clone(), left_asm));
        }

        let mut used_rx31 = false;
        let (rx1, imm10) = if is_const(right) && fits(const_val(right) as i64, 10, false) {
            (rx31(), AsmOperand::Imm10(const_val(right) as i16)) //As long as fits into imm10, we
            //are good
        } else if is_const(right) {
            load_const(rx30(), const_val(right), out); //But if it doesn't use rx30
            used_rx31 = true;
            (rx31(), AsmOperand::Imm10(0))
        } else {
            (self.operand_to_asm(right), AsmOperand::Imm10(0))
        };

        out.push(make(dest_asm, rx1, imm10));

        if used_rx31 { 
            out.push(AsmInst::Xor(rx31(), rx31(), AsmOperand::Imm10(0)));
        }
    }

    //B-type 3 operand: mul, add, sub
    fn lower_btype_alu(&mut self, dest: &IROperand, left: &IROperand, right: &IROperand,
                        make: fn(AsmOperand, AsmOperand, AsmOperand) -> AsmInst, out: &mut Vec<AsmInst>) {
        let mut used_rx31 = false;

        let l = if is_const(left) {
            load_const(rx30(), const_val(left), out);
            used_rx31 = true;
            rx31()
        } else {
            self.operand_to_asm(left)
        };

        let r = if is_const(right) {
            let target = if used_rx31 { rx30_reg() } else { rx30() };
            used_rx31 = true;
            load_const(target, const_val(right), out);
            reg_op(target)
        } else {
            self.operand_to_asm(right)
        };

        out.push(make(self.operand_to_asm(dest), l, r));

        if used_rx31 { out.push(AsmInst::Xor(rx31(), rx31(), AsmOperand::Imm10(0))); }
    }

    fn lower_cmp(&mut self, left: &IROperand, right: &IROperand, out: &mut Vec<AsmInst>) {
        let mut used_rx31 = false;

        let l_op = if Self.is_const(left) {
            Self::load_const(Self::rx30(), Self::const_val(left), out);
            Self::reg_op(Self::rx30());
            used_rx31 = true;
        } else {
            self.operand_to_asm(left);
        };

        let r_op = if Self.is_const(right) {
            Self::load_const(Self::rx30(), Self::const_val(right), out);
            Self::reg_op(Self::rx30());
            used_rx31 = true;
        } else {
            self.operand_to_asm(right);
        };

        out.push(AsmInst::Cmp(l_op, r_op));

        if used_rx31 {
            out.push(AsmInst::Xor(Self::rx31(), Self::rx31(), AsmOperand::Imm10(0)));
        }
    }

    fn type_bits(ty: &Type) -> u32 {
        match ty {
            Type::I8 | Type::U8 | Type::Bool => 8,
            Type::I16 | Type::U16 => 16,
            Type::I32 | Type::U32 => 32,
            _ => panic!("Casting only supports scalars"),
        }
    }

    fn is_signed(ty: &Type) -> bool {
        matches!(ty, Type::I8 | Type::I16 | Type::I32)
    }

    fn cast_const(val: i32, target_type: &Type) -> i32 {
        let bits = type_bits(target_type);
        if bits == 32 { return val; }
        let mask = (1u32 << bits) - 1;
        let truncated = (val as u32) & mask;
        if is_signed(target_type) && (truncated & (1 << (bits - 1))) != 0 {
            (truncated | !mask) as i32
        } else {
            truncated as i32
        }
    }

    fn lower_cast(&mut self, dest: &IROperand, src: &IROperand, target_type: &Type, src_type: &Type, out: &mut Vec<AsmInst>) {
        let dest_asm = self.operand_to_asm(dest);

        if is_const(src) {
            let casted = cast_const(const_val(src), target_type);
            if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                load_const(reg, casted, out);
            }
            return;
        }

        let src_asm = self.operand_to_asm(src);
        let src_bits = type_bits(src_type);
        let target_bits = type_bits(target_type);

        if is_signed(src_type) && target_bits > src_bits {
            //widening the signed is the only case where we need actual work
            if dest_asm != src_asm {
                out.push(AsmInst::Mov(dest_asm.clone(), src_asm));
            }
            let shift = (32 - src_bits) as i16;
            out.push(AsmInst::Shl(dest_asm.clone(), rx31(), AsmOperand::Imm10(shift)));
            out.push(AsmInst::Sra(dest_asm, rx31(), AsmOperand::Imm10(shift)));
        } else {
            //Any other operation is just move, because mov automatically zero extends,
            //automatically uses lower bits, and automatically just works, I love fragmented registers
            out.push(AsmInst::Mov(dest_asm, src_asm));
        }
    }

    fn lower_inst(&mut self, inst: &IRInst, out: &mut Vec<AsmInst>) {
        match inst {
            IRInst::Label(lab) => out.push(AsmInst::Label(format!("{}", lab))),
            IRInst::Jmp(target) => out.push(AsmInst::Jmp(target.clone())),

            IRInst::LoadPtr  { dest, ptr_addr } => self.lower_mem(dest, ptr_addr, true, out),
            IRInst::StorePtr { ptr_addr, src } => self.lower_mem(src, ptr_addr, false, out),

            IRInst::Add {dest, left, right} => self.lower_btype_alu(dest, left, right, AsmInst::Add, out),
            IRInst::Sub {dest, left, right} => self.lower_btype_alu(dest, left, right, AsmInst::Sub, out),
            IRInst::Mul {dest, left, right} => self.lower_btype_alu(dest, left, right, AsmInst::Mul, out),

            IRInst::Xor {dest, left, right} => self.lower_rtype_alu(dest, left, right, AsmInst::Xor, out),
            IRInst::Or  {dest, left, right} => self.lower_rtype_alu(dest, left, right, AsmInst::Or,  out),
            IRInst::And {dest, left, right} => self.lower_rtype_alu(dest, left, right, AsmInst::And, out),
            IRInst::Shl {dest, left, right} => self.lower_rtype_alu(dest, left, right, AsmInst::Shl, out),
            IRInst::Shr {dest, left, right} => self.lower_rtype_alu(dest, left, right, AsmInst::Shr, out),

            //Just code those 3 without functions its gonna be easier
            IRInst::Not {dest, src} => {
                let dest_asm = self.operand_to_asm(dest);

                //They are pretty much the same, so we first handle constants
                if is_const(src) {
                    let val = const_val(src);
                    if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                        load_const(reg, !val, out);
                    }
                } else { //that variables
                    let src_asm = self.operand_to_asm(src);
                    if dest != src { //And then dest, src
                        out.push(AsmInst::Mov(dest_asm.clone(), src_asm, AsmOperand::Imm10(0)));
                        out.push(AsmInst::Not(dest_asm));
                    } else {
                        out.push(AsmInst::Not(src_asm));
                    }
                }
            }

            IRInst::Negate {dest, src} => {
                let dest_asm = self.operand_to_asm(dest);

                if is_const(src) {
                    let val = const_val(src);
                    if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                        load_const(reg, -val, out);
                    }
                } else {
                    let src_asm = self.operand_to_asm(src);
                    out.push(AsmInst::Sub(dest_asm, rx31(), src_asm));
                }
            }

            IRInst::Cpy {dest, src} => {
                let dest_asm = self.operand_to_asm(dest);

                if is_const(src) {
                    if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                        load_const(reg, const_val(src), out);
                    }
                } else {
                    let src_asm = self.operand_to_asm(src);

                    if dest_asm != src_asm {
                        out.push(AsmInst::Mov(dest_asm, src_asm, AsmOperand::Imm10(0)));
                    }
                }
            }

            IRInst::Cast { dest, src, target_type, src_type } => self.lower_cast(dest, src, target_type, src_type, out),

            IRInst::AntiEqual {left, right, target} => {
                self.lower_cmp(left, right, out);
                out.push(AsmInst::Beq(target.clone()));
            }

            IRInst::Equal {left, right, target} => {
                self.lower_cmp(left, right, out);
                out.push(AsmInst::Bne(target.clone()));
            }

            IRInst::AntiMore {left, right, target, signed} => {
                self.lower_cmp(left, right, out);
                if signed {
                    out.push(AsmInst::Bgs(target.clone()));
                } else{
                    out.push(AsmInst::Bgu(target.clone()));
                }
            }

            IRInst::AntiLess {left, right, target, signed} => {
                self.lower_cmp(left, right, out);
                if signed {
                    out.push(AsmInst::Bss(target.clone()));
                } else {
                    out.push(AsmInst::Bsu(target.clone()));
                }
            }

            IRInst::InlineAsm {asm} => {
                for line in asm {
                    out.push(AsmInst::Inline(line));
                }
            }
        }
    }
}
