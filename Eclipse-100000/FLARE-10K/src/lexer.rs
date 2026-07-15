use std::iter::Peekable;
use std::str::Chars;

#[derive(Debug, PartialEq)]
pub enum Token {
    Func,
    For,
    If,
    While,
    Inline,
    Outline,
    Def,
    Return,

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
    As,

    Equal,
    IsEqual,
    Add,
    Sub,
    Asterix,
    Comma,
    Colon,
    Semicolon,
    ToRet,
    More,
    Less,

    LParen, //()
    RParen,
    LBracket, // []
    RBracket,
    LBrace, //{}
    RBrace,

    Comment(String), // For >_ comment
    InlineBlock(String),
}

pub struct Lexer<'a> {
    chars: Peekable<Chars<'a>>,
    line: usize,
    position: usize,
    is_inline: bool
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str, line: usize, position: usize) -> Self {
        Lexer {
            chars: input.chars().peekable(),
            line,
            position,
            is_inline: false,
        }
    }

    // Helpers
    fn advance(&mut self) -> Option<char> {
        let next_char = self.chars.next();
        
        //Track column and position
        if let Some(c) = next_char {
            if c == '\n' {
                self.line += 1;
                self.position = 1;
            } else {
                self.position += 1;
            }
        }

        next_char
    }

    fn peek(&mut self) -> Option<&char> {
        self.chars.peek()
    }

    fn skip_whitespace(&mut self) {
        while let Some(&c) = self.peek() {
            if c.is_whitespace() {
                if c == '\n' {
                    self.line += 1;
                    self.position = 0;
                }
                self.advance();
            } else {
                break;
            }
        }
    }

    fn read_idenkeyword(&mut self, first_char: char) -> Token {
        let mut ident = String::new();
        ident.push(first_char);

        while let Some(&c) = self.peek() {
            if c.is_alphanumeric() || c == '_' {
                ident.push(self.advance().unwrap());
            } else {
                break;
            }
        }

        match ident.as_str() {
            "func" => Token::Func,
            "for" => Token::For,
            "if" => Token::If,
            "while" => Token::While,
            "inline" => { self.is_inline = true; Token::Inline}
            "outline" => { self.is_inline = false; Token::Outline}
            "u32" => Token::TypeU32,
            "u16" => Token::TypeU16,
            "u8" => Token::TypeU8,
            "i32" => Token::TypeI32,
            "i16" => Token::TypeI16,
            "i8" => Token::TypeI8,
            "bool" => Token::TypeBool,
            "#def" => Token::Def,
            "return" => Token::Return,
            "as" => Token::As,
            _ => Token::Identifier(ident),
        }
    }

    fn read_number(&mut self, first_char: char) -> Token {
        let mut num_str = String::new();
        num_str.push(first_char);

        if first_char == '0' && self.peek() == Some(&'x') {
            // Exclude 0x
            self.advance();
            num_str.clear();

            while let Some(&c) = self.peek() {
                if c.is_ascii_hexdigit() {
                    num_str.push(self.advance().unwrap());
                } else {
                    break;
                }
            }
            let val = u32::from_str_radix(&num_str, 16).expect("Invalid hex literal");
            return Token::HexLiteral(val);
        }

        // Otherwise standard decimal
        while let Some(&c) = self.peek() {
            if c.is_numeric() {
                num_str.push(self.advance().unwrap());
            } else {
                break;
            }
        }

        let val = num_str.parse::<i32>().expect("Invalid decimal literal");
        Token::IntLiteral(val)
    }

    fn read_comment(&mut self) -> Token {
        let mut comment_content = String::new();
        while let Some(c) = self.advance() {
            if c == '\n' {
                break;
            }
            comment_content.push(c);
        }
        Token::Comment(comment_content)
    }

    fn read_inline(&mut self) -> Token {
        let mut depth = 0;
        let mut block_content = String::new();

        self.skip_whitespace();
        if self.peek() == Some(&'{') {
            self.advance();
            depth = 1;
        } else {
            panic!("Syntax Error: Expected '{{' after inline keyword at line {}", self.line);
        }

        while depth > 0 {
            if let Some(c) = self.advance() {
                if c == '{' {
                    depth += 1;
                } else if c == '}' {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                block_content.push(c);
            } else {
                panic!("Syntax Error: Unclosed inline assembly block at line {}", self.line);
            }
        }

        let mut content = block_content.trim().to_string();
        if content.ends_with("outline") {
            content = content.trim_end_matches("outline").trim().to_string();
        }

        Token::InlineBlock(content)
    }
}

impl<'a> Iterator for Lexer<'a> {
    type Item = Token;

    fn next(&mut self) -> Option<Self::Item> {

        self.skip_whitespace();
        let current_char = self.advance()?;
        let token: Token;

            token = match current_char {
                '(' => Token::LParen,
                ')' => Token::RParen,
                '[' => Token::LBracket,
                ']' => Token::RBracket,
                '{' => Token::LBrace,
                '}' => Token::RBrace,
                ',' => Token::Comma,
                ':' => Token::Colon,
                ';' => Token::Semicolon,
                '+' => Token::Add,
                '-' => Token::Sub,
                '*' => Token::Asterix,
                '<' => Token::Less,

                '=' => {
                    if self.peek() == Some(&'=') {
                        self.advance();
                        Token::IsEqual
                    } else if self.peek() == Some(&'>') {
                        self.advance();
                        Token::ToRet
                    } else {
                        Token::Equal
                    }
                }
                '>' => {
                    if self.peek() == Some(&'_') {
                        self.advance();
                        self.read_comment()
                    } else {
                        Token::More
                    }
                }

                c if c.is_alphabetic() || c == '_' || c == '#' => {
                    let tok = self.read_idenkeyword(c);
                    
                    if tok == Token::Inline {
                        self.read_inline()
                    } else {
                        tok
                    }
                }
                c if c.is_numeric() => self.read_number(c),

                _ => {
                    panic!(
                        "Syntax Error: Unexpected character '{}' at line {}, column {}", 
                        current_char, 
                        self.line, 
                        self.position
                    );
                }
            };
        Some(token)
    }
}
