//3AC IR generator, again similar to parser, actually most of compiler parts are very similar

use crate::parser::{Program, FunctionSignature, StructDef, Stmt, Expr, Type, MoreLess};

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
    Sra { dest: IROperand, left: IROperand, right: IROperand },

    Not { dest: IROperand, src: IROperand },
    Negate { dest: IROperand, src: IROperand},
    Cpy { dest: IROperand, src: IROperand },
    Cast { dest: IROperand, src: IROperand, target_type: Type },

    LoadPtr  { dest: IROperand, ptr_addr: IROperand },
    StorePtr { ptr_addr: IROperand, src: IROperand },

    AntiEqual { left: IROperand, right: IROperand, label: String }, //Branch if false, so they are
    Equal     { left: IROperand, right: IROperand, label: String }, //Inverted AntiEqual becomes
    AntiMore  { left: IROperand, right: IROperand, label: String }, //Branch if not equal 
    AntiLess  { left: IROperand, right: IROperand, label: String }, //Branch if more becomes brach
                                                                    //If less
    Label(String),
    JF(String), //Jump if 1 == 1

    Call { dest: Option<IROperand>, name: String, args: Vec<IROperand> },
    Return(Option<IROperand>),
    InlineAsm(Vec<String>),
}

pub struct IR {
    instsBuffer: Vec<IRInst>,
    temp_counter: usize,
    label_couter: usize,
}

//Helpers
impl IR {
    pub fn new(){

    }
    pub fn new_temp(&mut self) -> IROperand{
        let buff = IROperand::Temp(self.temp_counter)
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
        self.label_couter = 0;
    }
    pub fn emit(&mut self inst: IRInst) {
        self.instsBuffer.push(inst);
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

            Expr::FunctionCall(name, argss) => {
                let dest = self.new_temp();
                let mut args: Vec<IROperand> = Vec::new();

                for arg in argss {
                    args.push(self.reduce_expr(arg));
                }
                self.emit(IRInst::Call {
                    dest: dest.clone(),
                    name,
                    args,
                });
                dest
            }

            Expr::Cast(expr, target_type) => {
                dest = self.new_temp();
                src = self.reduce_expr(expr);
                self.emit(IRInst::Cast{
                    dest: dest.clone(),
                    src,
                    target_type
                });
            }

            Expr::Unary(op, expr) => {
                dest = self.new_temp();
                src = self.reduce_expr(expr);
                let inst = match op {
                    UnaryOpKind::Not => IRInst::Not {dest: dest.clone(), src: src},
                    UnaryOpKind::Negate => IRInst::Negate { dest: dest.clone(), src: src},
                }
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
                    _ => panic!("Division isn't implemented yet");
                };
                self.emit(inst);
                dest
            }

            Expr::Assign {lhs, rhs} => {
                let r_op = self.reduce_expr(rhs);
                match lhs.as_ref() {
                    Expr::Identifier(name) => { //Just assign
                        self.emit(IRInst::Cpy {
                            dest: IROperand::Variable(name.clone()),
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
            Expr::VarDecl {ty, name, initial} => {
                if initial {
                    let init_op = reduce_expr(initial);
                    self.emit(IRInst::Cpy {
                        dest: IROperand::Variable(name),
                        src: init_op
                    });
                }
            }
        }
    }

    fn reduce_cond(&mut self, expr: &Expr, false_label: String) {
        match expr {
            Expr::MoreLessEq { lhs, op, rhs } => {
                let l_op = self.reduce_expr(lhs);
                let r_op = self.reduce_expr(rhs);
                let inst = match op {
                    MoreLess::Eq    => IRInst::AntiEqual { left: l_op, right: r_op, label: false_label },
                    MoreLess::NotEq => IRInst::Equal     { left: l_op, right: r_op, label: false_label },
                    MoreLess::More  => IRInst::AntiMore  { left: l_op, right: r_op, label: false_label },
                    MoreLess::Less  => IRInst::AntiLess  { left: l_op, right: r_op, label: false_label },
                };
                self.emit(inst);
            }
            _ => { // For like while [1] or if [c]
                let cond_op = self.reduce_expr(expr);
                self.emit(IRInst::Beq {
                    left: cond_op,
                    right: IROperand::Constant(0),
                    label: false_label,
                });
            }
        }
    }
}

















