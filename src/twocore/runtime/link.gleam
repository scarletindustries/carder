//// `link` — the non-function-import instantiation/link contract (H4, R4). Fail-closed (H6/D3a).
////
//// The WebAssembly spec instantiates a module against a vector of **external values** the
//// embedder resolves for its imports (spec
//// [§4.5.4 instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
//// matching relation [§3.2](https://webassembly.github.io/spec/core/valid/matching.html)). In
//// 2core the store is per-instance and process-local (E1), so an external value is one of a few
//// concrete term shapes — a `Provided`. This module is the SINGLE OWNER of that contract (a new
//// single-owned module, R4), homed in `runtime/` so the conformance harness (unit 11) can call it
//// without a `pipeline` dependency.
////
//// ## Provided state vs a capability (H4)
////
//// An imported **function** is a *capability* — it is dispatched by `rt_host.call_host` at its
//// call site under the instance's `HostPolicy`, and never becomes a `Provided` state slot. An
//// imported **global / table / memory** is **provided state** — a value the instantiation
//// contract SUPPLIES, wired into the instance's cell/record (`rt_state.seed_full`/`fresh_full`)
//// exactly like a module-defined one. The two seams stay cleanly separated: `call_host` gates
//// behaviour, this contract supplies data.
////
//// ## Fail-closed linking (H6, spec §4.5.4)
////
//// `link_imports` resolves every non-function import against the build-controlled providers (the
//// fixed `spectest` module + the explicitly-`(register)`ed instances) and **fails closed** on any
//// unsatisfied import (`UnknownImport`) or type/limits-mismatched import (`IncompatibleImportType`)
//// — the `.wast` `assert_unlinkable` case. There is NO ambient default: a missing import is never
//// fabricated as a zero global / empty table / ambient memory; the instance is simply not created.
//// The resolver reads `#(module, name)` only to SELECT among build-controlled providers, never to
//// CONSTRUCT a runtime target (D3a) — exactly as `rt_host` never builds a module atom from data.
////
//// ## The `instantiate/0` vs `instantiate/1` ABI (H7 byte-identity)
////
//// An import-free module keeps `instantiate/0` (byte-identical to Phase-4). A module with ≥1
//// imported global/table/memory gets `instantiate/1(Imports)`, where `Imports` is the ordered,
//// **name-free positional** list `link_imports` returns — one `Provided` per STATE import, in the
//// module's state-import declaration order (a function import contributes NO element). `emit_core`
//// (unit 06) bakes each position's kind + target slot statically from the `ImportDecl` list, weaves
//// each `Provided` into the right `rt_state.FullDecl` slot (imports occupy the low indices, spec
//// §2.5.1), and calls `rt_state.seed_full`/`fresh_full`. So the wiring is build-controlled — no
//// runtime dispatch on an import name in generated code (D3a).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import twocore/ir.{
  type FuncType, type IdxType, type Module, type RefType, type ValType, FuncRef,
  Idx32, ImportFn, ImportGlobal, ImportMemory, ImportTable, ImportTag, TF32,
  TF64, TI32, TI64,
}
import twocore/runtime/rt_host
import twocore/runtime/rt_mem
import twocore/runtime/rt_table

/// Identity coercion of a `List(Dynamic)` to the `List(Int)` shape `rt_host.call_host`
/// consumes — sound because a host function argument is a raw numeric bit pattern (D5), which
/// on the BEAM is exactly an Erlang integer, so the runtime term is unchanged (no decode/copy).
/// Used ONLY at the host-closure boundary (`host_func_closure`); never on a reference/v128 term.
@external(erlang, "gleam_stdlib", "identity")
fn coerce_args_to_ints(args: List(Dynamic)) -> List(Int)

/// Identity coercion of `rt_host.call_host`'s `List(Int)` result back to the closure ABI's
/// `List(Dynamic)` value list — sound for the same reason (an `Int` bit pattern IS the term).
@external(erlang, "gleam_stdlib", "identity")
fn coerce_ints_to_dynamics(results: List(Int)) -> List(Dynamic)

/// The raw IEEE-754 bit pattern (D5) of the reference `spectest` module's `global_f32 = 666.6`,
/// as an `Int` — `0x4426A666` = `1143383654`, the f32 nearest to the double `666.6`. Stored as
/// raw bits, NEVER a BEAM double (a double cannot preserve the exact rounding), matching the
/// pipeline's float-bit convention. (Source: the spec's `imports.wast` host module.)
const spectest_global_f32_bits = 0x4426A666

