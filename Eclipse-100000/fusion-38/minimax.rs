//A script to compute values for XMU-T ROM
use std::f64::consts::PI;
fn main(){
    //thats chebyshev extrema, im not even gonna lie i don't know what it is i just copied the
    //formula. It acts as a starting guess
    let mut extrema = [0.0f64; 5];
    for i in 0..5 {
        extrema[i] = (PI*(i as f64) / 4.0).cos();
    }

    //alright extrema seems close lemme verify whether its fine or not ill use like 2% limit
    //So report: everything passes but the sin it acts kinda weird: ratio = 7596962011.63231
    //Which is pretty funny but im sure its fine
    let f: fn(f64) -> f64 = sqrt;
    let mid = 0.1;
    let half_w = 0.001;
    let test = coeffs(f, mid, half_w, 5, [0.0f64; 4]);
    print!("{:?}\n", test);
    let mut max_e = 0.0f64;
    for j in 0..=2000 {
        let t = -1.0 + j as f64 / 1000.0;
        let prod = ((test[3] * t + test[2]) * t + test[1]) * t + test[0];
        let err = (prod - f(mid + t * half_w)).abs();
        if err > max_e {
            max_e = err;
        }
    }
    let ratio = max_e / test[4].abs();
    if ratio > 1.02 {
        print!("massive error found!!! max e = {:e}, |E| = {:e}, ratio = {}\n", max_e, test[4].abs(), ratio);
    }
    let q = quantize(f, mid, half_w, LSB[3]);
    print!("{:?}\n", q);
    for (b, n) in [(0, 1), (1, 1), (2, 2), (4, 2), (6, 2), (8, 2), (10, 2), (12, 1), (13, 1)] {
        verify(b, n);
    }
    write();
}
//why am i doing it
fn rcp(x: f64)   -> f64 { 1.0 / x }
fn sin(x: f64)   -> f64 {(2.0 * PI * x).sin()} //in turns
fn log2(x: f64)  -> f64 {x.log2()}
fn exp2(x: f64)  -> f64 {x.exp2()}
fn arctan(x: f64)  -> f64 {x.atan() / (2.0 * PI) * 8.0}
fn sqrt(x: f64)  -> f64 {x.sqrt()}
fn rsqrt(x: f64) -> f64 {1.0 / x.sqrt()}
//runs one time for every x and returns array of 5 elems
//Im using degree 3 polynomial aka cubic, bc otherwise i just waste BRAM space which under
//No circumstances im doing, im just like that. That buys me a 2^-35 maximum error which idgaf about
//Its too big of an overkill, on the other hand i can shrink segments which is way more valuable,
//that way I can fit atan and sqrt here too which im very happy about.
//Actually thats mainly a solver now
fn coeffs(f: fn(f64) -> f64, mid: f64, half_w: f64, n: usize, fixed: [f64; 4]) -> [f64; 5] { //passing fns is cool ngl
    //alright its 2:25am and im watching The Organic Chemistry tutor on Gaussian elimination.
    //So its pretty clear actually nice method gj Gauss
    //So augumented matrix:
    //c0, c1, c2, c3, c4 | f(t_i)
    let mut gauss = [[0.0f64; 6]; 5];
    for i in 0..n {
        //thats chebyshev extrema again because now n is variable
        let t = (PI * i as f64 / (n - 1) as f64).cos();
        for k in 0..n - 1 {
            gauss[i][k] = t.powi(k as i32);
        }
        let sign = if i % 2 == 0 { 1.0 } else { -1.0 }; // nooooo ternaryyyy
        gauss[i][n - 1] = sign;
        let x = mid + t * half_w;
        //aura
        let mut rest = 0.0;
        for k in n - 1..4 {
            rest += fixed[k] * t.powi(k as i32);
        }
        gauss[i][n] = f(x) - rest;
    }
    //Gaussian elimination pivot or something.
    //Basically put the row with largest value in largest value left
    //And then execute gaussian elimination - clear everything below the pivot
    //so we're gonna be left with someting like that
    //0, 0, 0, coeff3, E | f(x)
    //0, 0, 0, 0,      E | f(x) bottom
    //So from the lowest column we can calculate E, then working our way up we can compute c3, c2,
    //c1 and c0 thats just bigass simoltanoes equation
    for col in 0..n {
        let mut largest = col;
        for row in col..n {
            if gauss[row][col].abs() > gauss[largest][col].abs() {
                largest = row;
            }
        }
        gauss.swap(col, largest);
        for row in col + 1..n { //ignoring pivot
            //row_belowpivot - factor * row_pivot = 0
            //factor = row_belowpivot / row_pivot
            let factor = gauss[row][col] / gauss[col][col];
            for i in col..=n { //for every row element below the pivot row is just happens to be col here
                gauss[row][i] -= factor * gauss[col][i]; //now its good
            }
        }
    }
    let mut coeffs = [0.0f64; 5];
    for i in (0..n).rev() {
        let mut sum = 0.0;
        for j in i + 1..n {
            sum += gauss[i][j]*coeffs[j];
        }
        coeffs[i] = (gauss[i][n] - sum) / gauss[i][i];
    }
    let e = coeffs[n - 1];
    for k in n - 1..4 {
        coeffs[k] = fixed[k];
    }
    coeffs[4] = e;
    coeffs //this still feels weird
}

