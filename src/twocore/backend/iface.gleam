//// The language-neutral **Interface Descriptor** — the Phase-12 keystone (P1),
//// freezing `«IFACE-DESC-FROZEN»`.
////
//// After a WASM module is compiled to a `.beam` (the raw run-ABI: arguments/results are
//// raw unsigned bit patterns, multi-value is a package, a trap is a BEAM exception), Phase 12
//// emits **companion typed host-language source files** (`.gleam`/`.erl`/`.ex`) that present a
//// native-typed API (`Int`/`Float`/`BitArray`, traps as `Result`). This module computes the
//// single descriptor every emitter renders — `describe(module, binding) -> Iface` — so the
//// three sibling emitters (P12-02/03/04) and the CLI (P12-05) build against ONE contract and
//// never re-derive from the IR.
////
//// ## The frozen surface (downstream builds against this verbatim)
////
//// - `Iface` / `ExportSig` / `StateModel` / `GeneratedFile` / `IfaceError` — the descriptor.
//// - `describe/2` — the fail-closed derivation.
//// - `host_types/1` — the canonical WASM→host type-name table (P2).
//// - `value_abi/1` — the boundary-conversion class + float codec width (P2 + R18) as data.
//// - `result_encoding/1` — the run-ABI result-package shape (R4).
//// - `sanitize_identifier/1` — the single-name host-identifier rule (R9/R15).
//// - `Emitter` — the uniform emitter signature `fn(Iface) -> List(GeneratedFile)` (§3.5).
////
//// ## The emitted `.beam` ABI the descriptor mirrors (R2/R19 — grounded in `emit_core`)
////
//// Phase 12 targets a **Threaded (tier-P)** build only (`describe/2` rejects `Cell`,
//// import-bearing, and mutable tiers up front). Under `state_strategy: Threaded`, `emit_core`
//// emits **every** export UNIFORMLY at arity `param_count + 1`
//// (verified in `emit_core.emit_fn_export`):
////
//// - a **state-reaching** export exports its internal def directly —
////   `fun(St, A…) -> {ResultPackage, St'}`;
//// - a **pure** export gets a thin adapter — `fun(St, A…) -> {apply 'g'/n(A…), St}` — still `n+1`.
////
//// So the binding ALWAYS supplies a leading `InstanceState` `St` and ALWAYS receives a
//// `{ResultPackage, St'}` 2-tuple. `ExportSig.emitted_arity`/`leading_state` carry this exactly
//// (the freeze test asserts `emitted_arity` equals the arity in the real emitted `.core`).
//// `touches_state` (the transitive state-reaching closure, R1) governs only the HOST surface:
//// whether the typed function threads the `Instance` back (`StateModel = Threaded`) or is
//// presented pure (`StateModel = Stateless`), NOT the `.beam` arity.
////
//// The `ResultPackage` follows the run-ABI (R4): **0 results → the atom `ok`; 1 result → the
//// bare value; N≥2 → an N-tuple** in declaration order (`result_encoding/1`).

import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// ───────────────────────────── The frozen types ─────────────────────────────

/// The language-neutral Interface Descriptor (P1). Computed once from the lowered/optimized
/// IR `Module` + the runtime `Binding` (`describe/2`); every emitter RENDERS this and never
/// re-derives from the IR.
///
/// - `module_name`: the FINAL loaded BEAM module atom the binding dispatches into — `module.name`
///   verbatim (`twocore@wasm@<base>`, R8/R14), NOT normalized. If Phase-11 `--link` renames the
///   module, the CLI renames `ir.Module.name` before BOTH `emit_core` and `describe`, so the
///   binding's static `'<atom>':export(…)` call and the loaded `.beam` agree.
/// - `state_model`: whether the HOST API threads an `Instance` (see `StateModel`).
/// - `exports`: one `ExportSig` per callable (`ExportFn`) export, in declaration order. Exported
///   state (`ExportGlobal`/`ExportTable`/`ExportMemory`/`ExportTag`) is skipped this phase (R13).
pub type Iface {
  Iface(module_name: String, state_model: StateModel, exports: List(ExportSig))
}

