//Parser for FLARE-10K precende table in the main directory of language.
//Refer to it, it might act as a documentation
//It is LL(1) recusrsive descent parser

use crate::lexer::Lexer;
use crate::lexer::Token;

#[derive(Debug, Clone, PartialEq)]
pub struct ParamField {
    pub ty: Type,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FunctionSignature {
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
    pub decl: Expr,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Program {
    pub structs: Vec<StructDef>,
    pub globals: Vec<GlobalDef>,
    pub functions: Vec<FunctionSignature>,
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
    Break,
    Expr(Expr), //Assigments or function calls
}

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    U8, U16, U32,
    I8, I16, I32,
    Bool,
    Struct(String),
    Ptr(Box<Type>),
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

    BitwiseAnd,
    BitwiseOr,
    BitwiseXor,
    Shl,
    Shr,
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
    Reference(Box<Expr>),
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
    FieldAccess {
        expr: Box<Expr>, // Allows chaining like a.b.c
        field: String,
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
        let (tok, _line, _col) = self.tokens.next().expect("Unexpected EOF");
        tok
    }

    fn peek_two(&mut self) -> Option<Token> {
        let mut iter_clone = self.tokens.clone();
        iter_clone.next();

        iter_clone.next().map(|(tok, _, _)| tok) //Return second one if it exists
    }

    fn expect(&mut self, to_expect: Token) {
        if let Some(&(ref next_tok, line, col)) = self.tokens.peek() {
            if next_tok == &to_expect {
                self.tokens.next();
            } else {
                panic!(
                    "Parser Error: Expected token {:?}, found {:?} at line {}, character {}",
                    to_expect, next_tok, line, col
                );
            }
        } else {
            panic!(
                "Parser Error: Expected token {:?}, found End of File",
                to_expect
            );
        }
    }

    fn match_type(&mut self) -> Type {
        let mut pointer_count = 0;
        //Consume asterixes, can be more than one
        while let Some(&(Token::Asterix, _, _)) = self.tokens.peek() {
            self.advance();
            pointer_count += 1;
        }

        let (line, col) = match self.tokens.peek() {
            Some((_, l, c)) => (*l, *c),
            None => panic!("Parser Error: Unexpected EOF parsing type"),
        };

        let tok = self.advance();
        let mut current_type = match tok {
            Token::TypeU32 => Type::U32,
            Token::TypeU16 => Type::U16,
            Token::TypeU8  => Type::U8,
            Token::TypeI32 => Type::I32,
            Token::TypeI16 => Type::I16,
            Token::TypeI8  => Type::I8,
            Token::TypeBool => Type::Bool,
            Token::Identifier(name) => Type::Struct(name),
            other => panic!("Parser Error: Expected type, found {:?} at line {}, character {}", other, line, col),
        };

        for _ in 0..pointer_count {
            current_type = Type::Ptr(Box::new(current_type));
        }

        current_type
    }
}

//Recursive descent
impl<'a> Parser<'a> {
    //Highest precedence
    //Parse: literals, identifiers, calls
    fn parse_atomic(&mut self) -> Expr {
        let (tok, line, col) = self.tokens.next().expect("Unexpected End of File");
        match tok {
            Token::IntLiteral(val) => Expr::IntLiteral(val),
            Token::HexLiteral(val) => Expr::HexLiteral(val),
            Token::BinaryLiteral(val) => Expr::HexLiteral(val),
            Token::BoolLiteral(val) => {Expr::IntLiteral(if val { 1 } else { 0 })},
            Token::Identifier(name) => Expr::Identifier(name),
            Token::LBracket => {
                let inner_expr = self.parse_assign();
                self.expect(Token::RBracket);
                Expr::Deref(Box::new(inner_expr))
            }
            Token::LParen => {
                let inner_expr = self.parse_assign();
                self.expect(Token::RParen);
                inner_expr
            }
            anything_else => panic!(
                "Parser Error: Expected atomic expression, found {:?} at line {}, character {}",
                anything_else, line, col
            ),
        }
    }

