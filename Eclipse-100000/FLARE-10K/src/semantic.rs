//Semantic analysis for FLARE-10K, its pretty lightweight

use crate::parser::{Program, FunctionSignature, StructDef, GlobalDef, Stmt, Expr, Type};
use std::collections::HashMap;

pub struct GlobalEnv {
    pub structs: HashMap<String, StructDef>,
    pub functions: HashMap<String, FunctionSignature>,
    pub globals: HashMap<String, Type>,
}

pub struct Semantic {
    env: GlobalEnv,
    scope_stack: Vec<HashMap<String, Type>>,
    loop_depth: usize
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
}

impl GlobalEnv {
    fn get_type_size(ty: &Type, structs: &HashMap<String, StructDef>) -> usize {
        match ty {
            Type::U32 | Type::I32 => 4, // In bytes
            Type::U16 | Type::I16 => 2,
            Type::U8  | Type::I8  => 1,
            Type::Bool => 1,
            Type::Ptr(_) => 4, // On 32-bit CPU
            Type::Struct(name) => {
                let struct_def = structs.get(name)
                    .expect(&format!("Semantic Error: Type {} is undefined", name));
                //Calculate size, works for structs with structs
                let mut total = 0;
                for field in &struct_def.fields {
                    total += Self::get_type_size(&field.ty, structs);
                }
                total
            }
        }
    }

    fn build_global_env(program: &Program) -> GlobalEnv {
        let mut env = GlobalEnv {
            structs: HashMap::new(),
            functions: HashMap::new(),
            globals: HashMap::new(),
        };

        for i in &program.structs {
            if env.structs.insert(i.name.clone(), i.clone()).is_some() { //.is_some() returns 1 if
                //it overwritten something, which implies duplicate
                panic!("Semantic error: Struct {} redefinition", i.name);
            }
        }

        for f in &program.functions {
            if env.functions.insert(f.name.clone(), f.clone()).is_some() {
                panic!("Semantic error: Function {} redefinition", f.name);
            }

            if let Some(Type::Struct(ref struct_name)) = f.to_return {
                if !env.structs.contains_key(struct_name) {
                    panic!("Semantic error: Function {} returns unknown type {}", f.name, struct_name);
                }
            }

            for param in &f.params {
                if let Type::Struct(ref struct_name) = param.ty {
                    if !env.structs.contains_key(struct_name) {
                        panic!("Semantic error: Function {} parameter {} has unknown type {}", f.name, param.name, struct_name);
                    }
                }
            }
        }

        for global in &program.globals {
            if let Expr::VarDecl { ty, name, .. } = &global.decl {
                if env.globals.insert(name.clone(), ty.clone()).is_some() {
                    panic!("Semantic error: global variable '{}' redefinition.", name);
                }
            } else {
                panic!("Semantic error: global block must contain a variable declaration.");
            }
        }

        env
    }
}
