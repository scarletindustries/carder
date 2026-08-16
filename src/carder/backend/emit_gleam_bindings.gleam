//// The **Gleam bindings emitter** (Phase-12, P12-02) — the headline deliverable.
////
//// Renders the language-neutral `Iface` (P12-01, `«IFACE-DESC-FROZEN»`) into a beautiful,
//// idiomatic, **typed** Gleam binding for a compiled WASM `.beam`, plus the tiny companion
//// `.erl` catch-shim it needs (Gleam cannot rescue a BEAM exception in-language) and a usage
//// README. A hand-written Gleam program `import`s the binding, calls a typed `pub fn` per
//// export, and gets native `Int`/`Float`/`BitArray` values back — with traps surfaced as
//// `Result(_, Trap)` rather than a raw uncaught exception.
////
//// ## What it emits (`emit_gleam/1`, the frozen `Emitter` signature)
////
//// Three deterministic `GeneratedFile`s (R22/R25a — stable ordering, no timestamps):
//// 1. `<base>_bindings.gleam` — the typed API. Its Gleam module name is derived legally from
////    `iface.module_name` (`carder@wasm@<x>` → `carder_wasm_<x>_bindings`), so it never
////    collides with the loaded `.beam` module atom (a `foo.gleam` compiles to Erlang module
////    `foo`, which would clobber `foo.beam`).
//// 2. `<base>_bindings_ffi.erl` — the catch-shim. It matches `error:{wasm_trap, _}`
////    STRUCTURALLY (R6/R7/R22), never a bare catch-all — an arity/undef emitter bug then
////    surfaces as a genuine crash, not a masked "fake trap".
//// 3. `<base>_bindings_README.md` — how to drop the two files under a consuming project's
////    `src/` and the value-ABI cheat-sheet (R22).
////
//// ## The prelude-only constraint (load-bearing)
////
//// The emitted `.gleam` uses **only the Gleam prelude + `@external`** — no `gleam/int`,
//// `gleam/result`, `gleam/dynamic`, etc. This is what lets the binding compile in a
//// dependency-free project (the P12-01 compile+call harness stages exactly such a project,
//// and it mirrors the real "drop these two files into my `src/`" story). So: the opaque
//// runtime term is an `@external` type, signed-int wrapping uses `%` + a branch (not
//// `int.bitwise_and`), and `Result` is destructured with `case` (not `result.map`).
////
//// ## The value ABI it renders (P2 + R9/R18, from `iface.value_abi`)
////
//// - **i32/i64 ⇄ `Int`**, presented **signed** two's-complement (`i32_to_raw`/`i32_of_raw`,
////   `i64_*`) — the raw ABI is the unsigned bit pattern; host ints are bignums so the
////   round-trip is exact (R9).
//// - **f32/f64 ⇄ `FloatVal`** = `Finite(Float) | NonFinite(BitArray)` (R18): a BEAM `float()`
////   cannot hold NaN/±Inf, so a non-finite value is carried as its raw IEEE bytes. The
////   bidirectional raw-bits accessors `f32_of_bits`/`f64_of_bits` (for args) and
////   `f32_bits`/`f64_bits` (for results) let a caller round-trip bit-exact values. The codec
////   width comes from `value_abi` (TF32⇒32, TF64⇒64), never from the `Float`-for-both type name.
//// - **v128 ⇄ `BitArray`** — identity (16 little-endian bytes).
//// - **funcref/externref ⇄ opaque `Ref`** — passthrough of the runtime box (no cross-language
////   function construction this phase).
//// - **results**: 0 → `Nil`, 1 → the bare value, N≥2 → an N-tuple (`result_encoding`, R4).
//// - **a trap** → `Error(Trap(reason))`, `reason` the rendered `{wasm_trap, kind}` term.
////
//// ## The two-shape host API (R19)
////
//// - `StateModel = Stateless` (no export threads state): the beautiful pure file — **no
////   `Instance`, no `instantiate`** in the surface; each export is `fn(args) -> Result(T, Trap)`
////   and re-instantiates internally per call.
//// - `StateModel = Threaded` (≥1 export threads state): `instantiate() -> Result(Instance, Trap)`
////   (a trapping start / OOB active segment becomes `Error`, R5); every export takes `inst`; a
////   `touches_state` export returns `Result(#(T, Instance), Trap)` (thread the new instance back),
////   the rest return `Result(T, Trap)` (take `inst`, drop the unchanged `St'`).
////
//// The emitted `.beam` ABI is uniformly `n+1` under the accepted (Threaded) build — every export
//// takes a leading `InstanceState` and returns `{ResultPackage, St'}` (R2/R19), whether or not it
//// touches state — so the binding always threads `St` INTERNALLY; the two shapes above govern only
//// what is exposed to the host.
////
//// ## Out of scope this phase (R24)
////
//// A WASM `throw`/`exnref` is a distinct term class the `{wasm_trap, _}` catch does NOT intercept,
//// so a throwing export escapes the typed-error surface — documented in the README, not modelled.