    //Parse function calls and postfixes(field access)
    fn parse_postfix(&mut self) -> Expr {
        let mut expr = self.parse_atomic();

        while let Some(&(ref token, line, col)) = self.tokens.peek() {
            match token {
                Token::Dot => {
                    self.advance();
                    let (next_tok, f_line, f_col) = self.tokens.next().expect("Unexpected EOF after '.'");
                    if let Token::Identifier(field_name) = next_tok {
                        expr = Expr::FieldAccess {
                            expr: Box::new(expr),
                            field: field_name,
                        };
                    } else {
                        panic!("Parser Error: Expected field ID after after dot, found {:?} at line {}, character {}", next_tok, f_line, f_col);
                    }
                }
                //Function call
                Token::LParen => {
                    self.advance();
                    let args = self.parse_call_args();

                    if let Expr::Identifier(name) = expr {
                        expr = Expr::FunctionCall { name, args };
                    } else {
                        panic!("Parser Error: Left-hand side of function call must be an identifier at line {}, character {}", line, col);
                    }
                }
                _ => break,
            }
        }
        expr
    }
    //Cast works just as in rust, its pretty convinient falls to atomic
    fn parse_cast(&mut self) -> Expr {
        let mut expr = self.parse_postfix();

        if let Some(&(Token::As, _, _)) = self.tokens.peek() {
            self.advance();

            let target_type = self.match_type(); 
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
            Some(&(Token::Sub, _, _)) => {
                self.advance();
                //Recursive, so --5 is possible
                let val = self.parse_unary();

                Expr::Unary {
                    op: UnaryOpKind::Negate,
                    expr: Box::new(val),
                }
            }
            Some(&(Token::Excl, _, _)) => {
                self.advance();
                let val = self.parse_unary();

                Expr::Unary {
                    op: UnaryOpKind::Not,
                    expr: Box::new(val),
                }
            }
            Some(&(Token::Ampersand, _, _)) => {
                self.advance();
                let target = self.parse_atomic();
                Expr::Reference(Box::new(target))
            }
            _ => self.parse_cast(),
        }
    }
    //Parse * and / higher precedence that + and -, first falls to unary
    fn parse_factor(&mut self) -> Expr {
        let mut expr = self.parse_unary();

        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            match token {
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

        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            match token {
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

    fn parse_shifts(&mut self) -> Expr {
        let mut expr = self.parse_term();

        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            let op = match token {
                Token::Shl => BinaryOpKind::Shl,
                Token::Shr => BinaryOpKind::Shr,
                _ => break,
            };
            self.advance();

            let right= self.parse_term();

            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
            }
        }
        expr
    }

    //Parsing regular bitwises, all have same precedence bc them having different ones is kidna
    //stupid imo
    fn parse_bitwises(&mut self) -> Expr {
        let mut expr = self.parse_shifts();

        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            let op = match token {
                Token::Ampersand => BinaryOpKind::BitwiseAnd,
                Token::Line => BinaryOpKind::BitwiseOr,
                Token::Hat => BinaryOpKind::BitwiseXor,
                _ => break,
            };
            self.advance();

            let right = self.parse_shifts();

            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
            };
        }
        expr
    }

