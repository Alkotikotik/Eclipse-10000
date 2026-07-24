//3AC IR generator, again similar to parser, actually most of compiler parts are very similar
use crate::parser::{Program, FunctionSignature, StructDef, Stmt, Expr, Type, MoreLess, BinaryOpKind, UnaryOpKind};
use std::collections::HashMap;

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
    SignedConstant(i32),
    UnsignedConstant(u32),
    Var(String),
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

    Not { dest: IROperand, src: IROperand },
    Negate { dest: IROperand, src: IROperand},
    Cpy { dest: IROperand, src: IROperand },
    Cast { dest: IROperand, src: IROperand, target_type: Type },

    LoadPtr  { dest: IROperand, ptr_addr: IROperand },
    StorePtr { ptr_addr: IROperand, src: IROperand },

    AntiEqual { left: IROperand, right: IROperand, label: String }, //Branch if false, so they are
    Equal     { left: IROperand, right: IROperand, label: String }, //Inverted AntiEqual becomes
    AntiMore  { left: IROperand, right: IROperand, label: String, signed: bool }, //Branch if not equal 
    AntiLess  { left: IROperand, right: IROperand, label: String, signed: bool }, //Branch if more becomes branch
                                                                                  //If less
    Label(String),
    JMP(String), //Jump if 1 == 1

    Call { dest: Option<IROperand>, name: String, args: Vec<IROperand> },
    Return(Option<IROperand>),
    InlineAsm(Vec<String>),
}

#[derive(Debug, Clone)]
pub struct IRFunction {
    pub name: String,
    pub params: Vec<String>,
    pub body: Vec<IRInst>,
}

#[derive(Debug, Clone)]
pub struct IRProgram {
    pub globals: Vec<Expr>,
    pub functions: Vec<IRFunction>,
}

pub struct IR {
    insts_buffer: Vec<IRInst>,
    temp_counter: usize,
    label_counter: usize,

    structs: HashMap<String, StructDef>,
    var_types: HashMap<String, Type>,
    loop_exit_stack: Vec<String>,
}

//Helpers
impl IR {
    pub fn new(program: &Program) -> Self {
        let mut structs = HashMap::new();
        for s in &program.structs {
            structs.insert(s.name.clone(), s.clone());
        }

        Self {
            insts_buffer: Vec::new(),
            temp_counter: 0,
            label_counter: 0,
            structs,
            var_types: HashMap::new(),
            loop_exit_stack: Vec::new(),
        }
    }
    pub fn new_temp(&mut self) -> IROperand {
        let buff = IROperand::Temp(self.temp_counter);
        self.temp_counter += 1;
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
        match ty {
            Type::U8  | Type::I8 | Type::Bool => 1,
            Type::U16 | Type::I16 => 2,
            Type::U32 | Type::I32 | Type::Ptr(_) => 4,
            Type::Struct(name) => {
                let struct_def = self.structs.get(name)
                    .unwrap_or_else(|| panic!("Unknown struct type: {}", name));
                struct_def.fields.iter()
                    .map(|f| self.get_type_align(&f.ty))
                    .max()
                    .unwrap_or(1)
            }
        }
    }

    //Calculate size based on padding and types
    pub fn get_type_size(&self, ty: &Type) -> usize {
        match ty {
            Type::U32 | Type::I32 | Type::Ptr(_) => 4,
            Type::U16 | Type::I16 => 2,
            Type::U8  | Type::I8 | Type::Bool => 1,
            Type::Struct(name) => {
                let struct_def = self.structs.get(name)
                    .unwrap_or_else(|| panic!("Unknown struct type: {}", name));

                let mut current_offset = 0;
                let mut max_align = 1;

                for field in &struct_def.fields {
                    let field_align = self.get_type_align(&field.ty);
                    if field_align > max_align {
                        max_align = field_align;
                    }
                    current_offset = align_to(current_offset, field_align);
                    current_offset += self.get_type_size(&field.ty);
                }

                align_to(current_offset, max_align)
            }
        }
    }
    
    //Get offset of specific field
    pub fn get_field_offset(&self, struct_name: &str, target_field: &str) -> usize {
        let struct_def = self.structs.get(struct_name)
            .unwrap_or_else(|| panic!("Unknown struct: {}", struct_name));

        let mut offset = 0;
        for field in &struct_def.fields {
            let field_align = self.get_type_align(&field.ty);
            offset = align_to(offset, field_align);

            if field.name == target_field {
                return offset;
            }
            offset += self.get_type_size(&field.ty);
        }
        panic!("Field {} not found in the struct {}", target_field, struct_name);
    }