/// How the host API presents instance state (R3/R19). The `.beam` ABI is uniformly `n+1`
/// regardless (see the module ABI note); this governs only the HOST-facing surface.
///
/// - `Stateless`: the whole-module transitive state-reaching closure is EMPTY (no export threads
///   state). The "beautiful pure file": there is **no `Instance` and no `instantiate`** in the
///   surface — each export is `fn(args) -> Result(T, Trap)`, internally obtaining a fresh state.
/// - `Threaded`: ≥1 export threads the `InstanceState` record. The binding exposes
///   `instantiate() -> Result(Instance, Trap)`; every export takes `inst`; a `touches_state`
///   export returns `Result(#(T, Instance), Trap)`, the rest return `Result(T, Trap)`
///   (take `inst`, discard the unchanged returned state).
pub type StateModel {
  Stateless
  Threaded
}

/// One callable export's typed surface — the exact per-export contract every emitter renders.
///
/// - `host_name`: the deterministic, language-legal identifier the host program calls
///   (`sanitize_identifier` + collision resolution, R9/R15). Legal as a Gleam function name
///   (`[a-z][a-z0-9_]*`, no keyword, no reserved API name), hence also a legal unquoted
///   Erlang/Elixir function name — one name valid in all three languages. May differ from the
///   WASM export name (`run-test` → `run_test`); the emitter documents the original in a `///`.
/// - `dispatch_atom`: the EXACT `ExportFn.export_name`, used VERBATIM in `@external`/`apply` as
///   the `.beam` export atom (never sanitized — correctness, R9). WASM export names are arbitrary
///   strings, so this is quoted at the call site.
/// - `params` / `results`: the export's WASM `FuncType`, derived via `ir.signature` — the value
///   types the boundary converts (`host_types/1` / `value_abi/1`).
/// - `touches_state`: whether the export reads/mutates instance state — the TRANSITIVE
///   state-reaching closure (`emit_core.state_reaching_closure`, R1), matching the emitted arity.
///   Governs the host-facing return shape under `StateModel = Threaded`.
/// - `emitted_arity`: the EXACT arity of the emitted `.beam` export under the (Threaded) build —
///   `list.length(params) + 1` (R2/R19). The single arity the emitter passes at the call site;
///   the freeze test asserts it equals the arity in the real emitted `.core`.
/// - `leading_state`: whether the `.beam` export takes a leading `InstanceState` argument — `True`
///   for every accepted (Threaded) export (R19). The export's return is the `{ResultPackage, St'}`
///   2-tuple; the `ResultPackage` shape is `result_encoding(results)` (R4).
pub type ExportSig {
  ExportSig(
    host_name: String,
    dispatch_atom: String,
    params: List(ir.ValType),
    results: List(ir.ValType),
    touches_state: Bool,
    emitted_arity: Int,
    leading_state: Bool,
  )
}

/// One emitted companion source file (P4). `path` is relative to the CLI `--out` dir; `content`
/// is the full UTF-8 source. Deterministic — no timestamps, stable ordering (P6/R25a).
pub type GeneratedFile {
  GeneratedFile(path: String, content: String)
}

/// The fail-closed rejections `describe/2` can return (P8, R13/R20). `describe/2` either produces
/// a valid `Iface` or rejects for one of these — an unresolved `ExportFn.fn_name` post-validation
/// is an IMPOSSIBLE state (a documented `let assert`), NOT an error variant.
///
/// - `CellUnsupported`: the build binding is `Cell` (tier-O). The process-wrapped server binding
///   for stateful modules is deferred; `--bindings` requires a Threaded build.
/// - `ImportBearingUnsupported`: the module has ANY import (`ImportFn`/`ImportGlobal`/`ImportTable`/
///   `ImportMemory`/`ImportTag`) — `instantiate/1` would need providers at instance time. A typed
///   provider surface is deferred.
/// - `MutableTierUnsupported`: a Threaded build over a mutable memory/table tier
///   (`Atomics`/`Nif`/`TableEts`/`TableAtomics`). A "pure-value-threaded" binding over ALIASED
///   mutable state would be a lie (an old `Instance` observing new writes), so `--bindings`
///   requires a pure-value tier (`Paged` + `TablePaged`) this phase (R20).
pub type IfaceError {
  CellUnsupported
  ImportBearingUnsupported
  MutableTierUnsupported
}

