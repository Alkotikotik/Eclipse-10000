//Semantic analysis for FLARE-10K, its pretty lightweight but I don't like it
use crate::parser::{Program, FunctionSignature, StructDef, Stmt, Expr, Type};
use std::collections::HashMap;

pub struct GlobalEnv {
    pub structs: HashMap<String, StructDef>,
    pub functions: HashMap<String, FunctionSignature>,
    pub globals: HashMap<String, Type>,
}

pub struct Semantic {
    env: GlobalEnv,
    scope_stack: Vec<HashMap<String, Type>>,
    loop_depth: usize,
}

impl Semantic {
    pub fn new(program: &Program) -> Self {
        let global_env = GlobalEnv::build_global_env(program);

        Semantic {
            env: global_env,
            scope_stack: Vec::new(),
            loop_depth: 0,
        }
    }

    pub fn push_scope(&mut self) {
        self.scope_stack.push(HashMap::new());
    }

    pub fn pop_scope(&mut self) {
        self.scope_stack.pop().expect("Semantic Error: Scope stack underflow, you are cooked buddy");
    }

    //Panic helper
    fn sem_panic(&self, message: &str, line: usize, character: usize) -> ! {
        panic!("Semantic Error: {}; line: {}, char: {}", message, line, character);
    }
}

impl Semantic {
    fn is_integer(&self, ty: &Type) -> bool {
        match ty {
            Type::U32 | Type::I32 | Type::U16 | Type::I16 | Type::U8 | Type::I8 => true,
            _ => false,
        }
    }

    fn check_compatibility(&self, expected: &Type, actual: &Type, line: usize, character: usize) {
        if expected == actual {
            return;
        }
        if self.is_integer(expected) && self.is_integer(actual) {
            return;
        }
        self.sem_panic(&format!("Type mismatch: expected {:?}, got {:?}", expected, actual), line, character);
    }

    fn declare(&mut self, name: String, ty: Type, line: usize, character: usize) {
        if let Some(current_scope) = self.scope_stack.last_mut() {
            if current_scope.insert(name.clone(), ty).is_some() {
                self.sem_panic(&format!("Variable {} redefinition in this scope", name), line, character);
            }
        } else {
            self.sem_panic("Cannot declare variable outside the scope", line, character);
        }
    }

    fn lookup_var(&self, name: &str, line: usize, character: usize) -> Type {
        //Check for var in the scope
        for scope in self.scope_stack.iter().rev() {
            if let Some(ty) = scope.get(name) {
                return ty.clone();
            }
        }
        // Then in global
        if let Some(ty) = self.env.globals.get(name) {
            return ty.clone();
        }
        self.sem_panic(&format!("Variable {} is undefined", name), line, character);
    }

    pub fn check_program(&mut self, program: &Program) {
        for func in &program.functions {
            self.check_function(func);
        }
    }

    fn check_function(&mut self, func: &FunctionSignature) {
        self.push_scope();
        self.loop_depth = 0;

        for param in &func.params {
            self.declare(param.name.clone(), param.ty.clone(), 0, 0);
        }

        for stmt in &func.body {
            self.check_stmt(stmt, &func.to_return);
        }

        self.pop_scope();
    }

    fn check_expr(&mut self, expr: &Expr, line: usize, character: usize) -> Type {
        match expr {
            Expr::IntLiteral(_) => Type::I32,
            Expr::HexLiteral(_) => Type::U32,

            Expr::Identifier(name) => self.lookup_var(name, line, character),

            Expr::Deref(inner_expr) => {
                let inner_type = self.check_expr(inner_expr, line, character);
                match inner_type {
                    Type::Ptr(base_type) => *base_type, //Default deref
                    Type::U32 | Type::I32 => Type::U32, // Allow raw memory address dereferencing
                    _ => {
                        self.sem_panic(&format!("Cannot dereference non-pointer type {:?}", inner_type), line, character);
                    }
                }
            }

            Expr::Ref(inner_expr) => {
                let inner_type = self.check_expr(inner_expr, line, character);
                Type::Ptr(Box::new(inner_type))
            }

            Expr::Binary { left, op: _, right } => {
                let left_ty = self.check_expr(left, line, character);
                let right_ty = self.check_expr(right, line, character);

                if left_ty != right_ty && !(self.is_integer(&left_ty) && self.is_integer(&right_ty)) {
                    self.sem_panic(
                        &format!("Type mismatch in binary operation: {:?} and {:?}", left_ty, right_ty),
                        line, character
                    );
                }
                left_ty
            }

            Expr::MoreLessEq { left, op: _, right } => {
                let left_ty = self.check_expr(left, line, character);
                let right_ty = self.check_expr(right, line, character);

                if left_ty != right_ty && !(self.is_integer(&left_ty) && self.is_integer(&right_ty)) {
                    self.sem_panic(
                        &format!("Type mismatch in comparison: {:?} and {:?}", left_ty, right_ty),
                        line, character
                    );
                }
                Type::Bool
            }

            Expr::FunctionCall { name, args } => {
                let func_sig = self.env.functions.get(name)
                    .unwrap_or_else(|| self.sem_panic(&format!("Call to undefined function '{}'", name), line, character))
                    .clone();

                if args.len() != func_sig.params.len() {
                    self.sem_panic(
                        &format!("Function {} expects {} arguments, but got {}", name, func_sig.params.len(), args.len()),
                        line, character
                    );
                }

                for (arg, param) in args.iter().zip(func_sig.params.iter()) {
                    let arg_ty = self.check_expr(arg, line, character);
                    self.check_compatibility(&param.ty, &arg_ty, line, character);
                }

                func_sig.to_return.unwrap_or(Type::U32) 
            }

            Expr::Assign { lhs, rhs } => {
                self.verify_lvalue(lhs, line, character);

                let lhs_ty = self.check_expr(lhs, line, character);
                let rhs_ty = self.check_expr(rhs, line, character);

                self.check_compatibility(&lhs_ty, &rhs_ty, line, character);
                lhs_ty
            }

            Expr::VarDecl { ty, name, initial } => {
                if let Some(init_expr) = initial {
                    let rhs_ty = self.check_expr(init_expr, line, character);
                    self.check_compatibility(ty, &rhs_ty, line, character);
                }
                self.declare(name.clone(), ty.clone(), line, character);
                ty.clone()
            }

            Expr::FieldAccess { expr, field } => {
                let expr_ty = self.check_expr(expr, line, character);
                if let Type::Struct(struct_name) = expr_ty {
                    let struct_def = self.env.structs.get(&struct_name)
                        .unwrap_or_else(|| self.sem_panic("Unknown struct", line, character));

                    let field_def = struct_def.fields.iter().find(|f| f.name == *field)
                        .unwrap_or_else(|| self.sem_panic("Field not found", line, character));

                    field_def.ty.clone()
                } else {
                    self.sem_panic("Cannot access field of non-struct type", line, character);
                }
            }

            Expr::Cast { expr, target_type } => {
                self.check_expr(expr, line, character);
                target_type.clone()
            }

            Expr::Unary { op: _, expr } => {
                self.check_expr(expr, line, character)
            }
        }
    }

