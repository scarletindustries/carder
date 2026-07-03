//// Regression test for the CI-only Porffor differential flake: on a COLD npm cache (a fresh CI
//// runner), the FIRST `npx porffor <file>` invocation prints an install diagnostic to stderr —
//// `npm warn exec The following package was not found and will be installed: porffor@0.61.13` —
//// which `ffi.run` folds into stdout, polluting the console reference the live differential
//// byte-compares (observed: `"npm warn exec …\nhello, beam\n"` vs the expected `"hello, beam\n"`).
//// `porffor.strip_npm_noise` removes npm's diagnostic lines so the oracle is robust regardless of
//// cache state. These assert the exact observed scenario + the warm-cache no-op.

import gleeunit/should
import twocore/js/porffor

/// The EXACT CI-observed pollution (`npm warn exec …` prepended to the program's `console.log`
/// output) is stripped back to the pure console reference.
pub fn strips_the_cold_cache_install_warning_test() {
  porffor.strip_npm_noise(
    "npm warn exec The following package was not found and will be installed: porffor@0.61.13\nhello, beam\n",
  )
  |> should.equal("hello, beam\n")
}

/// A WARM cache (local dev — porffor already installed) emits no npm diagnostics, so the strip is a
/// no-op: the console reference is unchanged (byte-identity for the common path).
pub fn warm_cache_output_is_unchanged_test() {
  porffor.strip_npm_noise("hello, beam\n")
  |> should.equal("hello, beam\n")
}

/// An ANSI-colored numeric log (Porffor's in-band color) survives the strip untouched — only npm's
/// `npm warn`/`npm notice` lines are removed, never program bytes.
pub fn ansi_output_survives_test() {
  porffor.strip_npm_noise("\u{001B}[33m42\u{001B}[0m\n")
  |> should.equal("\u{001B}[33m42\u{001B}[0m\n")
}

/// Multiple npm diagnostic prefixes (warn + notice) are all removed; interleaving is handled
/// line-wise, not just a leading strip.
pub fn removes_all_npm_diagnostic_lines_test() {
  porffor.strip_npm_noise(
    "npm warn exec installing\nnpm notice a new version\ncaught\n",
  )
  |> should.equal("caught\n")
}