/// The raw IEEE-754 bit pattern (D5) of the reference `spectest` module's `global_f64 = 666.6`,
/// as an `Int` — `0x4084D4CCCCCCCCCD` = `4649074691427585229`. Raw bits, never a BEAM double.
const spectest_global_f64_bits = 0x4084D4CCCCCCCCCD

/// The Safe max-pages cap baked into the `spectest` memory's `rt_mem.fresh` — `65536` = 2¹⁶
/// pages, the i32 4 GiB address-space cap (spec §2.5.4). The spectest memory declares max 2, so
/// its effective cap is `min(2, 65536) = 2`; this value only bounds `memory.grow` past the
/// declared max, never below it.
const spectest_mem_safe_cap = 65_536

/// A resolved external value supplied to an instance for ONE of its imports (spec §4.5.4
/// externval — the "provided state" of H4). It is the OUTPUT of `link_imports` (per STATE import)
/// and, wired into an `rt_state.FullDecl` slot by `emit_core` (unit 06), the INPUT to the
/// generated `instantiate/1`.
///
/// Every field the fail-closed matching gate needs (spec §3.2 / §4.5.4) is carried:
///
/// - `ProvidedGlobal(value, ty, mutable)`: a NUMERIC global's current value as a raw bit pattern
///   (D5 — i32/i64/f32/f64 all `Int`, never a BEAM double). `ty`/`mutable` drive global matching.
/// - `ProvidedRefGlobal(value, ty, mutable)`: a REFERENCE-typed global (funcref/externref), its
///   value an opaque `Dynamic` reference (R8). `ty` is `TFuncRef`/`TExternRef`.
/// - `ProvidedTable(value, ref_ty, min, max)`: a table externval — the OPAQUE `rt_table` value;
///   `ref_ty`/`min`/`max` drive table matching. `rt_state` stores `value` as-is (opaque).
/// - `ProvidedMemory(value, min_pages, max_pages, idx_type)`: a memory externval — the OPAQUE
///   `rt_mem` value; the limits + `idx_type` drive memory matching.
/// - `ProvidedFunc(ty, call)`: a FUNCTION export made callable across instances (I5/S5/«XLINK»).
///   `ty` drives fail-closed function-import matching (spec §3.2.7 — `match_func` compares
///   `FuncType` by equality, never the closure). `call` is the **linker-built closure capability**:
///   a first-class `fun` the LINKER (P6-09) constructs, capturing the exporting instance + its
///   exported function (a host/`spectest` import routes through the checked `rt_host` dispatch; a
///   cross-module import routes into the exporting instance's owning process). The generated
///   caller lowers an imported-function call (`CallImport`) to `link.call_import(call, args_list)`
///   over this HANDED-IN closure — a CAPABILITY, exactly like `externref`/`call_host`, NOT an
///   ambient `apply` of an attacker-chosen `module:atom` (D3a). The closure is held by the
///   caller's POSITIONAL import slot (R4 — name-free), never looked up by a runtime name in
///   generated code. A `ProvidedFunc` carrying a `fun` must NEVER be compared with `==` (BEAM
///   compares funs by identity); nothing here does (matching uses `ty` only). No P5 site
///   CONSTRUCTS a `ProvidedFunc` (it was only matched — cross-instance dispatch was absent, I5);
///   P6-09 adds the construction + the function-import `link_imports` path. The closure takes the
///   argument list and returns a **value LIST** (`List(Dynamic)`) — multi-value results (a host
///   `print*` returns `[]`, a cross-module fn returns 0/1/many), consistent with the R17 value-list
///   invoke ABI (S5).
pub type Provided {
  ProvidedGlobal(value: Int, ty: ValType, mutable: Bool)
  ProvidedRefGlobal(value: Dynamic, ty: ValType, mutable: Bool)
  ProvidedTable(value: Dynamic, ref_ty: RefType, min: Int, max: Option(Int))
  ProvidedMemory(
    value: Dynamic,
    min_pages: Int,
    max_pages: Option(Int),
    idx_type: IdxType,
  )
  ProvidedFunc(ty: FuncType, call: fn(List(Dynamic)) -> List(Dynamic))
}

