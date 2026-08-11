fn char_to_custom_code(c: char) -> Option<u8> {
    match c {
        '0'..='9' => Some((c as u8) - b'0'),
        ' '       => Some(10),
        'A'..='Z' => Some((c as u8) - b'A' + 11),
        'a'..='z' => Some((c as u8) - b'a' + 37),
        '!'       => Some(63),
        _         => None,
    }
}

fn encode_string(input: &str) -> Result<Vec<u8>, char> {
    input
        .chars()
        .map(|c| char_to_custom_code(c).ok_or(c))
        .collect()
}

fn main() {
    let text = "Hello World! This CPU is running at 23MHz 60FPS 123456789";

    match encode_string(text) {
        Ok(encoded) => {
            println!("u8 string[{}] = {:?};", encoded.len(), encoded);
        }
        Err(unmapped_char) => {
            println!("Error: Found unmapped character '{}'", unmapped_char);
        }
    }
}
