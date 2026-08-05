//Codegen, lets see what's it about
//Technically when I use "alive" its incorrect because the right term for it is just "live"
//But I don't like how plain "live" sound so ill use "alive"

use crate::IR3AC::{IRFunction, IRInst, IROperand, align_to, get_type_align, get_type_size};
use crate::parser::{Expr, StructDef, Type};
use std::collections::HashMap;
use std::collections::HashSet;
use std::fmt;

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

pub struct GlobalLayout {
    pub offsets: HashMap<String, usize>, // unpinned globals
    pub total_size: usize,               // bytes to reserve on the stack
    pub pins: HashMap<String, Register>, // pinned globals
    pub init_values: HashMap<String, GlobalInit>,
}

enum AddrBase {
    Spr(Spr),
    Reg(AsmOperand),
}

pub enum GlobalInit {
    Scalar(i32),
    None,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Spr {
    SP,
    LR,
    GP,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AsmOperand {
    Reg(Reg),
    Imm26(i32),
    Imm18(i32),
    Imm16(i16),
    Imm10(i16),
    Imm2(i8),
    Label(String),
}

#[derive(Debug, Clone)]
pub enum AsmInst {
    Mov(AsmOperand, AsmOperand, AsmOperand),
    Add(AsmOperand, AsmOperand, AsmOperand, AsmOperand), // 3 regisers
    Sub(AsmOperand, AsmOperand, AsmOperand, AsmOperand),
    Mul(AsmOperand, AsmOperand, AsmOperand, AsmOperand),
    Xor(AsmOperand, AsmOperand, AsmOperand), //2 register plus unsiged 10bit
    Or(AsmOperand, AsmOperand, AsmOperand),
    And(AsmOperand, AsmOperand, AsmOperand),
    Not(AsmOperand),
    Shl(AsmOperand, AsmOperand, AsmOperand),
    Shr(AsmOperand, AsmOperand, AsmOperand),
    Sra(AsmOperand, AsmOperand, AsmOperand),

    Load(AsmOperand, AsmOperand),
    Lma(AsmOperand),                         //Up to 25bits loads into rx31
    Ldr(AsmOperand, AsmOperand, AsmOperand), // dest, base, offset
    Str(AsmOperand, AsmOperand, AsmOperand), // src, base, offset

    SprLdr(AsmOperand, Spr, AsmOperand),
    SprStr(AsmOperand, Spr, AsmOperand),
    SprAdd(AsmOperand, Spr, AsmOperand),
    SprSub(AsmOperand, Spr, AsmOperand),
    SprLea(AsmOperand, Spr, AsmOperand),
    SprSet(AsmOperand, Spr),
    Push(AsmOperand),
    Pop(AsmOperand),

    Cmp(AsmOperand, AsmOperand),
    Beq(String),
    Bne(String),
    Bgu(String), //unsigned
    Bsu(String),
    Bgs(String), //signed
    Bss(String),

    Jmp(String),
    Jr(AsmOperand),
    Call(String),
    Inline(String),
    Label(String),
    Ret,
}

impl RegisterTracker {
    //Account for pinned globals
    pub fn new(reserved: &HashMap<String, Register>) -> Self {
        let mut t = Self {
            slots: [[false; 4]; 30],
        };
        for reg in reserved.values() {
            t.mark(reg.id, reg.reg_type, reg.sub_index);
        }
        t
    }

    //Mark as used by another variable
    pub fn mark(&mut self, reg_id: u8, reg_type: RegType, sub_idx: u8) {
        let num_bytes = reg_type.get_size();
        let start = sub_idx as usize;
        let regidasusize = reg_id as usize;

        for i in start..(start + num_bytes) {
            self.slots[regidasusize][i] = true;
        }
    }

    //First fit find free algorithm
    pub fn find_free(&mut self, reg_type: RegType) -> Option<(u8, u8)> {
        for reg_id in 0..30 {
            match reg_type {
                RegType::B8 => {
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

impl IROperand {
    pub fn is_var(&self) -> bool {
        matches!(self, IROperand::Var(_) | IROperand::Temp(_))
    }

    pub fn get_type(&self) -> RegType {
        RegType::B32
    }
}

//Just formatting
impl fmt::Display for AsmOperand {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AsmOperand::Reg(r) => write!(f, "{}", r),
            AsmOperand::Imm26(val)
            | AsmOperand::Imm18(val) => write!(f, "{}", val),
            AsmOperand::Imm16(val)
            | AsmOperand::Imm10(val) => write!(f, "{}", val),
            AsmOperand::Imm2(val) => write!(f, "{}", val),
            AsmOperand::Label(lbl) => write!(f, "{}", lbl),
        }
    }
}

impl fmt::Display for Register {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.reg_type {
            RegType::B8 => write!(f, "rz{}{}", self.id, self.sub_index),
            RegType::B16 => write!(f, "ry{}{}", self.id, self.sub_index / 2),
            RegType::B32 => write!(f, "rx{}", self.id),
        }
    }
}

impl fmt::Display for Reg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Reg::TheRealOne(r) => write!(f, "{}", r),
            &Reg::Virtual(_, _) => unreachable!(),
        }
    }
}

impl IRInst {
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
            | IRInst::Or { left, right, .. }
            | IRInst::And { left, right, .. }
            | IRInst::AntiEqual { left, right, .. }
            | IRInst::Equal { left, right, .. }
            | IRInst::AntiMore { left, right, .. }
            | IRInst::AntiLess { left, right, .. } => {
                if left.is_var() {
                    ls.push(left.clone());
                }
                if right.is_var() {
                    ls.push(right.clone());
                }
            }

            IRInst::Not { src, .. }
            | IRInst::Negate { src, .. }
            | IRInst::Cpy { src, .. }
            | IRInst::Cast { src, .. }
            | IRInst::LoadPtr { ptr_addr: src, .. } => {
                if src.is_var() {
                    ls.push(src.clone());
                }
            }

            IRInst::StorePtr { ptr_addr, src } => {
                if ptr_addr.is_var() {
                    ls.push(ptr_addr.clone());
                }
                if src.is_var() {
                    ls.push(src.clone());
                }
            }

            IRInst::RegFieldRead { struct_var, .. } => {
                if struct_var.is_var() {
                    ls.push(struct_var.clone());
                }
            }

            IRInst::RegFieldWrite {
                struct_var, src, ..
            } => {
                if struct_var.is_var() {
                    ls.push(struct_var.clone());
                }
                if src.is_var() {
                    ls.push(src.clone());
                }
            }

