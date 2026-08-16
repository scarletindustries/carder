//// `corpus` — the JS-subset conformance corpus manifest (P7-09 §C).
////
//// One `Program` per `corpus/<category>/<name>.js`, grown trivial -> real across the breadth of
//// Porffor-supported JS (arithmetic + precedence + Math; control flow; functions; closures;
//// recursion; strings; arrays; objects; booleans/logical; `try/catch`/`throw`). Each program is
//// self-contained and prints its observable(s) via `console.log`, so the observable is a
//// deterministic byte-stream the differential oracle judges (§E).
////
//// The manifest is the SINGLE source of truth for the corpus. For every program it also bakes the
//// two facts the judge needs but cannot read from the `.wasm`: the program's `Outcome` at
//// `porf run` (Clean vs an uncaught Throw) and — cross-checked against Node at vendor time
//// (`vendor.sh`) — an optional `SkipCategory` when Porffor's own output diverges from correct JS
//// (`porf run != node`, a Porffor bug we do not hold carder to, §E.2). A program with `skip: None`
//// is expected to run byte-identically to `porf run` AND reproduce correct JS; a `skip: Some(_)`
//// program is a DOCUMENTED, categorized non-green (kept, never deleted — DoD).
////
//// MEASURED against Porffor 0.61.13 + Node v22 (see `PIN`): 55 programs, 52 expected-pass, 3
//// `PorfforVsNodeDivergence` (`arith/negzero` `-0`->`"0"`; `closures/counter`/`closures/adder`
//// Porffor's broken lexical-closure capture -> `NaN`/`ReferenceError`). carder reproduces `porf run`
//// byte-for-byte on ALL 55 (including the 3 divergent ones), so `fail == 0` and the residual is
//// bounded by Porffor, not carder (J8).

import carder/js/report.{type SkipCategory, PorfforVsNodeDivergence}
import gleam/option.{type Option, None, Some}

const root = "test/carder/js/corpus/"

/// A program's execution outcome at the `porf run` reference (§E.3):
/// - `Clean` — `porf run` exited 0 (ran to completion).
/// - `Threw` — `porf run` exited non-zero on an UNCAUGHT JS `throw` at top level (a legitimate
///   observable — the BEAM side must also surface an uncaught exception, and any `console.log`
///   BEFORE the throw must still match byte-exact).
pub type Outcome {
  Clean
  Threw
}

/// One corpus program (§C).
/// - `category` / `name`: the `corpus/<category>/<name>.{js,wasm,expected}` triple; `label` joins
///   them as `"<category>/<name>"` for the printed table.
/// - `outcome`: the baked `porf run` outcome (`Clean`/`Threw`) — the expected BEAM outcome class.
/// - `skip`: `None` for an expected pass (`beam == porf == node`); `Some(category)` for a
///   documented, categorized non-green (a Porffor-vs-Node divergence at the pin).
pub type Program {
  Program(
    category: String,
    name: String,
    outcome: Outcome,
    skip: Option(SkipCategory),
  )
}

/// The `"<category>/<name>"` label of a program (the printed-table key). Total.
pub fn label(p: Program) -> String {
  p.category <> "/" <> p.name
}

/// The path to a program's vendored `.wasm` (Porffor's compiled output). Total.
pub fn wasm_path(p: Program) -> String {
  root <> p.category <> "/" <> p.name <> ".wasm"
}

/// The path to a program's baked `.expected` (the `porf run` reference stdout bytes). Total.
pub fn expected_path(p: Program) -> String {
  root <> p.category <> "/" <> p.name <> ".expected"
}

/// The path to a program's `.js` source (for the live differential's `porf run`/`node`). Total.
pub fn js_path(p: Program) -> String {
  root <> p.category <> "/" <> p.name <> ".js"
}

/// A clean expected-pass program (`porf run` exits 0, `beam == porf == node`). Total.
fn pass(category: String, name: String) -> Program {
  Program(category, name, Clean, None)
}

/// An expected-pass program whose `porf run` (and Node) both throw UNCAUGHT at top level after
/// printing its `console.log` output — a MATCHING error outcome, still a pass (§E.3). Total.
fn threw(category: String, name: String) -> Program {
  Program(category, name, Threw, None)
}

/// A program whose `porf run` diverges from Node (a Porffor bug) — a documented, categorized
/// `PorfforVsNodeDivergence` skip carrying the measured `porf`-vs-`node` note. `outcome` records
/// what `porf run` itself did (`Clean`/`Threw`). Total.
fn diverge(
  category: String,
  name: String,
  outcome: Outcome,
  note: String,
) -> Program {
  Program(category, name, outcome, Some(PorfforVsNodeDivergence(note)))
}

