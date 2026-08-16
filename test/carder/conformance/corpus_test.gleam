//// The Phase-1 ACCEPTANCE CORPUS — the goal proof (overview §1, run by capstone 11).
////
//// Each authored `corpus/<name>.wat` is compiled to `<name>.wasm` and driven through
//// the REAL pipeline (decode → validate → lower → emit_core → build_beam → invoke on
//// the BEAM); results are checked against `corpus/<name>.expected`, whose numeric-edge
//// values are sourced from the spec `.wast` files / wasmtime (cited inside each file).
//// This is the end-to-end proof that carder produces spec-correct BEAM code: the
//// arithmetic results, the two divide traps, the two's-complement wrap, the shift-count
//// masking, the signed/unsigned divide pair, the float value path, and the deny-all
//// `call_host` rejection.
////
//// Two acceptance items live as hand-built IR rather than `.wat`, because the Phase-1
//// WASM *decoder* does not yet decode them (a documented Phase-2 frontend gap), yet the
//// backend + runtime DO implement them and must be proven end-to-end through codegen:
////   - float ARITHMETIC (`f32.add`/`f64.add` → rt_num `FAdd`/`FMul`);
////   - the `call_host` capability boundary FIRING at run time (deny-all → a catchable
////     `{capability_denied, …}`), complementing the `.wat` host-import frontend rejection.

import carder/backend/build_beam
import carder/backend/emit_core
import carder/conformance/corpus.{
  type Expect, InstantiateTraps, Rejects, Returns, Traps,
}
import carder/conformance/driver
import carder/conformance/ffi
import carder/conformance/oracle
import carder/conformance/runner.{type Driver}
import carder/ir
import carder/pipeline
import carder/runtime/instance
import carder/runtime/profiles
import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

const corpus_dir = "test/carder/conformance/corpus"

// ─────────────────────────────── per-program acceptance ───────────────────────────────

/// `add` — direct numeric op + i32 two's-complement WRAP (add overflow, mul overflow).
pub fn add_corpus_test() {
  assert check_program("add") == []
}

/// `intops` — signed/unsigned divide pair, the div_s(INT_MIN,-1) overflow TRAP, the
/// div_u(_,0) divide-by-zero TRAP, and shift-count >= width masking — all through codegen.
pub fn intops_corpus_test() {
  assert check_program("intops") == []
}

/// `sum_to(n)` — loop/break/continue lowered to a constant-space tail-recursive BEAM loop.
pub fn sum_to_corpus_test() {
  assert check_program("sum_to") == []
}

/// `fib` — if + direct self-call + recursion.
pub fn fib_corpus_test() {
  assert check_program("fib") == []
}

/// `fac` — if + direct self-call + recursion (spec also bakes `fac` into `fac.wast`).
pub fn fac_corpus_test() {
  assert check_program("fac") == []
}

/// `floatops` — one f32 + one f64 program through the full WASM pipeline: float CONSTANTS
/// returned as raw IEEE-754 bits (D5) and trunc_sat float→int conversions (rt_num).
pub fn floatops_corpus_test() {
  assert check_program("floatops") == []
}

/// `hostimport` — a host import under deny-all is REJECTED end-to-end (fail-closed, D9/D4):
/// the module must not compile to a runnable instance.
pub fn hostimport_rejected_corpus_test() {
  assert check_program("hostimport") == []
}

// ─────────────────────────────── Phase-2 acceptance corpus (stateful, real .wat) ───────────────────────────────

/// #1 `mem` — linear memory round-trip (LE), an OOB load, and a partial multi-byte OOB
/// store that traps with ZERO mutation. Bounds per spec exec/instructions.html.
pub fn mem_corpus_test() {
  assert check_program("mem") == []
}

/// #2 `callind` — `call_indirect`'s three ordered, distinct faults (undefined element /
/// uninitialized element / indirect call type mismatch) plus a correct dispatch.
pub fn callind_corpus_test() {
  assert check_program("callind") == []
}

/// #3 `gvar` — a mutable global round-trips through `global.set`/`global.get`, with state
/// persisting across invokes (one-instance-one-process).
pub fn gvar_corpus_test() {
  assert check_program("gvar") == []
}

