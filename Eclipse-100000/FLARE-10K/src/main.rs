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
        println!("Lexer:");
        println!("{:?}", lexer);
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
    all_instructions.extend(Codegen::emit_global_preamble(&global_layout));
    for item in &ir_program.top_level {
        match item {
            IR3AC::TopLevelIR::Global(name) => {
                all_instructions.extend(Codegen::emit_single_global_init(name, &global_layout));
            }
            IR3AC::TopLevelIR::Function(name) => {
                let ir_func = ir_program
                    .functions
                    .iter()
                    .find(|f| &f.name == name)
                    .expect("Codegen error: unknown function in top-level order");
                let mut cg = Codegen::new(ir_func, &ast_structs, &global_layout);
                cg.run_allocator();
                all_instructions.extend(cg.lower_func());
            }
            IR3AC::TopLevelIR::InlineAsm(lines) => {
                for line in lines {
                    all_instructions.push(codegen::AsmInst::Inline(line.clone()));
                }
            }
        }
    }
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
