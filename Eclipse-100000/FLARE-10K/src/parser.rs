//Parser for FLARE-10K precende table in the main directory of language.
//Refer to it, it might act as a documentation

use std::iter::Peekable;
use std::str::Chars;

use crate::lexer::Lexer;
use crate::lexer::Token;

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    U32,
    U16,
    U8,
    I32,
    I16,
    I8,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum UnaryOpKind {
    Negate,
    Not,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BinaryOpKind {
    Mul,
    Div,
    Add,
    Sub,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MoreLess {
    More,
    Less,
    Eq,
    NotEq,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    IntLiteral(i32),
    HexLiteral(u32),

    Identifier(String),
    Deref(Box<Expr>),
    FunctionCall {
        name: String,
        args: Vec<Expr>,
    },
    Cast {
        expr: Box<Expr>,
        target_type: Type,
    },
    Unary {
        op: UnaryOpKind,
        expr: Box<Expr>,
    },
    Binary {
        left: Box<Expr>,
        op: BinaryOpKind,
        right: Box<Expr>,
    },
    MoreLessEq {
        left: Box<Expr>,
        op: MoreLess,
        right: Box<Expr>,
    },
    Assign {
        lhs: Box<Expr>,
        rhs: Box<Expr>,
    },
    
    VarDecl {
        ty: Type,
        name: String,
        initial: Option<Box<Expr>>, //Initial is optional
    },
}

pub struct Parser<'a> {
    tokens: std::iter::Peekable<Lexer<'a>>,
}

impl<'a> Parser<'a> {
    pub fn new(lexer: Lexer<'a>) -> Self {
        Parser {
            tokens: lexer.peekable(),
        }
    }

    fn advance(&mut self) -> Token {
        self.tokens.next().expect("Unexpected End of File")
    }

    fn expect(&mut self, to_expect: Token) {
        if self.tokens.peek() == Some(&to_expect) {
            self.tokens.next();
        } else {
            panic!("Error, expected: {:?}", to_expect);
        }
    }
}

//Recursive descent
impl<'a> Parser<'a> {

    fn parse_func(&mut self) -> Vec<Expr> { todo!() }

    //Highest precedence
    //Parse: literals, identifiers, calls
    fn parse_atomic(&mut self) -> Expr {
        match self.tokens.next() {
            Some(Token::IntLiteral(val)) => Expr::IntLiteral(val),
            Some(Token::HexLiteral(val)) => Expr::HexLiteral(val),
            Some(Token::Identifier(name)) => {
                if self.tokens.peek() == Some(&Token::LParen) {
                    self.tokens.next();
                    let args = self.parse_func();
                    self.expect(Token::RParen);
                    Expr::FunctionCall { name, args }
                } else {
                    Expr::Identifier(name)
                }
            }
            Some(Token::LBracket) => { //Adress can be an expression, eg [5+10]
                let inner_expr = self.parse_assign();
                self.expect(Token::RBracket);
                Expr::Deref(Box::new(inner_expr))
            }
            Some(Token::LParen) => { //For parenthisez math, like (1+5)*2
                let inner_expr = self.parse_assign();
                self.expect(Token::RParen);
                inner_expr
            }
            anything_else => panic!("Expected atomic expression, found {:?}", anything_else),
        }
    }
    //Cast works just as in rust, its pretty convinient falls to atomic
    fn parse_cast(&mut self) -> Expr {
        let mut expr = self.parse_atomic();
        
        if self.tokens.peek() == Some(&Token::As) {
            self.advance();

            let target_type = match self.advance() {
                Token::TypeU32 => Type::U32,
                Token::TypeU16 => Type::U16,
                Token::TypeU8 => Type::U8,
                Token::TypeI32 => Type::I32,
                Token::TypeI16 => Type::I16,
                Token::TypeI8 => Type::I8,

                other => panic!("Expected a type after 'as', found {:?}", other),
            };

            expr = Expr::Cast {
                expr: Box::new(expr),
                target_type,
            };
        }
        expr
    }
    //Unary is singalar values operations, like -val or !val, falls to cast if no ! or -
    fn parse_unary(&mut self) -> Expr {
        match self.tokens.peek() {
            Some(Token::Sub) => {
                self.advance();
                //Recursive, so --5 is possible
                let val = self.parse_unary();
                
                Expr::Unary {
                    op: UnaryOpKind::Negate,
                    expr: Box::new(val),
                }
            }
            Some(Token::Excl) => {
                self.advance();
                let val = self.parse_unary();
                
                Expr::Unary {
                    op: UnaryOpKind::Not,
                    expr: Box::new(val),
                }
            }
            _ => self.parse_cast(),
        }
    }
    //Parse * and / higher precedence that + and -, first falls to unary
    fn parse_factor(&mut self) -> Expr {
        let mut expr = self.parse_unary();
        
        while let Some(token) = self.tokens.peek(){
            match token{
                Token::Asterix => {
                    self.advance();
                    let right = self.parse_unary(); //Parsing RHS with unary bc it can be eg -val
                    
                    //Store as node for code generation later
                    expr = Expr::Binary {
                        left: Box::new(expr),
                        op: BinaryOpKind::Mul,
                        right: Box::new(right),
                    };
                }
                Token::Div => {
                    self.advance();
                    let right = self.parse_unary();

                    expr = Expr::Binary {
                        left: Box::new(expr),
                        op: BinaryOpKind::Div,
                        right: Box::new(right),
                    };
                }
                _ => break,
            }
        }
        expr
    }
    
    //Similar, falls to factor 
    fn parse_term(&mut self) -> Expr {
        let mut expr = self.parse_factor();
        
        while let Some(token) = self.tokens.peek(){
            match token{
                Token::Add => {
                    self.advance();
                    let right = self.parse_factor();

                    expr = Expr::Binary {
                        left: Box::new(expr),
                        op: BinaryOpKind::Add,
                        right: Box::new(right),
                    };
                }
                Token::Sub => {
                    self.advance();
                    let right = self.parse_factor();

                    expr = Expr::Binary {
                        left: Box::new(expr),
                        op: BinaryOpKind::Sub,
                        right: Box::new(right),
                    };
                }
                _ => break,
            }
        }
        expr
    }
    
    //Similar again falls to term bc it can be val+val1 < val*val1
    //Also it can technically be val < val1 < val2
    fn parse_compariSON(&mut self) -> Expr {
        let mut expr = self.parse_term();
        
        while let Some(token) = self.tokens.peek(){
            match token{
                Token::More => {
                    self.advance();
                    let right = self.parse_term();

                    expr = Expr::MoreLessEq {
                        left: Box::new(expr),
                        op: MoreLess::More,
                        right: Box::new(right),
                    };
                }
                Token::Less => {
                    self.advance();
                    let right = self.parse_term();

                    expr = Expr::MoreLessEq  {
                        left: Box::new(expr),
                        op: MoreLess::Less,
                        right: Box::new(right),
                    };
                }
                _ => break,
            }
        }
        expr
    }
    
    //Fals to comparison, eg val<val == val > val
    fn parse_equality(&mut self) -> Expr {
        let mut expr = self.parse_compariSON();
        
        while let Some(token) = self.tokens.peek(){
            match token{
                Token::IsEqual => {
                    self.advance();
                    let right = self.parse_compariSON();

                    expr = Expr::MoreLessEq {
                        left: Box::new(expr),
                        op: MoreLess::Eq,
                        right: Box::new(right),
                    };
                }
                Token::NotEqual => {
                    self.advance();
                    let right = self.parse_compariSON();

                    expr = Expr::MoreLessEq {
                        left: Box::new(expr),
                        op: MoreLess::NotEq,
                        right: Box::new(right),
                    };
                }
                _ => break,

            }
        }
        expr
    }

    fn parse_assign (&mut self) -> Expr {
        if let Some(token) = self.tokens.peek() {
            if matches!(token, Token::TypeU32 | Token::TypeU16 | Token::TypeU8 | Token::TypeI32 | Token::TypeI16 | Token::TypeI8) {
                return self.parse_var_decl();
            }
        }

        let lhs = self.parse_equality();

        if self.tokens.peek() == Some(&Token::Equal) {
            self.advance();
            
            match &lhs {
                Expr::Identifier(_) | Expr::Deref(_) => {}
                _ => panic!("Invalid lhs value: Only variables or memory addresses can be assigned"),
            }
            
            //Recursively to allow val=val1=5
            let rhs = self.parse_assign();

            Expr::Assign {
                lhs: Box::new(lhs),
                rhs: Box::new(rhs),
            }
        } else {
            lhs
        }
    }

    fn parse_var_decl(&mut self) -> Expr {

        let ty = match self.advance() {
            Token::TypeU32 => Type::U32,
            Token::TypeU16 => Type::U16,
            Token::TypeU8 => Type::U8,
            Token::TypeI32 => Type::I32,
            Token::TypeI16 => Type::I16,
            Token::TypeI8 => Type::I8,

            other => panic!("Expected type at the start of declaration, found {:?}", other),
        };
        let name = if let Token::Identifier(var_name) = self.advance() {
            var_name
        } else {
            panic!("Expected identifier name after type variable declaration");
        };

        if self.tokens.peek() == Some(&Token::Equal) {
            self.advance();
            let initial_expr = self.parse_assign();

            self.expect(Token::Semicolon);

            Expr::VarDecl {
                ty,
                name,
                initial: Some(Box::new(initial_expr)),
            }
        }
        else {
            self.expect(Token::Semicolon);
            Expr::VarDecl {
                ty,
                name,
                initial: None,
            }
        }
    }
}