import carder/backend/iface.{
  type ExportSig, type GeneratedFile, type Iface, type ValueAbi, FloatAbi,
  GeneratedFile, IntAbi, RefAbi, ResultBare, ResultTuple, ResultUnit, Stateless,
  Threaded, V128Abi,
}
import carder/ir
import gleam/int
import gleam/list
import gleam/string

/// Render an `Iface` into the Gleam binding drop (the frozen `Emitter` signature).
///
/// - `desc`: a VALID descriptor (`iface.describe/2` has already fail-closed on Cell /
///   import-bearing / mutable-tier builds — `emit_gleam` does not re-validate).
///
/// Returns exactly THREE `GeneratedFile`s, in a fixed order (deterministic — the same `Iface`
/// yields byte-identical content, R25a):
/// - `#(<base>_bindings.gleam, …)` — the typed API (prelude-only, so it compiles in a
///   dependency-free project).
/// - `#(<base>_bindings_ffi.erl, …)` — the structural `error:{wasm_trap, _}` catch-shim.
/// - `#(<base>_bindings_README.md, …)` — the usage note + value-ABI table (R22).
///
/// `<base>` is `iface.module_name` legalized to a Gleam identifier (`carder@wasm@x` →
/// `carder_wasm_x`), so the binding module name can never collide with the loaded `.beam`
/// module atom. Never fails: every `Iface` the descriptor produces is renderable.
pub fn emit_gleam(desc: Iface) -> List(GeneratedFile) {
  let base = iface.sanitize_identifier(desc.module_name)
  let gleam_module = base <> "_bindings"
  let shim_module = base <> "_bindings_ffi"

  [
    GeneratedFile(
      path: gleam_module <> ".gleam",
      content: render_gleam(desc, shim_module),
    ),
    GeneratedFile(
      path: shim_module <> ".erl",
      content: render_shim(shim_module),
    ),
    GeneratedFile(
      path: base <> "_bindings_README.md",
      content: render_readme(desc, gleam_module, shim_module),
    ),
  ]
}

// ───────────────────────────── feature detection ─────────────────────────────

/// The set of value-shapes present across a descriptor's exports — used to emit ONLY the helpers,
/// types, and `@external`s a given module actually references (so the generated `.gleam` builds
/// warning-free; an unused PRIVATE function/type is a Gleam warning, R.DoD §4).
type Features {
  Features(
    threaded: Bool,
    needs_i32_to_raw: Bool,
    needs_i32_of_raw: Bool,
    needs_i64_to_raw: Bool,
    needs_i64_of_raw: Bool,
    has_f32: Bool,
    has_f64: Bool,
    has_ref: Bool,
    needs_raw_term: Bool,
  )
}

/// Compute the `Features` of `desc`: scan every export's params (native→raw is referenced) and
/// results (raw→native is referenced). `needs_raw_term` is `True` iff some export has zero results
/// (its `ResultPackage` is the opaque atom `ok`) OR any param/result is a reference (the opaque
/// `Ref` box) — both need the private `RawTerm` foreign-term type.
fn detect_features(desc: Iface) -> Features {
  let params = list.flat_map(desc.exports, fn(e) { e.params })
  let results = list.flat_map(desc.exports, fn(e) { e.results })
  let has_abi = fn(vts: List(ir.ValType), pred: fn(ValueAbi) -> Bool) -> Bool {
    list.any(vts, fn(vt) { pred(iface.value_abi(vt)) })
  }
  let is_i32 = fn(a) { a == IntAbi(32) }
  let is_i64 = fn(a) { a == IntAbi(64) }
  let is_f32 = fn(a) { a == FloatAbi(32) }
  let is_f64 = fn(a) { a == FloatAbi(64) }
  let is_ref = fn(a) { a == RefAbi }
  let has_unit_result =
    list.any(desc.exports, fn(e) {
      iface.result_encoding(e.results) == ResultUnit
    })
  let has_ref = has_abi(params, is_ref) || has_abi(results, is_ref)
  Features(
    threaded: desc.state_model == Threaded,
    needs_i32_to_raw: has_abi(params, is_i32),
    needs_i32_of_raw: has_abi(results, is_i32),
    needs_i64_to_raw: has_abi(params, is_i64),
    needs_i64_of_raw: has_abi(results, is_i64),
    has_f32: has_abi(params, is_f32) || has_abi(results, is_f32),
    has_f64: has_abi(params, is_f64) || has_abi(results, is_f64),
    has_ref: has_ref,
    needs_raw_term: has_unit_result || has_ref,
  )
}

