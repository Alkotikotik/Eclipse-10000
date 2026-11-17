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
    let f: fn(f64) -> f64 = sin;
    let mid = 1.5;
    let half_w = 0.025;
    let test = coeffs(f, mid, half_w, extrema);
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
}
//why am i doing it
fn rcp(x: f64)   -> f64 { 1.0 / x }
fn sin(x: f64)   -> f64 {(2.0 * PI * x).sin()} //in turns
fn log2(x: f64)  -> f64 {x.log2()}
fn exp2(x: f64)  -> f64 {x.exp2()}
fn atan(x: f64)  -> f64 {x.atan() / (2.0 * PI)}
fn sqrt(x: f64)  -> f64 {x.sqrt()}
fn rsqrt(x: f64) -> f64 {1.0 / x.sqrt()}
//runs one time for every x and returns array of 5 elems
//Im using degree 3 polynomial aka cubic, bc otherwise i just waste BRAM space which under
//No circumstances im doing, im just like that. That buys me a 2^-35 maximum error which idgaf about
//Its too big of an overkill, on the other hand i can shrink segments which is way more valuable,
//that way I can fit atan and sqrt here too which im very happy about.
fn coeffs(f: fn(f64) -> f64, mid: f64, half_w: f64, extrema: [f64; 5]) -> [f64; 5] { //passing fns is cool ngl
    //alright its 2:25am and im watching The Organic Chemistry tutor on Gaussian elimination.
    //So its pretty clear actually nice method gj Gauss
    //So augumented matrix:
    //c0, c1, c2, c3, c4 | f(t_i)
    let mut gauss = [[0.0f64; 6]; 5];
    for i in 0..5 {
        for k in 0..4 {
            gauss[i][k] = extrema[i].powi(k as i32);
        }
        let sign = if i % 2 == 0 { 1.0 } else { -1.0 }; // nooooo ternaryyyy
        gauss[i][4] = sign;
        let x = mid + extrema[i] * half_w;
        //aura
        gauss[i][5] = f(x);
    }
    //Gaussian elimination pivot or something.
    //Basically put the row with largest value in largest value left
    //And then execute gaussian elimination - clear everything below the pivot
    //so we're gonna be left with someting like that
    //0, 0, 0, coeff3, E | f(x)
    //0, 0, 0, 0,      E | f(x) bottom
    //So from the lowest column we can calculate E, then working our way up we can compute c3, c2,
    //c1 and c0 thats just bigass simoltanoes equation
    for col in 0..5 {
        let mut largest = col;
        for row in col..5 {
            if gauss[row][col].abs() > gauss[largest][col].abs() {
                largest = row;
            }
        }
        gauss.swap(col, largest);
        for row in col + 1..5 { //ignoring pivot
            //row_belowpivot - factor * row_pivot = 0
            //factor = row_belowpivot / row_pivot
            let factor = gauss[row][col] / gauss[col][col];
            for i in col..6 { //for every row element below the pivot row is just happens to be col here
                gauss[row][i] -= factor * gauss[col][i]; //now its good
            }
        }
    }
    let mut coeffs = [0.0f64; 5];
    for i in (0..5).rev() {
        let mut sum = 0.0;
        for j in i + 1..5 {
            sum += gauss[i][j]*coeffs[j];
        }
        coeffs[i] = (gauss[i][5] - sum) / gauss[i][i];
    }
    coeffs //this still feels weird
}
