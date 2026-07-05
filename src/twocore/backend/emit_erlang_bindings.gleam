//// The **Erlang bindings emitter** (Phase-12, P12-03).
////
//// Renders the language-neutral `Iface` (P12-01, `«IFACE-DESC-FROZEN»`) into a single,
//// hand-written-quality `.erl` source file that gives a typed, idiomatic Erlang API to
//// instantiate a compiled WASM `.beam` and call each of its exports. Values follow the WASM
//// value-ABI (P2) — integers presented SIGNED, floats as a `{finite, float()} | {nonfinite,
//// binary()}` tagged tuple (so NaN/±Inf survive — R18), v128 as a 16-byte binary, refs opaque —
//// and a WASM trap becomes `{error, {wasm_trap, atom()}}`.
////
//// ## The key differentiator vs the Gleam emitter (P12-02)
////
//// Erlang catches a BEAM exception IN-LANGUAGE (`try … catch error:{wasm_trap, _} -> …`), so the
//// trap→`{error, _}` mapping is done inside the generated `.erl` — **no companion catch shim**.
//// `emit_erlang` therefore returns a **single-element** `List(GeneratedFile)` (the `List` return is
//// the uniform emitter signature, not a plurality this emitter uses). The trap match is STRUCTURAL
//// on `error:{wasm_trap, _}` (R7), never a bare catch-all — so an arity/`undef` emitter bug crashes
//// loudly instead of masquerading as a fake trap, and a WASM `throw`/`exnref` (a distinct term
//// class, R24) escapes rather than being mis-surfaced.
////
//// ## The two-shape host API (R19)
////
//// The emitted `.beam` ABI is uniformly `n+1` under the accepted (Threaded) build — every export
//// takes a leading `InstanceState` and returns `{ResultPackage, St'}` (R2/R19), whether or not it
//// touches state — so the binding always threads `St` INTERNALLY. The two shapes govern only the
//// host surface:
////
//// - **`StateModel = Stateless`** (no export threads state): the beautiful pure file — NO
////   `instance()`/`instantiate/0` in the surface; each export is `f(Args…) -> {ok, T} |
////   {error, trap()}`, re-instantiating internally per call (both the `instantiate/0` and the export
////   call sit inside the trap-catch, so a trapping start / OOB active segment becomes `{error, _}`,
////   R5).
//// - **`StateModel = Threaded`** (≥1 export threads state): `instantiate/0` returns
////   `{ok, instance()} | {error, trap()}` (R5); every export takes `Inst`; a `touches_state` export
////   returns `{ok, {T, instance()}} | {error, trap()}` (thread the new instance out — a 0-result
////   mutator is simply `{ok, instance()}`), the rest return `{ok, T} | {error, trap()}` (take `Inst`,
////   discard the unchanged `St'`).
////
//// ## The value ABI it renders (P2 + R9/R18, from `iface.value_abi`)
////
//// The frozen boundary conversions are emitted as private helpers, only when some export references
//// them, in the fixed order `enc_i32, enc_i64, enc_f32, enc_f64, dec_i32, dec_i64, dec_f32, dec_f64`
//// (an unused private function is an `erlc` warning; determinism per R25a):
////
//// | `ir.ValType` | arg encode (native→raw) | result decode (raw→native) | `-spec` type |
//// |---|---|---|---|
//// | `TI32` | `enc_i32/1` (`band 16#FFFFFFFF`) | `dec_i32/1` (subtract 2^32 when ≥ 2^31) | `integer()` |
//// | `TI64` | `enc_i64/1` (`band 16#…FFFF`) | `dec_i64/1` (subtract 2^64 when ≥ 2^63) | `integer()` |
//// | `TF32` | `enc_f32/1` (single-rounds) | `dec_f32/1` (guarded — R18) | `floatval()` |
//// | `TF64` | `enc_f64/1` | `dec_f64/1` (guarded — R18) | `floatval()` |
//// | `TV128` | identity | identity | `binary()` (16 B) |
//// | refs / term | identity | identity | `term()` |
////
//// The float codec is big-endian (`<<_:64>>` / `<<_:64/float>>` defaults) — the canonical IEEE-754
//// bit-pattern integer the runtime uses (`1.0` f64 ⇄ `16#3FF0000000000000`); encode/decode are
//// symmetric, and these `enc_f*`/`dec_f*` ARE the bidirectional bit accessors (R18): the finite
//// path is a native `float()`, the non-finite path (guarded on the all-ones exponent) carries the
//// raw IEEE bytes so NaN/±Inf are never lost or crash. The `dec_f*` guard lives in the `try … of`
//// clause, OUTSIDE the trap-catch (R7), so a valid non-finite result is never mistaken for a trap.