// ───────────────────────────── the `.gleam` file ─────────────────────────────

/// Render the full typed `.gleam` binding for `desc`, dispatching every call through `shim_module`
/// (the companion `.erl` rescuer). Sections are emitted in a fixed order and only when referenced.
fn render_gleam(desc: Iface, shim_module: String) -> String {
  let f = detect_features(desc)
  let module_name = desc.module_name

  let header = [
    "//// Typed Gleam bindings for the compiled WASM module `"
      <> module_name
      <> "`.",
    "//// Generated by carder — do not edit. Drop this file AND its companion `"
      <> shim_module
      <> ".erl`",
    "//// under your project's `src/` (Gleam finds the `.erl` FFI tree-wide under `src/`).",
    "////",
    "//// Integers are presented signed. Floats are `FloatVal` (`Finite`/`NonFinite`) so NaN/±Inf",
    "//// survive. A WASM trap becomes `Error(Trap(reason))`; a WASM `throw` is out of scope.",
  ]

  let types = render_types(f)
  let externs = [
    "/// Run a 0-arity thunk under the companion shim's try/catch: `Ok(v)`, or `Error(reason)`",
    "/// when the call raised a `{wasm_trap, _}` (the narrow trap boundary — R7).",
    "@external(erlang, \"" <> shim_module <> "\", \"rescue\")",
    "fn rescue(thunk: fn() -> a) -> Result(a, String)",
    "",
    "/// The compiled module's `instantiate/0` — returns the raw `InstanceState` record (may raise",
    "/// on a trapping start / OOB active segment; always called inside `rescue`).",
    "@external(erlang, \"" <> module_name <> "\", \"instantiate\")",
    "fn raw_instantiate() -> RawState",
  ]

  let instantiate = case f.threaded {
    True -> [
      "",
      "/// Instantiate the module (seeds memory / globals / table). Pure value threading — no",
      "/// process is spawned. A trap during instantiation surfaces as `Error(Trap(_))` (R5).",
      "pub fn instantiate() -> Result(Instance, Trap) {",
      "  case rescue(fn() { raw_instantiate() }) {",
      "    Ok(st) -> Ok(Instance(st))",
      "    Error(reason) -> Error(Trap(reason))",
      "  }",
      "}",
    ]
    False -> []
  }

  let exports =
    list.flat_map(desc.exports, fn(e) { ["", render_export(module_name, e, f)] })

  let helpers = render_helpers(f)

  [header, [""], types, [""], externs, instantiate, exports, [""], helpers]
  |> list.flatten
  |> string.join("\n")
  |> ensure_trailing_newline
}

