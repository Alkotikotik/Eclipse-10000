mod lexer;
use lexer::Lexer;

mod parser;
use parser::Parser;

use std::fs;

fn main() {
    let input_path = "main.flar";

    let src = fs::read_to_string(input_path).expect("[Fatal: file not found] you are cooked buddy");

    let lexer = Lexer::new(&src, 0, 0);

    for token in lexer {
        println!("[ {:?} ]", token);
    }
}