/// The per-language host-type NAMES for one WASM `ValType` (P2). Rendered into the emitters'
/// type annotations (`-spec`/`@spec`/Gleam types). The float names are the finite scalar type;
/// the non-finite sum-type wrapper (`Finite(Float) | NonFinite(BitArray)`, R18) is emitter-owned
/// and uses `value_abi/1`'s width for its raw-bits codec.
pub type HostTypeNames {
  HostTypeNames(gleam: String, erlang: String, elixir: String)
}

/// The boundary-conversion CLASS of one WASM `ValType` (P2) — the value-ABI mapping as DATA, so
/// the three emitters cannot drift on how each type crosses the native ⇄ raw-ABI boundary. Total
/// over every `ir.ValType`.
///
/// - `IntAbi(width)`: `TI32`⇒32 / `TI64`⇒64. Presented **signed** two's-complement; the raw ABI
///   is the unsigned bit pattern in `[0, 2^width)` (host ints are bignums — no width loss).
/// - `FloatAbi(width)`: `TF32`⇒32 / `TF64`⇒64. Finite values present as native float; non-finite
///   (NaN/±Inf) MUST go via the raw-bits path (a BEAM `float()` cannot hold them — R18). `width`
///   is the IEEE codec width (`<<F:width/float>>`), taken from HERE, never from `host_types/1`.
/// - `V128Abi`: `TV128`. Identity — 16 raw little-endian bytes (`BitArray`/`binary()`).
/// - `RefAbi`: `TFuncRef`/`TExternRef`/`TExnRef`/`TTerm`. Opaque passthrough (the boxed `rt_ref`
///   term); holdable/passable but not host-constructible this phase.
pub type ValueAbi {
  IntAbi(width: Int)
  FloatAbi(width: Int)
  V128Abi
  RefAbi
}

/// The run-ABI result-package shape of a `.beam` export (R4) — how the `ResultPackage` inside the
/// `{ResultPackage, St'}` return is encoded, from the export's result arity.
///
/// - `ResultUnit`: 0 results → the atom `ok`.
/// - `ResultBare`: 1 result → the bare value (no wrapper).
/// - `ResultTuple(n)`: `n ≥ 2` results → an `n`-tuple `{V1,…,Vn}` in declaration order.
pub type ResultEncoding {
  ResultUnit
  ResultBare
  ResultTuple(arity: Int)
}

/// The uniform emitter signature (§3.5) — the single contract all three emitters (P12-02/03/04)
/// and the CLI (P12-05) build against. Each emitter is a total `fn(Iface) -> List(GeneratedFile)`.
///
/// The return is a **`List`** (not one file) because Gleam cannot catch a BEAM exception
/// in-language: surfacing a trap as a `Result` requires a tiny companion `.erl` catch shim,
/// emitted as an ADDITIONAL `GeneratedFile`. Erlang and Elixir catch natively and return a single
/// file. P12-01 freezes only the shape; the bodies live in the sibling emitter modules.
pub type Emitter =
  fn(Iface) -> List(GeneratedFile)

// ───────────────────────────── describe/2 ─────────────────────────────