import gleam/int
import gleam/list
import gleam/string
import twocore/backend/iface.{
  type ExportSig, type GeneratedFile, type Iface, type StateModel, FloatAbi,
  GeneratedFile, IntAbi, RefAbi, ResultBare, ResultTuple, ResultUnit, Stateless,
  Threaded, V128Abi,
}
import twocore/ir

/// Render an `Iface` into the Erlang binding (the frozen `Emitter` signature).
///
/// - `desc`: a VALID descriptor (`iface.describe/2` has already fail-closed on Cell /
///   import-bearing / mutable-tier builds — `emit_erlang` does not re-validate).
///
/// Returns exactly ONE `GeneratedFile` (deterministic — the same `Iface` yields byte-identical
/// content, R25a): `#(<base>_bindings.erl, …)`, an `-module(<base>_bindings)` carrying `-spec` +
/// edoc `-doc` on every function. `<base>` is `iface.module_name` legalized to an Erlang-atom
/// identifier (`twocore@wasm@x` → `twocore_wasm_x`); the phase keeps binding-module naming uniform
/// across languages (NOT language-tagged), so this shares a BEAM atom with the Gleam binding's
/// compiled module — a known collision the capstone (P12-06) resolves by `code:purge`/`code:delete`
/// between per-language runs (R16). Never fails: every `Iface` the descriptor produces is
/// renderable.
pub fn emit_erlang(desc: Iface) -> List(GeneratedFile) {
  let binding = iface.sanitize_identifier(desc.module_name) <> "_bindings"
  [
    GeneratedFile(
      path: binding <> ".erl",
      content: render_module(desc, binding),
    ),
  ]
}

// ───────────────────────────── feature detection ─────────────────────────────

/// The set of value-shapes present across a descriptor's exports — used to emit ONLY the helpers
/// and types a given module actually references (an unused private function / unused type is an
/// `erlc` warning; determinism per R25a). `enc_*` is referenced iff some export PARAM has that
/// type; `dec_*` iff some export RESULT has it; `has_float` iff either side has any float.
type Features {
  Features(
    threaded: Bool,
    enc_i32: Bool,
    enc_i64: Bool,
    enc_f32: Bool,
    enc_f64: Bool,
    dec_i32: Bool,
    dec_i64: Bool,
    dec_f32: Bool,
    dec_f64: Bool,
    has_float: Bool,
  )
}

/// Compute the `Features` of `desc` by scanning every export's params (native→raw referenced) and
/// results (raw→native referenced).
fn detect_features(desc: Iface) -> Features {
  let params = list.flat_map(desc.exports, fn(e) { e.params })
  let results = list.flat_map(desc.exports, fn(e) { e.results })
  let any_param = fn(abi) {
    list.any(params, fn(vt) { iface.value_abi(vt) == abi })
  }
  let any_result = fn(abi) {
    list.any(results, fn(vt) { iface.value_abi(vt) == abi })
  }
  let has_float =
    any_param(FloatAbi(32))
    || any_param(FloatAbi(64))
    || any_result(FloatAbi(32))
    || any_result(FloatAbi(64))
  Features(
    threaded: desc.state_model == Threaded,
    enc_i32: any_param(IntAbi(32)),
    enc_i64: any_param(IntAbi(64)),
    enc_f32: any_param(FloatAbi(32)),
    enc_f64: any_param(FloatAbi(64)),
    dec_i32: any_result(IntAbi(32)),
    dec_i64: any_result(IntAbi(64)),
    dec_f32: any_result(FloatAbi(32)),
    dec_f64: any_result(FloatAbi(64)),
    has_float: has_float,
  )
}

// ───────────────────────────── module assembly ─────────────────────────────