            IRInst::Call {
                args, stack_args, ..
            } => {
                for (arg, _) in args {
                    if arg.is_var() {
                        ls.push(arg.clone());
                    }
                }
                for arg in stack_args {
                    if arg.is_var() {
                        ls.push(arg.clone());
                    }
                }
            }

            IRInst::Return(Some(val)) => {
                if val.is_var() {
                    ls.push(val.clone());
                }
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
            | IRInst::Or { dest, .. }
            | IRInst::And { dest, .. }
            | IRInst::Not { dest, .. }
            | IRInst::Negate { dest, .. }
            | IRInst::Cpy { dest, .. }
            | IRInst::Cast { dest, .. }
            | IRInst::LoadPtr { dest, .. } => {
                if dest.is_var() {
                    ls.push(dest.clone());
                }
            }

            IRInst::RegFieldRead { dest, .. } => {
                if dest.is_var() {
                    ls.push(dest.clone());
                }
            }

            IRInst::Call {
                dest: Some(dest), ..
            } => {
                if dest.is_var() {
                    ls.push(dest.clone());
                }
            }

            _ => {}
        }
        ls
    }
}

//Globals are stored at positive GP offset, so right above the stack, unless they are pinned, in
//which case they are always stored in a register
impl GlobalLayout {
    pub fn build(globals: &[Expr], structs: &HashMap<String, StructDef>) -> Self {
        let mut offsets = HashMap::new();
        let mut pins = HashMap::new();
        let mut init_values = HashMap::new();
        let mut total_size = 0usize;

        for decl in globals {
            let (ty, name, initial, pin) = match decl {
                Expr::VarDecl {
                    ty,
                    name,
                    initial,
                    pin,
                } => (ty, name, initial, pin),
                _ => panic!("Codegen Error: bad global declaration"),
            };

            if matches!(ty, Type::Array(_, _)) {
                panic!("Codegen Error: global arrays are not allowed ('{}')", name);
            }

            let size = get_type_size(ty, structs);
            let align = get_type_align(ty, structs);

            let init = match initial {
                Some(expr) => match **expr {
                    Expr::IntLiteral(v) => GlobalInit::Scalar(v),
                    Expr::HexLiteral(v) => GlobalInit::Scalar(v as i32),
                    _ => panic!(
                        "Codegen Error: global {} needs a literal initializer, no compile time evaluation",
                        name
                    ),
                },
                None => GlobalInit::None,
            };

            if let Some(reg_str) = pin {
                let reg = Codegen::parse_pin_register(reg_str);
                if reg.reg_type.get_size() != size {
                    panic!(
                        "Codegen Error: pinned global {} is {} bytes but register is {} bytes",
                        name,
                        size,
                        reg.reg_type.get_size()
                    );
                }
                pins.insert(name.clone(), reg);
            } else {
                total_size = align_to(total_size, align);
                offsets.insert(name.clone(), total_size);
                total_size += size;
            }

            init_values.insert(name.clone(), init);
        }

        GlobalLayout {
            offsets,
            total_size,
            pins,
            init_values,
        }
    }
}

//Calculating variable's liveless variable is alive if it is read from in any of the successors
//If it isn't being read though, it is dead. If value is overwritten before its being read from its
//dead too
impl BasicBlock {
    pub fn compute_uevar_varkill(&mut self) {
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
        Self {
            adjacent: HashMap::new(),
        }
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
            self.adjacent
                .entry(first.clone())
                .or_default()
                .insert(second.clone());
            self.adjacent.entry(second).or_default().insert(first);
        }
    }
    //Weighted Degree is sum of neighbor's sizes in bytes
    pub fn get_weighted_degree(
        &self,
        node: &IROperand,
        active_nodes: &HashSet<IROperand>,
        sizes: &HashMap<IROperand, RegType>,
    ) -> usize {
        self.adjacent
            .get(node)
            .map(|neighbors| {
                neighbors
                    .iter()
                    .filter(|n| active_nodes.contains(n))
                    .map(|n| sizes.get(n).copied().unwrap_or(RegType::B32).get_size())
                    .sum()
            })
            .unwrap_or(0)
    }
}

fn rx31() -> AsmOperand {
    reg_op(rx31_reg())
} //Here is a cool trick
fn rx30() -> AsmOperand {
    reg_op(rx30_reg())
} //Unfortunately we do in fact need second scratch

fn rx30_reg() -> Register {
    Register {
        id: 30,
        reg_type: RegType::B32,
        sub_index: 0,
    }
}
fn rx31_reg() -> Register {
    Register {
        id: 31,
        reg_type: RegType::B32,
        sub_index: 0,
    }
}

fn reg_op(reg: Register) -> AsmOperand {
    AsmOperand::Reg(Reg::TheRealOne(reg))
}
fn half_op(reg: Register, sub_index: u8) -> AsmOperand {
    reg_op(Register {
        id: reg.id,
        reg_type: RegType::B16,
        sub_index,
    })
}

fn is_const(op: &IROperand) -> bool {
    matches!(
        op,
        IROperand::SignedConstant(_) | IROperand::UnsignedConstant(_)
    )
}
fn const_val(op: &IROperand) -> i32 {
    match op {
        IROperand::SignedConstant(value) => *value,
        IROperand::UnsignedConstant(value) => *value as i32,
        _ => panic!("not a constant"),
    }
}

fn fits(value: i64, bits: u32, signed: bool) -> bool {
    //Literally what it means
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
        RegType::B32 if fits(value as i64, 18, true) => {
            //Fits into imm18
            out.push(AsmInst::Load(reg_op(dest), AsmOperand::Imm18(value)));
        }
        RegType::B32 if fits(value as i64, 26, true) => {
            //Fits into imm26,
            out.push(AsmInst::Lma(AsmOperand::Imm26(value)));
            if dest.id != 31 {
                //If we actually wanted it in rx31, jic tbh tho
                out.push(AsmInst::Mov(reg_op(dest), rx31(), AsmOperand::Imm10(0)));
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
        _ => out.push(AsmInst::Load(reg_op(dest), AsmOperand::Imm18(value))), // 16/8-bit value always fit in imm18
    }
}

pub struct Codegen<'a> {
    ir_func: &'a IRFunction,
    structs: &'a HashMap<String, StructDef>,
    cfg: Vec<BasicBlock>,
    allocations: HashMap<IROperand, Location>,
    frame_size: usize,
    slots: RegisterTracker,
    pins: HashMap<String, Register>,
    global_layout: &'a GlobalLayout,
    next_temp: usize,
    call_saves: HashMap<(usize, usize), Vec<IROperand>>,
    operand_sizes: HashMap<IROperand, RegType>,
    wait_for_the_final_result: Vec<AsmInst>,
}

