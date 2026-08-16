//// Spec-grounded tests for `runtime/link` — the non-function-import instantiation/link contract
//// (H4, R4). Assertions target the WebAssembly SPEC (link/instantiation semantics), never
//// "whatever the code emits":
////
//// - **Fail-closed linking** — an unprovided import is `UnknownImport` and a type/limits-mismatched
////   one is `IncompatibleImportType`; the instance is never created (spec
////   [§4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation), the
////   `.wast` `assert_unlinkable` case). NO ambient default is ever fabricated (H6/D3a).
//// - **Import matching** — globals are invariant (type + mutability); table/memory limits match in
////   the load-bearing direction `p.min ≥ d.min` / `p.max ≤ d.max` (spec
////   [§3.2](https://webassembly.github.io/spec/core/valid/matching.html)).
//// - **The `Namespace` provider seam** — carder hard-codes NO host module by name. A whole link
////   namespace is supplied by the caller as `link.Namespace(name, func, state)`, two resolver
////   closures. Everything `assert_unlinkable` depends on must hold THROUGH that seam: a matched
////   function import resolves (and its closure dispatches), a mismatched signature is
////   `IncompatibleImportType`, a name the resolver rejects is `UnknownImport`, and a state export
////   resolves / mismatches / is unknown the same way. (carder used to ship a built-in `spectest`
////   provider; that module is the WebAssembly frontend's fixture and left with it to the
////   `scribbler` repo, where its reference values are asserted. What carder still owns — and what
////   these tests pin — is the GENERAL seam any such namespace is supplied through.)
//// - **Provider precedence** — a namespace SOME provider owns is link-checked fail-closed; a
////   namespace NO provider owns is a generic host capability, NOT link-checked, resolved to a
////   `call_host` closure gated at its call site by the `HostPolicy`. Getting this backwards
////   either fabricates an ambient default (an H6 violation) or breaks every host-importing module.
//// - **Positional, name-free `Imports`** — one `Provided` per STATE import in declaration order;
////   function imports contribute no element (they are call-site capabilities, H4).

import carder/ir
import carder/runtime/instance.{HostDenyAll, HostOpen}
import carder/runtime/link.{
  type ImportError, type Provided, type Provider, IncompatibleImportType,
  Namespace, ProvidedFunc, ProvidedGlobal, ProvidedMemory, ProvidedRefGlobal,
  ProvidedTable, Registered, UnknownImport,
}
import carder/runtime/rt_host
import carder/runtime/rt_mem
import carder/runtime/rt_state
import carder/runtime/rt_table
import gleam/dict
import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import simplifile

/// Run `thunk`; `Ok(v)` on a normal return, `Error(text)` on ANY raise (used to prove a
/// fail-closed `panic`). See `carder_rt_state_test_ffi` (pure Gleam cannot `catch`).
@external(erlang, "carder_rt_state_test_ffi", "catch_thunk")
fn catch_thunk(thunk: fn() -> a) -> Result(a, String)

