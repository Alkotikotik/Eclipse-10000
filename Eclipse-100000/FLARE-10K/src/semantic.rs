//Semantic analysis for FLARE-10K, its pretty lightweight
mod parser;

use crate::parser::{Program, FunctionDef, Stmt, Expr, Type};

use::std::collections:HashMap;

#[derive(Debug, Clone)]
pub struct StructLayout {
    pub name: String,
    pub fields: HashMap<String, (Type, usize)>, //field type, offset
    pub total_size: usize,
}

#[derive(Debug, Clone)]
pub struct FunctionSignature {
    pub name: String,
    pub params: Vec<Type>,
    pub return_type: Option<Type>,
}

pub struct GlobalEnv {
    pub structs: HashMap<String, StructLayout>,
    pub functions: HashMap<String, FunctionSignature>,
    pub globals: HashMap<String, Type>,
}

pub struct Semantic {
    env: GlobalEnv,
    scope_stack: Vec<HashMap<String, Type>>,
}

impl Semantic {
    pub fn new(program: &Program) -> Self {
        let global_env = Self::build_global_env(program);

        SemanticAnalyzer {
            env: global_env,
            scope_stack: Vec::new(),
            loop_depth: usize,
        }
    }

    fn build_global_env(program: &Program) -> GlobalEnv {
    }

}

impl GlobalEnv {
    fn get_type_size(ty: &Type, structs: &HashMap<String, StructLayout>) -> usize {
        match ty {
            Type::U32 | Type::I32 => 4, //in bytes
            Type::U16 | Type::I16 => 2,
            Type::U8  | Type::I8  => 1,
            Type::Bool => 1,
            Type::Ptr(_) => 4, // On my 32bit CPU
            Type::Struct(name) => {
                structs.get(name)
                    .expect(&format!("Semnatic Error: Type {} is underfined"), name)
                    .total_size
            }
        }
    }


}
