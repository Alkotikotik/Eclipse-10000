//A script to compute values for XMU-T ROM

use std::f64::consts::PI;

fn main(){
    //thats chebyshev extrema, im not even gonna lie i don't know what it is i just copied the
    //formula. It acts as a starting guess
    let mut extrema : [f64; 4];
    for i in extrema.iter() {
        extrema[i] = ((PI*(i as f64) / 4).cos()).powi(i);
    }


}

//runs one time for every x and returns array of 5 elems
//Im using degree 3 polynomial aka cubic, bc otherwise i just waste BRAM space which under
//No circumstances im doing, im just like that. That buys me a 2^-35 maximum error which is a
//massive overkill but that supposed to simplify other steps hardware-wise i would be able to trunc
//or crude process some values. Also cubic is cool asf
fn rcp(x : f64, extrema : [f64; 4]) -> [f64; 4] {
    //alright its 2:25am and im watching The Organic Chemistry tutor on Gaussian elimination.
    //So its pretty clear actually nice method gj Gauss
    //So augumented matrix:
    //c0, c1, c2, c3, c4 | f(t_i)
    let mut gauss = [[0.0f64; 6]; 5];
    for i in 0..5 {
        let sign = if i % 2 == 0 { 1.0 } else { -1.0 }; // nooooo ternaryyyy
        gauss[i] = [extrema, sign, 1/x];
    }



}