/// Construct a FUNCTION external value (spec §4.5.4 func address) from an export signature +
/// its dispatch closure, WITHOUT depending on the `Provided` tuple layout (the D1-clean shape
/// ABI). The register seam (P6-10) uses this to publish a `(register)`ed module's exported
/// function as a cross-module callable — `call` is the routing closure it builds capturing the
/// exporting instance's live handle (§C.2 of the unit doc). `link_func_imports` uses it too, for
/// the host/`spectest` case (§B.3). See `ProvidedFunc` for the closure ABI + D3a contract.
///
/// - `ty`: the export's declared `FuncType` — drives fail-closed function-import matching
///   (spec §3.2.7 function equality); NEVER compared structurally with the closure.
/// - `call`: the dispatch closure (`fn(List(Dynamic)) -> List(Dynamic)`) applied 1-ary by
///   `call_import` at the import site.
/// - Returns the `ProvidedFunc(ty, call)` externval.
pub fn provided_func(
  ty: FuncType,
  call: fn(List(Dynamic)) -> List(Dynamic),
) -> Provided {
  ProvidedFunc(ty:, call:)
}

/// A source of externvals for a `#(module, name)` import (spec §4.5.4). Two build-controlled
/// providers exist — there is NO ambient/data-driven provider (D3a): (1) the built-in `spectest`
/// module (consulted directly via `spectest_export`/`rt_host.spectest_func_type`, always present,
/// not a `Provider`), and (2) `Registered(link_name, exports)` — a prior instance registered under
/// `link_name` by the `(register "name" $mod)` command, whose `exports` map its exported-state
/// names → the externvals captured at register time (snapshot semantics; unit 11 supplies these
/// from the harness registry).
pub type Provider {
  Registered(link_name: String, exports: Dict(String, Provided))
}

/// A fail-closed link failure (spec §4.5.4 — an unprovided or mismatched import is a link error;
/// the `.wast` `assert_unlinkable` case). NEVER an ambient default: the instance is not created.
///
/// - `UnknownImport(module, name)`: no provider supplies `#(module, name)` — the spec phrase
///   "unknown import".
/// - `IncompatibleImportType(module, name, detail)`: a provider supplies it but its externtype
///   does NOT match the declared import type (§3.2 matching) — the spec phrase "incompatible import
///   type". `detail` is a human-readable note (diagnostic only; match the variant, not the text).
pub type ImportError {
  UnknownImport(module: String, name: String)
  IncompatibleImportType(module: String, name: String, detail: String)
}

/// Resolve every non-function import of `module` against `providers` (+ the built-in `spectest`),
/// producing the ordered positional `Imports` list for the generated `instantiate/1` — or the
/// FIRST link failure (fail-closed, spec §4.5.4). Total; pure; no runtime dispatch (D3a).
///
/// - `module`: the IR module whose `imports` order IS the returned list's order.
/// - `providers`: the `(register)`ed instances (unit 11 supplies these); `spectest` is always
///   consulted IN ADDITION (module name `"spectest"`).
/// - Returns `Ok(provided_in_state_import_order)` when EVERY import is provided AND matches — one
///   `Provided` per imported global/table/memory, in declaration order, function imports
///   contributing NO element (they are call-site capabilities, H4). Else `Error(ImportError)` for
///   the first unsatisfied/mismatched import (the instance is never instantiated, H6).
///
/// A FUNCTION import is still CHECKED (existence + signature) so a bogus `spectest` / registered
/// function import fails `assert_unlinkable` (§C.3) rather than silently deferring to a call
/// denial; a function import to a genuine host capability (e.g. `env`) is NOT link-checked (it is
/// resolved by the `HostPolicy` at its call site), so it neither errors nor emits an element. The
/// function import's runtime CALLABLE (its dispatch closure) is resolved by the SEPARATE
/// `link_func_imports` seam (S5 — "the instance's function-import vector"), so THIS list stays
/// state-only and byte-identical to Phase-5 (H7).
pub fn link_imports(
  module: Module,
  providers: List(Provider),
) -> Result(List(Provided), ImportError) {
  resolve(module.imports, providers, [])
}