//so I need to round those bigass f64 numbers to a smaller ones and then convert to an int.
//LSB here represents a significance of the lowest bit in a number. Btw i run this split:
//31/23/14/4 bits and i actually ommit the signs because they don't change
//Also I realized that d1 never exceeds 2^22 and d2 never exceeds 2^13 meaning I can increase 
//Other values for more precision, n
const LSB: [i32; 4] = [-30, -30, -29, -27];
fn quantize(f: fn(f64) -> f64, mid: f64, half_w: f64, l3: i32) -> [i64; 4] {
    let mut fixed = [0.0f64; 4];
    let mut ints = [0i64; 4]; //that looks so much like inst
    for i in (0..4).rev() {
        let d_i = coeffs(f, mid, half_w, i + 2, fixed);
        let lsb = 2f64.powi(if i == 3 { l3 } else { LSB[i] });
        ints[i] = (d_i[i] / lsb).round() as i64;
        fixed[i] = ints[i] as f64 * lsb;
    }
    ints
}

//yup yup doesn't look great but this is what i came up with. Each function has to have its own
//range and span so here they are. And also i address by i/64 bc sqrt 
const FUNCS: [fn(f64) -> f64; 14] = [rsqrt, rsqrt, rcp, rcp, log2, log2, exp2, exp2, sin, sin, arctan, arctan, sqrt, sqrt];
const LO: [f64; 14] = [1.0, 2.0, 1.0, 1.5, 1.0, 1.5, 0.0, 0.5, 0.0, 0.125, 0.0, 0.5, 1.0, 2.0];
const SPAN: [f64; 14] = [1.0, 2.0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.125, 0.125, 0.5, 0.5, 1.0, 2.0];
const SIGN: [[i64; 2]; 14] = [[-1, 1], [-1, 1], [-1, 1], [-1, 1], [1, -1], [1, -1], [1, 1], [1, 1], [1, -1], [1, -1], [1, -1], [1, -1], [1, -1], [1, -1]];
const L3: [i32; 14] = [-25, -25, -27, -27, -27, -27, -27, -27, -27, -27, -27, -27, -27, -27];

//final write
fn write() {
    let mut mem = String::new();
    for i in 0..1024 {
        let b = i / 64;
        //so I shrunk rsqrt to 64segements for hi and lo to free up 128 segments for an idea i had
        //for while: runtime-programmable SFU slot i think its p cool.
        if b >= 14 {
            mem += "000000000000000000\n";
            continue;
        }
        let seg = (i % 64) as f64;
        let d = quantize(FUNCS[b], LO[b] + SPAN[b] * (seg + 0.5) / 64.0, SPAN[b] / 128.0, L3[b]); //get values
        //Important to assert that signs match(bc i omit them hoping that they are connstant) and
        //assert that it doesn't overflow
        assert!(d[0] >= 0 && d[1] * SIGN[b][0] >= 0 && d[2] * SIGN[b][1] >= 0, "sign mismatch at address {}: {:?}", i, d);
        assert!(d[0] < 1 << 31 && d[1].abs() < 1 << 23 && d[2].abs() < 1 << 14 && d[3] >= -8 && d[3] <= 7, "field overflow at address {}: {:?}", i, d);
        let word = ((d[0] as u128) << 41) | ((d[1].abs() as u128) << 18) | ((d[2].abs() as u128) << 4) | ((d[3] & 0xF) as u128);
        mem += &format!("{:018X}\n", word);
    }
    std::fs::write("transcendentals.mem", mem).unwrap();
}