/// Render the type declarations a module needs: the private foreign-term types (`RawState`, and
/// `RawTerm` when a unit-package or a ref is present), `Trap`, and — only when referenced — the
/// opaque `Instance`, the `FloatVal` sum type, and the opaque `Ref`.
fn render_types(f: Features) -> List(String) {
  let raw_state = [
    "/// The opaque runtime `InstanceState` term (an `@external` foreign type — never constructed",
    "/// in Gleam, only threaded).",
    "type RawState",
  ]
  let raw_term = case f.needs_raw_term {
    True -> [
      "",
      "/// An opaque foreign term: a zero-result export's `ok` package, or a boxed reference.",
      "type RawTerm",
    ]
    False -> []
  }
  let trap = [
    "",
    "/// A WASM trap surfaced as a value (P2). `reason` is the rendered BEAM error term, e.g.",
    "/// `\"{wasm_trap,int_div_by_zero}\"`.",
    "pub type Trap {",
    "  Trap(reason: String)",
    "}",
  ]
  let instance = case f.threaded {
    True -> [
      "",
      "/// A live instance: an opaque, pure-value wrapper over the runtime `InstanceState` record",
      "/// returned by `instantiate/0`. Threaded by value — no process (P3).",
      "pub opaque type Instance {",
      "  Instance(state: RawState)",
      "}",
    ]
    False -> []
  }
  let floatval = case f.has_f32 || f.has_f64 {
    True -> [
      "",
      "/// A WASM float argument/result (R18). Finite values present as a native `Float`; a",
      "/// non-finite value (NaN/±Inf), which a BEAM `float()` cannot hold, is carried as its raw",
      "/// IEEE-754 big-endian bytes. Use `f32_of_bits`/`f64_of_bits` to build one from raw bits and",
      "/// `f32_bits`/`f64_bits` to read them back.",
      "pub type FloatVal {",
      "  Finite(Float)",
      "  NonFinite(BitArray)",
      "}",
    ]
    False -> []
  }
  let ref_ = case f.has_ref {
    True -> [
      "",
      "/// An opaque funcref/externref handle — passthrough of the runtime box (no cross-language",
      "/// function construction this phase, P8).",
      "pub opaque type Ref {",
      "  Ref(raw: RawTerm)",
      "}",
    ]
    False -> []
  }
  list.flatten([raw_state, raw_term, trap, instance, floatval, ref_])
}

/// Render one export: its `raw_*` `@external` (arity `n+1`, leading `st: RawState`, returning
/// `#(package, RawState)`) plus its typed `pub fn` (native param/result conversions done OUTSIDE
/// the `rescue`, threading or dropping the instance per `touches_state`).
fn render_export(module_name: String, e: ExportSig, f: Features) -> String {
  let host = e.host_name
  let raw_params =
    list.index_map(e.params, fn(vt, i) {
      "a" <> int.to_string(i) <> ": " <> raw_type(vt)
    })
  let raw_sig_params = ["st: RawState", ..raw_params]
  let raw_ret = "#(" <> package_raw_type(e.results) <> ", RawState)"

  let external =
    "@external(erlang, \""
    <> module_name
    <> "\", \""
    <> e.dispatch_atom
    <> "\")\nfn raw_"
    <> host
    <> "("
    <> comma(raw_sig_params)
    <> ") -> "
    <> raw_ret

  string.join([external, render_pub_fn(e, f)], "\n")
}

/// Render the typed `pub fn` wrapper for one export (both API shapes — R19). Argument conversions
/// (native→raw) are bound with `let` BEFORE the `rescue` and the result conversion (raw→native) is
/// in the `Ok` arm AFTER it, so ONLY the `.beam` call sits inside the trap-catch (R7).
fn render_pub_fn(e: ExportSig, f: Features) -> String {
  let host = e.host_name
  let threaded = f.threaded
  let host_params =
    list.index_map(e.params, fn(vt, i) {
      "a" <> int.to_string(i) <> ": " <> host_type(vt)
    })
  let sig_params = case threaded {
    True -> ["inst: Instance", ..host_params]
    False -> host_params
  }
  let ret = return_type(e, threaded)

  let preps_args = list.index_map(e.params, fn(vt, i) { arg_prep(i, vt) })
  let prep_lines =
    list.filter_map(preps_args, fn(pa) {
      case pa.0 {
        "" -> Error(Nil)
        line -> Ok(line)
      }
    })
  let call_args = list.map(preps_args, fn(pa) { pa.1 })
  let call = "raw_" <> host <> "(" <> comma(["st", ..call_args]) <> ")"
  let ok_clause = ok_arm(e, threaded)

  let doc = export_doc(e, threaded)
  let head =
    "pub fn " <> host <> "(" <> comma(sig_params) <> ") -> " <> ret <> " {"

  let body = case threaded {
    True ->
      list.flatten([
        ["  let Instance(st) = inst"],
        prep_lines,
        [
          "  case rescue(fn() { " <> call <> " }) {",
          "    " <> ok_clause,
          "    Error(reason) -> Error(Trap(reason))",
          "  }",
        ],
      ])
    False ->
      list.flatten([
        prep_lines,
        [
          "  case",
          "    rescue(fn() {",
          "      let st = raw_instantiate()",
          "      " <> call,
          "    })",
          "  {",
          "    " <> ok_clause,
          "    Error(reason) -> Error(Trap(reason))",
          "  }",
        ],
      ])
  }

  list.flatten([doc, [head], body, ["}"]])
  |> string.join("\n")
}