/// Derive the `Iface` from a compiled module + its build binding (P1). Fail-closed (P8).
///
/// - `module`: the **lowered + optimized** IR module about to be emitted (R1/R17) — the SAME
///   `ir.Module` `emit_core` consumes, so `touches_state` is computed from the identical function
///   bodies (the CLI lowers once and hands one module to both). `module.name` MUST already be the
///   final loaded BEAM module atom (the CLI passes the Phase-11 `--link`-renamed module, if any) —
///   `describe` does NOT normalize it (R8).
/// - `binding`: the build binding. Only `state_strategy`, `mem_tier`, and `table_tier` are
///   consulted (the fail-closed gate); the runtime-module names are irrelevant here.
///
/// Returns, in this precedence:
/// - `Error(CellUnsupported)` if `binding.state_strategy == Cell`.
/// - `Error(ImportBearingUnsupported)` if `module.imports != []`.
/// - `Error(MutableTierUnsupported)` if the memory/table tier is not the pure-value pair
///   (`Paged` + `TablePaged`).
/// - `Ok(Iface)` otherwise — one `ExportSig` per `ExportFn` in declaration order; `state_model`
///   is `Threaded` iff any export `touches_state`, else `Stateless`.
///
/// Assumes a validated module: every `ExportFn.fn_name` resolves to a defined function (guaranteed
/// by the pipeline's validate stage). An unresolved name is an IMPOSSIBLE state → a documented
/// `let assert`, never an `IfaceError` variant (R13).
pub fn describe(
  module: ir.Module,
  binding: instance.Binding,
) -> Result(Iface, IfaceError) {
  case binding.state_strategy {
    instance.Cell -> Error(CellUnsupported)
    instance.Threaded ->
      case module.imports {
        [_, ..] -> Error(ImportBearingUnsupported)
        [] ->
          case is_pure_value_tier(binding) {
            False -> Error(MutableTierUnsupported)
            True -> Ok(build_iface(module))
          }
      }
  }
}

/// `True` iff the binding threads state purely by value — the ONLY tier `--bindings` accepts this
/// phase (R20). Requires `mem_tier == Paged` (immutable-binary rebuild-on-write) AND
/// `table_tier == TablePaged` (immutable sparse dict). Any mutable tier (`Atomics`/`Nif`/`TableEts`/
/// `TableAtomics`) aliases process-local state, so a value-threaded binding over it would let an old
/// `Instance` observe new writes — rejected fail-closed.
fn is_pure_value_tier(binding: instance.Binding) -> Bool {
  binding.mem_tier == instance.Paged
  && binding.table_tier == instance.TablePaged
}

