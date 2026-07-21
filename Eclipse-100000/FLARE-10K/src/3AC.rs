//3AC IR generator, again similar to parser, actually most of compiler parts are very similar

use crate::parser::{Program, FunctionSignature, StructDef, Stmt, Expr, Type};

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
    fn lower_expr(&mut self, expr: &Expr) -> IROperand {
        match expr {
            Expr::IntLiteral(a) => IROperand::SignedConstant(*a),
            Expr::HexLiteral(b) => IROperand::UnsignedConstant(*b),
            Expr::Identifier(name) => IROperand::Var(name.clone()),

            Expr::Binary {left, op, right} => {
                let l_op = self.lower_expr(left);
                let r_op = self.lower_expr(right);
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
                let r_op = self.lower_expr(rhs);
                match lhs.as_ref() {
                    Expr::Identifier(name) => { //Just assign
                        self.emit(IRInst::Cpy { dest: IROperand::Variable(name.clone()), src: r_op.clone() });
                        r_op
                    }
                    _ => { // Memory location, deref etc
                        let ptr_op = self.lower_lvalue(lhs);
                        self.emit(IRInst::StorePtr { ptr_addr: ptr_op, src: r_op.clone() });
                        r_op
                    }
                }
            }
            Expr::Deref(mem) => {
                let ptr_addr = self.lower_expr(mem);
                let dest = self.new_temp();
                self.emit(IRInst::LoadPtr { dest: dest.clone, ptr_addr});
                dest
            }
        }

    }
}

