/// The `Ok(...) -> Ok(...)` arm for an export: destructure `#(package, St')`, convert the package
/// to native, and either thread `Instance(St')` back (a `touches_state` export under Threaded) or
/// drop `St'`. Zero results → `Nil`; one → the bare value; N≥2 → an N-tuple.
fn ok_arm(e: ExportSig, threaded: Bool) -> String {
  let touches = threaded && e.touches_state
  let #(pkg_pat, base) = case iface.result_encoding(e.results) {
    ResultUnit -> #("_pkg", "Nil")
    ResultBare -> {
      let assert [r] = e.results
      #("pkg", conv_from_raw(r, "pkg"))
    }
    ResultTuple(_) -> {
      let pats =
        list.index_map(e.results, fn(_r, i) { "q" <> int.to_string(i) })
      let convs =
        list.index_map(e.results, fn(r, i) {
          conv_from_raw(r, "q" <> int.to_string(i))
        })
      #("#(" <> comma(pats) <> ")", "#(" <> comma(convs) <> ")")
    }
  }
  let st2 = case touches {
    True -> "st2"
    False -> "_st2"
  }
  let ok = case touches {
    True -> "Ok(#(" <> base <> ", Instance(st2)))"
    False -> "Ok(" <> base <> ")"
  }
  "Ok(#(" <> pkg_pat <> ", " <> st2 <> ")) -> " <> ok
}

/// The `///` doc for one export's `pub fn`: the WASM signature, the preserved original export name
/// when it was sanitized, and the state-threading / trap contract.
fn export_doc(e: ExportSig, threaded: Bool) -> List(String) {
  let renamed = case e.host_name == e.dispatch_atom {
    True -> ""
    False -> " (host name `" <> e.host_name <> "`)"
  }
  let contract = case threaded && e.touches_state {
    True ->
      "/// State-reaching: returns the updated `Instance` alongside the result. Traps → `Error(Trap)`."
    False -> "/// Traps → `Error(Trap)`."
  }
  [
    "/// Call the WASM export `"
      <> e.dispatch_atom
      <> "`"
      <> renamed
      <> " : "
      <> wasm_sig(e)
      <> ".",
    contract,
  ]
}

// ───────────────────────────── value-ABI renderers ─────────────────────────────

/// The raw-ABI wire type of a `ValType` in a `raw_*` `@external`: floats travel as their raw
/// bit-pattern `Int`; a reference is an opaque `RawTerm`; v128 is a `BitArray` (identity).
fn raw_type(vt: ir.ValType) -> String {
  case iface.value_abi(vt) {
    IntAbi(_) -> "Int"
    FloatAbi(_) -> "Int"
    V128Abi -> "BitArray"
    RefAbi -> "RawTerm"
  }
}

/// The host-facing native type of a `ValType`: `Int` (signed) / `FloatVal` / `BitArray` / `Ref`.
fn host_type(vt: ir.ValType) -> String {
  case iface.value_abi(vt) {
    IntAbi(_) -> "Int"
    FloatAbi(_) -> "FloatVal"
    V128Abi -> "BitArray"
    RefAbi -> "Ref"
  }
}

/// The raw type of the `ResultPackage` inside a `#(package, St')` return: `RawTerm` for the 0-result
/// `ok` atom, the single raw type for one result, an N-tuple of raw types for N≥2 (R4).
fn package_raw_type(results: List(ir.ValType)) -> String {
  case iface.result_encoding(results) {
    ResultUnit -> "RawTerm"
    ResultBare -> {
      let assert [r] = results
      raw_type(r)
    }
    ResultTuple(_) -> "#(" <> comma(list.map(results, raw_type)) <> ")"
  }
}

/// The native return type of an export's `pub fn`: `Result(#(T, Instance), Trap)` for a
/// state-reaching Threaded export, else `Result(T, Trap)`, where `T` is `Nil` / the bare host type
/// / an N-tuple of host types.
fn return_type(e: ExportSig, threaded: Bool) -> String {
  let base = host_result_type(e.results)
  case threaded && e.touches_state {
    True -> "Result(#(" <> base <> ", Instance), Trap)"
    False -> "Result(" <> base <> ", Trap)"
  }
}

/// The native `T` of an export's result list: `Nil` (0), the bare host type (1), an N-tuple (N≥2).
fn host_result_type(results: List(ir.ValType)) -> String {
  case iface.result_encoding(results) {
    ResultUnit -> "Nil"
    ResultBare -> {
      let assert [r] = results
      host_type(r)
    }
    ResultTuple(_) -> "#(" <> comma(list.map(results, host_type)) <> ")"
  }
}

