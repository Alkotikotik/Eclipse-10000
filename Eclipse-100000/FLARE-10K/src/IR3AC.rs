//3AC IR generator, again similar to parser, actually most of compiler parts are very similar
//I ocacsionally use "reduce" instead of "lower" because I think it sounds better, though sometimes
//still stick to lower
use crate::parser::{
    BinaryOpKind, Expr, FunctionSignature, MoreLess, Program, Stmt, StructDef, Type, UnaryOpKind,
};
use std::collections::HashMap;

//Alright so apparetenly HashSet randomizes every time proccess starts, that why my results were
//kinda random... Ord solves it though
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum IROperand {
    SignedConstant(i32),
    UnsignedConstant(u32),
    Var(String),
    Temp(usize),
    FrameSlot(usize),
    GlobalSlot(usize),
    IncomingArgSlot(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IRInst {
    Add {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    Sub {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    Mul {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    Div {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
        signed: bool,
    },
    Mod {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
        signed: bool,
    },
    Shl {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    Shr {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    Xor {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    Or {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },
    And {
        dest: IROperand,
        left: IROperand,
        right: IROperand,
    },

    Not {
        dest: IROperand,
        src: IROperand,
    },
    Negate {
        dest: IROperand,
        src: IROperand,
    },
    Cpy {
        dest: IROperand,
        src: IROperand,
    },
    Cast {
        dest: IROperand,
        src: IROperand,
        target_type: Type,
        src_type: Type,
    },

    LoadPtr {
        dest: IROperand,
        ptr_addr: IROperand,
    },
    StorePtr {
        ptr_addr: IROperand,
        src: IROperand,
    },

    RegFieldRead {
        //Fields of regarches are accessed using sub-registers, even though IR doesn't
        //know about it
        //Register fragmentation comes into play again
        dest: IROperand,
        struct_var: IROperand,
        byte_offset: usize,
        byte_size: usize,
    },
    RegFieldWrite {
        src: IROperand,
        struct_var: IROperand,
        byte_offset: usize,
        byte_size: usize,
    },

    AntiEqual {
        left: IROperand,
        right: IROperand,
        target: String,
    }, //Branch if false, so they are
    Equal {
        left: IROperand,
        right: IROperand,
        target: String,
    }, //Inverted AntiEqual becomes
    AntiMore {
        left: IROperand,
        right: IROperand,
        target: String,
        signed: bool,
        isEq: bool,
    }, //Branch if not equal
    AntiLess {
        left: IROperand,
        right: IROperand,
        target: String,
        signed: bool,
        isEq: bool,
    }, //Branch if more becomes branch
    //If less
    Label(String),
    JMP(String), //Jump if 1 == 1

    Call {
        dest: Option<IROperand>,
        name: String,
        args: Vec<(IROperand, String)>,
        stack_args: Vec<IROperand>,
    },
    Return(Option<IROperand>),
    InlineAsm(Vec<String>),
    Pin {
        var: String,
        register: String,
    },
    LocalAddr {
        dest: IROperand,
        offset: usize,
    },
    GlobalAddr {
        dest: IROperand,
        offset: usize,
    },
}

#[derive(Debug, Clone)]
pub struct IRFunction {
    pub name: String,
    pub params: Vec<(String, Type)>,
    pub var_types: HashMap<String, Type>,
    pub temp_types: HashMap<usize, Type>,
    pub body: Vec<IRInst>,
    pub local_frame_size: usize,
}

#[derive(Debug, Clone)]
pub struct IRProgram {
    pub globals: Vec<Expr>,
    pub functions: Vec<IRFunction>,
}

pub struct IR {
    insts_buffer: Vec<IRInst>,
    temp_counter: usize,
    temp_types: HashMap<usize, Type>,
    label_counter: usize,

    structs: HashMap<String, StructDef>,
    functions: HashMap<String, FunctionSignature>,
    var_types: HashMap<String, Type>,
    loop_exit_stack: Vec<String>,
    current_return_var: Option<String>,
    local_slots: HashMap<String, usize>,
    local_frame_size: usize,
}

pub fn get_type_align(ty: &Type, structs: &HashMap<String, StructDef>) -> usize {
    match ty {
        Type::U8 | Type::I8 | Type::Bool => 1,
        Type::U16 | Type::I16 => 2,
        Type::U32 | Type::I32 | Type::Ptr(_) => 4,
        Type::Array(elem_ty, _) => get_type_align(elem_ty, structs),
        Type::Struct(name) => {
            let struct_def = structs
                .get(name)
                .unwrap_or_else(|| panic!("Unknown struct type: {}", name));
            if struct_def.is_reg {
                4
            } else {
                struct_def
                    .fields
                    .iter()
                    .map(|f| get_type_align(&f.ty, structs))
                    .max()
                    .unwrap_or(1)
            }
        }
    }
}

pub fn get_type_size(ty: &Type, structs: &HashMap<String, StructDef>) -> usize {
    match ty {
        Type::U32 | Type::I32 | Type::Ptr(_) => 4,
        Type::U16 | Type::I16 => 2,
        Type::U8 | Type::I8 | Type::Bool => 1,
        Type::Array(elem_ty, count) => get_type_size(elem_ty, structs) * *count,
        Type::Struct(name) => {
            let struct_def = structs
                .get(name)
                .unwrap_or_else(|| panic!("Unknown struct type: {}", name));

            if struct_def.is_reg {
                struct_def
                    .fields
                    .iter()
                    .map(|f| get_type_size(&f.ty, structs))
                    .sum()
            } else {
                let mut current_offset = 0;
                let mut max_align = 1;

                for field in &struct_def.fields {
                    let field_align = get_type_align(&field.ty, structs);
                    if field_align > max_align {
                        max_align = field_align;
                    }
                    current_offset = align_to(current_offset, field_align);
                    current_offset += get_type_size(&field.ty, structs);
                }

                align_to(current_offset, max_align)
            }
        }
    }
}

pub enum ArgPlacement {
    Reg(String),
    Stack(usize),
}

pub fn classify_params(types: &[Type], structs: &HashMap<String, StructDef>) -> Vec<ArgPlacement> {
    let mut reg_slots: [[bool; 4]; 4] = [[false; 4]; 4];
    let mut stack_slot: usize = 0;
    let mut result = Vec::new();

    for ty in types {
        let by_reference = match ty {
            Type::Array(_, _) => true,
            Type::Struct(name) => !structs.get(name).map(|s| s.is_reg).unwrap_or(false),
            _ => false,
        };

        if by_reference {
            result.push(ArgPlacement::Stack(stack_slot));
            stack_slot += 1;
            continue;
        }

        let size = get_type_size(ty, structs);
        match find_arg_reg_slot(&mut reg_slots, size) {
            Some(reg_str) => result.push(ArgPlacement::Reg(reg_str)),
            None => {
                result.push(ArgPlacement::Stack(stack_slot));
                stack_slot += 1;
            }
        }
    }

    result
}

fn find_arg_reg_slot(slots: &mut [[bool; 4]; 4], size: usize) -> Option<String> {
    for reg_id in 0..4 {
        match size {
            1 => {
                for b in 0..4 {
                    if !slots[reg_id][b] {
                        slots[reg_id][b] = true;
                        return Some(format!("rz{}{}", reg_id, b));
                    }
                }
            }
            2 => {
                if !slots[reg_id][0] && !slots[reg_id][1] {
                    slots[reg_id][0] = true;
                    slots[reg_id][1] = true;
                    return Some(format!("ry{}0", reg_id));
                }
                if !slots[reg_id][2] && !slots[reg_id][3] {
                    slots[reg_id][2] = true;
                    slots[reg_id][3] = true;
                    return Some(format!("ry{}1", reg_id));
                }
            }
            _ => {
                if slots[reg_id].iter().all(|&used| !used) {
                    for b in 0..4 {
                        slots[reg_id][b] = true;
                    }
                    return Some(format!("rx{}", reg_id));
                }
            }
        }
    }
    None
}

fn expr_calls_function(expr: &Expr) -> bool {
    match expr {
        Expr::FunctionCall { .. } => true,
        Expr::Deref(inner) | Expr::Ref(inner) => expr_calls_function(inner),
        Expr::Unary { expr, .. } => expr_calls_function(expr),
        Expr::Cast { expr, .. } => expr_calls_function(expr),
        Expr::FieldAccess { expr, .. } => expr_calls_function(expr),
        Expr::Index { array, index } => expr_calls_function(array) || expr_calls_function(index),
        Expr::ArrayLiteral(elems) => elems.iter().any(expr_calls_function),
        Expr::Binary { left, right, .. } => expr_calls_function(left) || expr_calls_function(right),
        Expr::MoreLessEq { left, right, .. } => expr_calls_function(left) || expr_calls_function(right),
        Expr::Assign { lhs, rhs } => expr_calls_function(lhs) || expr_calls_function(rhs),
        Expr::VarDecl { initial, .. } => {
            initial.as_ref().map(|e| expr_calls_function(e)).unwrap_or(false)
        }
        _ => false,
    }
}

fn stmt_calls_function(stmt: &Stmt) -> bool {
    match stmt {
        Stmt::Expr(expr) => expr_calls_function(expr),
        Stmt::Return(Some(expr)) => expr_calls_function(expr),
        Stmt::For { init, cond, inc, body } => {
            expr_calls_function(init)
                || expr_calls_function(cond)
                || expr_calls_function(inc)
                || body.iter().any(stmt_calls_function)
        }
        Stmt::While { cond, body } => {
            expr_calls_function(cond) || body.iter().any(stmt_calls_function)
        }
        Stmt::IfElse { cond, main_branch, else_branch } => {
            expr_calls_function(cond)
                || main_branch.iter().any(stmt_calls_function)
                || else_branch
                    .as_ref()
                    .map(|b| b.iter().any(stmt_calls_function))
                    .unwrap_or(false)
        }
        _ => false,
    }
}

fn func_body_is_leaf(body: &[Stmt]) -> bool {
    !body.iter().any(stmt_calls_function)
}

//Helpers
impl IR {
    pub fn new(program: &Program) -> Self {
        let mut structs = HashMap::new();
        for s in &program.structs {
            structs.insert(s.name.clone(), s.clone());
        }

        let mut functions = HashMap::new();
        for f in &program.functions {
            functions.insert(f.name.clone(), f.clone());
        }

        Self {
            insts_buffer: Vec::new(),
            temp_counter: 0,
            temp_types: HashMap::new(),
            label_counter: 0,
            structs,
            functions,
            var_types: HashMap::new(),
            loop_exit_stack: Vec::new(),
            current_return_var: None,
            local_slots: HashMap::new(),
            local_frame_size: 0,
        }
    }
    pub fn new_temp(&mut self) -> IROperand {
        let buff = IROperand::Temp(self.temp_counter);
        self.temp_counter += 1;
        buff
    }
    fn new_temp_typed(&mut self, ty: Type) -> IROperand {
        let buff = self.new_temp();
        if let IROperand::Temp(id) = &buff {
            self.temp_types.insert(*id, ty);
        }
        buff
    }
    pub fn reset_temp(&mut self) {
        self.temp_counter = 0;
    }
    pub fn new_label(&mut self, prefix: &str) -> String {
        let buff = format!("~Lab_{}_{}", prefix, self.label_counter);
        self.label_counter += 1;
        buff
    }
    pub fn reset_labels(&mut self) {
        self.label_counter = 0;
    }
    pub fn emit(&mut self, inst: IRInst) {
        self.insts_buffer.push(inst);
    }

    //Theoretically should have done it in semantic but idc
    pub fn get_type_align(&self, ty: &Type) -> usize {
        get_type_align(ty, &self.structs)
    }

    //Calculate size based on padding and types
    pub fn get_type_size(&self, ty: &Type) -> usize {
        get_type_size(ty, &self.structs)
    }

    //Get offset of specific field
    pub fn get_field_offset(&self, struct_name: &str, target_field: &str) -> usize {
        let struct_def = self
            .structs
            .get(struct_name)
            .unwrap_or_else(|| panic!("Unknown struct: {}", struct_name));

        let mut offset = 0;
        for field in &struct_def.fields {
            if !struct_def.is_reg {
                let field_align = self.get_type_align(&field.ty);
                offset = align_to(offset, field_align);
            }

            if field.name == target_field {
                return offset;
            }
            offset += self.get_type_size(&field.ty);
        }
        panic!(
            "Field {} not found in the struct {}",
            target_field, struct_name
        );
    }

    //For field access
    fn infer_type(&self, expr: &Expr) -> Type {
        match expr {
            Expr::IntLiteral(_) => Type::I32,
            Expr::HexLiteral(_) => Type::U32,
            Expr::Identifier(name) => self
                .var_types
                .get(name)
                .cloned()
                .unwrap_or_else(|| panic!("Unknown variable {}", name)),

            Expr::Deref(inner) => {
                let inner_ty = self.infer_type(inner);
                match inner_ty {
                    Type::Ptr(target_ty) => *target_ty,
                    Type::U32 | Type::U16 | Type::U8 => Type::U32,
                    Type::Struct(s) => Type::Struct(s),
                    _ => panic!("Cannot dereference type {:?}", inner_ty),
                }
            }

            Expr::Index { array, .. } => {
                let array_ty = self.infer_type(array);
                match array_ty {
                    Type::Array(elem_ty, _) => *elem_ty,
                    Type::Ptr(elem_ty) => *elem_ty,
                    _ => panic!("Cannot index type {:?}", array_ty),
                }
            }

            Expr::FieldAccess { expr, field } => {
                let parent_ty = self.infer_type(expr);
                if let Type::Struct(struct_name) = parent_ty {
                    let s_def = &self.structs[&struct_name];
                    let f_def = s_def.fields.iter().find(|f| f.name == *field).unwrap();
                    f_def.ty.clone()
                } else {
                    panic!("Field access on non-struct type {:?}", parent_ty); //Theoretically
                    //unreachable but who knows
                }
            }
            Expr::Binary { left, op, .. } => {
                if matches!(op, BinaryOpKind::Shl) {
                    match self.infer_type(left) {
                        Type::I8 | Type::I16 | Type::I32 => Type::I32,
                        _ => Type::U32,
                    }
                } else {
                    self.infer_type(left)
                }
            }
            Expr::Unary { expr, .. } => self.infer_type(expr),
            Expr::Cast { target_type, .. } => target_type.clone(),
            Expr::Ref(inner) => {
                let inner_ty = self.infer_type(inner);
                Type::Ptr(Box::new(inner_ty))
            }
            Expr::FunctionCall { name, .. } => self
                .functions
                .get(name)
                .unwrap_or_else(|| panic!("Unknown function {}", name))
                .to_return
                .clone()
                .unwrap_or(Type::U32),
            _ => panic!("Error expression in infer_type: {:?}", expr),
        }
    }
}

impl IR {
    fn reduce_call_args(&mut self, name: &str, args: &[Expr]) -> (Vec<(IROperand, String)>, Vec<IROperand>) {
        let func_sig = self
            .functions
            .get(name)
            .unwrap_or_else(|| panic!("Unknown function {}", name))
            .clone();
        let arg_types: Vec<Type> = func_sig.params.iter().map(|p| p.ty.clone()).collect();
        let placements = classify_params(&arg_types, &self.structs);

        let mut reg_args = Vec::new();
        let mut stack_words: Vec<(usize, IROperand)> = Vec::new();

        for ((arg_expr, placement), param) in args
            .iter()
            .zip(placements.iter())
            .zip(func_sig.params.iter())
        {
            let by_reference = match &param.ty {
                Type::Array(_, _) => true,
                Type::Struct(sname) => !self.structs.get(sname).map(|s| s.is_reg).unwrap_or(false),
                _ => false,
            };
            match placement {
                ArgPlacement::Reg(reg_str) => {
                    reg_args.push((self.reduce_expr(arg_expr), reg_str.clone()));
                }
                ArgPlacement::Stack(slot) if by_reference => {
                    let addr = self.lower_lvalue(arg_expr);
                    stack_words.push((*slot, addr));
                }
                ArgPlacement::Stack(slot) => {
                    stack_words.push((*slot, self.reduce_expr(arg_expr)));
                }
            }
        }

        stack_words.sort_by_key(|(slot, _)| *slot);
        let stack_args = stack_words.into_iter().map(|(_, op)| op).collect();
        (reg_args, stack_args)
    }

    fn reduce_expr(&mut self, expr: &Expr) -> IROperand {
        match expr {
            Expr::IntLiteral(a) => IROperand::SignedConstant(*a),
            Expr::HexLiteral(b) => IROperand::UnsignedConstant(*b),
            Expr::Identifier(name) => IROperand::Var(name.clone()),

            Expr::Deref(mem) => {
                let result_ty = self.infer_type(expr);
                let ptr_addr = self.reduce_expr(mem);
                let dest = self.new_temp_typed(result_ty);
                self.emit(IRInst::LoadPtr {
                    dest: dest.clone(),
                    ptr_addr,
                });
                dest
            }

            Expr::Ref(mem) => self.lower_lvalue(mem),

            Expr::Index {array, index} => {
                let result_ty = self.infer_type(expr);
                let addr = self.compute_index_addr(array, index);
                let dest = self.new_temp_typed(result_ty);
                self.emit(IRInst::LoadPtr {
                    dest: dest.clone(),
                    ptr_addr: addr,
                });
                dest
            }

            Expr::FunctionCall {name, args} => {
                let result_ty = self.infer_type(expr);
                let dest = self.new_temp_typed(result_ty);
                let (reg_args, stack_args) = self.reduce_call_args(name, args);

                self.emit(IRInst::Call {
                    dest: Some(dest.clone()),
                    name: name.clone(),
                    args: reg_args,
                    stack_args,
                });

                dest
            }

            Expr::Cast {expr, target_type} => {
                let src_type = self.infer_type(expr);
                let dest = self.new_temp_typed(target_type.clone());
                let src = self.reduce_expr(expr);
                self.emit(IRInst::Cast {
                    dest: dest.clone(),
                    src,
                    target_type: target_type.clone(),
                    src_type,
                });
                dest
            }

            Expr::Unary {op, expr} => {
                let result_ty = self.infer_type(expr);
                let dest = self.new_temp_typed(result_ty);
                let src = self.reduce_expr(expr);
                let inst = match op {
                    UnaryOpKind::Not => IRInst::Not {
                        dest: dest.clone(),
                        src,
                    },
                    UnaryOpKind::Negate => IRInst::Negate {
                        dest: dest.clone(),
                        src,
                    },
                };
                self.emit(inst);
                dest
            }

            Expr::Binary {left, op, right} => {
                //Just future proofing
                if matches!(op, BinaryOpKind::Div | BinaryOpKind::Mod) {
                    let left_ty = self.infer_type(left);
                    let right_ty = self.infer_type(right);
                    let is_signed =
                        left_ty == right_ty && matches!(left_ty, Type::I32 | Type::I16 | Type::I8);

                    let l_op = self.reduce_expr(left);
                    let r_op = self.reduce_expr(right);
                    let dest = self.new_temp_typed(left_ty.clone());

                    let inst = if matches!(op, BinaryOpKind::Div) {
                        IRInst::Div {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                            signed: is_signed,
                        }
                    } else {
                        IRInst::Mod {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                            signed: is_signed,
                        }
                    };
                    self.emit(inst);
                    dest
                } else {
                    let left_ty = self.infer_type(left);
                    let l_op = self.reduce_expr(left);
                    let r_op = self.reduce_expr(right);
                    let dest_ty = if matches!(op, BinaryOpKind::Shl) {
                        match left_ty {
                            Type::I8 | Type::I16 | Type::I32 => Type::I32,
                            _ => Type::U32,
                        }
                    } else {
                        left_ty
                    };
                    let dest = self.new_temp_typed(dest_ty);

                    let inst = match op {
                        BinaryOpKind::Add => IRInst::Add {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::Sub => IRInst::Sub {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::Mul => IRInst::Mul {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::Shl => IRInst::Shl {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::Shr => IRInst::Shr {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::BitwiseAnd => IRInst::And {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::BitwiseOr => IRInst::Or {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::BitwiseXor => IRInst::Xor {
                            dest: dest.clone(),
                            left: l_op,
                            right: r_op,
                        },
                        BinaryOpKind::Div | BinaryOpKind::Mod => unreachable!(),
                    };
                    self.emit(inst);
                    dest
                }
            }

            Expr::Assign { lhs, rhs } => {
                let r_op = self.reduce_expr(rhs);
                match lhs.as_ref() {
                    Expr::Identifier(name) => {
                        //Just assign
                        self.emit(IRInst::Cpy {
                            dest: IROperand::Var(name.clone()),
                            src: r_op.clone(),
                        });
                        r_op
                    }
                    Expr::FieldAccess { expr: base, field } => {
                        if let Type::Struct(struct_name) = self.infer_type(base) {
                            if self.structs[&struct_name].is_reg {
                                let offset = self.get_field_offset(&struct_name, field);
                                let field_ty = self.structs[&struct_name]
                                    .fields
                                    .iter()
                                    .find(|f| &f.name == field)
                                    .unwrap()
                                    .ty
                                    .clone();
                                let size = self.get_type_size(&field_ty);
                                let struct_var = self.lower_lvalue(base);
                                self.emit(IRInst::RegFieldWrite {
                                    struct_var,
                                    byte_offset: offset,
                                    byte_size: size,
                                    src: r_op.clone(),
                                });
                                return r_op;
                            }
                        }
                        let ptr_op = self.lower_lvalue(lhs);
                        self.emit(IRInst::StorePtr {
                            ptr_addr: ptr_op,
                            src: r_op.clone(),
                        });
                        r_op
                    }
                    _ => {
                        // Memory location, deref etc
                        let ptr_op = self.lower_lvalue(lhs);
                        self.emit(IRInst::StorePtr {
                            ptr_addr: ptr_op,
                            src: r_op.clone(),
                        });
                        r_op
                    }
                }
            }
            //No MoreLessEq bc without cmp just isn't worth it and i still never use something like
            //a = b<c, nontheless I can still use if to achieve same functionality
            Expr::VarDecl {
                ty,
                name,
                initial,
                pin,
            } => {
                self.var_types.insert(name.clone(), ty.clone());

                if let Some(reg) = pin {
                    self.emit(IRInst::Pin {
                        var: name.clone(),
                        register: reg.clone(),
                    });
                }

                let is_local_struct = matches!(ty, Type::Struct(sname) if !self.structs[sname].is_reg);

                match ty {
                    Type::Array(elem_ty, count) => {
                        let elem_size = self.get_type_size(elem_ty);
                        let elem_align = self.get_type_align(elem_ty);
                        let slot_size = elem_size * count;
                        let offset = align_to(self.local_frame_size, elem_align);
                        self.local_frame_size = offset + slot_size;
                        self.local_slots.insert(name.clone(), offset);

                        if let Some(init_expr) = initial {
                            if let Expr::ArrayLiteral(elems) = &**init_expr {
                                for (i, elem_expr) in elems.iter().enumerate() {
                                    let val_op = self.reduce_expr(elem_expr);
                                    self.emit(IRInst::StorePtr {
                                        ptr_addr: IROperand::FrameSlot(offset + i * elem_size),
                                        src: val_op,
                                    });
                                }
                            }
                        } else {
                            for i in 0..*count {
                                self.emit(IRInst::StorePtr {
                                    ptr_addr: IROperand::FrameSlot(offset + i * elem_size),
                                    src: IROperand::SignedConstant(0),
                                });
                            }
                        }
                    }
                    Type::Struct(_) if is_local_struct => {
                        let size = self.get_type_size(ty);
                        let align = self.get_type_align(ty);
                        let offset = align_to(self.local_frame_size, align);
                        self.local_frame_size = offset + size;
                        self.local_slots.insert(name.clone(), offset);
                    }
                    _ => {
                        if let Some(init_expr) = initial {
                            let init_op = self.reduce_expr(init_expr);
                            self.emit(IRInst::Cpy { dest: IROperand::Var(name.clone()), src: init_op });
                        } else {
                            self.emit(IRInst::Cpy {
                                dest: IROperand::Var(name.clone()),
                                src: IROperand::SignedConstant(0),
                            });
                        }
                    }
                }
                IROperand::Var(name.clone())
            }

            Expr::FieldAccess { expr: base, field } => {
                if let Type::Struct(struct_name) = self.infer_type(base) {
                    if self.structs[&struct_name].is_reg {
                        let offset = self.get_field_offset(&struct_name, field);
                        let field_ty = self.structs[&struct_name]
                            .fields
                            .iter()
                            .find(|f| &f.name == field)
                            .unwrap()
                            .ty
                            .clone();
                        let size = self.get_type_size(&field_ty);
                        let struct_var = self.lower_lvalue(base);
                        let dest = self.new_temp_typed(field_ty);
                        self.emit(IRInst::RegFieldRead {
                            dest: dest.clone(),
                            struct_var,
                            byte_offset: offset,
                            byte_size: size,
                        });
                        return dest;
                    }
                }
                let result_ty = self.infer_type(expr);
                let addr = self.lower_lvalue(expr);
                let dest = self.new_temp_typed(result_ty);
                self.emit(IRInst::LoadPtr {
                    dest: dest.clone(),
                    ptr_addr: addr,
                });
                dest
            }
            _ => panic!("Unsupported expression format"),
        }
    }

    fn reduce_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::Expr(expr) => {
                match expr {
                    //Function with no dest
                    Expr::FunctionCall { name, args } => {
                        let (reg_args, stack_args) = self.reduce_call_args(name, args);

                        self.emit(IRInst::Call {
                            dest: None,
                            name: name.clone(),
                            args: reg_args,
                            stack_args,
                        });
                    }
                    _ => {
                        self.reduce_expr(expr);
                    } //In any other case
                }
            }
            Stmt::Return(expr) => {
                let ret_val = match expr {
                    Some(e) => Some(self.reduce_expr(e)),
                    None => self
                        .current_return_var
                        .as_ref()
                        .map(|n| IROperand::Var(n.clone())),
                };
                self.emit(IRInst::Return(ret_val));
            }
            Stmt::For {
                init,
                cond,
                inc,
                body,
            } => {
                let start_label = self.new_label("for_start");
                let end_label = self.new_label("for_end");

                self.reduce_expr(init);
                self.emit(IRInst::Label(start_label.clone()));

                self.reduce_cond(cond, end_label.clone());

                //For break
                self.loop_exit_stack.push(end_label.clone());

                for stmt in body {
                    self.reduce_stmt(stmt);
                }
                self.loop_exit_stack.pop();
                self.reduce_expr(inc);

                self.emit(IRInst::JMP(start_label));
                self.emit(IRInst::Label(end_label));
            }

            Stmt::While { cond, body } => {
                let start_label = self.new_label("while_start");
                let end_label = self.new_label("while_end");

                let always_true = matches!(cond, Expr::IntLiteral(n) if *n != 0)
                    || matches!(cond, Expr::HexLiteral(n) if *n != 0);

                self.emit(IRInst::Label(start_label.clone()));

                if !always_true {
                    //Jump past if false
                    self.reduce_cond(cond, end_label.clone());
                }

                //For breaks
                self.loop_exit_stack.push(end_label.clone());

                for stmt in body {
                    self.reduce_stmt(stmt);
                }

                self.loop_exit_stack.pop();

                self.emit(IRInst::JMP(start_label));
                self.emit(IRInst::Label(end_label));
            }
            Stmt::IfElse {
                cond,
                main_branch,
                else_branch,
            } => {
                let else_label = self.new_label("else");
                let end_label = self.new_label("endif");

                //If false jump to else
                let target_label = if else_branch.is_some() {
                    else_label.clone()
                } else {
                    end_label.clone()
                };
                self.reduce_cond(cond, target_label);

                for stmt in main_branch {
                    self.reduce_stmt(stmt);
                }

                //If there is else branch jump past it if "if" was true
                if let Some(else_stmts) = else_branch {
                    self.emit(IRInst::JMP(end_label.clone()));
                    self.emit(IRInst::Label(else_label));

                    for stmt in else_stmts {
                        self.reduce_stmt(stmt);
                    }
                }
                self.emit(IRInst::Label(end_label));
            }
            Stmt::Break => {
                if let Some(target) = self.loop_exit_stack.last() {
                    self.emit(IRInst::JMP(target.clone()));
                } else {
                    panic!("Break outside valid scope");
                }
            }
            Stmt::InlineAsm(block) => {
                let lines = block.lines().map(|s| s.trim().to_string()).collect();
                self.emit(IRInst::InlineAsm(lines));
            }
        }
    }

    pub fn reduce_everything(&mut self, program: &Program) -> IRProgram {
        let mut ir_globals: Vec<Expr> = Vec::new();
        for global in &program.globals {
            if let Expr::VarDecl { ty, name, .. } = &global.decl {
                self.var_types.insert(name.clone(), ty.clone());
            }
            ir_globals.push(global.decl.clone());
        }

        let mut ir_funcs = Vec::new();
        for func in &program.functions {
            let ir_func = self.reduce_func(func);
            ir_funcs.push(ir_func);
        }

        IRProgram {
            globals: ir_globals,
            functions: ir_funcs,
        }
    }

    fn reduce_func(&mut self, func: &FunctionSignature) -> IRFunction {
        self.insts_buffer.clear();
        self.reset_temp();
        self.temp_types.clear();
        self.local_slots.clear();
        self.local_frame_size = 0;
        self.current_return_var = func.return_name.clone();

        self.emit(IRInst::Label(format!("~{}", func.name)));

        let mut param_names = Vec::new();
        let mut param_types = Vec::new();
        for param in &func.params {
            self.var_types.insert(param.name.clone(), param.ty.clone());
            param_names.push(param.name.clone());
            param_types.push(param.ty.clone());
        }

        let leaf = func_body_is_leaf(&func.body);

        let placements = classify_params(&param_types, &self.structs);
        for (param, placement) in func.params.iter().zip(placements.iter()) {
            match placement {
                ArgPlacement::Reg(reg_str) => {
                    if leaf {
                        self.emit(IRInst::Pin {
                            var: param.name.clone(),
                            register: reg_str.clone(),
                        });
                    } else {
                        let arg_name = format!("__arg_{}", reg_str);
                        self.emit(IRInst::Pin {
                            var: arg_name.clone(),
                            register: reg_str.clone(),
                        });
                        self.emit(IRInst::Cpy {
                            dest: IROperand::Var(param.name.clone()),
                            src: IROperand::Var(arg_name),
                        });
                    }
                }
                ArgPlacement::Stack(slot) => {
                    self.emit(IRInst::LoadPtr {
                        dest: IROperand::Var(param.name.clone()),
                        ptr_addr: IROperand::IncomingArgSlot(*slot),
                    });
                }
            }
        }

        if let (Some(ret_name), Some(ret_ty)) = (&func.return_name, &func.to_return) {
            self.var_types.insert(ret_name.clone(), ret_ty.clone());
            self.emit(IRInst::Cpy {
                dest: IROperand::Var(ret_name.clone()),
                src: IROperand::SignedConstant(0),
            });
            if let Some(reg) = &func.return_pin {
                self.emit(IRInst::Pin {
                    var: ret_name.clone(),
                    register: reg.clone(),
                });
            }
        }

        for stmt in &func.body {
            self.reduce_stmt(stmt);
        }

        let is_def_ret_needed = match self.insts_buffer.last() {
            Some(IRInst::Return(_)) => false,
            _ => true,
        };

        if is_def_ret_needed {
            let implicit_ret = self
                .current_return_var
                .as_ref()
                .map(|n| IROperand::Var(n.clone()));
            self.emit(IRInst::Return(implicit_ret));
        }

        IRFunction {
            name: func.name.clone(),
            params: param_names
                .into_iter()
                .zip(param_types.into_iter())
                .collect(),
            var_types: self.var_types.clone(),
            temp_types: self.temp_types.clone(),
            body: self.insts_buffer.clone(),
            local_frame_size: self.local_frame_size,
        }
    }

    fn reduce_cond(&mut self, expr: &Expr, false_label: String) {
        match expr {
            Expr::MoreLessEq { left, op, right } => {
                let l_op = self.reduce_expr(left);
                let r_op = self.reduce_expr(right);

                let left_ty = self.infer_type(left);
                let right_ty = self.infer_type(right);
                let is_signed =
                    left_ty == right_ty && matches!(left_ty, Type::I32 | Type::I16 | Type::I8);
                let inst = match op {
                    MoreLess::Eq => IRInst::Equal {
                        left: l_op,
                        right: r_op,
                        target: false_label,
                    },
                    MoreLess::NotEq => IRInst::AntiEqual {
                        left: l_op,
                        right: r_op,
                        target: false_label,
                    },
                    MoreLess::More(is_eq) => IRInst::AntiMore {
                        left: l_op,
                        right: r_op,
                        target: false_label,
                        signed: is_signed,
                        isEq: *is_eq,
                    },
                    MoreLess::Less(is_eq) => IRInst::AntiLess {
                        left: l_op,
                        right: r_op,
                        target: false_label,
                        signed: is_signed,
                        isEq: *is_eq,
                    },
                };
                self.emit(inst);
            }
            _ => {
                // For like "while [1]{}" or "if [c]{}"
                let cond_op = self.reduce_expr(expr);
                self.emit(IRInst::AntiEqual {
                    left: cond_op,
                    right: IROperand::SignedConstant(0),
                    target: false_label,
                });
            }
        }
    }

    fn lower_lvalue(&mut self, expr: &Expr) -> IROperand {
        match expr {
            Expr::Identifier(name) => {
                if let Some(&offset) = self.local_slots.get(name) {
                    let dest = self.new_temp();
                    self.emit(IRInst::LocalAddr {
                        dest: dest.clone(),
                        offset,
                    });
                    dest
                } else {
                    IROperand::Var(name.clone())
                }
            }

            Expr::Deref(ptr_expr) => self.reduce_expr(ptr_expr),

            Expr::Index { array, index } => self.compute_index_addr(array, index),

            Expr::FieldAccess { expr, field } => {
                let parent_type = self.infer_type(expr);
                let struct_name = match parent_type {
                    Type::Struct(name) => name,
                    _ => panic!("Field access on non-struct"),
                };
                let offset = self.get_field_offset(&struct_name, field);

                match expr.as_ref() {
                    Expr::Deref(ptr_expr) => {
                        let base_addr = self.reduce_expr(ptr_expr);
                        if offset == 0 {
                            base_addr
                        } else {
                            let dest = self.new_temp();
                            self.emit(IRInst::Add {
                                dest: dest.clone(),
                                left: base_addr,
                                right: IROperand::UnsignedConstant(offset as u32),
                            });
                            dest
                        }
                    }
                    _ => {
                        let base_addr = self.lower_lvalue(expr);
                        let dest = self.new_temp();
                        self.emit(IRInst::Add {
                            dest: dest.clone(),
                            left: base_addr,
                            right: IROperand::UnsignedConstant(offset as u32),
                        });
                        dest
                    }
                }
            }
            _ => panic!("Invalid l-value"),
        }
    }

    fn compute_index_addr(&mut self, array: &Expr, index: &Expr) -> IROperand {
        let array_ty = self.infer_type(array);
        let (elem_ty, base_addr) = match array_ty {
            Type::Array(elem_ty, _) => (*elem_ty, self.lower_lvalue(array)),
            Type::Ptr(elem_ty) => (*elem_ty, self.reduce_expr(array)),
            other => panic!("Cannot index into type {:?}", other),
        };

        let elem_size = self.get_type_size(&elem_ty);
        let index_op = self.reduce_expr(index);

        if elem_size == 1 {
            let addr = self.new_temp();
            self.emit(IRInst::Add {
                dest: addr.clone(),
                left: base_addr,
                right: index_op,
            });
            addr
        } else {
            let offset = self.new_temp();
            self.emit(IRInst::Mul {
                dest: offset.clone(),
                left: index_op,
                right: IROperand::UnsignedConstant(elem_size as u32),
            });
            let addr = self.new_temp();
            self.emit(IRInst::Add {
                dest: addr.clone(),
                left: base_addr,
                right: offset,
            });
            addr
        }
    }
}

#[inline] //Didn't know rust had inlines until now
pub fn align_to(offset: usize, align: usize) -> usize {
    if align == 0 {
        return offset;
    }
    (offset + align - 1) & !(align - 1)
}