fn type_to_regtype(ty: &Type) -> RegType {
    match ty {
        Type::U8 | Type::I8 | Type::Bool => RegType::B8,
        Type::U16 | Type::I16 => RegType::B16,
        _ => RegType::B32,
    }
}

impl<'a> Codegen<'a> {
    pub fn new(
        ir_func: &'a IRFunction,
        structs: &'a HashMap<String, StructDef>,
        global_layout: &'a GlobalLayout,
    ) -> Self {
        let legalized_body = Self::legalize_globals(&ir_func.body, global_layout);
        let mut pins = Self::collect_pins(&legalized_body);
        pins.extend(global_layout.pins.clone());

        let next_temp = legalized_body
            .iter()
            .flat_map(|i| i.uses().into_iter().chain(i.kills()))
            .filter_map(|op| match op {
                IROperand::Temp(n) => Some(n + 1),
                _ => None,
            })
            .max()
            .unwrap_or(0);

        let mut codegen = Self {
            ir_func,
            structs,
            global_layout,
            cfg: Vec::new(),
            allocations: HashMap::new(),
            frame_size: 0,
            slots: RegisterTracker::new(&global_layout.pins),
            pins,
            next_temp,
            call_saves: HashMap::new(),
            operand_sizes: ir_func
                .var_types
                .iter()
                .map(|(name, ty)| (IROperand::Var(name.clone()), type_to_regtype(ty)))
                .collect(),
            wait_for_the_final_result: Vec::new(),
        };

        codegen.build_cfg(&legalized_body);
        codegen
    }

    pub fn parse_pin_register(pin_str: &str) -> Register {
        let upper = pin_str.to_uppercase();

        let prefix = if upper.starts_with("RZ") {
            "RZ"
        } else if upper.starts_with("RY") {
            "RY"
        } else if upper.starts_with("RX") {
            "RX"
        } else if upper.starts_with('R') {
            "R"
        } else {
            panic!("Codegen Error: invalid pin register {}", pin_str)
        };

        let rest = &upper[prefix.len()..];
        let num: u32 = rest
            .parse()
            .unwrap_or_else(|_| panic!("Codegen Error: invalid pin register {}", pin_str));

        match prefix {
            "RZ" => {
                let reg_id = (num / 10) as u8;
                let byte_sel = (num % 10) as u8;
                Register {
                    id: reg_id,
                    reg_type: RegType::B8,
                    sub_index: byte_sel,
                }
            }
            "RY" => {
                let reg_id = (num / 10) as u8;
                let half_sel = (num % 10) as u8;
                Register {
                    id: reg_id,
                    reg_type: RegType::B16,
                    sub_index: half_sel * 2,
                }
            }
            _ => {
                let reg_id = num as u8;
                Register {
                    id: reg_id,
                    reg_type: RegType::B32,
                    sub_index: 0,
                }
            }
        }
    }

    fn size_of(&self, op: &IROperand) -> RegType {
        self.operand_sizes.get(op).copied().unwrap_or(RegType::B32)
    }
}