/// The full corpus (§C) — 55 programs across 11 categories, MEASURED against Porffor 0.61.13.
/// Every `pass(...)` runs byte-identically to `porf run` (itself `== node`); the three
/// `diverge(...)` rows are documented Porffor-vs-Node divergences (kept as categorized skips, not
/// deleted). Additive — the capstone (P7-10) may grow it; a new Porffor-uncompilable or divergent
/// program is added as a categorized row, never a false green. Total.
pub fn programs() -> List(Program) {
  [
    // ── console/ — the intrinsic shim (printChar) + capture end-to-end; multi-statement ordering
    pass("console", "hello"),
    pass("console", "multi"),
    // ── arith/ — number ABI (print) + f64 arithmetic (IEEE); precedence; Math
    pass("arith", "precedence"),
    pass("arith", "mulsub"),
    pass("arith", "div"),
    pass("arith", "pow"),
    pass("arith", "mod"),
    pass("arith", "floatsum"),
    pass("arith", "math"),
    // Porffor renders -0 as "0"; correct JS (Node) renders "-0" (T13 documented divergence).
    diverge("arith", "negzero", Clean, "porf -0 -> \"0\", node \"-0\""),
    // ── control/ — structured control -> IR blocks/loops; constant-space hot loop (J7)
    pass("control", "ifelse"),
    pass("control", "forsum"),
    pass("control", "while"),
    pass("control", "switch"),
    pass("control", "ternary"),
    pass("control", "hotloop"),
    // ── functions/ — call/call_indirect + multi-value (f64,i32) params; arrows; defaults
    pass("functions", "named"),
    pass("functions", "arrow"),
    pass("functions", "returnsfn"),
    pass("functions", "default"),
    pass("functions", "callback"),
    // ── closures/ — first-class fns work (iife); LEXICAL CAPTURE is broken in Porffor 0.61.13
    pass("closures", "iife"),
    diverge("closures", "counter", Clean, "porf capture -> NaN, node 3"),
    diverge(
      "closures",
      "adder",
      Threw,
      "porf capture -> ReferenceError, node 15",
    ),
    // ── recursion/ — deep call chains as compiled BEAM calls; the scheduler preempts (J7)
    pass("recursion", "fib"),
    pass("recursion", "fact"),
    pass("recursion", "mutual"),
    // ── strings/ — string memory ops via the b/a intrinsics
    pass("strings", "concat"),
    pass("strings", "length"),
    pass("strings", "upper"),
    pass("strings", "template"),
    pass("strings", "charcode"),
    pass("strings", "split"),
    pass("strings", "indexof"),
    // ── arrays/ — array-in-linear-memory + first-class fn callbacks (call_indirect)
    pass("arrays", "length"),
    pass("arrays", "index"),
    pass("arrays", "map"),
    pass("arrays", "reduce"),
    pass("arrays", "filter"),
    pass("arrays", "push"),
    pass("arrays", "sort"),
    // ── objects/ — object-in-linear-memory + the (f64,i32) pointer/tag ABI
    pass("objects", "prop"),
    pass("objects", "mutate"),
    pass("objects", "keys"),
    // ── booleans/ — comparisons + logical ops
    pass("booleans", "and"),
    pass("booleans", "or"),
    pass("booleans", "not"),
    pass("booleans", "compare"),
    pass("booleans", "eq"),
    // ── trycatch/ — the keystone: WASM try/throw -> BEAM-native try/catch/raise (J1)
    pass("trycatch", "basic"),
    pass("trycatch", "string"),
    pass("trycatch", "nested"),
    pass("trycatch", "typeerror"),
    pass("trycatch", "finally"),
    // an uncaught throw at top level: a MATCHING error outcome (porf + node both exit 1)
    threw("trycatch", "uncaught"),
  ]
}

/// A small, breadth-spanning SAMPLE of the corpus for the LIVE differential (§H.3). The baked
/// Tier-A test (`js_conformance_test`) judges all 55 programs from the committed `.expected`; the
/// live `porf run`/`node` re-confirmation (`js_differential_test`) shells out ONE process per
/// program, so it runs this bounded sample to fit the per-test time budget (a full-corpus live run
/// would exceed it). The sample deliberately spans clean + uncaught-throw outcomes, an f64 corner,
/// deep recursion, the EH keystone, AND all three `PorfforVsNodeDivergence` rows — so the live
/// re-check exercises every judged path + every categorization. Total.
pub fn sample() -> List(Program) {
  [
    pass("console", "hello"),
    pass("recursion", "fib"),
    diverge("arith", "negzero", Clean, "porf -0 -> \"0\", node \"-0\""),
    diverge("closures", "counter", Clean, "porf capture -> NaN, node 3"),
    diverge(
      "closures",
      "adder",
      Threw,
      "porf capture -> ReferenceError, node 15",
    ),
    threw("trycatch", "uncaught"),
  ]
}