/// The argument-prep for the `i`-th param: a `#(let_line, call_arg)` where `let_line` (possibly
/// empty) binds the raw value BEFORE the `rescue` (R7) and `call_arg` is what the thunk passes.
/// Ints wrap to unsigned; floats decode `FloatVal` to raw bits; v128 passes through; a ref unwraps.
fn arg_prep(i: Int, vt: ir.ValType) -> #(String, String) {
  let a = "a" <> int.to_string(i)
  let r = "r" <> int.to_string(i)
  case iface.value_abi(vt) {
    IntAbi(32) -> #("  let " <> r <> " = i32_to_raw(" <> a <> ")", r)
    IntAbi(_) -> #("  let " <> r <> " = i64_to_raw(" <> a <> ")", r)
    FloatAbi(32) -> #(
      "  let assert <<" <> r <> ":size(32)>> = f32_bits(" <> a <> ")",
      r,
    )
    FloatAbi(_) -> #(
      "  let assert <<" <> r <> ":size(64)>> = f64_bits(" <> a <> ")",
      r,
    )
    V128Abi -> #("", a)
    RefAbi -> #("  let Ref(" <> r <> ") = " <> a, r)
  }
}

/// The raw→native conversion of a result bit-pattern held in variable `var`: signed-int decode,
/// float classification (`f*_of_bits` — OUTSIDE the trap-catch, R7), v128 identity, or `Ref` wrap.
fn conv_from_raw(vt: ir.ValType, var: String) -> String {
  case iface.value_abi(vt) {
    IntAbi(32) -> "i32_of_raw(" <> var <> ")"
    IntAbi(_) -> "i64_of_raw(" <> var <> ")"
    FloatAbi(32) -> "f32_of_bits(<<" <> var <> ":size(32)>>)"
    FloatAbi(_) -> "f64_of_bits(<<" <> var <> ":size(64)>>)"
    V128Abi -> var
    RefAbi -> "Ref(" <> var <> ")"
  }
}

/// The WASM signature `(t, …) -> (t, …)` for a doc comment, using the source value-type spellings.
fn wasm_sig(e: ExportSig) -> String {
  "("
  <> comma(list.map(e.params, wasm_type))
  <> ") -> ("
  <> comma(list.map(e.results, wasm_type))
  <> ")"
}

/// The WASM spelling of a `ValType` (`i32`/`f64`/`v128`/`funcref`/…), for doc comments only.
fn wasm_type(vt: ir.ValType) -> String {
  case vt {
    ir.TI32 -> "i32"
    ir.TI64 -> "i64"
    ir.TF32 -> "f32"
    ir.TF64 -> "f64"
    ir.TV128 -> "v128"
    ir.TFuncRef -> "funcref"
    ir.TExternRef -> "externref"
    ir.TExnRef -> "exnref"
    ir.TTerm -> "term"
  }
}

// ───────────────────────────── the conversion helpers ─────────────────────────────

