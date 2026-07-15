#[derive(Debug, PartialEq, Clone)]
pub enum Token {
    Func,
    For,
    If,
    Inline,
    Outline,
    Def,

    Identifier(String),
    IntLiteral(i32),
    HexLiteral(u32),
    
    TypeU32,
    TypeI32,
    TypeU8,
    TypeI16,

    Equal,
    AddEqual,
    SubEqual,
    IsEqual,
    Mul,
    Arrow,
    Comma,
    Colon,
    Semicolon,
    
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    
    Comment(String), // For >_ comment
}