/// #4 `memgrow` — `memory.grow` returns the old size; a grow past the DECLARED max returns
/// -1 and allocates nothing; `memory.size` reflects growth.
pub fn memgrow_corpus_test() {
  assert check_program("memgrow") == []
}

/// #5 `trunc` — trapping `i32.trunc_f32_s`: NaN → invalid conversion; ±Inf / out-of-range →
/// integer overflow; in-range truncates (spec exec/numerics.html).
pub fn trunc_corpus_test() {
  assert check_program("trunc") == []
}

/// #7a `trapstart` — a trapping `start` function makes the module FAIL to instantiate.
pub fn trapstart_uninstantiable_corpus_test() {
  assert check_program("trapstart") == []
}

/// #7b `oobdata` — an out-of-bounds active data segment makes the module FAIL to
/// instantiate (whole-range bounds check, no partial write).
pub fn oobdata_uninstantiable_corpus_test() {
  assert check_program("oobdata") == []
}

/// #6 Cross-instance ISOLATION: instantiate the SAME module twice (two owned processes →
/// two independent cells). A `global.set` and an `i32.store` in instance A are INVISIBLE to
/// instance B, and A still observes its own writes (E1/E3 per-instance isolation).
pub fn cross_instance_isolation_test() {
  let mod = compile_load(read("iso.wasm"), profiles.safe())
  let assert Ok(a) = ffi.start_instance(mod)
  let assert Ok(b) = ffi.start_instance(mod)

  // Mutate ONLY instance A.
  let assert Ok(_) = ffi.call_instance(a, atom.create("set_global"), [111])
  let assert Ok(_) = ffi.call_instance(a, atom.create("store"), [0, 222])

  // Instance B never observes A's writes.
  assert ffi.call_instance(b, atom.create("get_global"), []) == Ok(0)
  assert ffi.call_instance(b, atom.create("load"), [0]) == Ok(0)
  // Instance A still observes its own writes.
  assert ffi.call_instance(a, atom.create("get_global"), []) == Ok(111)
  assert ffi.call_instance(a, atom.create("load"), [0]) == Ok(222)

  ffi.stop_instance(a)
  ffi.stop_instance(b)
}

/// #4 (Safe cap) The Safe-profile hard max-pages cap fires: `growcap` declares NO max, so
/// the Binding's cap governs. Compiled with `profiles.safe_capped(1)`, a grow past 1 page
/// returns -1 and allocates nothing (E3 — untrusted code cannot allocate unboundedly).
pub fn safe_cap_grow_returns_minus_one_test() {
  let mod = compile_load(read("growcap.wasm"), profiles.safe_capped(1))
  let assert Ok(proc) = ffi.start_instance(mod)
  // Initial size 0; grow by 1 succeeds (within the cap of 1) and returns old size 0.
  assert ffi.call_instance(proc, atom.create("grow"), [1]) == Ok(0)
  assert ffi.call_instance(proc, atom.create("size"), []) == Ok(1)
  // A further grow exceeds the Safe cap of 1 page → the WASM i32 failure value -1, whose
  // unsigned bit pattern is 0xFFFFFFFF (masked to i32 as the value layer / oracle does), and
  // NOTHING is allocated (size stays 1).
  let assert Ok(fail) = ffi.call_instance(proc, atom.create("grow"), [1])
  assert int.bitwise_and(fail, 0xFFFF_FFFF) == 0xFFFF_FFFF
  assert ffi.call_instance(proc, atom.create("size"), []) == Ok(1)
  ffi.stop_instance(proc)
}

/// The `cell` state strategy preserves the Phase-1 constant-space tail loop for the ACTUAL
/// memory path: a `memory.store` EVERY iteration for 100k iterations completes and returns
/// the final value, using memory that does NOT grow proportionally to the iteration count
/// (100× the iterations must not mean ~100× the live process memory — a per-iteration leak
/// would). Proven directly, not inferred from `rt_meter`.
pub fn store_loop_constant_space_test() {
  let mod = compile_load(read("memloop.wasm"), profiles.safe())

  let assert Ok(small) = ffi.start_instance(mod)
  assert ffi.call_instance(small, atom.create("store_loop"), [1000]) == Ok(999)
  let mem_small = ffi.gc_and_memory(small)

  let assert Ok(big) = ffi.start_instance(mod)
  assert ffi.call_instance(big, atom.create("store_loop"), [100_000])
    == Ok(99_999)
  let mem_big = ffi.gc_and_memory(big)

  // Constant space: 100× the iterations must stay well under a small constant factor of the
  // small run's live memory (a loop-carried / accumulating state would blow this up ~100×).
  assert mem_big < mem_small * 4

  ffi.stop_instance(small)
  ffi.stop_instance(big)
}