/// Render the full `.erl` for `desc` under module atom `binding`. Sections are emitted as blocks
/// (a `List(String)` each, no surrounding blanks), joined by a single blank line, in a fixed order:
/// `-module`/`-moduledoc`, the export/export_type attributes, the type decls, `instantiate/0` (only
/// under Threaded), one clause per export in `iface.exports` order, then the referenced helpers.
fn render_module(desc: Iface, binding: String) -> String {
  let f = detect_features(desc)
  let blocks =
    list.flatten([
      [module_header_block(desc, binding)],
      [export_attrs_block(desc, f)],
      [type_decls_block(f)],
      instantiate_block(desc),
      list.map(desc.exports, fn(e) { render_export(desc, e, f) }),
      helper_blocks(f),
    ])
  blocks
  |> list.filter(fn(b) { b != [] })
  |> list.map(fn(b) { string.join(b, "\n") })
  |> string.join("\n\n")
  |> ensure_trailing_newline
}

/// The `-module` + `-moduledoc` header block. `-moduledoc` is one attribute spanning several
/// physical lines via adjacent-string-literal concatenation (Erlang joins them at parse time).
fn module_header_block(desc: Iface, binding: String) -> List(String) {
  [
    "-module(" <> binding <> ").",
    "-moduledoc \"Typed Erlang bindings for the compiled WASM module `"
      <> desc.module_name
      <> "`.\\n\"",
    "           \"Generated by 2core (Phase 12) - do not edit. Values follow the WASM value-ABI\\n\"",
    "           \"(P2): integers are presented SIGNED, floats as a `{finite, float()} |\\n\"",
    "           \"{nonfinite, binary()}` tagged tuple (so NaN/Inf survive), v128 as a 16-byte\\n\"",
    "           \"binary, refs opaque. A WASM trap becomes `{error, {wasm_trap, atom()}}`.\".",
  ]
}

/// The `-export` (with a leading `instantiate/0` under Threaded) + `-export_type` attributes.
fn export_attrs_block(desc: Iface, f: Features) -> List(String) {
  let inst = case desc.state_model {
    Threaded -> ["instantiate/0"]
    Stateless -> []
  }
  let export_entries =
    list.map(desc.exports, fn(e) {
      e.host_name <> "/" <> int.to_string(host_arity(e, desc.state_model))
    })
  let types =
    list.flatten([
      case f.threaded {
        True -> ["instance/0"]
        False -> []
      },
      ["trap/0"],
      case f.has_float {
        True -> ["floatval/0"]
        False -> []
      },
    ])
  [
    "-export([" <> comma(list.append(inst, export_entries)) <> "]).",
    "-export_type([" <> comma(types) <> "]).",
  ]
}

/// The `%%`-documented type declarations: `instance()` (opaque, Threaded only), `trap()` (always),
/// and `floatval()` (only when floats are present). All are `-export_type`'d, so none can be
/// flagged unused.
fn type_decls_block(f: Features) -> List(String) {
  let instance = case f.threaded {
    True -> [
      "%% Opaque handle to a live instance: the module's `InstanceState` record, threaded as a",
      "%% pure value (no process is spawned).",
      "-opaque instance() :: tuple().",
    ]
    False -> []
  }
  let trap = [
    "%% A WASM trap, surfaced as the raw error-class term so the caller can match the kind atom.",
    "-type trap() :: {wasm_trap, atom()}.",
  ]
  let floatval = case f.has_float {
    True -> [
      "%% A WASM float argument/result (R18). Finite values are a native `float()`; a non-finite",
      "%% value (NaN/Inf), which a `float()` cannot hold, is carried as its raw IEEE-754 bytes.",
      "-type floatval() :: {finite, float()} | {nonfinite, binary()}.",
    ]
    False -> []
  }
  list.flatten([instance, trap, floatval])
}

/// The `instantiate/0` clause block — Threaded only (a Stateless surface has no `instance()`). The
/// remote `instantiate/0` returns the raw `InstanceState` record; a trapping start / OOB active
/// segment raises, caught structurally to `{error, trap()}` (R5).
fn instantiate_block(desc: Iface) -> List(List(String)) {
  case desc.state_model {
    Stateless -> []
    Threaded -> {
      let m = quote_atom(desc.module_name)
      [
        [
          "-doc \"Instantiate `"
            <> desc.module_name
            <> "`: build a fresh instance (memory / globals / table). A trapping start or "
            <> "out-of-bounds active segment becomes `{error, trap()}`.\".",
          "-spec instantiate() -> {ok, instance()} | {error, trap()}.",
          "instantiate() ->",
          "    try " <> m <> ":instantiate() of",
          "        St -> {ok, St}",
          "    catch",
          "        error:{wasm_trap, _} = Trap -> {error, Trap}",
          "    end.",
        ],
      ]
    }
  }
}