// ── the imported-function CALL seam + the function-import vector (S5/«XLINK», P6-09) ───────────
//
// P5 only MATCHED a function import's signature (`match_fn`) — there was no callable. P6 makes an
// imported-function call real: `lower` emits `CallImport(slot, ty, args)`, `emit_core` (06) emits
// `link.call_import(closure, args_list)` against the caller's positional function-import slot, and
// THIS unit builds the closures + resolves the function-import vector (`link_func_imports`).
//
// **Why a SEPARATE vector, not the state `Imports` list (a deliberate, byte-identity deviation).**
// The unit doc's Deviation #2 sketches interleaving function slots into the single positional
// `Imports` list. That growth is only sound once `emit_core` grows in lockstep
// (`count_state_imports` → count function imports too + the `imported_slots` `ImportFn` arm + the
// dispatch-vector seed) — which is P6-06's charter and is NOT landed yet. Growing the single list
// now would desync `link_imports` (state resolver) from the driver's `provided == [] ? 0 : 1`
// arity dispatch and `emit_core`'s state-only destructure, breaking every already-instantiating
// `env`-function-importing corpus module. So `link_imports` stays STATE-ONLY (byte-identical, H7)
// and the function-import CALLABLES are resolved by a sibling seam, `link_func_imports` — which is
// exactly "the instance's function-import vector" S5 names. 06 composes the two vectors when it
// lands the dispatch-vector seed. This is the "leaf" flagged in state.md.

/// Dispatch an imported-function call — the thin 1-ary seam `emit_core` (06) emits for a
/// `CallImport` node (S5). It APPLIES the handed-in `closure` to the argument value list and
/// returns the callee's result value list. That is the ENTIRE body: `closure(args)`.
///
/// **D3a — a handed-in capability, never ambient authority.** `closure` is a first-class `fun`
/// value read from the caller's positional function-import slot (built by the linker at link time,
/// §B.3/§C.2), applied directly. This is NOT `erlang:apply(Module, Atom, Args)` on a data-derived
/// `module:atom`, and NOT the 2-arg `erlang:apply(Closure, ArgsList)` that would SPREAD the list
/// into an N-ary fun's parameters (the arity bug S5 fixes) — it is a plain 1-ary application of a
/// 1-ary list-taking closure. The dispatch target is thus a supplied capability, exactly like
/// `externref` / `call_host`; generated code never names the callee (D3a).
///
/// - `closure`: the resolved import's dispatch closure (`fn(List(Dynamic)) -> List(Dynamic)`) — a
///   host closure wrapping `rt_host.call_host` (§B.3) or a cross-module routing closure (§A/§C.2).
/// - `args`: the call's argument value list (D5 — each a raw i32/i64/f32/f64 bit pattern, an
///   `rt_ref` reference term, or a 16-byte v128 binary; one `Dynamic` per WASM argument).
/// - Returns the callee's result value list (multi-value: a host `print*` returns `[]`, a
///   cross-module function returns 0/1/many). A callee trap PROPAGATES by the closure raising
///   (§E.2) — `call_import` neither catches nor synthesizes a trap.
pub fn call_import(
  closure: fn(List(Dynamic)) -> List(Dynamic),
  args: List(Dynamic),
) -> List(Dynamic) {
  closure(args)
}

/// Resolve the FUNCTION-import vector of `module` — one dispatch closure per function import, in
/// function-import declaration order (spec §2.5.1) — matched FAIL-CLOSED (spec §3.2.7). This is
/// "the instance's function-import vector" (S5): the callables `emit_core` (06) seeds into the
/// imported-function dispatch vector and applies via `call_import`. SEPARATE from `link_imports`
/// (which stays state-only, byte-identical — see the section note); STATE imports contribute no
/// element here.
///
/// Each function import resolves to `ProvidedFunc(ty, call)`:
/// - `#("spectest", name)` → matched against `rt_host.spectest_func_type(name)` (equality); the
///   closure wraps `rt_host.call_host("spectest", name, _)` under THIS instance's `HostPolicy`
///   (§B.3). Missing name → `UnknownImport`; signature mismatch → `IncompatibleImportType`.
/// - `#(registered_mod, name)` where `registered_mod` is `(register)`ed → its export `name` must be
///   a `ProvidedFunc(sig, closure)`; match `sig == ty` and return that register-seam-built routing
///   closure (§C.2). Missing export → `UnknownImport`; a non-function export →
///   `IncompatibleImportType`; a signature mismatch → `IncompatibleImportType`.
/// - `#(other, name)` (neither `spectest` NOR registered) → a genuine host capability (e.g. `env`):
///   NOT link-checked (its fate is the call-site `HostPolicy`), resolved to a host closure wrapping
///   `call_host` and gated fail-closed at call time (preserves the P5 posture, §B.3).
///
/// - `module`: the IR module whose function imports are resolved.
/// - `providers`: the `(register)`ed instances (`spectest` is consulted IN ADDITION).
/// - Returns `Ok(closures_in_function_import_order)` when every function import is provided AND
///   matches, else `Error(ImportError)` for the FIRST unsatisfied/mismatched one (fail-closed, H6
///   — no instance is created; the `assert_unlinkable` case).
pub fn link_func_imports(
  module: Module,
  providers: List(Provider),
) -> Result(List(Provided), ImportError) {
  resolve_funcs(module.imports, providers, [])
}

