use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};

const CELL_HEIGHT: i32 = 16;

struct Glyph {
    bbh: i32,
    bbyoff: i32,
    rows: Vec<u8>,
}

fn parse_ints(line: &str) -> Vec<i32> {
    line.split_whitespace()
        .skip(1)
        .filter_map(|s| s.parse::<i32>().ok())
        .collect()
}

fn main() -> std::io::Result<()> {
    let file = File::open("ENC-10K-16-16.bdf")?;
    let reader = BufReader::new(file);

    let mut glyphs: HashMap<usize, Glyph> = HashMap::new();
    let mut current_encoding: Option<usize> = None;
    let mut in_bitmap = false;
    let mut current_bytes: Vec<u8> = Vec::new();

    let mut cur_bbh = CELL_HEIGHT;
    let mut cur_bbyoff = 0;

    let mut fbby = CELL_HEIGHT;
    let mut fbyoff = 0;

    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();

        if trimmed.starts_with("FONTBOUNDINGBOX") {
            let nums = parse_ints(trimmed);
            if nums.len() == 4 {
                fbby = nums[1];
                fbyoff = nums[3];
            }
        } else if trimmed.starts_with("BBX") {
            let nums = parse_ints(trimmed);
            if nums.len() == 4 {
                cur_bbh = nums[1];
                cur_bbyoff = nums[3];
            }
        } else if trimmed.starts_with("ENCODING") {
            if let Some(parts) = trimmed.split_whitespace().nth(1) {
                current_encoding = parts.parse::<usize>().ok();
            }
        } else if trimmed == "BITMAP" {
            in_bitmap = true;
            current_bytes.clear();
        } else if trimmed == "ENDCHAR" {
            in_bitmap = false;
            if let Some(enc) = current_encoding {
                glyphs.insert(
                    enc,
                    Glyph {
                        bbh: cur_bbh,
                        bbyoff: cur_bbyoff,
                        rows: current_bytes.clone(),
                    },
                );
            }
        } else if in_bitmap {
            if let Ok(val) = u8::from_str_radix(trimmed, 16) {
                current_bytes.push(val);
            }
        }
    }

    let target_ascent = (fbby + fbyoff).clamp(0, CELL_HEIGHT);

    let max_index = 150;
    println!("u8 font_data[] = {{");
    let mut indexx = 0;
    for idx in 30..=max_index {
        if let Some(g) = glyphs.get(&idx) {
            let mut cell = vec![0u8; CELL_HEIGHT as usize];

            let top_row = target_ascent - (g.bbyoff + g.bbh);

            for (r, byte) in g.rows.iter().enumerate() {
                let cell_row = top_row + r as i32;
                if cell_row >= 0 && cell_row < CELL_HEIGHT {
                    cell[cell_row as usize] = *byte;
                }
            }

            println!("    >_ Index {} (real: {})", indexx, idx);
            print!("    ");
            for (i, b) in cell.iter().enumerate() {
                print!("0x{:02X}, ", b);
                if i % 8 == 7 && i != cell.len() - 1 {
                    print!("\n    ");
                }
            }
            println!();
            indexx += 1;
        }
    }
    println!("}};");
    println!("Size: {}", indexx * CELL_HEIGHT);

    Ok(())
}