// ───────────────────────────── per-export renderer ─────────────────────────────

/// Render one export as a block: its `-doc` + `-spec` + function clause (§3 algorithm). Under
/// Threaded the head takes a leading `Inst`; under Stateless the clause re-instantiates internally.
/// Argument encodes are bound with `=` BEFORE the `try`, and the result decode lives in the
/// `try … of` clause (which Erlang runs OUTSIDE the catch), so only the `.beam` call is
/// trap-protected (R7).
fn render_export(desc: Iface, e: ExportSig, f: Features) -> List(String) {
  let threaded = f.threaded
  let touches = threaded && e.touches_state
  let host = e.host_name
  let m = quote_atom(desc.module_name)
  let target = m <> ":" <> quote_atom(e.dispatch_atom)

  // Head params A0, A1, … (prefixed with `Inst` under Threaded).
  let host_params = list.index_map(e.params, fn(_vt, i) { arg_var(i) })
  let head_params = case threaded {
    True -> ["Inst", ..host_params]
    False -> host_params
  }
  let head = host <> "(" <> comma(head_params) <> ") ->"

  // Argument encodes bound before the try; each yields a call argument.
  let encoded = list.index_map(e.params, fn(vt, i) { arg_encode(vt, i) })
  let enc_lines =
    list.filter_map(encoded, fn(p) {
      case p.0 {
        "" -> Error(Nil)
        line -> Ok(line)
      }
    })
  let call_args = list.map(encoded, fn(p) { p.1 })

  // The trap-protected call. Threaded threads the caller's `Inst`; Stateless re-instantiates.
  let try_block = case threaded {
    True -> [
      "    try " <> target <> "(" <> comma(["Inst", ..call_args]) <> ") of",
    ]
    False -> [
      "    try",
      "        St = " <> m <> ":instantiate(),",
      "        " <> target <> "(" <> comma(["St", ..call_args]) <> ")",
      "    of",
    ]
  }

  let of_clause = "        " <> result_of_clause(e, touches)
  let catch_block = [
    "    catch",
    "        error:{wasm_trap, _} = Trap -> {error, Trap}",
    "    end.",
  ]

  list.flatten([
    [export_doc(e)],
    [export_spec(e, desc.state_model)],
    [head],
    enc_lines,
    try_block,
    [of_clause],
    catch_block,
  ])
}

/// The single-line edoc `-doc` for an export: the WASM signature and the preserved original export
/// name (with the host function name when they differ, since `dispatch_atom` may be un-Erlang-like).
fn export_doc(e: ExportSig) -> String {
  let renamed = case e.host_name == e.dispatch_atom {
    True -> ""
    False -> " (host function `" <> e.host_name <> "`)"
  }
  "-doc \"WASM export `"
  <> erl_string_escape(e.dispatch_atom)
  <> "`"
  <> renamed
  <> " : "
  <> wasm_sig(e)
  <> ".\"."
}

/// The `-spec` for an export. Params: `instance()` (Threaded) ++ each host param type. Result: the
/// `{ok, _} | {error, trap()}` shape per §3 — a `touches_state` (Threaded) export threads
/// `instance()` back inside the `ok`, a 0-result mutator collapsing to `{ok, instance()}`.
fn export_spec(e: ExportSig, sm: StateModel) -> String {
  let threaded = sm == Threaded
  let touches = threaded && e.touches_state
  let param_types = list.map(e.params, erl_host_type)
  let spec_params = case threaded {
    True -> ["instance()", ..param_types]
    False -> param_types
  }
  let base = spec_result_base(e)
  let ok = case touches {
    True ->
      case iface.result_encoding(e.results) {
        ResultUnit -> "{ok, instance()}"
        _ -> "{ok, {" <> base <> ", instance()}}"
      }
    False -> "{ok, " <> base <> "}"
  }
  "-spec "
  <> e.host_name
  <> "("
  <> comma(spec_params)
  <> ") -> "
  <> ok
  <> " | {error, trap()}."
}

/// The `-spec` result-payload type (the `T` inside `{ok, T}`), before any instance threading: `ok`
/// for 0 results (the unit atom), the bare host type for 1, an `{…}` tuple for N≥2.
fn spec_result_base(e: ExportSig) -> String {
  case iface.result_encoding(e.results) {
    ResultUnit -> "ok"
    ResultBare -> {
      let assert [r] = e.results
      erl_host_type(r)
    }
    ResultTuple(_) -> "{" <> comma(list.map(e.results, erl_host_type)) <> "}"
  }
}