/// The build-fixed `spectest` module's exported STATE externvals (spec test host module, R14). A
/// literal `case` — NO ambient authority (D3a): `name` selects among build-controlled results,
/// never constructs a target. Returns `Ok(Provided)` for a known export, `Error(Nil)` otherwise
/// (→ the resolver's `UnknownImport`). The reference values are the official `spectest` module's
/// (the spec's `imports.wast` host module):
///
/// - `global_i32 : i32 = 666`, `global_i64 : i64 = 666` — immutable, raw bits.
/// - `global_f32 : f32 = 666.6`, `global_f64 : f64 = 666.6` — immutable, stored as their raw
///   IEEE-754 bit pattern (D5), never a BEAM double.
/// - `table : funcref (min 10, max 20)` — a fresh empty funcref table (`rt_table.new`; every slot
///   null).
/// - `memory : (min 1, max 2)` pages — a fresh Idx32 memory (`rt_mem.fresh`).
///
/// The table/memory are built through the SAME `rt_table.new`/`rt_mem.fresh` (the paged tier — the
/// import/spectest tier) the importing binding links, so `rt_table`/`rt_mem` operate on them
/// uniformly once installed.
pub fn spectest_export(name: String) -> Result(Provided, Nil) {
  case name {
    "global_i32" -> Ok(ProvidedGlobal(value: 666, ty: TI32, mutable: False))
    "global_i64" -> Ok(ProvidedGlobal(value: 666, ty: TI64, mutable: False))
    "global_f32" ->
      Ok(ProvidedGlobal(
        value: spectest_global_f32_bits,
        ty: TF32,
        mutable: False,
      ))
    "global_f64" ->
      Ok(ProvidedGlobal(
        value: spectest_global_f64_bits,
        ty: TF64,
        mutable: False,
      ))
    "table" ->
      Ok(ProvidedTable(
        value: rt_table.new(10, Some(20)),
        ref_ty: FuncRef,
        min: 10,
        max: Some(20),
      ))
    "memory" ->
      Ok(ProvidedMemory(
        value: rt_mem.fresh(1, Some(2), spectest_mem_safe_cap),
        min_pages: 1,
        max_pages: Some(2),
        idx_type: Idx32,
      ))
    _ -> Error(Nil)
  }
}

/// The spec link PHRASE for an `ImportError` (spec §4.5.4) — `"unknown import"` for
/// `UnknownImport`, `"incompatible import type"` for `IncompatibleImportType`. Unit 11 surfaces
/// this so a `.wast` `assert_unlinkable "phrase"` matches on the spec text. Total.
pub fn import_error_phrase(err: ImportError) -> String {
  case err {
    UnknownImport(_, _) -> "unknown import"
    IncompatibleImportType(_, _, _) -> "incompatible import type"
  }
}

// ── weaving helpers (the `Provided` → `FullDecl` slot ABI for emit_core, unit 06) ──────────────
//
// `emit_core` knows STATICALLY (from the `ImportDecl` list) the kind + target slot of each
// positional `Provided`, so it calls exactly the matching extractor to pull a slot value out of an
// `Imports` element — a stable ABI decoupled from the `Provided` tuple layout. Each is fail-closed
// (a mismatched variant is an internal codegen invariant violation, unreachable — 06 pairs the
// extractor with the import kind; a `panic` is node-safe, never a WASM trap).

/// Extract a numeric global's raw bit pattern from a `ProvidedGlobal` (for a `FullDecl.globals`
/// slot). Fail-closed `panic` on any other variant (internal invariant).
pub fn provided_global_bits(p: Provided) -> Int {
  case p {
    ProvidedGlobal(value, _, _) -> value
    _ ->
      panic as "link.provided_global_bits: not a numeric global (internal invariant violation)"
  }
}

/// Extract a reference global's opaque value from a `ProvidedRefGlobal` (for a `FullDecl.ref_globals`
/// slot). Fail-closed `panic` on any other variant.
pub fn provided_ref_value(p: Provided) -> Dynamic {
  case p {
    ProvidedRefGlobal(value, _, _) -> value
    _ ->
      panic as "link.provided_ref_value: not a reference global (internal invariant violation)"
  }
}