//exshaustive verify for every mantissa bit, 2^24 ain't even that much of a computations
fn verify(b: usize, n: usize) {
    let f = FUNCS[b];
    let nseg = 64 * n;
    let lo = LO[b];
    let span = SPAN[b] * n as f64;
    let rem_bits = 24 - nseg.trailing_zeros() as i32;
    let h = rem_bits - 1;
    let e = [LSB[0], LSB[1] - h, LSB[2] - 2 * h, L3[b] - 3 * h];
    let base = e[3];
    let mut rom = [[0i64; 4]; 128];
    for s in 0..nseg {
        rom[s] = quantize(f, lo + span * (s as f64 + 0.5) / nseg as f64, span / (2 * nseg) as f64, L3[b]);
    }
    let mut max_ulp = 0.0f64;
    let mut worst = 0;
    let mut correct = 0u64;
    for i in 0..(2_i32.pow(24)) {
        let test_subject = i & 0x00FF_FFFF;
        let addr = test_subject >> rem_bits; //7 address bits that select a segment
        //Flipping top bit subtracts 2^16 bc its two's compliment
        //I type binary in the qalc btw and convert it to hex bc i think hex is prettier
        let part = ((test_subject & ((1 << rem_bits) - 1)) - (1 << h)) as i128; //lower 17bits that select part of the segment
        let d = rom[addr as usize];
        //so f64 can't handle 75bits to all precision i need to. 75bc i don't drop signs yet
        //So i just put it in the i128 as a sum
        let sum = ((d[0] as i128) << (e[0] - base))
                + ((d[1] as i128 * part) << (e[1] - base))
                + ((d[2] as i128 * part * part) << (e[2] - base))
                + d[3] as i128 * part * part * part;
        let mag = sum.abs();
        //Now this is good ol gefp32 rounding, find leading one, shift and round nearest-even
        //Same one as I did in GUCH
        let result = if mag == 0 {
            0.0
        } else {
            let lead = 127 - mag.leading_zeros() as i32;
            let drop = lead - 24;
            let mut q = mag;
            if drop > 0 {
                q = mag >> drop;
                let rest = mag - (q << drop);
                let half = 1i128 << (drop - 1);
                if rest > half || (rest == half && q & 1 == 1) {
                    q += 1;
                }
            }
            let v = q as f64 * 2f64.powi(drop.max(0) + base);
            if sum < 0 { -v } else { v }
        };
        //So this just compares rounded result to an actual and checks for an error.
        //Ulp should stay below 1 at least and ideally in the 0.5-0.6 range ill test it rn
        //rcp - 0.6075 ulp, perfect
        //alright not writing allat its mostly fine apart from atan which is at 0.8663 ulp and its
        //kinda tight but im sure its fine. Also log2 has 24ulp but thats bc of values near 1 and im
        //fien with that
        //And sin outputs garbare but im sure its fine lmao
        //jk jk it was just in a different range now its somewhat fine, at least abs error is
        //Also i can multiply atan by 8 and then reduce exp by 3 in gefp32 to achieve more precision
        let x = lo + span * test_subject as f64 / 16777216.0;
        let true_v = f(x);
        if true_v == 0.0 {
            continue;
        }
        let ulp = 2f64.powi(true_v.abs().log2().floor() as i32 - 24);
        let err = (result - true_v).abs() / ulp;
        if err > max_ulp {
            max_ulp = err;
            worst = test_subject;
        }
        if result == (true_v / ulp).round() * ulp {
            correct += 1;
        }
    }
    print!("block {:2} [{}, {}): max {:.4} ulp at fraction 0x{:06X}, correctly rounded {:.3}%\n", b, lo, lo + span, max_ulp, worst, correct as f64 / 16777216.0 * 100.0);
}
