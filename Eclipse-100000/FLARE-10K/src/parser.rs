//Parser for FLARE-10K precende table in the main directory of language.
//Refer to it, it might act as a documentation
//It is LL(1) recisrive descent parser
use std::iter::Peekable;
use std::str::Chars;

use crate::lexer::Lexer;
use crate::lexer::Token;

#[derive(Debug, Clone, PartialEq)]
pub struct ParamField {
    pub ty: Type,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FunctionDef {
    pub name: String,
    pub params: Vec<ParamField>,
    pub to_return: Option<Type>,
    pub body: Vec<Stmt>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StructDef {
    pub name: String,
    pub fields: Vec<ParamField>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GlobalDef {
    pub ty: Type,
    pub name: String,
    pub val: Expr,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Program {
    pub structs: Vec<StructDef>,
    pub globals: Vec<GlobalDef>,
    pub functions: Vec<FunctionDef>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    For {
        init: Box<Expr>,
        cond: Expr,
        inc: Expr,
        body: Vec<Stmt>,
    },
    While {
        cond: Expr,
        body: Vec<Stmt>,
    },
    IfElse {
        cond: Expr,
        main_branch: Vec<Stmt>,
        else_branch: Option<Vec<Stmt>>,
    },
    InlineAsm(String),
    Return(Option<Expr>),
    Expr(Expr), //Assigments or function calls
}

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

    //Highest precedence
    //Parse: literals, identifiers, calls
    fn parse_atomic(&mut self) -> Expr {
        match self.tokens.next() {
            Some(Token::IntLiteral(val)) => Expr::IntLiteral(val),
            Some(Token::HexLiteral(val)) => Expr::HexLiteral(val),
            Some(Token::Identifier(name)) => {
                if self.tokens.peek() == Some(&Token::LParen) {
                    self.tokens.next();
                    let args = self.parse_call_args();
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
            Some(Token::LParen) => { //For parenthisezed math, like (1+5)*2
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
    
    //General, for parsing stmts
    fn parse_stmt(&mut self) -> Stmt {
        match self.tokens.peek() {
            Some(Token::For) => {
                self.advance();
                self.parse_for_stmt()
            }
            Some(Token::While) => {
                self.advance();
                self.parse_while_stmt()
            }
            Some(Token::If) => {
                self.advance();
                self.parse_ifelse_stmt()
            }
            Some(Token::Inline) => {
                self.advance();
                self.parse_inline_asm()
            }
            Some(Token::Return) => {
                self.advance();
                self.parse_return_stmt()
            }
            _ => {
                let expr = self.parse_assign();
                self.expect(Token::Semicolon);
                Stmt::Expr(expr)
            }
        }
    }

    fn parse_for_stmt(&mut self) -> Stmt {
        self.expect(Token::LBracket);

        let init = self.parse_assign();
        self.expect(Token::Semicolon);

        let cond = self.parse_assign();
        self.expect(Token::Semicolon);

        let inc = self.parse_assign();

        //Trailing semicolon is optional, so both [true] and [true;] are valid
        if self.tokens.peek() == Some(&Token::Semicolon) {
            self.advance();
        }

        self.expect(Token::RBracket);
        self.expect(Token::LBrace);

        let mut body = Vec::new();
        while let Some(token) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            body.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);

        Stmt::For {
            init: Box::new(init),
            cond,
            inc,
            body,
        }
    }

    fn parse_ifelse_stmt(&mut self) -> Stmt {
        self.expect(Token::LBracket);
        let cond = self.parse_assign();
        self.expect(Token::RBracket);

        self.expect(Token::LBrace);
        let mut main_branch = Vec::new();
        while let Some(token) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            main_branch.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);
        let mut else_branch = None;

        if self.tokens.peek() == Some(&Token::Else) {
            self.advance();

            if self.tokens.peek() == Some(&Token::If) {
                self.advance();
                let buff = self.parse_ifelse_stmt();
                else_branch = Some(vec![buff]);
            } else {
                self.expect(Token::LBrace);
                let mut else_body = Vec::new();
                while let Some(token) = self.tokens.peek() {
                    if token == &Token::RBrace {
                        break;
                    }
                    else_body.push(self.parse_stmt());
                }
                self.expect(Token::RBrace);
                else_branch = Some(else_body);
            }
        }

        Stmt::IfElse {
            cond,
            main_branch,
            else_branch,
        }
    }

    fn parse_while_stmt(&mut self) -> Stmt {
        self.expect(Token::LBracket);
        let cond = self.parse_assign();
        self.expect(Token::RBracket);

        self.expect(Token::LBrace);
        let mut body = Vec::new();
        while let Some(token) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            body.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);

        Stmt::While {
            cond,
            body,
        }
    }

    fn parse_return_stmt(&mut self) -> Stmt {
        if self.tokens.peek() == Some(&Token::Semicolon) { //Empty return for voids
            self.advance();
            Stmt::Return(None)
        } else {
            let to_return = self.parse_assign();
            self.expect(Token::Semicolon);
            Stmt::Return(Some(to_return))
        }
    }

    fn parse_inline_asm(&mut self) -> Stmt {
        self.expect(Token::LBracket);

        let inline_string = match self.advance() {
            Token::InlineBlock(asm_str) => asm_str,
            other => panic!("Expected raw asm, but got {:?}", other),
        };

        self.expect(Token::Outline);
        self.expect(Token::RBracket);
        self.expect(Token::Semicolon);

        Stmt::InlineAsm(inline_string)
    }

    fn parse_call_args(&mut self) -> Vec<Expr> {
        let mut args: Vec<Expr> = Vec::new();
        if self.tokens.peek() == Some(&Token::RParen) {//Zero args
            return args;
        }

        loop {
            args.push(self.parse_assign());

            match self.tokens.peek() {
                Some(&Token::Comma) => {
                    self.advance();
                }
                Some(&Token::RParen) => {
                    break;
                }
                other => panic!("Expected ',' or ')' in function arguments, but found {:?}", other),
            }
        }
        args
    }

    //Parsing whole program, very top of precedence table
    fn parse_everything(&mut self) -> Program {
        let mut program = Program {
            structs: Vec::new(),
            globals: Vec::new(),
            functions: Vec::new(),
        };

        while let Some(token) = self.tokens.peek() {
            match token {
                Token::Arch => {
                    self.advance();
                    program.structs.push(self.parse_arch());
                }
                Token::Def => {
                    self.advance();
                    program.globals.push(self.parse_global());
                }
                Token::Func => {
                    self.advance();
                    program.functions.push(self.parse_function());
                }
                other => panic!("Expected global declaration (arch, #def, or func), but found {:?}", other),
            }
        }
        program
    }

    fn parse_function(&mut self) -> FunctionDef {
        let name: String;
        let mut params: Vec<ParamField> = Vec::new();
        let to_return: Option<Type>;
        let mut body: Vec<Stmt> = Vec::new();

        if let Some(Token::Identifier(a)) = self.tokens.peek() {
            name = a.clone();
            self.advance();
        } else {
            panic!("Expected function name after func");
        }

        self.expect(Token::LParen);

        if self.tokens.peek() == Some(&Token::RParen) { // No params
            self.advance();
        } else {
            loop {
                if let Some(token) = self.tokens.peek() {
                    if matches!(token, Token::TypeU32 | Token::TypeU16 | Token::TypeU8 | Token::TypeI32 | Token::TypeI16 | Token::TypeI8) {
                        let ty = match self.advance() {
                            Token::TypeU32 => Type::U32,
                            Token::TypeU16 => Type::U16,
                            Token::TypeU8 => Type::U8,
                            Token::TypeI32 => Type::I32,
                            Token::TypeI16 => Type::I16,
                            Token::TypeI8 => Type::I8,
                            _ => unreachable!(),
                        };

                        let param_name = match self.advance() {
                            Token::Identifier(buff) => buff,
                            other => panic!("Expected name after type, found {:?}", other),
                        };

                        params.push(ParamField { ty, name: param_name });
                    } else {
                        panic!("Expected parameter type declaration");
                    }
                }

                match self.tokens.peek() {
                    Some(&Token::Comma) => {
                        self.advance();
                    }
                    Some(&Token::RParen) => {
                        self.advance();
                        break;
                    }
                    other => panic!("Expected ',' or ')' in function parameters, but found {:?}", other),
                }
            }
        }

        if self.tokens.peek() == Some(&Token::ToRet) {
            self.advance();

            if let Some(token) = self.tokens.peek() {
                if matches!(token, Token::TypeU32 | Token::TypeU16 | Token::TypeU8 | Token::TypeI32 | Token::TypeI16 | Token::TypeI8) {
                    to_return = Some(match self.advance() {
                        Token::TypeU32 => Type::U32,
                        Token::TypeU16 => Type::U16,
                        Token::TypeU8 => Type::U8,
                        Token::TypeI32 => Type::I32,
                        Token::TypeI16 => Type::I16,
                        Token::TypeI8 => Type::I8,
                        _ => unreachable!(),
                    });
                } else {
                    panic!("Expected return type after =>");
                }
            } else {
                panic!("Expected return type after =>");
            }
        } else {
            to_return = None;
        }

        self.expect(Token::LBrace);
        while let Some(token) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            body.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);

        FunctionDef {
            name,
            params,
            to_return,
            body,
        }
    }
}