/// The `try … of` clause body `Pattern -> OkExpr` matching the `{ResultPackage, St'}` return. The
/// package pattern destructures per `result_encoding` (R4); `St'` is bound (`St`) only when the
/// export threads it out, else ignored (`_St`). The result decode runs here — OUTSIDE the catch
/// (R7). A 0-result mutator returns `{ok, St}`; other threaded exports `{ok, {Decoded, St}}`; a pure
/// export `{ok, Decoded}` (`ok` for 0 results).
fn result_of_clause(e: ExportSig, touches: Bool) -> String {
  let #(pkg_pat, decoded) = case iface.result_encoding(e.results) {
    ResultUnit -> #("_Pkg", "ok")
    ResultBare -> {
      let assert [r] = e.results
      #("Pkg", result_decode(r, "Pkg"))
    }
    ResultTuple(_) -> {
      let pats = list.index_map(e.results, fn(_r, i) { res_var(i) })
      let convs =
        list.index_map(e.results, fn(r, i) { result_decode(r, res_var(i)) })
      #("{" <> comma(pats) <> "}", "{" <> comma(convs) <> "}")
    }
  }
  let st = case touches {
    True -> "St"
    False -> "_St"
  }
  let ok = case touches {
    True ->
      case iface.result_encoding(e.results) {
        ResultUnit -> "{ok, St}"
        _ -> "{ok, {" <> decoded <> ", St}}"
      }
    False -> "{ok, " <> decoded <> "}"
  }
  "{" <> pkg_pat <> ", " <> st <> "} -> " <> ok
}

// ───────────────────────────── value-ABI renderers ─────────────────────────────

/// The host-facing Erlang `-spec` type of a `ValType`: `integer()` (signed) / `floatval()` /
/// `binary()` (v128, 16 B) / `term()` (opaque ref).
fn erl_host_type(vt: ir.ValType) -> String {
  case iface.value_abi(vt) {
    IntAbi(_) -> "integer()"
    FloatAbi(_) -> "floatval()"
    V128Abi -> "binary()"
    RefAbi -> "term()"
  }
}

/// The argument-prep for the `i`-th param: `#(let_line_or_empty, call_arg)`. A `let_line` (empty
/// for identity conversions) binds the raw value with `=` BEFORE the `try` (R7); `call_arg` is what
/// the `.beam` call passes. Ints wrap to unsigned; floats decode the `floatval()` tuple to raw bits;
/// v128 / refs pass the host var through unchanged.
fn arg_encode(vt: ir.ValType, i: Int) -> #(String, String) {
  let a = arg_var(i)
  let e = "E" <> int.to_string(i)
  let bind = fn(fun) { #("    " <> e <> " = " <> fun <> "(" <> a <> "),", e) }
  case iface.value_abi(vt) {
    IntAbi(32) -> bind("enc_i32")
    IntAbi(_) -> bind("enc_i64")
    FloatAbi(32) -> bind("enc_f32")
    FloatAbi(_) -> bind("enc_f64")
    V128Abi -> #("", a)
    RefAbi -> #("", a)
  }
}

/// The raw→native decode of a result bit-pattern held in variable `var`: signed-int decode, guarded
/// float classification (`dec_f*`, R18), or v128 / ref identity.
fn result_decode(vt: ir.ValType, var: String) -> String {
  case iface.value_abi(vt) {
    IntAbi(32) -> "dec_i32(" <> var <> ")"
    IntAbi(_) -> "dec_i64(" <> var <> ")"
    FloatAbi(32) -> "dec_f32(" <> var <> ")"
    FloatAbi(_) -> "dec_f64(" <> var <> ")"
    V128Abi -> var
    RefAbi -> var
  }
}