/// Render the private conversion helpers a module references, in a fixed order (only-when-used, so
/// the generated file has no dead private function — a Gleam warning). The float raw-bits accessors
/// are `pub` (the R18 escape hatch) and emitted whenever their width is present.
fn render_helpers(f: Features) -> List(String) {
  let i32_to = case f.needs_i32_to_raw {
    True -> [
      "/// Encode a signed i32 host value as its raw unsigned 32-bit ABI pattern (exact — bignums).",
      "fn i32_to_raw(v: Int) -> Int {",
      "  let m = v % 0x1_0000_0000",
      "  case m < 0 {",
      "    True -> m + 0x1_0000_0000",
      "    False -> m",
      "  }",
      "}",
      "",
    ]
    False -> []
  }
  let i32_of = case f.needs_i32_of_raw {
    True -> [
      "/// Interpret a raw unsigned 32-bit ABI pattern as a signed i32 (two's-complement).",
      "fn i32_of_raw(raw: Int) -> Int {",
      "  case raw >= 0x8000_0000 {",
      "    True -> raw - 0x1_0000_0000",
      "    False -> raw",
      "  }",
      "}",
      "",
    ]
    False -> []
  }
  let i64_to = case f.needs_i64_to_raw {
    True -> [
      "/// Encode a signed i64 host value as its raw unsigned 64-bit ABI pattern (exact — bignums).",
      "fn i64_to_raw(v: Int) -> Int {",
      "  let m = v % 0x1_0000_0000_0000_0000",
      "  case m < 0 {",
      "    True -> m + 0x1_0000_0000_0000_0000",
      "    False -> m",
      "  }",
      "}",
      "",
    ]
    False -> []
  }
  let i64_of = case f.needs_i64_of_raw {
    True -> [
      "/// Interpret a raw unsigned 64-bit ABI pattern as a signed i64 (two's-complement).",
      "fn i64_of_raw(raw: Int) -> Int {",
      "  case raw >= 0x8000_0000_0000_0000 {",
      "    True -> raw - 0x1_0000_0000_0000_0000",
      "    False -> raw",
      "  }",
      "}",
      "",
    ]
    False -> []
  }
  let f64 = case f.has_f64 {
    True -> [
      "/// Raw IEEE-754 big-endian bytes (8) of an f64 `FloatVal`. `Finite` is encoded, single-",
      "/// rounding is not involved at f64 width; `NonFinite` returns its stored bytes verbatim.",
      "pub fn f64_bits(v: FloatVal) -> BitArray {",
      "  case v {",
      "    Finite(f) -> <<f:float-size(64)>>",
      "    NonFinite(bytes) -> bytes",
      "  }",
      "}",
      "",
      "/// Decode 8 raw IEEE-754 big-endian bytes into an f64 `FloatVal` — `NonFinite` iff the",
      "/// exponent is all-ones (NaN/±Inf), else the native `Finite` double.",
      "pub fn f64_of_bits(bytes: BitArray) -> FloatVal {",
      "  let assert <<_sign:size(1), exponent:size(11), _mant:size(52)>> = bytes",
      "  case exponent == 0x7FF {",
      "    True -> NonFinite(bytes)",
      "    False -> {",
      "      let assert <<f:float-size(64)>> = bytes",
      "      Finite(f)",
      "    }",
      "  }",
      "}",
      "",
    ]
    False -> []
  }
  let f32 = case f.has_f32 {
    True -> [
      "/// Raw IEEE-754 big-endian bytes (4) of an f32 `FloatVal`. `Finite` is single-rounded to",
      "/// binary32 (over-range magnitudes saturate to ±Inf); `NonFinite` returns its bytes verbatim.",
      "pub fn f32_bits(v: FloatVal) -> BitArray {",
      "  case v {",
      "    Finite(f) -> <<f:float-size(32)>>",
      "    NonFinite(bytes) -> bytes",
      "  }",
      "}",
      "",
      "/// Decode 4 raw IEEE-754 big-endian bytes into an f32 `FloatVal` — `NonFinite` iff the",
      "/// exponent is all-ones (NaN/±Inf), else the native `Finite` double (widened from binary32).",
      "pub fn f32_of_bits(bytes: BitArray) -> FloatVal {",
      "  let assert <<_sign:size(1), exponent:size(8), _mant:size(23)>> = bytes",
      "  case exponent == 0xFF {",
      "    True -> NonFinite(bytes)",
      "    False -> {",
      "      let assert <<f:float-size(32)>> = bytes",
      "      Finite(f)",
      "    }",
      "  }",
      "}",
      "",
    ]
    False -> []
  }
  let all = list.flatten([i32_to, i32_of, i64_to, i64_of, f64, f32])
  // Drop the trailing blank separator (each block ends with "") so the file ends cleanly.
  case list.reverse(all) {
    ["", ..rest] -> list.reverse(rest)
    _ -> all
  }
}

// ───────────────────────────── the `.erl` catch-shim ─────────────────────────────

/// Render the companion `.erl` catch-shim (`shim_module`). It runs a caller-supplied 0-arity thunk
/// under `try/catch`, matching `error:{wasm_trap, _}` STRUCTURALLY (R6/R7/R22) — never a bare
/// catch-all, so an arity/`undef` emitter bug crashes loudly instead of masquerading as a trap. The
/// module/function of every `.beam` call is STATIC in the Gleam `@external`s, so the shim is a pure
/// thunk-runner (it never does a data-driven `apply`).
fn render_shim(shim_module: String) -> String {
  [
    "%% "
      <> shim_module
      <> ".erl — generated companion catch-shim. Do not edit.",
    "%%",
    "%% Gleam cannot rescue a BEAM exception in-language, so each typed binding call routes the",
    "%% `.beam` export through this thunk. A normal return is {ok, V}; a WASM trap ({wasm_trap, _}",
    "%% raised by rt_trap) becomes {error, ReasonText}. The catch is STRUCTURAL on",
    "%% error:{wasm_trap, _} — never a bare catch-all — so an arity/undef emitter bug surfaces as a",
    "%% crash, not a fake trap. A WASM `throw`/exnref is a distinct term class, intentionally NOT",
    "%% intercepted here (out of the typed-error surface this phase).",
    "-module('" <> shim_module <> "').",
    "-export([rescue/1]).",
    "",
    "rescue(Thunk) ->",
    "    try Thunk() of",
    "        Value -> {ok, Value}",
    "    catch",
    "        error:{wasm_trap, _} = Reason ->",
    "            {error, unicode:characters_to_binary(io_lib:format(\"~0p\", [Reason]))}",
    "    end.",
  ]
  |> string.join("\n")
  |> ensure_trailing_newline
}

