use std::iter::Peekable;
use std::str::Chars;

mod lexer;
use lexer::Lexer;

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
    }
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

    fn parse_expr(&mut self) -> Expr { todo!() }
    fn parse_func(&mut self) -> Vec<Expr> { todo!() }

    //Highest precedence
    fn parse_atomic(&mut self) -> Expr {
        match self.tokens.peek() {
            Some(Token::IntLiteral(_)) => {
                if let Token::IntLiteral(val) = self.advance() {
                    Expr::IntLiteral(val)
                } else { unreachable!() } //Literally unreachable just for later optimizations
            }
            Some(Token::HexLiteral(_)) => {
                if let Token::HexLiteral(val) = self.advance() {
                    Expr::HexLiteral(val)
                } else { unreachable!() }
            }
            Some(Token::Identifier(_)) => {
                if let Token::Identifier(name) = self.advance() {
                    if self.tokens.peek() == Some(&Token::LParen) {
                        self.advance();
                        let args = self.parse_func();
                        self.expect(Token::RParen);
                        Expr::FunctionCall { name, args }
                    } else {
                        Expr::Identifier(name)
                    }
                } else { unreachable!() }
            }
            Some(Token::LBracket) => {
                self.advance();
                let val = self.parse_expr();
                self.expect(Token::RBracket);
                Expr::Deref(Box::new(val))
            }
            _ => panic!("Expected atomic expression"),
        }
    }
    fn parse_cast(&mut self) -> Expr {
        let mut expr = self.parse_atomic();
        
        if self.tokens.peek() == Some(&Token::As) {
            self.advance();

            let target_type = match self.advance() {
                Token::U32 => Type::U32,
                Token::U16 => Type::U16,
                Token::U8 => Type::U8,
                Token::I32 => Type::I32,
                Token::I16 => Type::I16,
                Token::I8 => Type::I8,



                other => panic!("Expected a type after 'as', found {:?}", other),
            };

            expr = Expr::Cast {
                expr: Box::new(expr),
                target_type,
            };
        }
        expr
    }

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

    fn parse_factor(&mut self) -> Expr {
        let mut expr = self.parse_unary();
        
        while let Some(token) = self.tokens.peek(){
            match token{
                Token::Mul => {
                    self.advance();
                    let right = self.parse_unary();

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
                _ => break;
            }
        }
        expr
    }

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
                _ => break;
            }
        }
        expr
    }
    
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
                _ => break;
            }
        }
        expr
    }

    fn parse_equality(&mut self) -> Expr {
        let mut expr = self.parse_compariSON();
        
        while let Some(token) = self.tokens.peek(){
            match token{
                Token::IsEqual => {
                    self.advance();
                    let right = self.parse_term();

                    expr = Expr::MoreLessEq {
                        left: Box::new(expr),
                        op: MoreLess::Eq,
                        right: Box::new(right),
                    };
                _ => break;

                }
            }
        }
        expr
    }

    fn parse_assign(&mut self) -> Expr {

    }
}
