use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, Write};

fn main() -> io::Result<()> {
    let input_path = "program.twinion";
    let output_path = "program.twex";

    let mut labels: HashMap<String, u16> = HashMap::new();
    let mut instructions: Vec<String> = Vec::new();

    let file = File::open(input_path)?;
    let reader = io::BufReader::new(file);
    let mut address_counter = 0;
    
    // First pass
    for line_result in reader.lines() {
        let line = line_result?;
        let not_commented = line.split(">_").next().unwrap().trim();
        if not_commented.is_empty() {
            continue;
        }

        if not_commented.starts_with('~') && not_commented.ends_with(':') {
            // Found label
            let label = not_commented[1..not_commented.len() - 1].to_string();
            labels.insert(label, address_counter);
        } else {
            // Found instruction
            instructions.push(not_commented.to_string());
            address_counter += 1;
        }
    }

    let mut machine_code: Vec<u16> = Vec::new();
    
    // Second pass 
    for (current_address, instruction) in instructions.iter().enumerate() {
        machine_code.push(tokenizer(instruction, &labels, current_address as u16));
    }

    write_hex(output_path, &machine_code)?;
    println!("Compilation successful! Written to {}", output_path);
    Ok(())
}

fn tokenizer(instruction: &str, labels: &HashMap<String, u16>, _current_address: u16) -> u16 {
    //Clean up
    let normalized = instruction.replace(|c: char| c == '-' || c == '>' || c =='<' || c == '[' || c == ']' || c == ',', " ");
    let tokens: Vec<&str> = normalized.split_whitespace().collect();

    if tokens.is_empty() { return 0; }

    let opcode_str = tokens[0].to_uppercase();
    let opcode = match opcode_str.as_str() {
        "ADD" => 0b00010,
        "SUB" => 0b00100,
        "XOR" => 0b00011,
        "OR"  => 0b00001,
        "AND" => 0b00000,
        "NOT" => 0b00101,
        "SHL" => 0b01000,
        "SHR" => 0b01100,
        "MUL" => 0b01111,
        "LOAD"=> 0b10010,
        "LDR" => 0b10100,
        "STR" => 0b10110,
        "BEQ" => 0b11111,
        "BNE" => 0b11110,
        "BS"  => 0b11100,
        "BG"  => 0b11000,
        "JMP" => 0b10001,
        _ => 0b00000,
    };

    let mut rx0_bits: u16 = 0;
    let mut rx1_bits: u16 = 0;
    let mut spare_bits: u16 = 0;

    if tokens.len() > 1 {
        if tokens[1].starts_with("rx") {
            rx0_bits = parse_register(tokens[1]);
        } else {
            spare_bits = tokens[1].parse::<u16>().unwrap_or(0) & 0x1F;
        }
    }

    if tokens.len() > 2 {
        if tokens[2].starts_with("rx") {
            rx1_bits = parse_register(tokens[2]);
        } else {
            //handle labels
            let clean_token = tokens[2].trim_start_matches('~');
            if let Some(&label_address) = labels.get(clean_token) {
                spare_bits = label_address & 0x1F;
            //Handle contstants
            } else {
                spare_bits = tokens[2].parse::<u16>().unwrap_or(0) & 0x1F;
            }
        }
    }
    
    if tokens.len() > 3 {
        let clean_token = tokens[3].trim_start_matches('~');
        if let Some(&label_address) = labels.get(clean_token) {
            spare_bits = label_address & 0x1F;
        } else {
            spare_bits = tokens[3].parse::<u16>().unwrap_or(0) & 0x1F;
        }
    }

    (opcode << 11) | (rx0_bits << 8) | (rx1_bits << 5) | spare_bits
}


fn parse_register(reg_str: &str) -> u16 {
    match reg_str.to_lowercase().as_str() {
        "rx0" => 0b000, "rx1" => 0b001, "rx2" => 0b010, "rx3" => 0b011,
        "rx4" => 0b100, "rx5" => 0b101, "rx6" => 0b110, "rx7" => 0b111,
        _ => 0,
    }
}

fn write_hex(output_path: &str, code: &[u16]) -> io::Result<()> {
    let mut file = File::create(output_path)?;
    writeln!(file, "v3.0 hex words addressed")?;

    for (i, chunk) in code.chunks(4).enumerate() {
        let base_addr = i * 4;
        write!(file, "{:02x}:", base_addr)?;
        for word in chunk {
            write!(file, " {:04x}", word)?;
        }
        writeln!(file)?;
    }
    Ok(())
}