    fn check_stmt(&mut self, stmt: &Stmt, expected_return: &Option<Type>) {
        let line = 0; 
        let character = 0;

        match stmt {
            Stmt::For { init, cond, inc, body } => {
                self.push_scope();
                self.check_expr(init, line, character);

                let cond_ty = self.check_expr(cond, line, character);
                if cond_ty != Type::Bool && !self.is_integer(&cond_ty) {
                    self.sem_panic("'For' cond must evaluate to bool or int equivalent(1/0)", line, character);
                }

                self.check_expr(inc, line, character);

                self.loop_depth += 1;
                for s in body { self.check_stmt(s, expected_return); }
                self.loop_depth -= 1;

                self.pop_scope();
            }

            Stmt::While { cond, body } => {
                let cond_ty = self.check_expr(cond, line, character);
                if cond_ty != Type::Bool && !self.is_integer(&cond_ty) {
                    self.sem_panic("'While' cond must evaluate to bool or int equivalent(1/0)", line, character);
                }

                self.loop_depth += 1;
                for s in body { self.check_stmt(s, expected_return); }
                self.loop_depth -= 1;
            }

            Stmt::IfElse { cond, main_branch, else_branch } => {
                let cond_ty = self.check_expr(cond, line, character);
                if cond_ty != Type::Bool && !self.is_integer(&cond_ty) {
                    self.sem_panic("'If' cond must evaluate to boolean or int equivalent(1/0)", line, character);
                }

                self.push_scope();
                for s in main_branch { self.check_stmt(s, expected_return); }
                self.pop_scope();

                if let Some(else_stmts) = else_branch {
                    self.push_scope();
                    for s in else_stmts { self.check_stmt(s, expected_return); }
                    self.pop_scope();
                }
            }

            Stmt::Return(expr_opt) => {
                match (expr_opt, expected_return) {
                    (Some(expr), Some(expected_ty)) => {
                        let ret_ty = self.check_expr(expr, line, character);
                        self.check_compatibility(expected_ty, &ret_ty, line, character);
                    }
                    (None, None) => {} //Void return
                    _ => self.sem_panic("Function exit", line, character),
                }
            }

            Stmt::Break => {
                if self.loop_depth == 0 {
                    self.sem_panic("Cannot break outside of a loop", line, character);
                }
            }

            Stmt::Expr(expr) => {
                self.check_expr(expr, line, character);
            }

            Stmt::InlineAsm(_) => {}
        }
    }

    fn verify_lvalue(&self, expr: &Expr, line: usize, character: usize) {
        match expr {
            Expr::Identifier(_) => {}
            Expr::Deref(_) => {}
            Expr::FieldAccess { .. } => {}
            _ => self.sem_panic("Left side is wrong", line, character),
        }
    }
}

impl GlobalEnv {

    fn build_global_env(program: &Program) -> GlobalEnv {
        let mut env = GlobalEnv {
            structs: HashMap::new(),
            functions: HashMap::new(),
            globals: HashMap::new(),
        };

        for i in &program.structs {
            if env.structs.insert(i.name.clone(), i.clone()).is_some() {
                panic!("Semantic error: Struct {} redefinition", i.name);
            }
        }

        for f in &program.functions {
            if env.functions.insert(f.name.clone(), f.clone()).is_some() {
                panic!("Semantic error: global variable {} redefinition", f.name);
            }

            if let Some(Type::Struct(ref struct_name)) = f.to_return {
                if !env.structs.contains_key(struct_name) {
                    panic!("Semantic error: Unknown type in function {}, type {}", f.name, struct_name);
                }
            }

            for param in &f.params {
                if let Type::Struct(ref struct_name) = param.ty {
                    if !env.structs.contains_key(struct_name) {
                        panic!("Semantic error: Unknown type in {}, {}, {}", f.name, param.name, struct_name);
                    }
                }
            }
        }

        for global in &program.globals {
            if let Expr::VarDecl { ty, name, .. } = &global.decl {
                if env.globals.insert(name.clone(), ty.clone()).is_some() {
                    panic!("Semantic error: Global variable redifinition {}", name);
                }
            } else {
                panic!("Semantic error: Global variable redefinition");
            }
        }
        env
    }
}
