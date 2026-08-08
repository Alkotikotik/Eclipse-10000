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
use clap::Parser as ClapParser;
use std::path::PathBuf;

#[derive(ClapParser, Debug)]
#[command(author = "Qclipsing", version = "v0.0", about = "Flare-10k Compiler", long_about = None)]
struct Args {
    #[arg(value_name = "FILE")]
    input: PathBuf,
    #[arg(short = 'o', long, value_name = "FILE")]
    output: Option<PathBuf>,
    #[arg(long)]
    lex: bool,
    #[arg(long)]
    ast: bool,
    #[arg(long)]
    ir: bool,
    #[arg(long)]
    asm: bool,
}
fn main() {
    let args = Args::parse();
    // Read Source File
    let src = fs::read_to_string(&args.input).unwrap_or_else(|err| {
        eprintln!("Error: Could not read file {:?}: {}", args.input, err);
        std::process::exit(1);
    });
    let lexer = Lexer::new(&src, 1, 1);
    if args.lex {
        for token in lexer {
            println!("[{:?}]", token);
        }
        return;
    }
    let mut parser = Parser::new(lexer);
    let ast = parser.parse_everything();
    if args.ast {
        println!("Parser's AST:");
        println!("{:#?}", ast);
        return;
    }
    let mut semantic_analyzer = Semantic::new(&ast);
    semantic_analyzer.check_program(&ast);
    let mut ir_generator = IR::new(&ast);
    let ir_program = ir_generator.reduce_everything(&ast);
    if args.ir {
        println!("IR:");
        println!("{:#?}", ir_program);
        return;
    }
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
    //let all_instructions = Codegen::strip_useless_xors(all_instructions);
    let asm_text = generate_assembly(all_instructions).expect("Codegen error: failed to compile");
    if args.asm {
        println!("Assembly:");
        println!("{}", asm_text);
        return;
    }
    let output_path = args
        .output
        .clone()
        .unwrap_or_else(|| args.input.with_extension("s"));
    fs::write(&output_path, &asm_text).unwrap_or_else(|err| {
        eprintln!("Error: Could not write file {:?}: {}", output_path, err);
        std::process::exit(1);
    });
    println!(
        "Compilation succeeded! Assembly written to: {:?}",
        output_path
    );
}
