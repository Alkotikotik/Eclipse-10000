mod IR3AC;
mod codegen;
mod generate;
mod lexer;
mod parser;
mod semantic;

use IR3AC::IR;
use codegen::{Codegen, GlobalLayout};
use generate::generate_assembly;
use lexer::Lexer;
use parser::Parser;
use semantic::Semantic;
use std::collections::HashMap;
use std::fs;

fn main() {
    let input_path = "main.flar";
    let output_path = "main.eci";

    let src = fs::read_to_string(input_path).expect("[Fatal: file not found] you are cooked buddy");

    println!("Lexer:");
    let lexer_debug = Lexer::new(&src, 1, 1);
    for _token in lexer_debug {
        // println!("[ {:?} ]", _token);
    }

    println!("Parser");
    let lexer = Lexer::new(&src, 1, 1);
    let mut parser = Parser::new(lexer);
    let ast = parser.parse_everything();

    println!("Parser Success! Generated AST:");
    println!("{:#?}", ast);

    println!("Semantic");
    let mut semantic_analyzer = Semantic::new(&ast);
    semantic_analyzer.check_program(&ast);
    println!("Semantic Analysis Success, you are not cooked buddy");

    println!("Intermediate Representation (3AC):");
    let mut ir_generator = IR::new(&ast);
    let ir_program = ir_generator.reduce_everything(&ast);
    println!("{:#?}", ir_program);

    println!("Generating Assembly Instructions...");

    let mut ast_structs = HashMap::new();
    for s in &ast.structs {
        ast_structs.insert(s.name.clone(), s.clone());
    }

    let global_layout = GlobalLayout::build(&ir_program.globals, &ast_structs);

    let mut all_instructions = Vec::new();

    let global_prologue = Codegen::emit_global_prologue(&global_layout);
    all_instructions.extend(global_prologue);

    for ir_func in &ir_program.functions {
        let mut cg = Codegen::new(ir_func, &ast_structs, &global_layout);

        cg.run_allocator();

        let func_instructions = cg.lower_func();
        all_instructions.extend(func_instructions);
    }

    println!("Formatting Assembly Code...");
    let asm_text = generate_assembly(all_instructions)
        .expect("[Fatal: Assembly Formatting Error] Failed to serialize assembly instructions");

    println!("Writing assembly to output file: {}", output_path);
    fs::write(output_path, asm_text)
        .expect("[Fatal: File Write Error] Failed to write generated assembly to disk");

    println!("File compiled and exited with code 0");
}