// ─────────────────────────────── IR-sourced float arithmetic ───────────────────────────────

/// Float ARITHMETIC end-to-end through codegen (rt_num `FAdd`/`FMul`), from hand-built IR
/// since the Phase-1 decoder has no `f32.add` yet. Values flow as raw IEEE-754 bits (D5):
/// `f32.add(1.0, 2.0) == 3.0` is bits `1065353216 + 1073741824 -> 1077936128`; likewise
/// `f64.mul(1.5, 2.5) == 3.75` is `4609434218613702656 * 4612811918334230528 ->
/// 4615626668101337088` (raw f64 bits).
pub fn float_arithmetic_ir_e2e_test() {
  let mod = load_ir(float_arith_module())
  // f32.add(1.0, 2.0) == 3.0  (raw f32 bits)
  assert ffi.catch_apply(mod, atom.create("f32add"), [
      1_065_353_216,
      1_073_741_824,
    ])
    == Ok(1_077_936_128)
  // f64.mul(1.5, 2.5) == 3.75 (raw f64 bits)
  assert ffi.catch_apply(mod, atom.create("f64mul"), [
      4_609_434_218_613_702_656,
      4_612_811_918_334_230_528,
    ])
    == Ok(4_615_626_668_101_337_088)
}

/// The `call_host` capability boundary FIRES at run time under the Safe deny-all host:
/// a genuine host import raises a catchable `{capability_denied, …}` (fail-closed, D9).
/// This complements the `.wat` `hostimport` frontend rejection by exercising `rt_host`
/// itself end-to-end (the `.wat` path cannot reach it — the decoder drops imports).
pub fn call_host_denied_ir_e2e_test() {
  let mod = load_ir(host_import_module())
  let assert Error(reason) =
    ffi.catch_apply(mod, atom.create("useimport"), [123])
  assert string.contains(reason, "capability_denied")
}

// ─────────────────────────────── driving machinery ───────────────────────────────