    //For field access
    fn infer_type(&self, expr: &Expr) -> Type {
        match expr {
            Expr::IntLiteral(_) => Type::I32,
            Expr::HexLiteral(_) => Type::U32,
            Expr::Identifier(name) => self.var_types.get(name).cloned()
                .unwrap_or_else(|| panic!("Unknown variable {}", name)),

            Expr::Deref(inner) => {
                let inner_ty = self.infer_type(inner);
                match inner_ty {
                    Type::Ptr(target_ty) => *target_ty,
                    Type::U32 | Type::U16 | Type::U8 => Type::U32,
                    Type::Struct(s) => Type::Struct(s),
                    _ => panic!("Cannot dereference type {:?}", inner_ty),
                }
            },

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
            },
            _ => panic!("Error expression in infer_type: {:?}", expr),
        }
    }
}

impl IR {
    fn reduce_expr(&mut self, expr: &Expr) -> IROperand {
        match expr {
            Expr::IntLiteral(a) => IROperand::SignedConstant(*a),
            Expr::HexLiteral(b) => IROperand::UnsignedConstant(*b),
            Expr::Identifier(name) => IROperand::Var(name.clone()),

            Expr::Deref(mem) => {
                let ptr_addr = self.reduce_expr(mem);
                let dest = self.new_temp();
                self.emit(IRInst::LoadPtr { 
                    dest: dest.clone(),
                    ptr_addr
                });
                dest
            }

            Expr::Ref(mem) => {
                self.lower_lvalue(mem)
            }

            Expr::FunctionCall {name, args} => {
                let dest = self.new_temp();
                let mut reduced_args = Vec::new();

                for arg in args {
                    reduced_args.push(self.reduce_expr(arg));
                }

                self.emit(IRInst::Call {
                    dest: Some(dest.clone()),
                    name: name.clone(),
                    args: reduced_args,
                });

                dest
            }

            Expr::Cast { expr, target_type } => {
                let dest = self.new_temp();
                let src = self.reduce_expr(expr);
                self.emit(IRInst::Cast {
                    dest: dest.clone(),
                    src,
                    target_type: target_type.clone(),
                });
                dest
            }

            Expr::Unary { op, expr } => {
                let dest = self.new_temp();
                let src = self.reduce_expr(expr);
                let inst = match op {
                    UnaryOpKind::Not => IRInst::Not { dest: dest.clone(), src },
                    UnaryOpKind::Negate => IRInst::Negate { dest: dest.clone(), src },
                };
                self.emit(inst);
                dest
            }

            Expr::Binary {left, op, right} => {
                let l_op = self.reduce_expr(left);
                let r_op = self.reduce_expr(right);
                let dest = self.new_temp();

                let inst = match op {
                    BinaryOpKind::Add => IRInst::Add { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::Sub => IRInst::Sub { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::Mul => IRInst::Mul { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::Shl => IRInst::Shl { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::Shr => IRInst::Shr { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::BitwiseAnd => IRInst::And { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::BitwiseOr  => IRInst::Or  { dest: dest.clone(), left: l_op, right: r_op },
                    BinaryOpKind::BitwiseXor => IRInst::Xor { dest: dest.clone(), left: l_op, right: r_op },
                    _ => panic!("Division isn't implemented yet"),
                };
                self.emit(inst);
                dest
            }

            Expr::Assign {lhs, rhs} => {
                let r_op = self.reduce_expr(rhs);
                match lhs.as_ref() {
                    Expr::Identifier(name) => { //Just assign
                        self.emit(IRInst::Cpy {
                            dest: IROperand::Var(name.clone()),
                            src: r_op.clone() 
                        });
                        r_op
                    }
                    _ => { // Memory location, deref etc
                        let ptr_op = self.lower_lvalue(lhs);
                        self.emit(IRInst::StorePtr { ptr_addr: ptr_op, src: r_op.clone() });
                        r_op
                    }
                }
            }
            //No MoreLessEq bc without cmp just isn't worth it and i still never use something like
            //a = b<c, nontheless I can still use if to achieve same functionality
            Expr::VarDecl { ty, name, initial } => {
                self.var_types.insert(name.clone(), ty.clone());

                if let Some(init_expr) = initial {
                    let init_op = self.reduce_expr(init_expr);
                    self.emit(IRInst::Cpy {
                        dest: IROperand::Var(name.clone()),
                        src: init_op,
                    });
                }
                IROperand::Var(name.clone())
            }

            Expr::FieldAccess {expr, ..} => {
                let addr = self.lower_lvalue(expr);
                let dest = self.new_temp();
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
                    Expr::FunctionCall {name, args} => {
                        let mut reduced_args = Vec::new();
                        for arg in args {
                            reduced_args.push(self.reduce_expr(arg));
                        }

                        self.emit(IRInst::Call {
                            dest: None,
                            name: name.clone(),
                            args: reduced_args,
                        });
                    }
                    _ => { self.reduce_expr(expr); } //In any other case
                }
            }
            Stmt::Return(expr) => {
                let ret_val = expr.as_ref().map(|a| self.reduce_expr(a));
                self.emit(IRInst::Return(ret_val));
            }
            Stmt::For{init, cond, inc, body} => {
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

            Stmt::While {cond, body} => {
                let start_label = self.new_label("while_start");
                let end_label = self.new_label("while_end");

                self.emit(IRInst::Label(start_label.clone()));
                //Jump past if false
                self.reduce_cond(cond, end_label.clone());

                //For breaks
                self.loop_exit_stack.push(end_label.clone());

                for stmt in body {
                    self.reduce_stmt(stmt);
                }

                self.loop_exit_stack.pop();

                self.emit(IRInst::JMP(start_label));
                self.emit(IRInst::Label(end_label));
            }
            Stmt::IfElse {cond, main_branch, else_branch} => {
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

        self.emit(IRInst::Label(func.name.clone()));

        let mut param_names = Vec::new();
        for param in &func.params { //Params are basically just regular vars in 3AC
            self.var_types.insert(param.name.clone(), param.ty.clone());
            param_names.push(param.name.clone());
        }

        for stmt in &func.body {
            self.reduce_stmt(stmt);
        }

        let is_def_ret_needed = match self.insts_buffer.last() {
            Some(IRInst::Return(_)) => false,
            _ => true,
        };

        if is_def_ret_needed {
            self.emit(IRInst::Return(None));
        }

        IRFunction {
            name: func.name.clone(),
            params: param_names,
            body: self.insts_buffer.clone(),
        }

    }

    fn reduce_cond(&mut self, expr: &Expr, false_label: String) {
        match expr {
            Expr::MoreLessEq { left, op, right } => {
                let l_op = self.reduce_expr(left);
                let r_op = self.reduce_expr(right);

                let left_ty = self.infer_type(left);
                let right_ty = self.infer_type(right);
                let is_signed = left_ty == right_ty && matches!(left_ty, Type::I32 | Type::I16 | Type::I8);
                let inst = match op {
                    MoreLess::Eq    => IRInst::AntiEqual { left: l_op, right: r_op, label: false_label },
                    MoreLess::NotEq => IRInst::Equal     { left: l_op, right: r_op, label: false_label },
                    MoreLess::More  => IRInst::AntiMore  { left: l_op, right: r_op, label: false_label, signed: is_signed },
                    MoreLess::Less  => IRInst::AntiLess  { left: l_op, right: r_op, label: false_label, signed: is_signed },
                };
                self.emit(inst);
            }
            _ => { // For like "while [1]{}" or "if [c]{}"
                let cond_op = self.reduce_expr(expr);
                self.emit(IRInst::AntiEqual {
                    left: cond_op,
                    right: IROperand::SignedConstant(0),
                    label: false_label,
                });
            }
        }
    }

    fn lower_lvalue(&mut self, expr: &Expr) -> IROperand {
        match expr {
            Expr::Identifier(name) => {
                IROperand::Var(name.clone())
            }

            Expr::Deref(ptr_expr) => {
                self.reduce_expr(ptr_expr)
            }

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
            },
            _ => panic!("Invalid l-value"),
        }
    }
}

#[inline] //Didn't know rust had inlines until now
fn align_to(offset: usize, align: usize) -> usize {
    if align == 0 {
        return offset;
    }
    (offset + align - 1) & !(align - 1)
}