/// Extract a table's opaque externval from a `ProvidedTable` (for a `FullDecl.tables` slot).
/// Fail-closed `panic` on any other variant.
pub fn provided_table_value(p: Provided) -> Dynamic {
  case p {
    ProvidedTable(value, _, _, _) -> value
    _ ->
      panic as "link.provided_table_value: not a table (internal invariant violation)"
  }
}

/// Extract a memory's opaque externval from a `ProvidedMemory` (for a `FullDecl.mems` slot).
/// Fail-closed `panic` on any other variant.
pub fn provided_memory_value(p: Provided) -> Dynamic {
  case p {
    ProvidedMemory(value, _, _, _) -> value
    _ ->
      panic as "link.provided_memory_value: not a memory (internal invariant violation)"
  }
}

/// Extract the dispatch closure from a `ProvidedFunc` (for an imported-function dispatch-vector
/// slot, S5/§D.2). `emit_core` (06) weaves each function-import positional `Imp<p>` through this
/// fixed `link` call (D3a — a build-controlled extractor, the slot chosen statically), then applies
/// the closure via `call_import`. Fail-closed `panic` on any other variant (an internal codegen
/// invariant — 06 pairs the extractor with the import kind; a `panic` is node-safe, never a WASM
/// trap — matching `provided_global_bits`/`provided_table_value` etc.).
pub fn provided_func_call(p: Provided) -> fn(List(Dynamic)) -> List(Dynamic) {
  case p {
    ProvidedFunc(_, call) -> call
    _ ->
      panic as "link.provided_func_call: not a function (internal invariant violation)"
  }
}

// ── internal resolution ────────────────────────────────────────────────────────────────────────

/// Walk the module's imports in declaration order, accumulating one `Provided` per STATE import
/// (reversed, restored by `list.reverse`) and skipping function imports (checked but no element).
/// Returns the first `ImportError` fail-closed.
fn resolve(
  imports: List(ir.ImportDecl),
  providers: List(Provider),
  acc: List(Provided),
) -> Result(List(Provided), ImportError) {
  case imports {
    [] -> Ok(list.reverse(acc))
    [imp, ..rest] ->
      case resolve_one(imp, providers) {
        Error(e) -> Error(e)
        Ok(None) -> resolve(rest, providers, acc)
        Ok(Some(p)) -> resolve(rest, providers, [p, ..acc])
      }
  }
}

/// Resolve ONE import: `Ok(Some(p))` for a satisfied+matched STATE import (the positional value),
/// `Ok(None)` for a checked function import (no element), or `Error` fail-closed.
fn resolve_one(
  imp: ir.ImportDecl,
  providers: List(Provider),
) -> Result(Option(Provided), ImportError) {
  case imp {
    ImportFn(capability, name, ty) ->
      resolve_fn_import(capability, name, ty, providers)
    ImportGlobal(module, name, ty, mutable) -> {
      use p <- result.try(find_provided(module, name, providers))
      case p {
        ProvidedGlobal(_, pty, pmut) | ProvidedRefGlobal(_, pty, pmut) ->
          case pty == ty && pmut == mutable {
            True -> Ok(Some(p))
            False ->
              Error(IncompatibleImportType(
                module,
                name,
                "global type/mutability",
              ))
          }
        _ -> Error(IncompatibleImportType(module, name, "expected a global"))
      }
    }
    ImportTable(module, name, ref_ty, min, max) -> {
      use p <- result.try(find_provided(module, name, providers))
      case p {
        ProvidedTable(_, pref, pmin, pmax) ->
          case pref == ref_ty && limits_match(pmin, pmax, min, max) {
            True -> Ok(Some(p))
            False ->
              Error(IncompatibleImportType(module, name, "table type/limits"))
          }
        _ -> Error(IncompatibleImportType(module, name, "expected a table"))
      }
    }
    ImportMemory(module, name, min_pages, max_pages, idx_type) -> {
      use p <- result.try(find_provided(module, name, providers))
      case p {
        ProvidedMemory(_, pmin, pmax, pidx) ->
          case
            pidx == idx_type && limits_match(pmin, pmax, min_pages, max_pages)
          {
            True -> Ok(Some(p))
            False ->
              Error(IncompatibleImportType(module, name, "memory type/limits"))
          }
        _ -> Error(IncompatibleImportType(module, name, "expected a memory"))
      }
    }
    // Phase-7 imported exception TAG (T2): its link-time identity resolution (a P5-style
    // `Provided.ProvidedTag`) is DEFERRED (§H.4) — cross-module EH linking is out of the
    // single-module Porffor scope. The keystone contributes NO positional value for it (`Ok(None)`,
    // like a checked function import). Byte-neutral (no Phase-1..6 module imports a tag); P7-05/link
    // owns the real `ProvidedTag` identity if pursued.
    ImportTag(_module, _name, _params) -> Ok(None)
  }
}