/// The WASM signature `(t, …) -> t` / `(t, …) -> (t, …)` / `(t, …) -> ()` for a doc comment.
fn wasm_sig(e: ExportSig) -> String {
  let params = "(" <> comma(list.map(e.params, wasm_type)) <> ")"
  let results = case e.results {
    [] -> "()"
    [r] -> wasm_type(r)
    rs -> "(" <> comma(list.map(rs, wasm_type)) <> ")"
  }
  params <> " -> " <> results
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

// ───────────────────────────── conversion helpers ─────────────────────────────

/// Render the private value-ABI helper defs a module references, each as its own block, in the
/// fixed order (only-when-used, so no dead private function — an `erlc` warning — is emitted). The
/// leading comment is prepended only when at least one helper is present.
fn helper_blocks(f: Features) -> List(List(String)) {
  let helpers =
    list.flatten([
      case f.enc_i32 {
        True -> [["enc_i32(V) -> V band 16#FFFFFFFF."]]
        False -> []
      },
      case f.enc_i64 {
        True -> [["enc_i64(V) -> V band 16#FFFFFFFFFFFFFFFF."]]
        False -> []
      },
      case f.enc_f32 {
        True -> [
          [
            "enc_f32({finite, F}) -> <<B:32>> = <<F:32/float>>, B;",
            "enc_f32({nonfinite, Bytes}) -> <<B:32>> = Bytes, B.",
          ],
        ]
        False -> []
      },
      case f.enc_f64 {
        True -> [
          [
            "enc_f64({finite, F}) -> <<B:64>> = <<F:64/float>>, B;",
            "enc_f64({nonfinite, Bytes}) -> <<B:64>> = Bytes, B.",
          ],
        ]
        False -> []
      },
      case f.dec_i32 {
        True -> [
          [
            "dec_i32(B) when B >= 16#80000000 -> B - 16#100000000;",
            "dec_i32(B) -> B.",
          ],
        ]
        False -> []
      },
      case f.dec_i64 {
        True -> [
          [
            "dec_i64(B) when B >= 16#8000000000000000 -> B - 16#10000000000000000;",
            "dec_i64(B) -> B.",
          ],
        ]
        False -> []
      },
      case f.dec_f32 {
        True -> [
          [
            "dec_f32(B) ->",
            "    <<_S:1, Exp:8, _M:23>> = <<B:32>>,",
            "    case Exp of",
            "        16#FF -> {nonfinite, <<B:32>>};",
            "        _ -> <<F:32/float>> = <<B:32>>, {finite, F}",
            "    end.",
          ],
        ]
        False -> []
      },
      case f.dec_f64 {
        True -> [
          [
            "dec_f64(B) ->",
            "    <<_S:1, Exp:11, _M:52>> = <<B:64>>,",
            "    case Exp of",
            "        16#7FF -> {nonfinite, <<B:64>>};",
            "        _ -> <<F:64/float>> = <<B:64>>, {finite, F}",
            "    end.",
          ],
        ]
        False -> []
      },
    ])
  case helpers {
    [] -> []
    _ -> [
      [
        "%% Value-ABI conversions (P2) - only the helpers referenced by some export are emitted,",
        "%% in a fixed order (deterministic output). Big-endian float codec (canonical IEEE bits).",
      ],
      ..helpers
    ]
  }
}

// ───────────────────────────── small utilities ─────────────────────────────

/// The head/host variable name for the `i`-th argument (`A0`, `A1`, …).
fn arg_var(i: Int) -> String {
  "A" <> int.to_string(i)
}

/// The pattern variable name for the `i`-th multi-value result (`R0`, `R1`, …).
fn res_var(i: Int) -> String {
  "R" <> int.to_string(i)
}

/// The host arity (`-export`/head arity) of an export: `len(params)` under Stateless, `+1` for the
/// leading `Inst` under Threaded. (This is the HOST surface arity — distinct from
/// `ExportSig.emitted_arity`, which is always `len(params)+1` on the `.beam`.)
fn host_arity(e: ExportSig, sm: StateModel) -> Int {
  case sm {
    Threaded -> list.length(e.params) + 1
    Stateless -> list.length(e.params)
  }
}

/// Wrap `raw` as a single-quoted Erlang atom `'…'`, escaping any embedded `\` and `'`. Used for the
/// module atom (contains `@`) and every dispatch atom (an arbitrary WASM export string).
fn quote_atom(raw: String) -> String {
  let escaped =
    raw
    |> string.replace("\\", "\\\\")
    |> string.replace("'", "\\'")
  "'" <> escaped <> "'"
}

/// Escape a string for embedding inside an Erlang `"…"` literal (used in `-doc` text): `\` and `"`
/// are backslash-escaped and a literal newline becomes `\n`.
fn erl_string_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

/// Join strings with `", "` — the argument / field / list-entry separator used throughout.
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
