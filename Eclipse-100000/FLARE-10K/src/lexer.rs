use std::iter::Peekable;
use std::str::Chars;

pub enum Token {
    Func,
    For,
    If,
    While,
    Inline,
    Outline,
    Def,

    Identifier(String),
    IntLiteral(i32),
    HexLiteral(u32),

    TypeU32,
    TypeU16,
    TypeU8,
    TypeI32,
    TypeI16,
    TypeI8,
    TypeBool,

    Equal,
    AddEqual,
    SubEqual,
    IsEqual,
    Mul,
    Arrow,
    Comma,
    Colon,
    Semicolon,

    LParen, //()
    RParen,
    LBracket, // []
    RBracket,
    LBrace, //{}
    RBrace,

    Comment(String), // For >_ comment
}

struct Lexer<'lt>{ //lifetime
    chars: Peekable<Chars<'a>>,

    line: usize,
    position: usize,
}

impl<'lt> Lexer<'lt>{
    fn new(input: &'lt str, line: usize, position: usize) -> Self {
        Lexer {
            chars: input.chars().peekable(),
            line: line,
            position: position,
        }
    }

    //Helpers
    fn move(&mut self) -> Option<char> {
        self.input.next();
    }
    fn peek(&mut self) -> Option<&char> {
        self.input.peek()
    }
}