/// Resolve a FUNCTION import for the STATE `Imports` list: it is CHECKED fail-closed (existence +
/// signature) but contributes NO positional STATE element — the callable lives in the SEPARATE
/// function-import vector (`link_func_imports`), and the state list stays byte-identical (H7, see
/// the seam note). Delegates matching to the shared `resolve_func_provided` (ONE source of truth
/// for function matching) and discards the resolved callable, mapping a successful resolution to
/// `Ok(None)`. So a bogus `spectest`/registered function import still fails `assert_unlinkable`
/// exactly as in P5, and a genuine host capability (`env`) neither errors nor emits an element.
fn resolve_fn_import(
  capability: String,
  name: String,
  ty: FuncType,
  providers: List(Provider),
) -> Result(Option(Provided), ImportError) {
  case resolve_func_provided(capability, name, ty, providers) {
    Ok(_callable) -> Ok(None)
    Error(e) -> Error(e)
  }
}

/// Walk the module's imports in declaration order, accumulating one `ProvidedFunc` per FUNCTION
/// import (reversed, restored by `list.reverse`) and skipping state imports. Returns the first
/// `ImportError` fail-closed. The function-import-vector twin of `resolve` (S5).
fn resolve_funcs(
  imports: List(ir.ImportDecl),
  providers: List(Provider),
  acc: List(Provided),
) -> Result(List(Provided), ImportError) {
  case imports {
    [] -> Ok(list.reverse(acc))
    [imp, ..rest] ->
      case imp {
        ImportFn(capability, name, ty) ->
          case resolve_func_provided(capability, name, ty, providers) {
            Ok(p) -> resolve_funcs(rest, providers, [p, ..acc])
            Error(e) -> Error(e)
          }
        _ -> resolve_funcs(rest, providers, acc)
      }
  }
}

/// Resolve ONE function import to its dispatch closure (`ProvidedFunc(ty, call)`), matched
/// fail-closed (spec §3.2.7 — function types are matched by EQUALITY). The shared resolver both
/// `resolve_fn_import` (state list, discards the callable) and `resolve_funcs` (function vector,
/// keeps it) go through, so matching has ONE definition.
///
/// - `#("spectest", name)` → equality-matched against `rt_host.spectest_func_type(name)`; on a
///   match the closure wraps `rt_host.call_host` (§B.3). Missing → `UnknownImport`; mismatch →
///   `IncompatibleImportType`.
/// - `#(reg, name)`, `reg` registered → its `ProvidedFunc(sig, closure)` export; `sig == ty` →
///   that register-seam-built routing closure (§C.2). Missing → `UnknownImport`; a non-function
///   export or a signature mismatch → `IncompatibleImportType`.
/// - `#(other, name)`, unregistered → a genuine host capability (e.g. `env`): resolved to a host
///   closure wrapping `call_host` (call-site-gated, NOT link-checked — P5 posture, §B.3).
fn resolve_func_provided(
  capability: String,
  name: String,
  ty: FuncType,
  providers: List(Provider),
) -> Result(Provided, ImportError) {
  case capability {
    "spectest" ->
      case rt_host.spectest_func_type(name) {
        Ok(sig) -> match_func(capability, name, sig, ty, host_func_closure)
        Error(Nil) -> Error(UnknownImport(capability, name))
      }
    _ ->
      case is_registered(capability, providers) {
        // A genuine host capability (env, wasi, …): call-site-gated, not link-checked.
        False -> Ok(ProvidedFunc(ty, host_func_closure(capability, name)))
        True ->
          case lookup_registered(capability, name, providers) {
            Ok(ProvidedFunc(sig, closure)) ->
              case sig == ty {
                True -> Ok(ProvidedFunc(sig, closure))
                False ->
                  Error(IncompatibleImportType(
                    capability,
                    name,
                    "function signature",
                  ))
              }
            Ok(_) ->
              Error(IncompatibleImportType(
                capability,
                name,
                "expected a function",
              ))
            Error(Nil) -> Error(UnknownImport(capability, name))
          }
      }
  }
}