/// Run `thunk`; `Ok(#(cap, name))` ONLY if it raises the error-class `{capability_denied, Cap,
/// Name}` (the host deny boundary), else `Error(text)`. See `carder_rt_test_ffi`.
@external(erlang, "carder_rt_test_ffi", "host_denial")
fn host_denial(thunk: fn() -> a) -> Result(#(String, String), String)

/// A minimal module whose only content is `imports` — the fixture the resolver walks (every other
/// field empty, so `link_imports` sees exactly the imports under test in declaration order).
fn module_with_imports(imports: List(ir.ImportDecl)) -> ir.Module {
  ir.Module(
    name: "carder@link@test",
    uses_numerics: False,
    memories: [],
    globals: [],
    imports: imports,
    functions: [],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    tags: [],
  )
}

/// A `link.Namespace` provider under `link_name` backed by two FIXED tables — the general seam a
/// caller supplies a whole host module through (carder itself knows no host module by name).
///
/// - `funcs`: the namespace's function exports, `name -> Provided` (each normally a
///   `ProvidedFunc(sig, closure)`; a non-function value is allowed on purpose so the
///   "imported a state export as a function" rejection can be exercised).
/// - `states`: the namespace's global/table/memory exports, `name -> Provided`.
/// - The FUNCTION resolver deliberately IGNORES the declared `FuncType` it is handed and answers
///   from `funcs` alone, so `link` performs the spec §3.2.7 EQUALITY match itself and a
///   signature mismatch is observable. (A resolver that instead echoes the declared type — the
///   escape hatch for reference-typed ABIs — matches by construction and so proves nothing here.)
/// - Any name absent from its table is `Error(Nil)`, which the resolver must turn into the spec's
///   `UnknownImport` — the `assert_unlinkable "unknown import"` case.
fn namespace(
  link_name: String,
  funcs: List(#(String, Provided)),
  states: List(#(String, Provided)),
) -> Provider {
  let func_table = dict.from_list(funcs)
  let state_table = dict.from_list(states)
  Namespace(
    link_name: link_name,
    func: fn(name, _declared_ty) { dict.get(func_table, name) },
    state: fn(name) { dict.get(state_table, name) },
  )
}

/// A do-nothing dispatch closure returning no values — a stand-in for a host namespace's handler
/// where only MATCHING (not the call) is under test.
fn no_result(_args: List(dynamic.Dynamic)) -> List(dynamic.Dynamic) {
  []
}

/// A `Namespace` under link name `"host"` exporting one of EACH import kind — a function
/// `print_i32 : [i32] -> []`, a global `g_i32 = 666`, a real `funcref` table `10..20` and a real
/// Idx32 memory `1..2`. The interleaving/ordering tests import all four from it, so the ordering
/// they assert is genuinely about DECLARATION ORDER rather than about which kinds happen to
/// resolve.
fn mixed_namespace() -> Provider {
  namespace(
    "host",
    [#("print_i32", link.provided_func(ir.FuncType([ir.TI32], []), no_result))],
    [
      #("g_i32", ProvidedGlobal(666, ir.TI32, False)),
      #(
        "memory",
        ProvidedMemory(
          rt_mem.fresh(1, Some(2), rt_mem.hard_max_pages),
          1,
          Some(2),
          ir.Idx32,
        ),
      ),
      #(
        "table",
        ProvidedTable(rt_table.new(10, Some(20)), ir.FuncRef, 10, Some(20)),
      ),
    ],
  )
}

// ── 1. Fail-closed: unsatisfied import (spec §4.5.4 "unknown import") ─────────────

/// A global imported from a module carder does NOT provide resolves to `UnknownImport`, and the
/// instance is never created (fail-closed, no ambient zero-global default). The spec phrase is
/// "unknown import".
pub fn unknown_state_import_fails_closed_test() {
  let m =
    module_with_imports([ir.ImportGlobal("no_such_module", "g", ir.TI32, False)])
  is_unknown(link.link_imports(m, []), "no_such_module", "g")
  |> should.be_true
  phrase_of(link.link_imports(m, [])) |> should.equal(Ok("unknown import"))
}

/// A FUNCTION import naming a namespace a provider DOES own, but an export that namespace does
/// NOT have (`#("host","not_a_print")` against a `Namespace` whose resolver returns `Error(Nil)`)
/// is a link error ("unknown import"), not merely a deferred call denial (§C.3). This is the
/// fail-closed half of the precedence rule: once a provider claims the namespace, an unknown name
/// inside it is rejected AT LINK TIME rather than falling through to the generic host capability.
pub fn unknown_namespace_function_fails_closed_test() {
  let provider =
    namespace(
      "host",
      [
        #(
          "print_i32",
          link.provided_func(ir.FuncType([ir.TI32], []), no_result),
        ),
      ],
      [],
    )
  let m =
    module_with_imports([
      ir.ImportFn("host", "not_a_print", ir.FuncType([], [])),
    ])
  is_unknown(link.link_imports(m, [provider]), "host", "not_a_print")
  |> should.be_true
  phrase_of(link.link_imports(m, [provider]))
  |> should.equal(Ok("unknown import"))
}

// ── 2. Fail-closed: import type-mismatch (spec §3.2 matching) + satisfying counterparts ─

/// Global matching is invariant: a global imported `const i32` but provided `mut i32` (mutability
/// mismatch) and one imported `i64` but provided `i32` (type mismatch) both fail
/// `IncompatibleImportType`; the SATISFYING counterparts admit `Ok`. (spec §3.2 global matching.)
pub fn global_mismatch_and_match_test() {
  // (a) mutability mismatch: import const, provided mut.
  let provider =
    Registered("M", dict.from_list([#("g", ProvidedGlobal(0, ir.TI32, True))]))
  let import_const =
    module_with_imports([ir.ImportGlobal("M", "g", ir.TI32, False)])
  is_incompatible(link.link_imports(import_const, [provider]), "M", "g")
  |> should.be_true
  phrase_of(link.link_imports(import_const, [provider]))
  |> should.equal(Ok("incompatible import type"))

  // The satisfying counterpart (import mut, provided mut) admits, carrying the value through.
  let import_mut =
    module_with_imports([ir.ImportGlobal("M", "g", ir.TI32, True)])
  link.link_imports(import_mut, [provider])
  |> should.equal(Ok([ProvidedGlobal(0, ir.TI32, True)]))

  // (b) type mismatch: import i64, provided i32.
  let provider_i32 =
    Registered("M", dict.from_list([#("g", ProvidedGlobal(1, ir.TI32, False))]))
  let import_i64 =
    module_with_imports([ir.ImportGlobal("M", "g", ir.TI64, False)])
  is_incompatible(link.link_imports(import_i64, [provider_i32]), "M", "g")
  |> should.be_true
}

/// Table limits match in the load-bearing direction: a table imported `min 10` but provided
/// `min 1` violates `p.min ≥ d.min` ⇒ `IncompatibleImportType`; the satisfying `min 10` provider
/// admits. (spec §3.2 table matching.)
pub fn table_limits_mismatch_and_match_test() {
  let under =
    Registered(
      "M",
      dict.from_list([#("t", ProvidedTable(dynamic.nil(), ir.FuncRef, 1, None))]),
    )
  let m = module_with_imports([ir.ImportTable("M", "t", ir.FuncRef, 10, None)])
  is_incompatible(link.link_imports(m, [under]), "M", "t") |> should.be_true

  // A provider at least as large satisfies (p.min 10 ≥ d.min 10).
  let ok =
    Registered(
      "M",
      dict.from_list([
        #("t", ProvidedTable(dynamic.nil(), ir.FuncRef, 10, None)),
      ]),
    )
  link.link_imports(m, [ok])
  |> should.equal(Ok([ProvidedTable(dynamic.nil(), ir.FuncRef, 10, None)]))
}

/// Memory limits match in the load-bearing direction: a memory imported `max 1` but provided
/// `max 2` violates `p.max ≤ d.max` ⇒ `IncompatibleImportType`; a provider capped `≤ 1` admits.
/// (spec §3.2 memory matching.)
pub fn memory_limits_mismatch_and_match_test() {
  let over =
    Registered(
      "M",
      dict.from_list([
        #("mem", ProvidedMemory(dynamic.nil(), 1, Some(2), ir.Idx32)),
      ]),
    )
  let m =
    module_with_imports([ir.ImportMemory("M", "mem", 1, Some(1), ir.Idx32)])
  is_incompatible(link.link_imports(m, [over]), "M", "mem") |> should.be_true

  // A provider capped no larger than the import satisfies (p.max 1 ≤ d.max 1).
  let ok =
    Registered(
      "M",
      dict.from_list([
        #("mem", ProvidedMemory(dynamic.nil(), 1, Some(1), ir.Idx32)),
      ]),
    )
  link.link_imports(m, [ok])
  |> should.equal(Ok([ProvidedMemory(dynamic.nil(), 1, Some(1), ir.Idx32)]))
}

/// An imported reference-typed global (externref) matches on type + mutability like a numeric one
/// — the `ref_globals` parallel path (R8). A `funcref`-vs-`externref` type mismatch fails closed.
pub fn ref_global_match_and_mismatch_test() {
  let ext = dynamic.string("some-externref")
  let provider =
    Registered(
      "M",
      dict.from_list([#("r", ProvidedRefGlobal(ext, ir.TExternRef, False))]),
    )
  // Matching externref import admits, carrying the opaque value through.
  let m = module_with_imports([ir.ImportGlobal("M", "r", ir.TExternRef, False)])
  link.link_imports(m, [provider])
  |> should.equal(Ok([ProvidedRefGlobal(ext, ir.TExternRef, False)]))

  // funcref import vs externref provider ⇒ type mismatch.
  let m2 = module_with_imports([ir.ImportGlobal("M", "r", ir.TFuncRef, False)])
  is_incompatible(link.link_imports(m2, [provider]), "M", "r") |> should.be_true
}

// ── 3. The `Namespace` provider seam — a whole host module supplied by the caller ────
//
// carder ships NO built-in host module: a namespace like the WebAssembly suite's `spectest`, a
// TeaVM guest's `teavmJso` or a Porffor guest's `""` intrinsics is handed in by the FRONTEND as
// `link.Namespace(name, func, state)`. Everything the spec's `assert_unlinkable` depends on must
// therefore hold THROUGH that seam, which is what this section pins (spec §4.5.4 instantiation,
// §3.2 matching). The concrete `spectest` reference values (`global_i32 = 666`, `table 10..20`,
// `memory 1..2`) are the WebAssembly frontend's fixture and are asserted in `scribbler`.

/// A `Namespace`'s STATE resolver satisfies global imports, positionally and in declaration order
/// — the general replacement for a built-in host module's global exports. Two immutable globals
/// resolve to exactly the values the resolver returned, in the module's import order.
pub fn namespace_state_import_resolves_test() {
  let provider =
    namespace("host", [], [
      #("g_i32", ProvidedGlobal(666, ir.TI32, False)),
      #("g_i64", ProvidedGlobal(666, ir.TI64, False)),
    ])
  let m =
    module_with_imports([
      ir.ImportGlobal("host", "g_i32", ir.TI32, False),
      ir.ImportGlobal("host", "g_i64", ir.TI64, False),
    ])
  link.link_imports(m, [provider])
  |> should.equal(
    Ok([
      ProvidedGlobal(666, ir.TI32, False),
      ProvidedGlobal(666, ir.TI64, False),
    ]),
  )
}

/// A STATE name the `Namespace`'s resolver returns `Error(Nil)` for is `UnknownImport` — the
/// provider is a CLOSED set, never an ambient default (H6). The spec phrase is "unknown import".
pub fn namespace_unknown_state_export_fails_closed_test() {
  let provider =
    namespace("host", [], [#("g", ProvidedGlobal(1, ir.TI32, False))])
  let m = module_with_imports([ir.ImportGlobal("host", "nope", ir.TI32, False)])
  is_unknown(link.link_imports(m, [provider]), "host", "nope")
  |> should.be_true
  phrase_of(link.link_imports(m, [provider]))
  |> should.equal(Ok("unknown import"))
}

/// A `Namespace`-supplied state export is TYPE-MATCHED exactly like a `Registered` one (spec §3.2
/// — the seam changes WHERE the externval comes from, never WHETHER it is checked): an `i64`
/// import answered with an `i32` global is `IncompatibleImportType`, not a silent coercion.
pub fn namespace_state_mismatch_fails_closed_test() {
  let provider =
    namespace("host", [], [#("g", ProvidedGlobal(1, ir.TI32, False))])
  let m = module_with_imports([ir.ImportGlobal("host", "g", ir.TI64, False)])
  is_incompatible(link.link_imports(m, [provider]), "host", "g")
  |> should.be_true
  phrase_of(link.link_imports(m, [provider]))
  |> should.equal(Ok("incompatible import type"))
}

/// A `Namespace` can supply REAL table/memory externvals, not just descriptors: a `funcref` table
/// declared `10..20` and an Idx32 memory declared `1..2` resolve, and once installed into a fresh
/// instance cell they behave as real state — `table.size = 10`, `memory.size = 1` page. This is
/// the property the WebAssembly suite's imported-table/imported-memory cases rest on, kept here
/// against the general seam (the specific `spectest` limits are the frontend's fixture).
pub fn namespace_provides_real_table_and_memory_test() {
  let table_value = rt_table.new(10, Some(20))
  let mem_value = rt_mem.fresh(1, Some(2), rt_mem.hard_max_pages)
  let provider =
    namespace("host", [], [
      #("table", ProvidedTable(table_value, ir.FuncRef, 10, Some(20))),
      #("memory", ProvidedMemory(mem_value, 1, Some(2), ir.Idx32)),
    ])
  let m =
    module_with_imports([
      ir.ImportTable("host", "table", ir.FuncRef, 10, Some(20)),
      ir.ImportMemory("host", "memory", 1, Some(2), ir.Idx32),
    ])
  let assert Ok([
    ProvidedTable(t, ref_ty, tmin, tmax),
    ProvidedMemory(mem, mmin, mmax, idx),
  ]) = link.link_imports(m, [provider])
  ref_ty |> should.equal(ir.FuncRef)
  tmin |> should.equal(10)
  tmax |> should.equal(Some(20))
  mmin |> should.equal(1)
  mmax |> should.equal(Some(2))
  idx |> should.equal(ir.Idx32)

  // Install both provided externvals into a fresh cell and probe them through the runtime.
  rt_state.seed_full(
    rt_state.FullDecl(mems: [mem], globals: [], tables: [t], ref_globals: []),
  )
  rt_table.size(0) |> should.equal(10)
  rt_mem.size_at(0) |> should.equal(1)
}

// ── 4. Function-import checking (spec §3.2 function matching, §C.3) ───────────────

/// A `Namespace`-provided FUNCTION import that EXISTS and whose signature MATCHES resolves `Ok`
/// and contributes NO positional state element (a function is a call-site capability, H4). A
/// SIGNATURE MISMATCH (right name, wrong type) fails `IncompatibleImportType` — the spec matches
/// function types by EQUALITY (§3.2.7), so a namespace resolver cannot widen or narrow one.
pub fn namespace_function_import_matching_test() {
  let provider =
    namespace(
      "host",
      [
        #(
          "print_i32",
          link.provided_func(ir.FuncType([ir.TI32], []), no_result),
        ),
      ],
      [],
    )

  // [i32] -> []  — exists and matches ⇒ Ok, no state element.
  let ok =
    module_with_imports([
      ir.ImportFn("host", "print_i32", ir.FuncType([ir.TI32], [])),
    ])
  link.link_imports(ok, [provider]) |> should.equal(Ok([]))

  // Right name, wrong signature ⇒ incompatible import type.
  let bad =
    module_with_imports([
      ir.ImportFn("host", "print_i32", ir.FuncType([ir.TI64], [])),
    ])
  is_incompatible(link.link_imports(bad, [provider]), "host", "print_i32")
  |> should.be_true
  phrase_of(link.link_imports(bad, [provider]))
  |> should.equal(Ok("incompatible import type"))
}

/// PRECEDENCE (the rule `assert_unlinkable` rests on). A function import whose namespace NO
/// provider owns (`env` here, while a provider owns `host`) is a GENERIC HOST CAPABILITY: it is
/// NOT link-checked — no name lookup, no signature match — so it neither errors nor contributes
/// an element (`Ok([])`), and its fate is decided at its CALL SITE by the instance's `HostPolicy`
/// (fail-closed deny by default). This is why an `env`-importing corpus module keeps
/// instantiating. The complement is `unknown_namespace_function_fails_closed_test`: the moment a
/// provider DOES claim the namespace, the same shape of import is rejected at link time. Which
/// side an import falls on is decided ONLY by whether a provider owns its link name.
pub fn unowned_namespace_function_import_falls_through_to_host_test() {
  let owner =
    namespace(
      "host",
      [
        #(
          "print_i32",
          link.provided_func(ir.FuncType([ir.TI32], []), no_result),
        ),
      ],
      [],
    )
  let m =
    module_with_imports([
      ir.ImportFn("env", "anything", ir.FuncType([ir.TI32], [ir.TI32])),
    ])
  // No providers at all, and with an unrelated namespace provider present: both fall through.
  link.link_imports(m, []) |> should.equal(Ok([]))
  link.link_imports(m, [owner]) |> should.equal(Ok([]))

  // A name that WOULD be unknown inside the owned namespace still falls through under `env` —
  // the fall-through is about namespace OWNERSHIP, not about the name existing anywhere.
  let m2 =
    module_with_imports([ir.ImportFn("env", "not_a_print", ir.FuncType([], []))])
  link.link_imports(m2, [owner]) |> should.equal(Ok([]))
}

// ── 5. (register) → import + positional, name-free ordering ──────────────────────

/// `(register "M" A)` then a later module importing `#("M","g")` reads the externval captured at
/// register time (snapshot semantics) — a registered global `g = 7` resolves to
/// `ProvidedGlobal(7, …)` (spec `assert_return (get "M" "g")` reads `7`).
pub fn registered_import_resolves_test() {
  let provider =
    Registered("M", dict.from_list([#("g", ProvidedGlobal(7, ir.TI32, False))]))
  let m = module_with_imports([ir.ImportGlobal("M", "g", ir.TI32, False)])
  link.link_imports(m, [provider])
  |> should.equal(Ok([ProvidedGlobal(7, ir.TI32, False)]))
}

/// The returned `Imports` is POSITIONAL and NAME-FREE: one `Provided` per STATE import in
/// declaration order, function imports contributing NO element. An interleaved
/// (fn, global, memory, fn, table) import list yields exactly [global, memory, table].
pub fn imports_are_positional_state_only_test() {
  let provider = mixed_namespace()
  let m =
    module_with_imports([
      ir.ImportFn("env", "f1", ir.FuncType([], [])),
      ir.ImportGlobal("host", "g_i32", ir.TI32, False),
      ir.ImportMemory("host", "memory", 1, Some(2), ir.Idx32),
      ir.ImportFn("host", "print_i32", ir.FuncType([ir.TI32], [])),
      ir.ImportTable("host", "table", ir.FuncRef, 10, Some(20)),
    ])
  // Exactly the three STATE imports, in order (both function imports skipped — the unowned `env`
  // host capability AND the namespace-provided one).
  kind_tags(link.link_imports(m, [provider]))
  |> should.equal(Ok(["global", "memory", "table"]))
  // The leading global carries the provider's value through unchanged.
  case link.link_imports(m, [provider]) {
    Ok([ProvidedGlobal(bits, ..), ..]) -> bits
    _ -> -1
  }
  |> should.equal(666)
}

// ── 6. The weaving extractors (the `Provided` → `FullDecl` slot ABI for emit_core) ─

/// The extractors pull the right slot value out of a `Provided` (the ABI unit 06 weaves with):
/// numeric-global bits, reference value, and the opaque table/memory externvals round-trip.
pub fn weaving_extractors_round_trip_test() {
  link.provided_global_bits(ProvidedGlobal(0x7FC00001, ir.TF32, False))
  |> should.equal(0x7FC00001)

  let ext = dynamic.string("ext")
  link.provided_ref_value(ProvidedRefGlobal(ext, ir.TExternRef, False))
  |> should.equal(ext)

  let tbl = dynamic.string("tbl")
  link.provided_table_value(ProvidedTable(tbl, ir.FuncRef, 0, None))
  |> should.equal(tbl)

  let mem = dynamic.string("mem")
  link.provided_memory_value(ProvidedMemory(mem, 1, None, ir.Idx32))
  |> should.equal(mem)
}

// ── helpers ──────────────────────────────────────────────────────────────────────

/// `True` iff `r` is `Error(UnknownImport(module, name))`.
fn is_unknown(
  r: Result(List(Provided), ImportError),
  module: String,
  name: String,
) -> Bool {
  case r {
    Error(UnknownImport(m, n)) -> m == module && n == name
    _ -> False
  }
}

/// `True` iff `r` is `Error(IncompatibleImportType(module, name, _))` (the detail text is not
/// pinned — spec behaviour is the variant, not the diagnostic string).
fn is_incompatible(
  r: Result(List(Provided), ImportError),
  module: String,
  name: String,
) -> Bool {
  case r {
    Error(IncompatibleImportType(m, n, _)) -> m == module && n == name
    _ -> False
  }
}

/// Map a resolution result to the ordered list of provided KIND tags (or `Error(Nil)` on a link
/// failure) — asserts positional ordering + kind without pinning opaque values.
fn kind_tags(
  r: Result(List(Provided), ImportError),
) -> Result(List(String), Nil) {
  case r {
    Ok(ps) -> Ok(list.map(ps, kind_tag))
    Error(_) -> Error(Nil)
  }
}

fn kind_tag(p: Provided) -> String {
  case p {
    ProvidedGlobal(..) -> "global"
    ProvidedRefGlobal(..) -> "ref_global"
    ProvidedTable(..) -> "table"
    ProvidedMemory(..) -> "memory"
    ProvidedFunc(..) -> "func"
  }
}

/// Map a `link_imports` result to `Ok(spec-phrase)` on failure (`Error(Nil)` on success), so a
/// test can assert the exact `assert_unlinkable` phrase.
fn phrase_of(r: Result(List(Provided), ImportError)) -> Result(String, Nil) {
  case r {
    Ok(_) -> Error(Nil)
    Error(e) -> Ok(link.import_error_phrase(e))
  }
}

// ── 7. The imported-function CALL seam + the function-import vector (S5/«XLINK», P6-09) ─────────
//
// The linker MACHINERY proven in ISOLATION (the full WASM→WASM e2e run is P6-06/P6-10's, once
// emit_core seeds the dispatch vector + emits `call_import` for a `CallImport` node). Spec cites:
// §4.5.4 instantiation (func external value), §3.2.7 function matching (equality), §4.4.7 traps.

/// `call_import` dispatches the HANDED-IN closure capability — never a name (D3a). Applying it to
/// two different closures yields each closure's own result (so the target is the supplied `fun`,
/// not an ambient lookup), and the argument list reaches the closure as a SINGLE 1-ary application
/// (no `apply/2` spread — S5's arity fix): a 2-element arg list arrives intact.
pub fn call_import_dispatches_the_handed_in_capability_test() {
  let a = fn(_args) { [dynamic.int(1)] }
  let b = fn(_args) { [dynamic.int(2)] }
  link.call_import(a, []) |> should.equal([dynamic.int(1)])
  link.call_import(b, []) |> should.equal([dynamic.int(2)])

  // The whole arg list is handed to the 1-ary closure intact (not spread into parameters).
  let passthrough = fn(args) { args }
  link.call_import(passthrough, [dynamic.int(7), dynamic.int(8)])
  |> should.equal([dynamic.int(7), dynamic.int(8)])
}

/// `provided_func` builds a `ProvidedFunc(ty, call)` and `provided_func_call` extracts the closure
/// back out (the emit-side ABI, §D.2); the closure round-trips through `call_import`. The carried
/// `ty` is the export signature (drives matching); the closure is applied, never `==`'d.
pub fn provided_func_round_trips_test() {
  let ty = ir.FuncType([], [ir.TI32])
  let pf = link.provided_func(ty, fn(_args) { [dynamic.int(42)] })
  // `ty` is carried verbatim (matching reads it).
  let assert ProvidedFunc(carried, _) = pf
  carried |> should.equal(ty)
  // The closure round-trips out and dispatches.
  link.call_import(link.provided_func_call(pf), [])
  |> should.equal([dynamic.int(42)])
}

/// `provided_func_call` fails CLOSED (`panic`, node-safe) on a non-function `Provided` — an
/// internal codegen invariant, mirroring `provided_global_bits` etc. (never a WASM trap).
pub fn provided_func_call_panics_on_non_function_test() {
  catch_thunk(fn() {
    let _ = link.provided_func_call(ProvidedGlobal(0, ir.TI32, False))
    Nil
  })
  |> result.is_error
  |> should.be_true
}

/// The registry resolves a `(register)`ed module's FUNCTION export to its dispatch closure
/// (spec §4.5.4 func external value): a provider carrying `ProvidedFunc(sig, closure)` under an
/// export name is matched (sig equality) and returned as the importer's function-import-vector
/// slot; the closure (here a stand-in for the cross-module routing closure §C.2) dispatches
/// through `call_import`.
pub fn link_func_imports_resolves_registered_function_test() {
  let sig = ir.FuncType([], [ir.TI32])
  // A stand-in for the register-seam-built routing closure (P6-10 captures the live handle).
  let route = fn(_args) { [dynamic.int(42)] }
  let provider =
    Registered("A", dict.from_list([#("call", link.provided_func(sig, route))]))
  let m = module_with_imports([ir.ImportFn("A", "call", sig)])

  let assert Ok([pf]) = link.link_func_imports(m, [provider])
  // The resolved slot is exactly the registered function's callable.
  link.call_import(link.provided_func_call(pf), [])
  |> should.equal([dynamic.int(42)])
}

/// `link_func_imports` fails CLOSED (spec §3.2.7 / §4.5.4, the `assert_unlinkable` path) on every
/// unsatisfied or mismatched function import: a missing registered export, a signature mismatch, a
/// registered NON-function export, a missing `Namespace` function, and a `Namespace` signature
/// mismatch — each a link error, no instance created. The satisfying counterparts link `Ok`.
/// The `Namespace` arms matter because that seam is how EVERY host module now reaches the linker
/// (carder ships none by name), so `assert_unlinkable` depends on it rejecting exactly here.
pub fn link_func_imports_fail_closed_test() {
  let sig = ir.FuncType([], [ir.TI32])
  let provider =
    Registered(
      "A",
      dict.from_list([#("call", link.provided_func(sig, fn(_a) { [] }))]),
    )
  let host =
    namespace(
      "host",
      [
        #(
          "print_i32",
          link.provided_func(ir.FuncType([ir.TI32], []), no_result),
        ),
      ],
      [],
    )

  // (a) missing registered export → unknown import.
  let missing = module_with_imports([ir.ImportFn("A", "nope", sig)])
  is_unknown(link.link_func_imports(missing, [provider]), "A", "nope")
  |> should.be_true

  // (b) signature mismatch (import [i32]->[] vs provider []->[i32]) → incompatible import type.
  let wrong_sig =
    module_with_imports([ir.ImportFn("A", "call", ir.FuncType([ir.TI32], []))])
  is_incompatible(link.link_func_imports(wrong_sig, [provider]), "A", "call")
  |> should.be_true

  // (c) a registered NON-function export imported as a function → incompatible import type.
  let state_provider =
    Registered("B", dict.from_list([#("g", ProvidedGlobal(0, ir.TI32, False))]))
  let as_func = module_with_imports([ir.ImportFn("B", "g", sig)])
  is_incompatible(link.link_func_imports(as_func, [state_provider]), "B", "g")
  |> should.be_true

  // (d) a name the owning `Namespace`'s resolver rejects → unknown import.
  let bad_namespace =
    module_with_imports([ir.ImportFn("host", "not_a_print", sig)])
  is_unknown(
    link.link_func_imports(bad_namespace, [host]),
    "host",
    "not_a_print",
  )
  |> should.be_true

  // (e) a `Namespace` function with the wrong signature → incompatible import type.
  let namespace_mismatch =
    module_with_imports([
      ir.ImportFn("host", "print_i32", ir.FuncType([ir.TI64], [])),
    ])
  is_incompatible(
    link.link_func_imports(namespace_mismatch, [host]),
    "host",
    "print_i32",
  )
  |> should.be_true

  // The satisfying registered + namespace counterparts link Ok (one slot each).
  let ok_reg = module_with_imports([ir.ImportFn("A", "call", sig)])
  let assert Ok([_]) = link.link_func_imports(ok_reg, [provider])
  let ok_namespace =
    module_with_imports([
      ir.ImportFn("host", "print_i32", ir.FuncType([ir.TI32], [])),
    ])
  let assert Ok([_]) = link.link_func_imports(ok_namespace, [host])
  Nil
}

/// The `Namespace` seam yields a CALLABLE, not merely a match: the resolver's own closure is what
/// lands in the function-import vector and what `call_import` dispatches (spec §4.5.4 func
/// external value). Proves the seam carries authority through, the same way a `Registered`
/// module's routing closure does — with NO `HostPolicy` involvement, because a provided namespace
/// is a linked capability, not a generic host call.
pub fn link_func_imports_dispatches_namespace_closure_test() {
  let ty = ir.FuncType([ir.TI32], [ir.TI32])
  let echo_twice = fn(args) {
    case args {
      [a] -> [a, a]
      _ -> []
    }
  }
  let host =
    namespace("host", [#("dup", link.provided_func(ty, echo_twice))], [])
  let m = module_with_imports([ir.ImportFn("host", "dup", ty)])

  let assert Ok([pf]) = link.link_func_imports(m, [host])
  link.call_import(link.provided_func_call(pf), [dynamic.int(5)])
  |> should.equal([dynamic.int(5), dynamic.int(5)])
}

/// An UNOWNED-namespace function import's dispatch closure routes through `rt_host.call_host`
/// under THIS instance's `HostPolicy` (§B.3): admitted (here `HostOpen`), `env.identity :
/// [i32] -> [i32]` echoes its argument. Proves the host-closure construction + the value-list ABI
/// on the fall-through side of the precedence rule.
pub fn link_func_imports_host_closure_dispatches_test() {
  rt_host.seed_policy(HostOpen)

  // env.identity : [i32] -> [i32]  → echoes its argument (the representative host handler).
  let id_mod =
    module_with_imports([
      ir.ImportFn("env", "identity", ir.FuncType([ir.TI32], [ir.TI32])),
    ])
  let assert Ok([id_pf]) = link.link_func_imports(id_mod, [])
  link.call_import(link.provided_func_call(id_pf), [dynamic.int(9)])
  |> should.equal([dynamic.int(9)])
}

/// The host-closure capability boundary is preserved: under deny-all (the fail-closed default,
/// D4) the SAME `env.identity` closure DENIES — applying it raises the catchable
/// `{capability_denied, "env", "identity"}` (surfaced as a trap through `call_import`, no path
/// around the gate — §B.3). Proves cross-module linking does not widen the host boundary.
pub fn link_func_imports_host_closure_denied_under_deny_all_test() {
  rt_host.seed_policy(HostDenyAll)
  let m =
    module_with_imports([
      ir.ImportFn("env", "identity", ir.FuncType([ir.TI32], [ir.TI32])),
    ])
  let assert Ok([pf]) = link.link_func_imports(m, [])
  let closure = link.provided_func_call(pf)
  host_denial(fn() { link.call_import(closure, [dynamic.int(1)]) })
  |> should.equal(Ok(#("env", "identity")))
}

/// The function-import vector is POSITIONAL in FUNCTION-import declaration order (spec §2.5.1),
/// STATE imports contributing no element (they are the SEPARATE `link_imports` list). An
/// interleaved (fn, global, memory, fn, table) import list yields exactly the two function slots.
pub fn link_func_imports_positional_order_test() {
  rt_host.seed_policy(HostOpen)
  let provider = mixed_namespace()
  let m =
    module_with_imports([
      ir.ImportFn("env", "f1", ir.FuncType([], [])),
      ir.ImportGlobal("host", "g_i32", ir.TI32, False),
      ir.ImportMemory("host", "memory", 1, Some(2), ir.Idx32),
      ir.ImportFn("host", "print_i32", ir.FuncType([ir.TI32], [])),
      ir.ImportTable("host", "table", ir.FuncRef, 10, Some(20)),
    ])
  // Exactly the two FUNCTION imports, in order; the three state imports are absent here. Both
  // resolution routes appear — the unowned `env` host closure and the `Namespace`-provided one —
  // and each occupies exactly one slot, in declaration order.
  kind_tags(link.link_func_imports(m, [provider]))
  |> should.equal(Ok(["func", "func"]))

  // And `link_imports` (the STATE list) is UNCHANGED — byte-identical, state-only (H7).
  kind_tags(link.link_imports(m, [provider]))
  |> should.equal(Ok(["global", "memory", "table"]))
}

/// D3a source guard: `link.gleam`'s dispatch is a handed-in capability, never an ambient
/// `apply(Module, Atom, …)`. The only `@external` is `gleam_stdlib:identity` (numeric coercion);
/// there is NO `erlang:apply` BIF external anywhere. Structural belt to the `call_import` proof.
pub fn link_dispatch_is_capability_not_ambient_apply_test() {
  let assert Ok(src) = simplifile.read("src/carder/runtime/link.gleam")
  // No `@external(erlang, "erlang", "apply")` (nor any erlang:apply BIF binding).
  should.be_false(string.contains(src, "\"erlang\", \"apply\""))
  // The coercion external IS present (identity — not a dispatch primitive).
  should.be_true(string.contains(src, "\"gleam_stdlib\", \"identity\""))
}
