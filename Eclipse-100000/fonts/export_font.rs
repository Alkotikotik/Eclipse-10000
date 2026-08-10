use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};

fn main() -> std::io::Result<()> {
    let file = File::open("ENC-10K-16.bdf")?;
    let reader = BufReader::new(file);

    let mut glyphs: HashMap<usize, Vec<u8>> = HashMap::new();
    let mut current_encoding: Option<usize> = None;
    let mut in_bitmap = false;
    let mut current_bytes: Vec<u8> = Vec::new();

    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();

        if trimmed.starts_with("ENCODING") {
            if let Some(parts) = trimmed.split_whitespace().nth(1) {
                current_encoding = parts.parse::<usize>().ok();
            }
        } else if trimmed == "BITMAP" {
            in_bitmap = true;
            current_bytes.clear();
        } else if trimmed == "ENDCHAR" {
            in_bitmap = false;
            if let Some(enc) = current_encoding {
                // Pad or truncate to exactly 16 bytes
                while current_bytes.len() < 16 {
                    current_bytes.push(0x00);
                }
                current_bytes.truncate(16);
                glyphs.insert(enc, current_bytes.clone());
            }
        } else if in_bitmap {
            if let Ok(val) = u8::from_str_radix(trimmed, 16) {
                current_bytes.push(val);
            }
        }
    }

    let max_index = 95;

    println!("u8 font_data[] = {{");
    let mut indexx = 0;
    for idx in 45..=max_index {
        if let Some(bytes) = glyphs.get(&idx) {
            println!("    >_ Index {} (real: {})", indexx, idx);
            print!("    ");
            for (i, b) in bytes.iter().enumerate() {
                print!("0x{:02X}, ", b);
                if i == 7 {
                    print!("\n    ");
                }
            }
            println!();
            indexx += 1;
        }
    }

    println!("}};");
    println!("Size: {}", indexx * 16);
    Ok(())
}