/// A function externtype matches iff the signatures are structurally EQUAL (spec §3.2.7 function
/// matching — functions are invariant). On a match, build the callable via `build_closure(module,
/// name)` and return `Ok(ProvidedFunc(declared, closure))`; else `IncompatibleImportType`. Used
/// for the `spectest`/host case where THIS unit builds the closure (the registered case reuses the
/// register-seam-supplied closure directly).
fn match_func(
  module: String,
  name: String,
  provided: FuncType,
  declared: FuncType,
  build_closure: fn(String, String) -> fn(List(Dynamic)) -> List(Dynamic),
) -> Result(Provided, ImportError) {
  case provided == declared {
    True -> Ok(ProvidedFunc(declared, build_closure(module, name)))
    False -> Error(IncompatibleImportType(module, name, "function signature"))
  }
}

/// Build a HOST function import's dispatch closure — the fail-closed capability boundary (§B.3) as
/// a `fn(List(Dynamic)) -> List(Dynamic)`. It marshals the argument value list to the raw
/// bit-pattern `List(Int)` `rt_host.call_host` consumes (identity coercion — a host arg is numeric,
/// D5), applies `call_host` under THIS instance's `HostPolicy` (deny-all by default; `safe_spectest`
/// admits the `spectest` prints), and packages the `List(Int)` result back as a value list.
///
/// `call_host` RAISES the catchable `{capability_denied, Cap, Name}` on a denied call, so a denied
/// host import surfaces as a trap through `call_import` exactly as before (no path around the gate).
/// D3a: `Cap`/`Name` are the build-controlled import strings captured here at link time; `call_host`
/// dispatches a build-fixed handler closure directly (rt_host §D3a), never `apply/3` on a
/// data-derived module/atom.
fn host_func_closure(
  cap: String,
  name: String,
) -> fn(List(Dynamic)) -> List(Dynamic) {
  fn(args) {
    coerce_ints_to_dynamics(rt_host.call_host(
      cap,
      name,
      coerce_args_to_ints(args),
    ))
  }
}

/// Find the `Provided` for a STATE import `#(module, name)`, or `UnknownImport` fail-closed. The
/// built-in `spectest` module is consulted directly; every other module name is looked up among
/// the `(register)`ed providers.
fn find_provided(
  module: String,
  name: String,
  providers: List(Provider),
) -> Result(Provided, ImportError) {
  let found = case module {
    "spectest" -> spectest_export(name)
    _ -> lookup_registered(module, name, providers)
  }
  case found {
    Ok(p) -> Ok(p)
    Error(Nil) -> Error(UnknownImport(module, name))
  }
}

/// The externval a registered provider `link_name` exports under `name`, or `Error(Nil)` if no
/// provider owns `link_name` or it does not export `name`.
fn lookup_registered(
  link_name: String,
  name: String,
  providers: List(Provider),
) -> Result(Provided, Nil) {
  case providers {
    [] -> Error(Nil)
    [Registered(pname, exports), ..rest] ->
      case pname == link_name {
        True -> dict.get(exports, name)
        False -> lookup_registered(link_name, name, rest)
      }
  }
}

/// `True` iff some provider is registered under link-name `link_name` (distinguishes a registered
/// module — whose missing export is `UnknownImport` — from a genuine host capability).
fn is_registered(link_name: String, providers: List(Provider)) -> Bool {
  case providers {
    [] -> False
    [Registered(pname, _), ..rest] ->
      case pname == link_name {
        True -> True
        False -> is_registered(link_name, rest)
      }
  }
}

/// Limits matching (spec §3.2.5): the PROVIDED limits `{pmin, pmax}` satisfy the DECLARED import
/// limits `{dmin, dmax}` iff the provider is at least as large (`pmin ≥ dmin`) AND, when the import
/// caps the max (`dmax = Some(dm)`), the provider is capped no larger (`pmax = Some(pm)`, `pm ≤ dm`).
/// An uncapped import (`dmax = None`) accepts any provided max; an uncapped PROVIDER under a capped
/// import does NOT match. Getting this backwards silently admits an under-sized import — hence the
/// explicit direction.
fn limits_match(
  pmin: Int,
  pmax: Option(Int),
  dmin: Int,
  dmax: Option(Int),
) -> Bool {
  case pmin >= dmin {
    False -> False
    True ->
      case dmax {
        None -> True
        Some(dm) ->
          case pmax {
            Some(pm) -> pm <= dm
            None -> False
          }
      }
  }
}