/// Run a `corpus/<name>` program through the real driver and return the list of failure
/// descriptions (empty ⇒ every expectation held). A `reject` program asserts the module
/// fails to instantiate; otherwise the module instantiates once and each expectation is
/// invoked and compared.
fn check_program(name: String) -> List(String) {
  let d = driver.pipeline()
  let assert Ok(bytes) = read_bytes(name <> ".wasm")
  let assert Ok(text) = read_text(name <> ".expected")
  let assert Ok(expects) = corpus.parse(text)

  case expects {
    [Rejects] ->
      case d.instantiate(bytes) {
        Error(_) -> []
        Ok(_) -> [name <> ": expected REJECT, but the module instantiated"]
      }
    [InstantiateTraps(text)] ->
      // The module compiles, but instantiation must TRAP (OOB active segment / trapping
      // start). driver.instantiate prefixes an instantiation-time trap with "instantiate: ".
      case d.instantiate(bytes) {
        Ok(_) -> [name <> ": expected instantiation TRAP, but it instantiated"]
        Error(reason) ->
          case string.split_once(reason, "instantiate: ") {
            Ok(#(_, trap)) ->
              case runner.trap_matches(trap, text) {
                True -> []
                False -> [
                  name
                  <> ": instantiation trapped "
                  <> trap
                  <> " want substring '"
                  <> text
                  <> "'",
                ]
              }
            Error(_) -> [
              name
              <> ": expected an instantiation trap, got a compile-stage rejection: "
              <> reason,
            ]
          }
      }
    _ ->
      case d.instantiate(bytes) {
        Error(e) -> [name <> ": module failed to instantiate: " <> e]
        Ok(inst) ->
          list.filter_map(expects, fn(ex) {
            case run_expect(d, inst, ex) {
              Ok(Nil) -> Error(Nil)
              Error(msg) -> Ok(name <> ": " <> msg)
            }
          })
      }
  }
}

fn run_expect(d: Driver, inst, ex: Expect) -> Result(Nil, String) {
  case ex {
    Rejects -> Error("unexpected 'reject' among value expectations")
    InstantiateTraps(_) ->
      Error("unexpected 'instantiate' among value expectations")
    Returns(field, args, results) ->
      case d.invoke(inst, field, args) {
        runner.Returned(actual) ->
          case oracle.matches_all(actual, results) {
            True -> Ok(Nil)
            False ->
              Error(
                field
                <> ": got "
                <> string.inspect(actual)
                <> " want "
                <> string.inspect(results),
              )
          }
        runner.Trapped(r) -> Error(field <> ": expected return, trapped " <> r)
        runner.DriverError(x) -> Error(field <> ": driver error " <> x)
      }
    Traps(field, args, text) ->
      case d.invoke(inst, field, args) {
        runner.Trapped(r) ->
          case runner.trap_matches(r, text) {
            True -> Ok(Nil)
            False ->
              Error(
                field <> ": trapped " <> r <> " want substring '" <> text <> "'",
              )
          }
        runner.Returned(v) ->
          Error(
            field
            <> ": expected trap '"
            <> text
            <> "', returned "
            <> string.inspect(v),
          )
        runner.DriverError(x) -> Error(field <> ": driver error " <> x)
      }
  }
}

fn read_bytes(file: String) -> Result(BitArray, String) {
  ffi.read_file(corpus_dir <> "/" <> file)
}

/// Read a corpus `.wasm` file, asserting success (a missing fixture is a test bug).
fn read(file: String) -> BitArray {
  let assert Ok(bytes) = read_bytes(file)
  bytes
}

/// Compile `bytes` through the full pipeline under `binding` and LOAD the module, returning
/// its atom (a unique name per call, so repeated instantiations don't clobber). Used by the
/// dedicated Phase-2 tests that need a custom `Binding` (the Safe cap) or a raw owning pid
/// (isolation / constant-space) — they then drive it via `ffi.start_instance`.
fn compile_load(bytes: BitArray, binding: instance.Binding) -> Atom {
  let assert Ok(m0) = pipeline.source_to_ir(bytes)
  let m =
    ir.Module(..m0, name: m0.name <> "_" <> int.to_string(ffi.unique_int()))
  let assert Ok(cmod) = pipeline.ir_to_cmod(m, binding)
  let assert Ok(mod) = build_beam.compile_and_load(cmod)
  mod
}

fn read_text(file: String) -> Result(String, String) {
  use bytes <- result.try(ffi.read_file(corpus_dir <> "/" <> file))
  bit_array.to_string(bytes) |> result.replace_error("non-UTF8 .expected")
}

// ─────────────────────────────── hand-built IR helpers ───────────────────────────────

/// Emit `m` to Core text, compile + load it into the test VM, return the module atom.
/// A failure here is a genuine test failure (the backend should compile valid IR).
fn load_ir(m: ir.Module) -> Atom {
  let assert Ok(cmod) = emit_core.emit_module(m, instance.safe_default())
  let assert Ok(mod) = build_beam.compile_and_load(cmod)
  mod
}

fn numeric_module(name: String, fns: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "carder@corpus@" <> name <> "_" <> int.to_string(ffi.unique_int()),
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
    tags: [],
  )
}

fn float_arith_module() -> ir.Module {
  let f32add =
    ir.Function(
      name: "f32add",
      params: [ir.Local("p0", ir.TF32), ir.Local("p1", ir.TF32)],
      result: [ir.TF32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Num(ir.FAdd(ir.FW32), [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let f64mul =
    ir.Function(
      name: "f64mul",
      params: [ir.Local("p0", ir.TF64), ir.Local("p1", ir.TF64)],
      result: [ir.TF64],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Num(ir.FMul(ir.FW64), [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  numeric_module("float", [f32add, f64mul])
}

fn host_import_module() -> ir.Module {
  let f =
    ir.Function(
      name: "useimport",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.CallHost("env", "forbidden", [ir.Var("p0")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  numeric_module("host", [f])
}