// ───────────────────────────── the usage README ─────────────────────────────

/// Render the usage README (R22): how to install the two files under a consuming project's `src/`,
/// the state-model-specific call sketch, and the value-ABI cheat-sheet.
fn render_readme(
  desc: Iface,
  gleam_module: String,
  shim_module: String,
) -> String {
  let usage = case desc.state_model {
    Stateless -> [
      "This module is **stateless** — there is no `Instance`. Each export re-instantiates",
      "internally, so you just call it:",
      "",
      "```gleam",
      "import " <> gleam_module,
      "",
      "pub fn main() {",
      "  let assert Ok(_result) = " <> gleam_module <> ".<export>(<args>)",
      "}",
      "```",
    ]
    Threaded -> [
      "This module is **threaded** — `instantiate/0` returns a pure-value `Instance` you pass to",
      "each export. A state-reaching export hands back a new `Instance`:",
      "",
      "```gleam",
      "import " <> gleam_module,
      "",
      "pub fn main() {",
      "  let assert Ok(inst) = " <> gleam_module <> ".instantiate()",
      "  let assert Ok(_result) = "
        <> gleam_module
        <> ".<pure_export>(inst, <args>)",
      "  let assert Ok(#(_r, inst2)) = "
        <> gleam_module
        <> ".<state_export>(inst, <args>)",
      "}",
      "```",
    ]
  }
  [
    "# Typed bindings for `" <> desc.module_name <> "`",
    "",
    "Generated by carder. Two source files make up the binding:",
    "",
    "- `"
      <> gleam_module
      <> ".gleam` — the typed API (prelude-only; no stdlib dependency).",
    "- `"
      <> shim_module
      <> ".erl` — a companion catch-shim turning a WASM trap into `Result`.",
    "",
    "## Install",
    "",
    "Drop **both** files under your Gleam project's `src/` (they need not be siblings — Gleam",
    "discovers the `.erl` FFI tree-wide under `src/`). The compiled `"
      <> desc.module_name
      <> ".beam`",
    "and the carder runtime modules must be on the code path; for a self-contained artifact, compile",
    "the module with `--link`.",
    "",
    "## Usage",
    "",
    ..list.append(usage, [
      "",
      "## Value ABI",
      "",
      "- `i32` / `i64` ⇄ `Int` (signed two's-complement).",
      "- `f32` / `f64` ⇄ `FloatVal` = `Finite(Float) | NonFinite(BitArray)` (NaN/±Inf via the raw",
      "  bytes); bit-exact round-trips via `f32_of_bits`/`f64_of_bits` and `f32_bits`/`f64_bits`.",
      "- `v128` ⇄ `BitArray` (16 little-endian bytes).",
      "- `funcref` / `externref` ⇄ opaque `Ref`.",
      "- multi-value results ⇄ a tuple; zero results ⇄ `Nil`.",
      "- a trap ⇄ `Error(Trap(reason))`.",
      "",
      "## Not covered this phase",
      "",
      "A WASM `throw` / `exnref` is a distinct term class and is **not** intercepted by the trap",
      "catch — a throwing export escapes the typed-error surface.",
    ])
  ]
  |> string.join("\n")
  |> ensure_trailing_newline
}

// ───────────────────────────── small utilities ─────────────────────────────

/// Join strings with `", "` — the argument/field separator used throughout the renderers.
fn comma(parts: List(String)) -> String {
  string.join(parts, ", ")
}

/// Guarantee exactly one trailing newline (deterministic file endings, R25a).
fn ensure_trailing_newline(s: String) -> String {
  case string.ends_with(s, "\n") {
    True -> s
    False -> s <> "\n"
  }
}
