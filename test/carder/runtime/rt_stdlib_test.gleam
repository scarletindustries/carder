//// Spec-based tests for `rt_stdlib` (unit 09) — the minimal Safe `own` stdlib.
////
//// `gcd` is asserted against the **mathematical definition** (Euclid's algorithm and the
//// conventions `gcd(n,0)=|n|`, `gcd(0,0)=0`), NOT against whatever the code emits. The
//// positive `call_host → own` path (a program reaching `gcd` and getting the right
//// answer) is exercised end-to-end by units 07/11; here we pin the function's results.

import carder/runtime/rt_stdlib
import gleeunit/should

pub fn gcd_12_18_test() {
  rt_stdlib.gcd(12, 18) |> should.equal(6)
}

/// Symmetric in its arguments.
pub fn gcd_18_12_test() {
  rt_stdlib.gcd(18, 12) |> should.equal(6)
}

pub fn gcd_zero_left_test() {
  rt_stdlib.gcd(0, 5) |> should.equal(5)
}

pub fn gcd_zero_right_test() {
  rt_stdlib.gcd(5, 0) |> should.equal(5)
}

/// Coprime arguments ⇒ 1.
pub fn gcd_coprime_test() {
  rt_stdlib.gcd(17, 5) |> should.equal(1)
}

/// The `gcd(0,0)=0` convention.
pub fn gcd_zero_zero_test() {
  rt_stdlib.gcd(0, 0) |> should.equal(0)
}

/// A larger non-coprime pair.
pub fn gcd_48_36_test() {
  rt_stdlib.gcd(48, 36) |> should.equal(12)
}

/// Negative arguments ⇒ the non-negative gcd of the magnitudes.
pub fn gcd_negative_test() {
  rt_stdlib.gcd(-12, 18) |> should.equal(6)
  rt_stdlib.gcd(12, -18) |> should.equal(6)
  rt_stdlib.gcd(-12, -18) |> should.equal(6)
}