/// Assemble the `Iface` for an ACCEPTED (Threaded, import-free, pure-value-tier) module. Split
/// from `describe/2` so the fail-closed gate reads top-to-bottom. Assumes every `ExportFn.fn_name`
/// resolves (guaranteed by validate — the `let assert` documents the impossible state, R13).
fn build_iface(module: ir.Module) -> Iface {
  let reaching = emit_core.state_reaching_closure(module.functions)
  // Collect one `#(export_name, function)` per `ExportFn`, in declaration order; skip exported
  // STATE (R13 — not a typed callable this phase).
  let fn_exports =
    list.filter_map(module.exports, fn(exp) {
      case exp {
        ir.ExportFn(export_name, fn_name) -> {
          let assert Ok(fun) =
            list.find(module.functions, fn(f) { f.name == fn_name })
          Ok(#(export_name, fun))
        }
        _ -> Error(Nil)
      }
    })
  // Sanitize + collision-resolve host names ACROSS all exports first (declaration order), so a
  // deterministic `_2`/`_3` suffix disambiguates duplicates and reserved names (R15).
  let host_names = assign_host_names(list.map(fn_exports, fn(pair) { pair.0 }))
  let exports =
    list.map2(fn_exports, host_names, fn(pair, host_name) {
      let #(export_name, fun) = pair
      let sig = ir.signature(fun)
      ExportSig(
        host_name: host_name,
        dispatch_atom: export_name,
        params: sig.params,
        results: sig.results,
        touches_state: set.contains(reaching, fun.name),
        // Under the (always-Threaded) accepted binding, emit_core emits at `n+1` with a leading
        // `St` and a `{Package, St'}` return — for BOTH state-reaching and pure exports (R19).
        emitted_arity: list.length(sig.params) + 1,
        leading_state: True,
      )
    })
  let state_model = case list.any(exports, fn(e) { e.touches_state }) {
    True -> Threaded
    False -> Stateless
  }
  Iface(module_name: module.name, state_model: state_model, exports: exports)
}

// ───────────────────────────── value-ABI mapping (P2) ─────────────────────────────

/// The canonical WASM→host type-NAME mapping (P2). Total over every `ir.ValType` (an exhaustive
/// `case`, no catch-all, so a future `ValType` forces a decision here). Integers are presented
/// **signed** (what a host programmer expects from "i32"); the module is sign-agnostic on the bits.
///
/// - `TI32`/`TI64` → `Int` / `integer()` / `integer()`.
/// - `TF32`/`TF64` → `Float` / `float()` / `float()` (the finite scalar; non-finite via `value_abi`).
/// - `TV128` → `BitArray` / `binary()` / `binary()` (16 LE bytes).
/// - `TFuncRef`/`TExternRef`/`TExnRef`/`TTerm` → `Ref` / `term()` / `term()` (opaque passthrough).
pub fn host_types(vt: ir.ValType) -> HostTypeNames {
  case vt {
    ir.TI32 | ir.TI64 -> HostTypeNames("Int", "integer()", "integer()")
    ir.TF32 | ir.TF64 -> HostTypeNames("Float", "float()", "float()")
    ir.TV128 -> HostTypeNames("BitArray", "binary()", "binary()")
    ir.TFuncRef | ir.TExternRef | ir.TExnRef | ir.TTerm ->
      HostTypeNames("Ref", "term()", "term()")
  }
}

/// The boundary-conversion CLASS + float codec width of one `ir.ValType` (P2 + R18) — the
/// value-ABI as data (see `ValueAbi`). Total over every `ir.ValType` (exhaustive `case`, no
/// catch-all). The float `width` here (32/64) is the IEEE raw-bits codec width every emitter MUST
/// use for f32/f64 (never `host_types`, which says `Float` for both).
pub fn value_abi(vt: ir.ValType) -> ValueAbi {
  case vt {
    ir.TI32 -> IntAbi(32)
    ir.TI64 -> IntAbi(64)
    ir.TF32 -> FloatAbi(32)
    ir.TF64 -> FloatAbi(64)
    ir.TV128 -> V128Abi
    ir.TFuncRef | ir.TExternRef | ir.TExnRef | ir.TTerm -> RefAbi
  }
}

/// The run-ABI result-package shape for a `results` list (R4). The emitters destructure the
/// `ResultPackage` (inside the `{ResultPackage, St'}` export return) by this:
/// `[]` → `ResultUnit` (the atom `ok`); `[_]` → `ResultBare` (the bare value); `n≥2` →
/// `ResultTuple(n)` (an `n`-tuple in declaration order). Total — never fails.
pub fn result_encoding(results: List(ir.ValType)) -> ResultEncoding {
  case results {
    [] -> ResultUnit
    [_] -> ResultBare
    _ -> ResultTuple(list.length(results))
  }
}

// ───────────────────────────── host-name sanitization (R9/R15) ─────────────────────────────

/// Sanitize one WASM export name into a Gleam-legal lowercase identifier (`[a-z][a-z0-9_]*`),
/// which is also a legal unquoted Erlang/Elixir function name (R9/R15). Deterministic + total.
///
/// Rules: uppercase letters lowercase; `[a-z0-9_]` are kept; every other byte (dash, dot, `@`,
/// control, unicode) becomes `_`; a result that is empty or does not start with `[a-z]` (e.g. the
/// Porffor export `"0"`, or `"_start"`) is prefixed `e_`. NOTE: this alone does NOT reserve API
/// names or resolve inter-export collisions — `describe/2` layers those on (see `assign_host_names`);
/// exposed `pub` so an emitter/CLI can legalize a related identifier (e.g. a binding module base)
/// from the same rule.
///
/// - `raw`: the WASM export name (any string).
/// - Returns a non-empty identifier matching `[a-z][a-z0-9_]*`.
pub fn sanitize_identifier(raw: String) -> String {
  let mapped =
    string.to_graphemes(raw)
    |> list.map(map_ident_char)
    |> string.concat
  case starts_with_lower(mapped) {
    True -> mapped
    False -> "e_" <> mapped
  }
}

/// Map one grapheme to its identifier-legal form: `A-Z`→`a-z`, `a-z0-9_` kept, else `_`. A
/// multi-byte / non-ASCII grapheme is not in the kept set, so it maps to `_` (deterministic).
fn map_ident_char(g: String) -> String {
  case g {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> g
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "_" -> g
    "A" -> "a"
    "B" -> "b"
    "C" -> "c"
    "D" -> "d"
    "E" -> "e"
    "F" -> "f"
    "G" -> "g"
    "H" -> "h"
    "I" -> "i"
    "J" -> "j"
    "K" -> "k"
    "L" -> "l"
    "M" -> "m"
    "N" -> "n"
    "O" -> "o"
    "P" -> "p"
    "Q" -> "q"
    "R" -> "r"
    "S" -> "s"
    "T" -> "t"
    "U" -> "u"
    "V" -> "v"
    "W" -> "w"
    "X" -> "x"
    "Y" -> "y"
    "Z" -> "z"
    _ -> "_"
  }
}

/// `True` iff `s` is non-empty and its first grapheme is a lowercase ASCII letter (`[a-z]`) — the
/// Gleam identifier start requirement.
fn starts_with_lower(s: String) -> Bool {
  case string.first(s) {
    Ok(c) -> is_ascii_az(c)
    Error(_) -> False
  }
}

/// `True` iff the single grapheme `c` is one of `a`..`z` (ASCII lowercase letter).
fn is_ascii_az(c: String) -> Bool {
  case c {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    _ -> False
  }
}

/// Assign a UNIQUE host name to each WASM export name, in declaration order (R15). Each name is
/// `sanitize_identifier`'d, then disambiguated against (a) the reserved generated API/helper/type
/// names + the union of Gleam/Erlang/Elixir keywords and (b) every previously-assigned host name,
/// by appending the smallest `_<n>` (`n` from 2) that is free. Deterministic — a re-`describe` of
/// the same module yields identical names.
fn assign_host_names(export_names: List(String)) -> List(String) {
  let #(names, _used) =
    list.fold(export_names, #([], reserved_names()), fn(acc, raw) {
      let #(names, used) = acc
      let candidate = sanitize_identifier(raw)
      let final = disambiguate(candidate, used, 2)
      #([final, ..names], set.insert(used, final))
    })
  list.reverse(names)
}

