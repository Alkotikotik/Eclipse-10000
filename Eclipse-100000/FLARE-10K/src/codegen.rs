//Codegen, lets see what's it about
//Technically when I use "alive" its incorrect because the right term for it is just "live"
//But I don't like how plain "live" sound so ill use "alive"

use crate::IR3AC::{IRInst, IRFunction, IROperand};
use std::collections::HashMap;
use std::collections::HashSet;

pub const REGS_BYTES: usize = 124; //rx31 is scratchpad/0

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
    slots: [[bool; 4]; 31],
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

    //Control Flow Grapth(CFG) don't confuse with Context Free Grammar(CFG too)
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

        let mut active_nodes: HashSet<IROperand> = graph.adj.keys().cloned().collect();
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

    //Final allocator step
    pub fn run_allocator(&mut self) {
        self.compute_liveness();
        let graph = self.build_iterf_graph();
        let alloc_stack = self.color(graph.clone());
        self.allocate(alloc_stack, &graph);
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

}
