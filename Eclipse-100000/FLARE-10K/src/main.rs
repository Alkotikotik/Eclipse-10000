mod lexer;
mod parser;
mod semantic;

use lexer::Lexer;
use parser::Parser;
use semantic::Semantic;
use std::fs;

fn main() {
    let input_path = "main.flar";

    let src = fs::read_to_string(input_path).expect("[Fatal: file not found] you are cooked buddy");

    println!("--- Step 1: Lexical Analysis ---");
    let lexer_debug = Lexer::new(&src, 1, 1);
    for token in lexer_debug {
        println!("[ {:?} ]", token);
    }

    println!("\n--- Step 2: Parsing ---");
    let lexer = Lexer::new(&src, 1, 1);

    let mut parser = Parser::new(lexer);

    let ast = parser.parse_everything();

    println!("Parser Success! Generated AST:");
    println!("{:#?}", ast);

    println!("\n--- Step 3: Semantic Analysis ---");
    let mut semantic_analyzer = Semantic::new(&ast);
    semantic_analyzer.check_program(&ast);
    println!("Semantic Analysis Success! Your code is fully verified.");
}
