use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, Write};

fn main() -> io::Result<()> {
    let input_path = "stresstest.eci";
    let output_path = "stresstest.hex";

    let mut labels: HashMap<String, u16> = HashMap::new();
    let mut instrs: Vec<String> = Vec::new();

    let file = File::open(input_path)?;
    let reader = io::BufReader::new(file);
    let mut address_counter = 0;

    // First pass collect labels and isntructions
    for line_result in reader.lines() {
        let line = line_result?;
        let not_commented = line.split(">_").next().unwrap().trim();
        if not_commented.is_empty() {
            continue;
        }

        if not_commented.starts_with('~') && not_commented.ends_with(':') {
            let label = not_commented[1..not_commented.len() - 1].to_string();
            labels.insert(label, address_counter);
        } else {
            instrs.push(not_commented.to_string());
            address_counter += 4;
        }
    }

    //opcodes mapping
    let mut opcodes: HashMap<&str, u32> = HashMap::new();
    opcodes.insert("ADD", 0b000001);
    opcodes.insert("SUB", 0b000011);
    opcodes.insert("MUL", 0b000111); //Mul defaults to LOMUL
    opcodes.insert("LOMUL", 0b000111);
    opcodes.insert("HIMUL", 0b001101);
    opcodes.insert("XOR", 0b000010);
    opcodes.insert("OR", 0b000110);
    opcodes.insert("AND", 0b001110);
    opcodes.insert("NOT", 0b001111);
    opcodes.insert("SHL", 0b001000);
    opcodes.insert("SHR", 0b001100);
    opcodes.insert("SRA", 0b001010);
    opcodes.insert("LOAD", 0b010001);
    opcodes.insert("LDR", 0b100011);
    opcodes.insert("STR", 0b100111);
    opcodes.insert("BEQ", 0b110000);
    opcodes.insert("BNE", 0b110001);
    opcodes.insert("BS", 0b110011);
    opcodes.insert("BG", 0b110111);
    opcodes.insert("JMP", 0b111111);

    let mut output_file = File::create(output_path)?;

    // Second pass: Tokenization and machine code construction
    for (current_address, inst_line) in instrs.iter().enumerate() {
        let current_pc = (current_address as u32) * 4;

        let cleared = inst_line
            //Practically this syntax is optional
            .replace("<-", " ")
            .replace("[", " ")
            .replace("]", " ")
            .replace(",", " ");

        let tokens: Vec<&str> = cleared.split_whitespace().collect();

        if tokens.is_empty() {
            continue;
        }

        let instr = tokens[0].to_uppercase();
        let opcode = *opcodes.get(instr.as_str()).unwrap_or_else(|| {
            panic!("Unknown instruction token: {}", instr);
        });

        let mut rx0: u32 = 0;
        let mut rx1: u32 = 0;
        let mut immediate: u32 = 0;

        match instr.as_str() {
            "LOAD" => {
                if tokens.len() > 1 {
                    rx0 = parse_reg(tokens[1]);
                }
                if tokens.len() > 2 {
                    immediate = tokens[2].parse::<u32>().unwrap_or(0);
                }
            }
            "LDR" | "STR" => {
                if tokens.len() > 1 {
                    rx0 = parse_reg(tokens[1]);
                }
                if tokens.len() > 2 {
                    rx1 = parse_reg(tokens[2]);
                }
                if tokens.len() > 3 {
                    if tokens[3] == "-" && tokens.len() > 4 {
                        let val = tokens[4].parse::<i32>().unwrap_or(0);
                        immediate = (-val) as u32;
                    } 
                    else if tokens[3] == "+" && tokens.len() > 4 {
                        immediate = tokens[4].parse::<i32>().unwrap_or(0) as u32;
                    } 
                    else {
                        let target = tokens[3].trim_start_matches('~');
                        if let Some(&label_addr) = labels.get(target) {
                            let offset = (label_addr as i32) - ((current_pc + 4) as i32);
                            immediate = offset as u32;
                        } else {
                            immediate = target.parse::<i32>().unwrap_or(0) as u32;
                        }
                    }
                }
            }
            "BEQ" | "BNE" | "BS" | "BG" => {
                if tokens.len() > 1 {
                    rx0 = parse_reg(tokens[1]);
                }
                if tokens.len() > 2 {
                    rx1 = parse_reg(tokens[2]);
                }
                if tokens.len() > 3 {
                    let target = tokens[3].trim_start_matches('~');
                    if let Some(&label_addr) = labels.get(target) {
                        let offset = (label_addr as i32) - ((current_pc + 4) as i32);
                        immediate = offset as u32;
                    } else {
                        immediate = target.parse::<u32>().unwrap_or(0);
                    }
                }
            }
            "JMP" => {
                if tokens.len() > 1 {
                    let target = tokens[1].trim_start_matches('~');
                    if let Some(&label_addr) = labels.get(target) {
                        let offset = (label_addr as i32) - ((current_pc + 4) as i32);
                        immediate = offset as u32;
                    } else {
                        immediate = target.parse::<u32>().unwrap_or(0);
                    }
                }
            }
            _ => {
                if tokens.len() > 1 {
                    rx0 = parse_reg(tokens[1]);
                }
                if tokens.len() > 2 {
                    rx1 = parse_reg(tokens[2]);
                }
            }
        }

        let machine_code: u32 = ((opcode & 0x3F) << 26)
            | ((rx0 & 0x1F) << 21)
            | ((rx1 & 0x1F) << 16)
            | (immediate & 0xFFFF);

        // SystemVerilog $readmemh format
        writeln!(output_file, "{:08X}", machine_code)?;
    }

    Ok(())
}

fn parse_reg(reg_str: &str) -> u32 {
    let clean = reg_str.trim_start_matches(|c| c == 'r' || c == 'R' || c == 'x' || c == 'X');
    clean.parse::<u32>().unwrap_or(0)
}