fn substitute_operand(inst: IRInst, old: &IROperand, new: &IROperand) -> IRInst {
    let sub = |op: IROperand| if &op == old { new.clone() } else { op };
    match inst {
        IRInst::Add { dest, left, right } => IRInst::Add {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Sub { dest, left, right } => IRInst::Sub {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Mul { dest, left, right } => IRInst::Mul {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Div {
            dest,
            left,
            right,
            signed,
        } => IRInst::Div {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
            signed,
        },
        IRInst::Mod {
            dest,
            left,
            right,
            signed,
        } => IRInst::Mod {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
            signed,
        },
        IRInst::Shl { dest, left, right } => IRInst::Shl {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Shr { dest, left, right } => IRInst::Shr {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Xor { dest, left, right } => IRInst::Xor {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Or { dest, left, right } => IRInst::Or {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::And { dest, left, right } => IRInst::And {
            dest: sub(dest),
            left: sub(left),
            right: sub(right),
        },
        IRInst::Not { dest, src } => IRInst::Not {
            dest: sub(dest),
            src: sub(src),
        },
        IRInst::Negate { dest, src } => IRInst::Negate {
            dest: sub(dest),
            src: sub(src),
        },
        IRInst::Cpy { dest, src } => IRInst::Cpy {
            dest: sub(dest),
            src: sub(src),
        },
        IRInst::Cast {
            dest,
            src,
            target_type,
            src_type,
        } => IRInst::Cast {
            dest: sub(dest),
            src: sub(src),
            target_type,
            src_type,
        },
        IRInst::LoadPtr { dest, ptr_addr } => IRInst::LoadPtr {
            dest: sub(dest),
            ptr_addr: sub(ptr_addr),
        },
        IRInst::StorePtr { ptr_addr, src } => IRInst::StorePtr {
            ptr_addr: sub(ptr_addr),
            src: sub(src),
        },
        IRInst::AntiEqual {
            left,
            right,
            target,
        } => IRInst::AntiEqual {
            left: sub(left),
            right: sub(right),
            target,
        },
        IRInst::Equal {
            left,
            right,
            target,
        } => IRInst::Equal {
            left: sub(left),
            right: sub(right),
            target,
        },
        IRInst::AntiMore {
            left,
            right,
            target,
            signed,
        } => IRInst::AntiMore {
            left: sub(left),
            right: sub(right),
            target,
            signed,
        },
        IRInst::AntiLess {
            left,
            right,
            target,
            signed,
        } => IRInst::AntiLess {
            left: sub(left),
            right: sub(right),
            target,
            signed,
        },
        IRInst::Call {
            dest,
            name,
            args,
            stack_args,
        } => IRInst::Call {
            dest: dest.map(|d| sub(d)),
            name,
            args: args.into_iter().map(|(arg, pin)| (sub(arg), pin)).collect(),
            stack_args: stack_args.into_iter().map(|arg| sub(arg)).collect(),
        },
        IRInst::Return(val) => IRInst::Return(val.map(sub)),
        other => other,
    }
}

impl<'a> Codegen<'a> {
    //Pins before cfg
    fn collect_pins(body: &[IRInst]) -> HashMap<String, Register> {
        let mut pins = HashMap::new();
        for inst in body {
            if let IRInst::Pin { var, register } = inst {
                pins.insert(var.clone(), Self::parse_pin_register(register));
            }
        }
        pins
    }

    //Building basics blocks of cfg, basic block is the largest code of block that doesn't contain branching
    //For example statements bodies without branching
    pub fn build_bbs(body: &[IRInst]) -> Vec<BasicBlock> {
        //basic blocks &[IRInst] is basically
        //reference to the vector of IRInst but we don't copy it we just know where it is
        let mut leaders = std::collections::BTreeSet::new(); //Vector with auto sort, plus uniqueness
        leaders.insert(0);

        for (idx, inst) in body.iter().enumerate() {
            match inst {
                IRInst::Label(_) => {
                    leaders.insert(idx);
                }

                IRInst::JMP(_)
                | IRInst::Return(_)
                | IRInst::AntiEqual { .. }
                | IRInst::Equal { .. }
                | IRInst::AntiLess { .. }
                | IRInst::AntiMore { .. } => {
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

        for (id, window) in indices.windows(2).enumerate() {
            //Exactly what it sounds like we are
            //creating a window between 2 leaders
            let start = window[0];
            let end = window[1];

            let instructions = body[start..end].to_vec();

            let label = match instructions.first() {
                Some(IRInst::Label(lbl)) => Some(lbl.clone()),
                _ => None,
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
                    IRInst::AntiEqual { target, .. }
                    | IRInst::Equal { target, .. }
                    | IRInst::AntiLess { target, .. }
                    | IRInst::AntiMore { target, .. } => {
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
        for src_id in 0..num_blocks {
            //predecessors are easy, if block B is successors of block A,
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

        let depths = Self::compute_loop_depths(&self.cfg);
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
                    if !self.cfg[i].varkill.contains(var) {
                        //Minus VarKill
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

    //Using varkills to determine if variable is alive at the call, if yes spill it
    fn compute_call_save_sets(&self) -> HashMap<(usize, usize), Vec<IROperand>> {
        let mut result = HashMap::new();

        for block in &self.cfg {
            let mut live = block.live_out.clone();

            for (idx, inst) in block.body.iter().enumerate().rev() {
                if matches!(inst, IRInst::Call { .. }) {
                    let kills: HashSet<IROperand> = inst.kills().into_iter().collect();
                    let mut to_save: Vec<IROperand> = live
                        .iter()
                        .filter(|v| !kills.contains(v))
                        .filter(|v| self.is_caller_saved_register(v))
                        .cloned()
                        .collect();
                    to_save.sort_by_key(|v| format!("{:?}", v));
                    result.insert((block.id, idx), to_save);
                }

                for definition in inst.kills() {
                    live.remove(&definition);
                }
                for use_var in inst.uses() {
                    live.insert(use_var);
                }
            }
        }

        result
    }

    fn is_caller_saved_register(&self, op: &IROperand) -> bool {
        if let IROperand::Var(name) = op {
            if self.pins.contains_key(name) {
                return false;
            }
        }
        matches!(self.allocations.get(op), Some(Location::Register(_)))
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
                    graph.add_node(definition.clone());
                    for live_var in &live {
                        graph.add_edge(definition.clone(), live_var.clone());
                    }
                    live.remove(&definition);
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
        let spill_costs = self.compute_spill_costs();

        let mut active_nodes: HashSet<IROperand> = graph
            .adjacent
            .keys()
            .filter(|a| !self.allocations.contains_key(a))
            .cloned()
            .collect();
        let mut alloc_stack: Vec<IROperand> = Vec::new();

        while !active_nodes.is_empty() {
            let candidate = active_nodes //find node where Weighted degree is less than REGS_BYTES
                .iter()
                .find(|node| {
                    let neighbor_bytes =
                        graph.get_weighted_degree(node, &active_nodes, &self.operand_sizes);
                    let node_bytes = self.size_of(node).get_size();

                    neighbor_bytes + node_bytes <= REGS_BYTES
                })
                .cloned();

            let chosen_node = match candidate {
                Some(node) => node,
                //Now if there isn't node with degree < REGS_BYTES we remove the node the node that
                //minimizes SpillCost/Degree it will be our optimistic candidate, and because we are
                //using spill cost which is 10^depth chances of optimistic candidate of getting
                //allocated are pretty high, but not 100%
                None => active_nodes
                    .iter()
                    .min_by(|a, b| {
                        let degree_a =
                            graph.get_weighted_degree(a, &active_nodes, &self.operand_sizes) as f64;
                        let degree_b =
                            graph.get_weighted_degree(b, &active_nodes, &self.operand_sizes) as f64;

                        let cost_a = spill_costs.get(a).unwrap_or(&1.0) / degree_a;
                        let cost_b = spill_costs.get(b).unwrap_or(&1.0) / degree_b;

                        cost_a
                            .partial_cmp(&cost_b)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .cloned()
                    .unwrap(),
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
            let mut tracker = RegisterTracker::new(&self.pins);

            if let Some(neighbors) = graph.adjacent.get(&operand) {
                for neighbor in neighbors {
                    if let Some(Location::Register(reg)) = self.allocations.get(neighbor) {
                        tracker.mark(reg.id, reg.reg_type, reg.sub_index);
                    }
                }
            }
            let operand_type = self.size_of(&operand);
            if let Some((phys_reg_id, sub_index)) = tracker.find_free(operand_type) {
                let assigned_reg = Register {
                    id: phys_reg_id,
                    reg_type: operand_type,
                    sub_index,
                };
                self.allocations
                    .insert(operand, Location::Register(assigned_reg));
            } else {
                //Spill
                let offset = self.frame_size;
                self.frame_size += operand_type.get_size();
                self.allocations
                    .insert(operand, Location::StackOffset(offset));
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
            let spilled: HashSet<IROperand> = self
                .allocations
                .iter()
                .filter(|(_, loc)| matches!(loc, Location::StackOffset(_)))
                .map(|(op, _)| op.clone())
                .collect();

            if spilled.is_empty() {
                break;
            } //No spilled? Nice - break

            self.rewrite_spills(&spilled);
            self.allocations.clear();
            
            let max_passes = 100;
            passes += 1;
            if passes > max_passes {
                panic!(
                    "Codegen Error: More than {} passes occured, there must be something wrong, can't help though", max_passes
                );
            }
        }
    }

    //Check for pin conflicts
    fn seed_pins(&mut self, graph: &InterferenceGraph) {
        for (var_name, reg) in &self.pins {
            self.allocations
                .entry(IROperand::Var(var_name.clone()))
                .or_insert(Location::Register(*reg));
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
    pub fn find_loops(
        cfg: &[BasicBlock],
        doms: &HashMap<usize, HashSet<usize>>,
    ) -> Vec<HashSet<usize>> {
        let mut loops = Vec::new();

        //Looking for back edges which is edge between A and B where A dominates B
        //When such an edge is found, the natural loop consists of all nodes that can reach B
        //without passing through A
        for block in cfg {
            for &succ in &block.successors {
                if let Some(succ_doms) = doms.get(&block.id) {
                    if succ_doms.contains(&succ) {
                        let loop_nodes = Self::populate_loop_body(cfg, succ, block.id);
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
            if node == header {
                continue;
            }

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
        let doms = Self::compute_dominators(cfg);
        let loops = Self::find_loops(cfg, &doms);

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
    fn spill_offset(allocations: &HashMap<IROperand, Location>, operand: &IROperand, spilled: &HashSet<IROperand>) -> Option<usize> {
        if !spilled.contains(operand) {
            return None;
        }
        match allocations.get(operand) {
            Some(Location::StackOffset(off)) => Some(*off),
            _ => None,
        }
    }

    fn new_scratch(next_temp: &mut usize) -> IROperand {
        let t = IROperand::Temp(*next_temp);
        *next_temp += 1;
        t
    }

    fn rewrite_spills(&mut self, spilled: &HashSet<IROperand>) {
        let allocations = &self.allocations;
        let next_temp = &mut self.next_temp;

        for block in &mut self.cfg {
            let mut new_body = Vec::new();

            for inst in &block.body {
                let mut inst = inst.clone();

                for used in inst.uses() {
                    if let Some(off) = Self::spill_offset(allocations, &used, spilled) {
                        let val = Self::new_scratch(next_temp);
                        new_body.push(IRInst::LoadPtr {
                            dest: val.clone(),
                            ptr_addr: IROperand::FrameSlot(off),
                        });
                        inst = substitute_operand(inst, &used, &val);
                    }
                }

                let mut store_backs = Vec::new();
                for def in inst.kills() {
                    if let Some(off) = Self::spill_offset(allocations, &def, spilled) {
                        let tmp = Self::new_scratch(next_temp);
                        inst = substitute_operand(inst, &def, &tmp);
                        store_backs.push(IRInst::StorePtr {
                            ptr_addr: IROperand::FrameSlot(off),
                            src: tmp,
                        });
                    }
                }

                new_body.push(inst);
                new_body.extend(store_backs);
            }

            block.body = new_body;
        }
    }

    //Only non-leaf functions ever clobber LR (by calling something else), so only they
    //need to save/restore it - leaf functions can RET straight off the caller's LR
    fn is_leaf(&self) -> bool {
        !self
            .cfg
            .iter()
            .any(|b| b.body.iter().any(|i| matches!(i, IRInst::Call { .. })))
    }

    //Actual codegen time
    pub fn lower_func(&mut self) -> Vec<AsmInst> {
        let mut compiled = Vec::new();
        let leaf = self.is_leaf();
        let blocks = self.cfg.clone();

        if let Some(first_inst) = blocks.first().and_then(|b| b.body.first()) {
            if let IRInst::Label(_) = first_inst {
                self.lower_inst(first_inst, (0, 0), &mut compiled);
            }
        }

        if self.frame_size > 0 {
            compiled.push(AsmInst::SprLea(
                reg_op(rx30_reg()),
                Spr::SP,
                AsmOperand::Imm16(0),
            ));
            compiled.push(AsmInst::SprSub(
                reg_op(rx30_reg()),
                Spr::SP,
                AsmOperand::Imm16(self.frame_size as i16),
            ));
        }

        if !leaf {
            compiled.push(AsmInst::SprLea(
                reg_op(rx30_reg()),
                Spr::LR,
                AsmOperand::Imm16(0),
            ));
            compiled.push(AsmInst::Push(reg_op(rx30_reg())));
        }

        self.call_saves = self.compute_call_save_sets();

        for (bidx, block) in blocks.iter().enumerate() {
            for (idx, inst) in block.body.iter().enumerate() {
                if bidx == 0 && idx == 0 { continue; }
                self.lower_inst(inst, (block.id, idx), &mut compiled);
            }
        }
        compiled
    }

    //Place the globals before the stack
    fn legalize_globals(body: &[IRInst], layout: &GlobalLayout) -> Vec<IRInst> {
        let mut next_temp = body
            .iter()
            .flat_map(|i| i.uses().into_iter().chain(i.kills()))
            .filter_map(|op| match op {
                IROperand::Temp(n) => Some(n + 1),
                _ => None,
            })
            .max()
            .unwrap_or(0);

        let mut new_body = Vec::new();

        for inst in body {
            let mut inst = inst.clone();

            for used in inst.uses() {
                if let IROperand::Var(name) = &used {
                    if let Some(&off) = layout.offsets.get(name) {
                        let tmp = IROperand::Temp(next_temp);
                        next_temp += 1;
                        new_body.push(IRInst::LoadPtr {
                            dest: tmp.clone(),
                            ptr_addr: IROperand::GlobalSlot(off),
                        });
                        inst = substitute_operand(inst, &used, &tmp);
                    }
                }
            }

            let mut store_backs = Vec::new();
            for def in inst.kills() {
                if let IROperand::Var(name) = &def {
                    if let Some(&off) = layout.offsets.get(name) {
                        let tmp = IROperand::Temp(next_temp);
                        next_temp += 1;
                        inst = substitute_operand(inst, &def, &tmp);
                        store_backs.push(IRInst::StorePtr {
                            ptr_addr: IROperand::GlobalSlot(off),
                            src: tmp,
                        });
                    }
                }
            }

            new_body.push(inst);
            new_body.extend(store_backs);
        }

        new_body
    }

    fn operand_to_asm(&self, op: &IROperand) -> AsmOperand {
        match op {
            IROperand::SignedConstant(var) => AsmOperand::Imm18(*var),
            IROperand::UnsignedConstant(var) => AsmOperand::Imm18(*var as i32),
            IROperand::Var(_) | IROperand::Temp(_) => match self.allocations[op] {
                Location::Register(reg) => AsmOperand::Reg(Reg::TheRealOne(reg)),
                Location::StackOffset(_) => unreachable!("Spills already rewritten"),
            },
            IROperand::FrameSlot(_) => unreachable!("Only valid as ptr_addr"),
            IROperand::GlobalSlot(_) => unreachable!("Only valid as ptr_addr"),
            IROperand::IncomingArgSlot(_) => unreachable!("Only valid as ptr_addr"),
        }
    }

    //Minimal version of codegen for now

    //So we can load into stack, pointer, or raw address that function resolves that
    fn resolve_addr(&self, ptr_addr: &IROperand, out: &mut Vec<AsmInst>) -> (AddrBase, i32, bool) {
        match ptr_addr {
            IROperand::FrameSlot(off) => (AddrBase::Spr(Spr::SP), *off as i32, false),
            IROperand::GlobalSlot(off) => (AddrBase::Spr(Spr::GP), *off as i32, false),
            IROperand::IncomingArgSlot(idx) => (
                AddrBase::Spr(Spr::SP),
                (self.frame_size + idx * 4) as i32,
                false,
            ),
            _ if is_const(ptr_addr) => {
                //If its true, it means that rx31 got corrupted or sum, and we gotta clean in up
                load_const(rx30_reg(), const_val(ptr_addr), out);
                (AddrBase::Reg(rx30()), 0, true)
            }
            _ => (AddrBase::Reg(self.operand_to_asm(ptr_addr)), 0, false),
        }
    }

    pub fn emit_global_prologue(layout: &GlobalLayout) -> Vec<AsmInst> {
        let mut out = Vec::new();

        if layout.total_size > 0 {
            out.push(AsmInst::SprLea(
                reg_op(rx30_reg()),
                Spr::SP,
                AsmOperand::Imm16(0),
            ));
            out.push(AsmInst::SprSub(
                reg_op(rx30_reg()),
                Spr::SP,
                AsmOperand::Imm16(layout.total_size as i16),
            ));
            out.push(AsmInst::SprLea(
                reg_op(rx30_reg()),
                Spr::SP,
                AsmOperand::Imm16(0),
            ));
            out.push(AsmInst::SprSet(reg_op(rx30_reg()), Spr::GP));
        }

        for (name, init) in &layout.init_values {
            if let GlobalInit::Scalar(v) = init {
                if let Some(reg) = layout.pins.get(name) {
                    load_const(*reg, *v, &mut out);
                } else if let Some(&off) = layout.offsets.get(name) {
                    load_const(rx30_reg(), *v, &mut out);
                    out.push(AsmInst::SprStr(
                        reg_op(rx30_reg()),
                        Spr::GP,
                        AsmOperand::Imm16(off as i16),
                    ));
                }
            }
        }

        out
    }

    //Lowers further, low load and store ptr
    fn lower_mem(
        &self,
        dest_or_src: &IROperand,
        ptr_addr: &IROperand,
        is_load: bool,
        out: &mut Vec<AsmInst>,
    ) {
        let (base, off, used_rx30) = self.resolve_addr(ptr_addr, out);

        let value_operand = if is_load {
            self.operand_to_asm(dest_or_src)
        } else if is_const(dest_or_src) {
            load_const(rx30_reg(), const_val(dest_or_src), out);
            reg_op(rx30_reg())
        } else {
            self.operand_to_asm(dest_or_src)
        };

        match base {
            AddrBase::Spr(spr) => out.push(if is_load {
                AsmInst::SprLdr(value_operand, spr, AsmOperand::Imm16(off as i16))
            } else {
                AsmInst::SprStr(value_operand, spr, AsmOperand::Imm16(off as i16))
            }),
            AddrBase::Reg(base_reg) => out.push(if is_load {
                AsmInst::Ldr(value_operand, base_reg, AsmOperand::Imm10(off as i16))
            } else {
                AsmInst::Str(value_operand, base_reg, AsmOperand::Imm10(off as i16))
            }),
        }

        if used_rx30 {
            out.push(AsmInst::Xor(rx30(), rx30(), AsmOperand::Imm10(0)));
        }
    }

    //R-type, so 2 operand like xor, or etc, its rx0 = rx0 OP (rx1 + imm10)
    fn lower_rtype_alu(
        &mut self,
        dest: &IROperand,
        left: &IROperand,
        right: &IROperand,
        make: fn(AsmOperand, AsmOperand, AsmOperand) -> AsmInst,
        out: &mut Vec<AsmInst>,
    ) {
        let dest_asm = self.operand_to_asm(dest);
        let left_asm = self.operand_to_asm(left);

        if dest_asm != left_asm {
            out.push(AsmInst::Mov(
                dest_asm.clone(),
                left_asm,
                AsmOperand::Imm10(0),
            ));
        }

        let mut used_rx31 = false;
        let (rx1, imm10) = if is_const(right) && fits(const_val(right) as i64, 10, false) {
            (rx31(), AsmOperand::Imm10(const_val(right) as i16)) //As long as fits into imm10, we
        //are good
        } else if is_const(right) {
            load_const(rx30_reg(), const_val(right), out); //But if it doesn't use rx30
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

    fn fits_imm2(val: i64) -> Option<i8> {
        match val {
            -1 => Some(0b11),
            0 => Some(0b00),
            1 => Some(0b01),
            2 => Some(0b10),
            _ => None,
        }
    }

    //B-type 3 operand: mul, add, sub
    fn lower_btype_alu(
        &mut self,
        dest: &IROperand,
        left: &IROperand,
        right: &IROperand,
        make: fn(AsmOperand, AsmOperand, AsmOperand, AsmOperand) -> AsmInst,
        out: &mut Vec<AsmInst>,
    ) {
        let (l, left_used_rx30) = if is_const(left) && const_val(left) == 0 {
            (rx31(), false)
        } else if is_const(left) {
            load_const(rx30_reg(), const_val(left), out);
            (reg_op(rx30_reg()), true)
        } else {
            (self.operand_to_asm(left), false)
        };

        //Again imm2 is purely for "for" loops
        if is_const(right) {
            if let Some(imm2) = Self::fits_imm2(const_val(right) as i64) {
                out.push(make(
                    self.operand_to_asm(dest),
                    l,
                    rx31(),
                    AsmOperand::Imm2(imm2),
                ));
                return;
            }
        }

        let (r, used_rx31) = if is_const(right) {
            let target = if left_used_rx30 {
                rx31_reg()
            } else {
                rx30_reg()
            };
            load_const(target, const_val(right), out);
            (reg_op(target), left_used_rx30)
        } else {
            (self.operand_to_asm(right), false)
        };

        out.push(make(self.operand_to_asm(dest), l, r, AsmOperand::Imm2(0)));

        if used_rx31 {
            out.push(AsmInst::Xor(rx31(), rx31(), AsmOperand::Imm10(0)));
        }
    }

    fn lower_cmp(&mut self, left: &IROperand, right: &IROperand, out: &mut Vec<AsmInst>) {
        let mut used_rx30 = false;

        let l_op = if is_const(left) {
            load_const(rx30_reg(), const_val(left), out);
            used_rx30 = true;
            reg_op(rx30_reg())
        } else {
            self.operand_to_asm(left)
        };

        let r_op = if is_const(right) {
            load_const(rx30_reg(), const_val(right), out);
            used_rx30 = true;
            reg_op(rx30_reg())
        } else {
            self.operand_to_asm(right)
        };

        out.push(AsmInst::Cmp(l_op, r_op));

        if used_rx30 {
            out.push(AsmInst::Xor(rx30(), rx30(), AsmOperand::Imm10(0)));
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
        let bits = Self::type_bits(target_type);
        if bits == 32 {
            return val;
        }
        let mask = (1u32 << bits) - 1;
        let truncated = (val as u32) & mask;
        if Self::is_signed(target_type) && (truncated & (1 << (bits - 1))) != 0 {
            (truncated | !mask) as i32
        } else {
            truncated as i32
        }
    }

    fn lower_cast(
        &mut self,
        dest: &IROperand,
        src: &IROperand,
        target_type: &Type,
        src_type: &Type,
        out: &mut Vec<AsmInst>,
    ) {
        let dest_asm = self.operand_to_asm(dest);

        if is_const(src) {
            let casted = Self::cast_const(const_val(src), target_type);
            if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                load_const(reg, casted, out);
            }
            return;
        }

        let src_asm = self.operand_to_asm(src);
        let src_bits = Self::type_bits(src_type);
        let target_bits = Self::type_bits(target_type);

        if Self::is_signed(src_type) && target_bits > src_bits {
            //widening the signed is the only case where we need actual work
            if dest_asm != src_asm {
                out.push(AsmInst::Mov(
                    dest_asm.clone(),
                    src_asm,
                    AsmOperand::Imm10(0),
                ));
            }
            let shift = (32 - src_bits) as i16;
            out.push(AsmInst::Shl(
                dest_asm.clone(),
                rx31(),
                AsmOperand::Imm10(shift),
            ));
            out.push(AsmInst::Sra(dest_asm, rx31(), AsmOperand::Imm10(shift)));
        } else {
            //Any other operation is just move, because mov automatically zero extends,
            //automatically uses lower bits, and automatically just works, I love fragmented registers
            out.push(AsmInst::Mov(dest_asm, src_asm, AsmOperand::Imm10(0)));
        }
    }

    fn lower_inst(&mut self, inst: &IRInst, site: (usize, usize), out: &mut Vec<AsmInst>) {
        match inst {
            IRInst::Label(lab) => out.push(AsmInst::Label(format!("{}", lab))),
            IRInst::JMP(target) => out.push(AsmInst::Jmp(target.clone())),

            IRInst::LoadPtr { dest, ptr_addr } => self.lower_mem(dest, ptr_addr, true, out),
            IRInst::StorePtr { ptr_addr, src } => self.lower_mem(src, ptr_addr, false, out),

            IRInst::Add { dest, left, right } => {
                self.lower_btype_alu(dest, left, right, AsmInst::Add, out)
            }
            IRInst::Sub { dest, left, right } => {
                self.lower_btype_alu(dest, left, right, AsmInst::Sub, out)
            }
            IRInst::Mul { dest, left, right } => {
                self.lower_btype_alu(dest, left, right, AsmInst::Mul, out)
            }

            IRInst::Xor { dest, left, right } => {
                self.lower_rtype_alu(dest, left, right, AsmInst::Xor, out)
            }
            IRInst::Or { dest, left, right } => {
                self.lower_rtype_alu(dest, left, right, AsmInst::Or, out)
            }
            IRInst::And { dest, left, right } => {
                self.lower_rtype_alu(dest, left, right, AsmInst::And, out)
            }
            IRInst::Shl { dest, left, right } => {
                self.lower_rtype_alu(dest, left, right, AsmInst::Shl, out)
            }
            IRInst::Shr { dest, left, right } => {
                self.lower_rtype_alu(dest, left, right, AsmInst::Shr, out)
            }

            //Just code those 3 without functions its gonna be easier
            IRInst::Not { dest, src } => {
                let dest_asm = self.operand_to_asm(dest);

                //They are pretty much the same, so we first handle constants
                if is_const(src) {
                    let val = const_val(src);
                    if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                        load_const(reg, !val, out);
                    }
                } else {
                    //that variables
                    let src_asm = self.operand_to_asm(src);
                    if dest != src {
                        //And then dest, src
                        out.push(AsmInst::Mov(
                            dest_asm.clone(),
                            src_asm,
                            AsmOperand::Imm10(0),
                        ));
                        out.push(AsmInst::Not(dest_asm));
                    } else {
                        out.push(AsmInst::Not(src_asm));
                    }
                }
            }

            IRInst::Negate { dest, src } => {
                let dest_asm = self.operand_to_asm(dest);

                if is_const(src) {
                    let val = const_val(src);
                    if let AsmOperand::Reg(Reg::TheRealOne(reg)) = dest_asm {
                        load_const(reg, -val, out);
                    }
                } else {
                    let src_asm = self.operand_to_asm(src);
                    out.push(AsmInst::Sub(dest_asm, rx31(), src_asm, AsmOperand::Imm2(0)));
                }
            }

            IRInst::Cpy { dest, src } => {
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

            IRInst::Cast {
                dest,
                src,
                target_type,
                src_type,
            } => self.lower_cast(dest, src, target_type, src_type, out),

            IRInst::RegFieldRead {
                dest,
                struct_var,
                byte_offset,
                byte_size,
            } => {
                let struct_asm = self.operand_to_asm(struct_var);
                let field_asm = match struct_asm {
                    AsmOperand::Reg(Reg::TheRealOne(reg)) => reg_op(Register {
                        id: reg.id,
                        reg_type: match byte_size {
                            1 => RegType::B8,
                            2 => RegType::B16,
                            _ => RegType::B32,
                        },
                        sub_index: reg.sub_index + *byte_offset as u8,
                    }),
                    _ => panic!(
                        "Codegen Error: regarch field access requires a register-resident struct"
                    ),
                };
                let dest_asm = self.operand_to_asm(dest);
                if dest_asm != field_asm {
                    out.push(AsmInst::Mov(dest_asm, field_asm, AsmOperand::Imm10(0)));
                }
            }

            IRInst::RegFieldWrite {
                src,
                struct_var,
                byte_offset,
                byte_size,
            } => {
                let struct_asm = self.operand_to_asm(struct_var);
                let field_asm = match struct_asm {
                    AsmOperand::Reg(Reg::TheRealOne(reg)) => reg_op(Register {
                        id: reg.id,
                        reg_type: match byte_size {
                            1 => RegType::B8,
                            2 => RegType::B16,
                            _ => RegType::B32,
                        },
                        sub_index: reg.sub_index + *byte_offset as u8,
                    }),
                    _ => panic!(
                        "Codegen Error: regarch field access requires a register-resident struct"
                    ),
                };
                if is_const(src) {
                    if let AsmOperand::Reg(Reg::TheRealOne(reg)) = field_asm {
                        load_const(reg, const_val(src), out);
                    }
                } else {
                    let src_asm = self.operand_to_asm(src);
                    if src_asm != field_asm {
                        out.push(AsmInst::Mov(field_asm, src_asm, AsmOperand::Imm10(0)));
                    }
                }
            }

            IRInst::AntiEqual {
                left,
                right,
                target,
            } => {
                self.lower_cmp(left, right, out);
                out.push(AsmInst::Beq(target.clone()));
            }

            IRInst::Equal {
                left,
                right,
                target,
            } => {
                self.lower_cmp(left, right, out);
                out.push(AsmInst::Bne(target.clone()));
            }

            IRInst::AntiMore {
                left,
                right,
                target,
                signed,
            } => {
                self.lower_cmp(left, right, out);
                if *signed {
                    out.push(AsmInst::Bss(target.clone()));
                } else {
                    out.push(AsmInst::Bsu(target.clone()));
                }
            }

            IRInst::AntiLess {
                left,
                right,
                target,
                signed,
            } => {
                self.lower_cmp(left, right, out);
                if *signed {
                    out.push(AsmInst::Bgs(target.clone()));
                } else {
                    out.push(AsmInst::Bgu(target.clone()));
                }
            }

            IRInst::InlineAsm(asm) => {
                for line in asm {
                    out.push(AsmInst::Inline(line.to_string()));
                }
            }

            IRInst::Div { .. } | IRInst::Mod { .. } => {
                panic!("Codegen Error: division and modulo aren't implemented yet")
            }

            IRInst::Pin { .. } => {}

            //So first 4 arguments go into 4 first registers depending on their size, rest are
            //spilled on the stack
            IRInst::Call {
                dest,
                name,
                args,
                stack_args,
            } => {
                let to_save = self
                    .call_saves
                    .get(&site)
                    .cloned()
                    .unwrap_or_default();
                for var in &to_save {
                    out.push(AsmInst::Push(self.operand_to_asm(var)));
                }

                let mut pending: Vec<(Register, AsmOperand)> = Vec::new();
                for (arg, reg_str) in args {
                    let target_reg = Self::parse_pin_register(reg_str);
                    if is_const(arg) {
                        load_const(target_reg, const_val(arg), out); // consts have no source-reg conflict
                    } else {
                        pending.push((target_reg, self.operand_to_asm(arg)));
                    }
                }

                //So it previosely moved variable to the argument registers not in the correct
                //order, because it isn't aware of cycles.
                //Thus fix is making it kinda aware of cycles.
                while !pending.is_empty() {
                    let is_source = |r: &Register| {
                        pending.iter().any(|(_, src)| matches!(src, AsmOperand::Reg(Reg::TheRealOne(sr)) if sr == r))
                    };

                    if let Some(idx) = pending.iter().position(|(t, _)| !is_source(t)) {
                        let (t, s) = pending.remove(idx);
                        if AsmOperand::Reg(Reg::TheRealOne(t)) != s {
                            out.push(AsmInst::Mov(reg_op(t), s, AsmOperand::Imm10(0)));
                        }
                    } else {
                        // pure cycle left: break it via rx30
                        let (t, s) = pending.remove(0);
                        out.push(AsmInst::Mov(rx30(), reg_op(t), AsmOperand::Imm10(0))); // save clobbered value
                        out.push(AsmInst::Mov(reg_op(t), s, AsmOperand::Imm10(0)));
                        // whoever was waiting on old `t`'s value now reads it from rx30
                        for (_, src) in pending.iter_mut() {
                            if matches!(src, AsmOperand::Reg(Reg::TheRealOne(sr)) if *sr == t) {
                                *src = rx30();
                            }
                        }
                    }
                }

                out.push(AsmInst::Call(name.clone()));

                if !stack_args.is_empty() {
                    out.push(AsmInst::SprLea(
                        reg_op(rx30_reg()),
                        Spr::SP,
                        AsmOperand::Imm16(0),
                    ));
                    out.push(AsmInst::SprAdd(
                        reg_op(rx30_reg()),
                        Spr::SP,
                        AsmOperand::Imm16((stack_args.len() * 4) as i16),
                    ));
                }

                if let Some(dest) = dest {
                    let dest_asm = self.operand_to_asm(dest);
                    if dest_asm != rx30() {
                        out.push(AsmInst::Mov(dest_asm, rx30(), AsmOperand::Imm10(0)));
                    }
                }

                for var in to_save.iter().rev() {
                    out.push(AsmInst::Pop(self.operand_to_asm(var)));
                }
            }

            //return returns to rx30 to matter what, though I do make sure next instruction moved
            //value out of rx30 bc its a scratch afterall
            IRInst::Return(val) => {
                if let Some(val) = val {
                    if is_const(val) {
                        load_const(rx30_reg(), const_val(val), out);
                    } else {
                        let val_asm = self.operand_to_asm(val);
                        if val_asm != rx30() {
                            out.push(AsmInst::Mov(rx30(), val_asm, AsmOperand::Imm10(0)));
                        }
                    }
                }

                if !self.is_leaf() {
                    out.push(AsmInst::Pop(reg_op(rx31_reg())));
                    out.push(AsmInst::SprSet(reg_op(rx31_reg()), Spr::LR));
                }

                if self.frame_size > 0 {
                    out.push(AsmInst::SprLea(
                        reg_op(rx31_reg()),
                        Spr::SP,
                        AsmOperand::Imm16(0),
                    ));
                    out.push(AsmInst::SprAdd(
                        reg_op(rx31_reg()),
                        Spr::SP,
                        AsmOperand::Imm16(self.frame_size as i16),
                    ));
                }

                out.push(AsmInst::Ret);
            }
        }
    }
}
