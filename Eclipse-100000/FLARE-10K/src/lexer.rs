//Lexer - performs lexical analysis on the input file and returns tokens
use std::iter::Peekable;
use std::str::Chars;

#[derive(Debug, PartialEq)]
pub enum Token {
    Func,
    For,
    If,
    Else,
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
    NotEqual,
    Add,
    Sub,
    Asterix,
    Div,
    Comma,
    Colon,
    Semicolon,
    ToRet,
    More,
    Less,
    Excl,

    LParen, //()
    RParen,
    LBracket, //[]
    RBracket,
    LBrace, //{}
    RBrace,

    InlineBlock(String),
}

pub struct Lexer<'a> {
    chars: Peekable<Chars<'a>>,
    line: usize,
    position: usize,
    token_queue: Vec<Token>, //For inline
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str, line: usize, position: usize) -> Self {
        Lexer {
            chars: input.chars().peekable(),
            line,
            position,
            token_queue: Vec::new(),
        }
    }

    fn advance(&mut self) -> Option<char> {
        let next_char = self.chars.next();
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
            "else" => Token::Else,
            "while" => Token::While,
            "inline" => Token::Inline,
            "outline" => Token::Outline,
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

    fn skip_comment(&mut self) {
        while let Some(c) = self.advance() {
            if c == '\n' {
                break;
            }
        }
    }

    fn read_inline_block(&mut self) {
        let mut block_content = String::new();

        loop {
            if let Some(c) = self.advance() {
                block_content.push(c);
                if block_content.ends_with("outline];") {
                    break;
                }
            } else {
                panic!("Error: inline wasn't closed");
            }
        }

        let content_len = block_content.len();
        let raw_asm = &block_content[..content_len - 9];
        let trimmed_asm = raw_asm.trim().to_string();

        // Just push needed tokens to the queue, conditions are met anyways
        self.token_queue.push(Token::LBracket);
        self.token_queue.push(Token::InlineBlock(trimmed_asm));
        self.token_queue.push(Token::Outline);
        self.token_queue.push(Token::RBracket);
        self.token_queue.push(Token::Semicolon);
    }
}

impl<'a> Iterator for Lexer<'a> {
    type Item = Token;

    fn next(&mut self) -> Option<Self::Item> {
        if !self.token_queue.is_empty() {
            return Some(self.token_queue.remove(0));
        }

        self.skip_whitespace();
        let current_char = self.advance()?;

        let token = match current_char {
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
            '/' => Token::Div,

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
                    self.skip_comment();
                    return self.next();
                } else {
                    Token::More
                }
            }
            '!' => {
                if self.peek() == Some(&'=') {
                    self.advance();
                    Token::NotEqual
                } else {
                    Token::Excl
                }
            }

            c if c.is_alphabetic() || c == '_' || c == '#' => {
                let tok = self.read_idenkeyword(c);

                if tok == Token::Inline {
                    self.skip_whitespace();
                    if self.peek() == Some(&'[') {
                        self.advance();
                        self.read_inline_block();

                        Token::Inline
                    } else {
                        tok
                    }
                } else {
                    tok
                }
            }
            c if c.is_numeric() => self.read_number(c),

            _ => {
                panic!(
                    "Syntax Error: Unexpected character '{}' at line {}, column {}",
                    current_char, self.line, self.position
                );
            }
        };

        Some(token)
    }
}