    //Similar again falls to term bc it can be val+val1 < val*val1
    //Also it can technically be val < val1 < val2
    #[warn(non_snake_case)] //Very important
    fn parse_compariSON(&mut self) -> Expr {
        let mut expr = self.parse_bitwises();

        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            match token {
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

                    expr = Expr::MoreLessEq {
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

        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            match token {
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

    fn parse_assign(&mut self) -> Expr {
        if let Some(&(ref token, _, _)) = self.tokens.peek() {
            let is_builtin_type = matches!(
                token,
                Token::TypeU32
                    | Token::TypeU16
                    | Token::TypeU8
                    | Token::TypeI32
                    | Token::TypeI16
                    | Token::TypeI8
                    | Token::TypeBool
                    | Token::Asterix
            );

            //Its an struct if its identifier followed by another identifier
            let is_struct_type = matches!(token, Token::Identifier(_))
                && matches!(self.peek_two(), Some(Token::Identifier(_)));

            if is_builtin_type || is_struct_type {
                return self.parse_var_decl();
            }
        }

        let lhs = self.parse_equality();

        if let Some(&(Token::Equal, _, _)) = self.tokens.peek() {
            self.advance();

            match &lhs {
                Expr::Identifier(_) | Expr::Deref(_) | Expr::FieldAccess { .. } => {}
                other => panic!(
                    "Parser Error: Invalid lhs value: Only variables or memory addresses can be assigned, found {:?}", other
                ),
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
        let ty = self.match_type();

        let (ident_tok, ident_line, ident_col) =
            self.tokens.next().expect("Unexpected End of File");
        let name = if let Token::Identifier(var_name) = ident_tok {
            var_name
        } else {
            panic!(
                "Parser Error: Expected identifier name after type variable declaration, found {:?} at line {}, character {}",
                ident_tok, ident_line, ident_col
            );
        };

        if let Some(&(Token::Equal, _, _)) = self.tokens.peek() {
            self.advance();
            let initial_expr = self.parse_assign();

            Expr::VarDecl {
                ty,
                name,
                initial: Some(Box::new(initial_expr)),
            }
        } else {
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
            Some(&(Token::For, _, _)) => {
                self.advance();
                self.parse_for_stmt()
            }
            Some(&(Token::While, _, _)) => {
                self.advance();
                self.parse_while_stmt()
            }
            Some(&(Token::Break, _, _)) => {
                self.advance();
                self.expect(Token::Semicolon);
                Stmt::Break
            }
            Some(&(Token::If, _, _)) => {
                self.advance();
                self.parse_ifelse_stmt()
            }
            Some(&(Token::Inline, _, _)) => {
                self.advance();
                self.parse_inline_asm()
            }
            Some(&(Token::Return, _, _)) => {
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
        if let Some(&(Token::Semicolon, _, _)) = self.tokens.peek() {
            self.advance();
        }

        self.expect(Token::RBracket);
        self.expect(Token::LBrace);

        let mut body = Vec::new();
        while let Some(&(ref token, _, _)) = self.tokens.peek() {
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
        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            main_branch.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);
        let mut else_branch = None;

        if let Some(&(Token::Else, _, _)) = self.tokens.peek() {
            self.advance();

            if let Some(&(Token::If, _, _)) = self.tokens.peek() {
                self.advance();
                let buff = self.parse_ifelse_stmt();
                else_branch = Some(vec![buff]);
            } else {
                self.expect(Token::LBrace);
                let mut else_body = Vec::new();
                while let Some(&(ref token, _, _)) = self.tokens.peek() {
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
        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            body.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);

        Stmt::While { cond, body }
    }

    fn parse_return_stmt(&mut self) -> Stmt {
        if let Some(&(Token::Semicolon, _, _)) = self.tokens.peek() {
            //Empty return for voids
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

        let (next_tok, line, col) = self.tokens.next().expect("Unexpected End of File");
        let inline_string = match next_tok {
            Token::InlineBlock(asm_str) => asm_str,
            other => panic!(
                "Parser Error: Expected raw asm, but got {:?} at line {}, character {}",
                other, line, col
            ),
        };

        self.expect(Token::Outline);
        self.expect(Token::RBracket);
        self.expect(Token::Semicolon);

        Stmt::InlineAsm(inline_string)
    }

    fn parse_call_args(&mut self) -> Vec<Expr> {
        let mut args: Vec<Expr> = Vec::new();
        if let Some(&(Token::RParen, _, _)) = self.tokens.peek() {
            //Zero args
            return args;
        }

        loop {
            args.push(self.parse_assign());

            let (next_tok, line, col) = self.tokens.next().expect("Unexpected End of File");
            match next_tok {
                Token::Comma => {}
                Token::RParen => {
                    break;
                }
                other => panic!(
                    "Parser Error: Expected ',' or ')' in function arguments, but found {:?} at line {}, character {}",
                    other, line, col
                ),
            }
        }
        args
    }

    //Parsing whole program, very top of precedence table
    pub fn parse_everything(&mut self) -> Program {
        let mut program = Program {
            structs: Vec::new(),
            globals: Vec::new(),
            functions: Vec::new(),
        };

        while let Some(&(ref token, line, col)) = self.tokens.peek() {
            match token {
                Token::Arch => {
                    self.advance();
                    program.structs.push(self.parse_arch());
                }
                Token::Def => {
                    self.advance();
                    let var_expr = self.parse_var_decl();
                    self.expect(Token::Semicolon);
                    program.globals.push(GlobalDef { decl: var_expr });
                }
                Token::Func => {
                    self.advance();
                    program.functions.push(self.parse_function());
                }
                other => panic!(
                    "Parser Error: Expected global declaration (arch, #def, or func), but found {:?} at line {}, character {}",
                    other, line, col
                ),
            }
        }
        program
    }

    fn parse_function(&mut self) -> FunctionSignature {
        let name: String;
        let mut params: Vec<ParamField> = Vec::new();
        let to_return: Option<Type>;
        let mut body: Vec<Stmt> = Vec::new();

        if let Some(&(Token::Identifier(ref a), _, _)) = self.tokens.peek() {
            name = a.clone();
            self.advance();
        } else {
            panic!("Parser Error: Expected function name after func");
        }

        self.expect(Token::LParen);

        if let Some(&(Token::RParen, _, _)) = self.tokens.peek() {
            // No params
            self.advance();
        } else {
            loop {
                let (token, line, col) = self
                    .tokens
                    .peek()
                    .cloned()
                    .expect("Unexpected EOF in parameters");

                if matches!(
                    token,
                    Token::TypeU32
                        | Token::TypeU16
                        | Token::TypeU8
                        | Token::TypeI32
                        | Token::TypeI16
                        | Token::TypeI8
                        | Token::TypeBool
                        | Token::Identifier(_)
                        | Token::Asterix
                ) {
                    let ty = self.match_type();

                    let (name_tok, name_line, name_col) =
                        self.tokens.next().expect("Unexpected End of File");
                    let param_name = match name_tok {
                        Token::Identifier(buff) => buff,
                        other => panic!(
                            "Parser Error: Expected name after type, found {:?} at line {}, character {}",
                            other, name_line, name_col
                        ),
                    };

                    params.push(ParamField {
                        ty,
                        name: param_name,
                    });
                } else {
                    panic!(
                        "Parser Error: Expected parameter type declaration, found {:?} at line {}, character {}",
                        token, line, col
                    );
                }

                let (delim_tok, delim_line, delim_col) =
                    self.tokens.next().expect("Unexpected End of File");
                match delim_tok {
                    Token::Comma => {}
                    Token::RParen => {
                        break;
                    }
                    other => panic!(
                        "Parser Error: Expected ',' or ')' in function parameters, but found {:?} at line {}, character {}",
                        other, delim_line, delim_col
                    ),
                }
            }
        }

        if let Some(&(Token::ToRet, _, _)) = self.tokens.peek() {
            self.advance();

            if let Some(&(ref token, line, col)) = self.tokens.peek() {
                if matches!(
                    token,
                    Token::TypeU32
                        | Token::TypeU16
                        | Token::TypeU8
                        | Token::TypeI32
                        | Token::TypeI16
                        | Token::TypeI8
                        | Token::TypeBool
                        | Token::Identifier(_)
                        | Token::Asterix
                ) {
                    to_return = Some(self.match_type());
                } else {
                    panic!(
                        "Parser Error: Expected return type after =>, found {:?} at line {}, character {}",
                        token, line, col
                    );
                }
            } else {
                panic!("Parser Error: Expected return type after =>, reached End of File");
            }
        } else {
            to_return = None;
        }

        self.expect(Token::LBrace);
        while let Some(&(ref token, _, _)) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            body.push(self.parse_stmt());
        }
        self.expect(Token::RBrace);

        FunctionSignature {
            name,
            params,
            to_return,
            body,
        }
    }

    fn parse_arch(&mut self) -> StructDef {
        let name: String;
        let mut fields: Vec<ParamField> = Vec::new();

        if let Some(&(Token::Identifier(ref a), _, _)) = self.tokens.peek() {
            name = a.clone();
            self.advance();
        } else {
            panic!("Parser Error: Expected struct name after arch");
        }
        self.expect(Token::LBrace);

        while let Some(&(ref token, line, col)) = self.tokens.peek() {
            if token == &Token::RBrace {
                break;
            }
            if matches!(
                token,
                Token::TypeU32
                    | Token::TypeU16
                    | Token::TypeU8
                    | Token::TypeI32
                    | Token::TypeI16
                    | Token::TypeI8
                    | Token::TypeBool
                    | Token::Identifier(_)
                    | Token::Asterix
            ) {
                let ty = self.match_type();

                let (name_tok, name_line, name_col) =
                    self.tokens.next().expect("Unexpected End of File");
                let field_name = match name_tok {
                    Token::Identifier(buff) => buff,
                    other => panic!(
                        "Parser Error: Expected name after type, found {:?} at line {}, character {}",
                        other, name_line, name_col
                    ),
                };

                fields.push(ParamField {
                    ty,
                    name: field_name,
                });
                self.expect(Token::Semicolon);
            } else {
                panic!(
                    "Parser Error: Expected field declaration inside struct body, found {:?} at line {}, character {}",
                    token, line, col
                );
            }
        }

        self.expect(Token::RBrace);
        self.expect(Token::Semicolon);

        StructDef { name, fields }
    }
}

