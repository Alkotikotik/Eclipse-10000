use std::collections::HashMap;
use std::env;
use std::fs::File;
use std::io::{self, BufRead, Write};
use std::process;

fn parse_imm64(token: &str) -> i64 {
    let clean = token.trim_start_matches('~');
    if clean.starts_with("-0x") || clean.starts_with("-0X") {
        let hex_part = &clean[3..];
        -i64::from_str_radix(hex_part, 16).unwrap_or(0)
    } else if clean.starts_with("0x") || clean.starts_with("0X") {
        let hex_part = &clean[2..];
        i64::from_str_radix(hex_part, 16).unwrap_or(0)
    } else {
        clean.parse::<i64>().unwrap_or(0)
    }
}

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: {} <input_file.eci> <output_file.hex>", args[0]);
        process::exit(1);
    }

    let input_path = &args[1];
    let output_path = &args[2];

    let mut labels: HashMap<String, u32> = HashMap::new();
    let mut instrs: Vec<String> = Vec::new();

    let file = File::open(input_path)?;
    let reader = io::BufReader::new(file);
    let mut address_counter: u32 = 0;

    // First pass: collect labels and instructions
    for line_result in reader.lines() {
        let line = line_result?;
        let not_commented = line.split(">_").next().unwrap().trim();
        if not_commented.is_empty() {
            continue;
        }

        if not_commented.to_uppercase().starts_with("#ORG") {
            let parts: Vec<&str> = not_commented.split_whitespace().collect();
            if parts.len() > 1 {
                let target_address = parse_imm64(parts[1]) as u32;

                while address_counter < target_address {
                    instrs.push("PAD".to_string());
                    address_counter += 4;
                }
            }
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

    // Exact Opcode Mappings matched to Control Unit Hardware Spec
    let mut opcodes: HashMap<&str, u32> = HashMap::new();
    opcodes.insert("PAD",   0b000000);
    opcodes.insert("ADD",   0b000001);
    opcodes.insert("SUB",   0b000011);
    opcodes.insert("MUL",   0b000111);
    opcodes.insert("LOMUL", 0b000111);
    opcodes.insert("HIMUL", 0b001101);
    opcodes.insert("XOR",   0b000010);
    opcodes.insert("OR",    0b000110);
    opcodes.insert("AND",   0b001110);
    opcodes.insert("NOT",   0b001111);
    opcodes.insert("SHL",   0b001000);
    opcodes.insert("SHR",   0b001100);
    opcodes.insert("SRA",   0b001010);

    opcodes.insert("LOAD",  0b010001);
    opcodes.insert("LMA",   0b011111);
    opcodes.insert("LDR",   0b100011);
    opcodes.insert("STR",   0b100111);

    opcodes.insert("CMP",   0b110000);

    // Unsigned Branching
    opcodes.insert("BEQ",   0b110001);
    opcodes.insert("BNE",   0b110010);
    opcodes.insert("BGU",   0b110011);
    opcodes.insert("BSU",   0b110100);

    // Signed Branching
    opcodes.insert("BGS",   0b110101);
    opcodes.insert("BSS",   0b110110);

    // Control Flow & System
    opcodes.insert("JMP",   0b111111);
    opcodes.insert("JR",    0b110111);
    opcodes.insert("CALL",  0b111000);
    opcodes.insert("RET",   0b111100);
    opcodes.insert("SYS",   0b111110);
    opcodes.insert("RETU",  0b111101);

    let mut output_file = File::create(output_path)?;

    // Second pass: Instruction construction
    for (current_address, inst_line) in instrs.iter().enumerate() {
        let current_pc = (current_address as u32) * 4;

        let cleared = inst_line
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
        let mut immediate: i64 = 0;
        let mut dest_reg_4bit: u32 = 0;

        match instr.as_str() {
            "LOAD" => {
                if tokens.len() > 1 {
                    rx0 = parse_reg(tokens[1]);
                }
                if tokens.len() > 2 {
                    immediate = parse_imm64(tokens[2]);
                }
            }
            "LMA" => {
                if tokens.len() > 1 {
                    dest_reg_4bit = parse_reg_4bit(tokens[1]);
                }
                if tokens.len() > 2 {
                    let target = tokens[2].trim_start_matches('~');
                    if let Some(&label_addr) = labels.get(target) {
                        immediate = label_addr as i64;
                    } else {
                        immediate = parse_imm64(tokens[2]);
                    }
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
                        let val = parse_imm64(tokens[4]);
                        immediate = -val;
                    } else if tokens[3] == "+" && tokens.len() > 4 {
                        immediate = parse_imm64(tokens[4]);
                    } else {
                        let target = tokens[3].trim_start_matches('~');
                        if let Some(&label_addr) = labels.get(target) {
                            let offset = (label_addr as i64) - ((current_pc + 4) as i64);
                            immediate = offset;
                        } else {
                            immediate = parse_imm64(tokens[3]);
                        }
                    }
                }
            }
            "CMP" => {
                if tokens.len() > 1 {
                    rx0 = parse_reg(tokens[1]);
                }
                if tokens.len() > 2 {
                    rx1 = parse_reg(tokens[2]);
                }
            }
            "BEQ" | "BNE" | "BGU" | "BSU" | "BGS" | "BSS" => {
                if tokens.len() > 1 {
                    let target = tokens[1].trim_start_matches('~');
                    if let Some(&label_addr) = labels.get(target) {
                        let offset = (label_addr as i64) - ((current_pc + 4) as i64);
                        immediate = offset;
                    } else {
                        immediate = parse_imm64(tokens[1]);
                    }
                }
            }
            "JR" => {
                if tokens.len() > 1 {
                    rx1 = parse_reg(tokens[1]);
                }
            }
            "JMP" | "CALL" => {
                if tokens.len() > 1 {
                    let target = tokens[1].trim_start_matches('~');
                    if let Some(&label_addr) = labels.get(target) {
                        let offset = (label_addr as i64) - ((current_pc + 4) as i64);
                        immediate = offset;
                    } else {
                        immediate = parse_imm64(tokens[1]);
                    }
                }
            }
            "RET" | "SYS" | "RETU" | "PAD" => {
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

        let imm_u32 = immediate as u32;

        let machine_code: u32 = match instr.as_str() {
            "LMA" => {
                ((opcode & 0x3F) << 26)
                    | ((dest_reg_4bit & 0x0F) << 22)
                    | (imm_u32 & 0x003F_FFFF)
            }
            "JMP" | "CALL" => {
                ((opcode & 0x3F) << 26) | (imm_u32 & 0x03FF_FFFF)
            }
            _ => {
                ((opcode & 0x3F) << 26)
                    | ((rx0 & 0x7F) << 19)
                    | ((rx1 & 0x7F) << 12)
                    | (imm_u32 & 0x0FFF)
            }
        };

        writeln!(output_file, "{:02X}", (machine_code & 0xFF) as u8)?;
        writeln!(output_file, "{:02X}", ((machine_code >> 8) & 0xFF) as u8)?;
        writeln!(output_file, "{:02X}", ((machine_code >> 16) & 0xFF) as u8)?;
        writeln!(output_file, "{:02X}", ((machine_code >> 24) & 0xFF) as u8)?;
    }

    Ok(())
}

fn parse_reg(reg_str: &str) -> u32 {
    let upper = reg_str.to_uppercase();

    if upper == "SP" || upper == "TSP" {
        return (15 << 3) | 0b000;
    } else if upper == "LR" || upper == "RA" {
        return (14 << 3) | 0b000;
    }

    let prefix = if upper.starts_with("RZ") {
        "RZ"
    } else if upper.starts_with("RY") {
        "RY"
    } else if upper.starts_with("RX") {
        "RX"
    } else if upper.starts_with('R') {
        "R"
    } else {
        ""
    };

    let rest = upper.trim_start_matches(prefix);

    if rest.contains('_') || rest.contains('.') {
        let parts: Vec<&str> = rest.split(|c| c == '_' || c == '.').collect();
        let reg_id = parts[0].parse::<u32>().unwrap_or(0) & 0x0F;
        let sub_offset = parts.get(1).and_then(|s| s.parse::<u32>().ok()).unwrap_or(0) & 0x07;
        return (reg_id << 3) | sub_offset;
    }

    let num = rest.parse::<u32>().unwrap_or(0);

    match prefix {
        "RZ" => {
            let reg_id = (num / 10) & 0x0F;
            let offset = (num % 10) & 0x07;
            (reg_id << 3) | offset
        }
        "RY" => {
            let reg_id = (num / 10) & 0x0F;
            let offset = if (num % 10) > 0 { 0b010 } else { 0b000 };
            (reg_id << 3) | offset
        }
        _ => {
            let reg_id = num & 0x0F;
            (reg_id << 3) | 0b000
        }
    }
}

fn parse_reg_4bit(reg_str: &str) -> u32 {
    let addr_7b = parse_reg(reg_str);
    (addr_7b >> 3) & 0x0F
}