/// Return `candidate` if free in `used`, else `candidate_<n>` for the smallest `n ≥ start` that
/// is free. Terminates: the `_<n>` family is infinite and `used` is finite.
fn disambiguate(candidate: String, used: Set(String), n: Int) -> String {
  case set.contains(used, candidate) {
    False -> candidate
    True -> {
      let next = candidate <> "_" <> int.to_string(n)
      case set.contains(used, next) {
        False -> next
        True -> disambiguate(candidate, used, n + 1)
      }
    }
  }
}

/// The names an export host name must NOT collide with (R15): the generated typed-API surface
/// (helpers/types, lowercased) plus the UNION of Gleam/Erlang/Elixir reserved words — so a single
/// `host_name` is safe in every emitter. Over-reserving is harmless (it only triggers a `_2`).
fn reserved_names() -> Set(String) {
  set.from_list([
    // Generated API / helper / type names (lowercased — a lowercase host_name could shadow them).
    "instantiate", "raw_instantiate", "rescue", "instance", "trap", "ref",
    "finite", "nonfinite", "i32_to_raw", "i32_of_raw", "i64_to_raw",
    "i64_of_raw", "f32_bits", "f32_of_bits", "f64_bits", "f64_of_bits",
    "v128_bytes", "module_info", "main",
    // Gleam / Erlang / Elixir reserved words (union — lowercase forms).
    "as", "assert", "case", "const", "external", "fn", "if", "import", "let",
    "opaque", "pub", "todo", "type", "use", "panic", "echo", "after", "and",
    "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "catch",
    "cond", "div", "end", "fun", "not", "of", "or", "orelse", "receive", "rem",
    "try", "when", "xor", "maybe", "do", "else", "false", "true", "nil", "in",
    "ok", "error",
  ])
}
