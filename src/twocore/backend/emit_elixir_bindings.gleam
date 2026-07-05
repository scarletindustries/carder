//// The **Elixir bindings emitter** (Phase-12, P12-04).
////
//// Renders the language-neutral `Iface` (P12-01, `«IFACE-DESC-FROZEN»`) into a single,
//// idiomatic `.ex` source file that gives a typed Elixir API to instantiate a compiled WASM
//// `.beam` and call each of its exports. Values follow the WASM value-ABI (P2) — integers
//// presented SIGNED, floats as a `{:finite, float()} | {:nonfinite, binary()}` tagged tuple (so
//// NaN/±Inf survive — R18), v128 as a 16-byte binary, refs opaque — and a WASM trap becomes
//// `{:error, {:wasm_trap, atom()}}`.
////
//// ## Best-effort, and zero-Elixir-runtime-dependency (R23)
////
//// Elixir compilation is BEST-EFFORT (P8): the capstone/emitter tests skip-if-`elixirc`-absent
//// (a categorized skip, never a false green). More importantly, the generated binding is written
//// to run with **zero `Elixir.*` runtime dependencies** so a loaded binding executes on a bare
//// BEAM node (no Elixir stdlib ebin needed at call time):
////
//// - Traps are caught **Erlang-style** — `try … catch :error, {:wasm_trap, _} = reason -> …` —
////   NOT `rescue e in ErlangError` (which pulls `Elixir.Exception.normalize/3` and `undef`s
////   without the Elixir stdlib on the VM).
//// - Integer masking is `:erlang.band/2` (a BIF), signed decode is a GUARD clause, the float
////   codec is BEAM bit syntax (`<<f::float-size(64)>>`) — no `Bitwise`/`Kernel`/`Integer`/`Float`
////   stdlib calls at runtime.
//// - The instance is the raw `InstanceState` record threaded as a pure value (no struct — a
////   `defstruct` would drag `Enum` into `__struct__/1`); its opaque type is `@opaque instance`.
////
//// ## The key differentiator vs the Gleam emitter (P12-02)
////
//// Like Erlang, Elixir catches the BEAM exception IN-LANGUAGE, so there is **no companion catch
//// shim** — `emit_elixir` returns a **single-element** `List(GeneratedFile)` (the `List` return
//// is the uniform emitter signature, not a plurality this emitter uses). The trap match is
//// STRUCTURAL on `{:wasm_trap, _}` (R7), never a bare `:error, reason` catch-all — so an
//// arity/`undef` emitter bug crashes loudly instead of masquerading as a fake trap, and a WASM
//// `throw`/`exnref` (a distinct term class, R24) escapes rather than being mis-surfaced.
////
//// ## The two-shape host API (R19)
////
//// The emitted `.beam` ABI is uniformly `n+1` under the accepted (Threaded) build — every export
//// takes a leading `InstanceState` and returns `{ResultPackage, St'}` (R2/R19), whether or not it
//// touches state — so the binding always threads the state INTERNALLY. The two shapes govern only
//// the host surface:
////
//// - **`StateModel = Stateless`** (no export threads state): the beautiful pure file — NO
////   `instantiate/0` in the surface; each export is `f(args) -> {:ok, t} | {:error, trap}`,
////   re-instantiating internally per call (both the `instantiate` and the export call sit inside
////   the trap-catch, so a trapping start / OOB active segment becomes `{:error, _}`, R5).
//// - **`StateModel = Threaded`** (≥1 export threads state): `instantiate/0` returns
////   `{:ok, instance()} | {:error, trap()}` (R5); every export takes `inst`; a `touches_state`
////   export returns `{:ok, {t, instance()}} | {:error, trap()}` (thread the new instance out — a
////   0-result mutator is `{:ok, instance()}`), the rest return `{:ok, t} | {:error, trap()}`
////   (take `inst`, discard the unchanged returned state).
////
//// ## The value ABI it renders (P2 + R9/R18, from `iface.value_abi`)
////
//// The frozen boundary conversions are emitted as private helpers, only when some export
//// references them, in a fixed order (an unused `defp` is an `elixirc` warning; determinism per
//// R25a). The float codec is big-endian (BEAM bit-syntax default — the canonical IEEE-754
//// bit-pattern the runtime uses); `f32_bits`/`f64_bits` (encode) and `f32_of_bits`/`f64_of_bits`
//// (decode, guarded on the all-ones exponent) ARE the bidirectional bit accessors (R18) — the
//// finite path is a native `float()`, the non-finite path carries the raw IEEE bytes so NaN/±Inf
//// never crash. The decode lives in the `try … else` clause, OUTSIDE the trap-catch (R7).

import gleam/int
import gleam/list
import gleam/string
import twocore/backend/iface.{
  type ExportSig, type GeneratedFile, type Iface, FloatAbi, GeneratedFile,
  IntAbi, RefAbi, ResultBare, ResultTuple, ResultUnit, Threaded, V128Abi,
}
import twocore/ir

/// Render an `Iface` into the Elixir binding (the frozen `Emitter` signature).
///
/// - `desc`: a VALID descriptor (`iface.describe/2` has already fail-closed on Cell /
///   import-bearing / mutable-tier builds — `emit_elixir` does not re-validate).
///
/// Returns exactly ONE `GeneratedFile` (deterministic — the same `Iface` yields byte-identical
/// content, R25a): `#(<base>_bindings.ex, …)`, a `defmodule <Camelized>Bindings` carrying
/// `@moduledoc`/`@spec`/`@doc`/`@typedoc`. `<base>` is `iface.module_name` legalized to an
/// identifier (`twocore@wasm@x` → `twocore_wasm_x`); the Elixir module compiles to the DISTINCT
/// atom `Elixir.<Camelized>Bindings`, so — unlike the Gleam/Erlang siblings' `twocore_wasm_x_bindings`
/// — it never collides with the loaded `.beam` atom or the sibling bindings (R16 is a
/// Gleam/Erlang-only concern). Never fails: every `Iface` the descriptor produces is renderable.
///
/// **Elixir is best-effort (P8):** the emitter is a pure Gleam function (always runs), but the
/// authoritative compile+call proof is gated on `elixirc` being on `PATH` — a categorized skip
/// (never a false green) when absent.
pub fn emit_elixir(desc: Iface) -> List(GeneratedFile) {
  let base = iface.sanitize_identifier(desc.module_name)
  [GeneratedFile(path: base <> "_bindings.ex", content: render_module(desc))]
}

// ───────────────────────────── feature detection ─────────────────────────────

/// The set of value-shapes present across a descriptor's exports — used to emit ONLY the
/// conversion helpers and types a module actually references (an unused private function is an
/// `elixirc` warning; determinism per R25a). An `enc_*` helper is referenced iff some export PARAM
/// has that type; a `dec_*` helper iff some export RESULT has it; `has_float` iff either side has
/// any float (gates the `floatval` type).
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

/// Render the full `.ex` for `desc`. The `defmodule … do` wraps a sequence of blocks (each a
/// `List(String)` already indented two spaces) joined by a single blank line, in a fixed order:
/// `@moduledoc`, the type declarations, `instantiate/0` (Threaded only), one clause per export in
/// `iface.exports` order, then the referenced conversion helpers. Deterministic (R25a).
fn render_module(desc: Iface) -> String {
  let f = detect_features(desc)
  let alias = module_alias(desc.module_name)
  let blocks =
    list.flatten([
      [moduledoc_block(desc)],
      [types_block(f)],
      instantiate_block(desc, f.threaded),
      list.map(desc.exports, fn(e) { render_export(desc, e, f.threaded) }),
      helper_blocks(f),
    ])
  let inner =
    blocks
    |> list.filter(fn(b) { b != [] })
    |> list.map(fn(b) { string.join(b, "\n") })
    |> string.join("\n\n")
  "defmodule " <> alias <> " do\n" <> inner <> "\nend\n"
}

/// The Elixir module alias for `module_name`: camelize the legalized base and suffix `Bindings`
/// (`twocore@wasm@x` → `TwocoreWasmXBindings`). Compiles to the atom `Elixir.<alias>` — distinct
/// from the loaded `.beam` atom and the sibling bindings, so it never collides (R16).
fn module_alias(module_name: String) -> String {
  camelize(iface.sanitize_identifier(module_name)) <> "Bindings"
}

/// The `@moduledoc` heredoc block (indented two spaces). Inside a `"""` heredoc, `#{…}` still
/// interpolates, so the embedded module name is escaped (`ex_string_escape`).
fn moduledoc_block(desc: Iface) -> List(String) {
  let m = ex_string_escape(desc.module_name)
  [
    "  @moduledoc \"\"\"",
    "  Typed Elixir bindings for the compiled WebAssembly module `" <> m <> "`.",
    "",
    "  Generated by 2core (Phase 12) - do not edit. Values follow the WASM value-ABI",
    "  (P2): integers are presented SIGNED, floats as a `{:finite, float()} |",
    "  {:nonfinite, binary()}` tagged tuple (so NaN/Inf survive), v128 as a 16-byte",
    "  binary, refs opaque. A WASM trap becomes `{:error, {:wasm_trap, atom()}}`.",
    "",
    "  Runs with zero Elixir stdlib deps at call time (only `:erlang`/bit-syntax/guards),",
    "  so it works on a bare BEAM node; the trap catch is Erlang-style `:error, {:wasm_trap, _}`.",
    "  \"\"\"",
  ]
}

/// The type declarations block: `@opaque instance` (Threaded only), `@type trap` (always), and
/// `@type floatval` (only when floats are present). Each is `@typedoc`'d. Conditional emission
/// keeps every declared type referenced.
fn types_block(f: Features) -> List(String) {
  let instance = case f.threaded {
    True -> [
      "  @typedoc \"An opaque live instance: the runtime `InstanceState` record, threaded as a pure value (no process is spawned).\"",
      "  @opaque instance :: tuple()",
      "",
    ]
    False -> []
  }
  let trap = [
    "  @typedoc \"A WASM trap, surfaced as the raw error-class reason `{:wasm_trap, kind}`.\"",
    "  @type trap :: {:wasm_trap, atom()}",
  ]
  let floatval = case f.has_float {
    True -> [
      "",
      "  @typedoc \"A WASM float arg/result (R18): finite values are a native `float()`; a non-finite (NaN/Inf) value, which a `float()` cannot hold, is its raw IEEE-754 bytes.\"",
      "  @type floatval :: {:finite, float()} | {:nonfinite, binary()}",
    ]
    False -> []
  }
  list.flatten([instance, trap, floatval])
}

/// The `instantiate/0` clause block — Threaded only (a Stateless surface has no `instance()`). The
/// remote `instantiate/0` returns the raw `InstanceState` record; a trapping start / OOB active
/// segment raises, caught structurally to `{:error, trap()}` (R5). The wrap into `{:ok, st}` runs
/// in the `else` clause, OUTSIDE the catch (R7).
fn instantiate_block(desc: Iface, threaded: Bool) -> List(List(String)) {
  case threaded {
    False -> []
    True -> {
      let m = ex_string_escape(desc.module_name)
      [
        [
          "  @doc \"Instantiate `"
            <> m
            <> "`: build a fresh instance (memory / globals / table). A trapping start or out-of-bounds active segment becomes `{:error, trap()}`.\"",
          "  @spec instantiate() :: {:ok, instance()} | {:error, trap()}",
          "  def instantiate() do",
          "    try do",
          "      :\"" <> m <> "\".instantiate()",
          "    else",
          "      st -> {:ok, st}",
          "    catch",
          "      :error, {:wasm_trap, _} = reason -> {:error, reason}",
          "    end",
          "  end",
        ],
      ]
    }
  }
}

// ───────────────────────────── per-export renderer ─────────────────────────────

/// Render one export as a block: its `@doc` + `@spec` + `def` clause (§3 algorithm). Under Threaded
/// the head takes a leading `inst`; under Stateless the clause re-instantiates internally. Argument
/// encodes are bound with `=` BEFORE the `try`, and the result decode lives in the `try … else`
/// clause (Elixir runs `else` OUTSIDE the catch), so only the `.beam` call is trap-protected (R7).
fn render_export(desc: Iface, e: ExportSig, threaded: Bool) -> List(String) {
  let touches = threaded && e.touches_state
  let host = e.host_name
  let m = ex_string_escape(desc.module_name)
  let target = remote_call(m, e.dispatch_atom)

  // Head params a0, a1, … (prefixed with `inst` under Threaded).
  let host_params = list.index_map(e.params, fn(_vt, i) { arg_var(i) })
  let head_params = case threaded {
    True -> ["inst", ..host_params]
    False -> host_params
  }
  let head = "  def " <> host <> "(" <> comma(head_params) <> ") do"

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

  // The trap-protected call. Threaded threads the caller's `inst`; Stateless re-instantiates.
  let try_lines = case threaded {
    True -> [
      "    try do",
      "      " <> target <> "(" <> comma(["inst", ..call_args]) <> ")",
    ]
    False -> [
      "    try do",
      "      st = :\"" <> m <> "\".instantiate()",
      "      " <> target <> "(" <> comma(["st", ..call_args]) <> ")",
    ]
  }
  let else_lines = ["    else", "      " <> result_else_clause(e, touches)]
  let catch_lines = [
    "    catch",
    "      :error, {:wasm_trap, _} = reason -> {:error, reason}",
    "    end",
  ]

  list.flatten([
    [export_doc(e, threaded)],
    [export_spec(e, threaded)],
    [head],
    enc_lines,
    try_lines,
    else_lines,
    catch_lines,
    ["  end"],
  ])
}

/// The single-line `@doc` for an export: the WASM signature, the preserved original export name
/// (with the host function name when they differ, since `dispatch_atom` may be un-Elixir-like), and
/// the state-threading contract.
fn export_doc(e: ExportSig, threaded: Bool) -> String {
  let renamed = case e.host_name == e.dispatch_atom {
    True -> ""
    False -> " (host function `" <> e.host_name <> "`)"
  }
  let contract = case threaded, e.touches_state {
    True, True -> " Reads/mutates instance state, so it threads the instance."
    True, False ->
      " State-free: the instance is unchanged, so it is not returned."
    False, _ -> ""
  }
  "  @doc \"Exported `"
  <> ex_string_escape(e.dispatch_atom)
  <> "`"
  <> renamed
  <> " : "
  <> wasm_sig(e)
  <> "."
  <> contract
  <> "\""
}

/// The `@spec` for an export. Params: `instance()` (Threaded) ++ each host param type. Result: the
/// `{:ok, _} | {:error, trap()}` shape per §3 — a `touches_state` (Threaded) export threads
/// `instance()` back inside the `:ok`, a 0-result mutator collapsing to `{:ok, instance()}`.
fn export_spec(e: ExportSig, threaded: Bool) -> String {
  let touches = threaded && e.touches_state
  let param_types = list.map(e.params, elixir_host_type)
  let spec_params = case threaded {
    True -> ["instance()", ..param_types]
    False -> param_types
  }
  let base = spec_result_base(e)
  let ok = case touches {
    True ->
      case iface.result_encoding(e.results) {
        ResultUnit -> "{:ok, instance()}"
        _ -> "{:ok, {" <> base <> ", instance()}}"
      }
    False -> "{:ok, " <> base <> "}"
  }
  "  @spec "
  <> e.host_name
  <> "("
  <> comma(spec_params)
  <> ") :: "
  <> ok
  <> " | {:error, trap()}"
}

/// The `@spec` result-payload type (the `T` inside `{:ok, T}`), before any instance threading:
/// `:ok` for 0 results (the unit atom), the bare host type for 1, an `{…}` tuple for N≥2.
fn spec_result_base(e: ExportSig) -> String {
  case iface.result_encoding(e.results) {
    ResultUnit -> ":ok"
    ResultBare -> {
      let assert [r] = e.results
      elixir_host_type(r)
    }
    ResultTuple(_) -> "{" <> comma(list.map(e.results, elixir_host_type)) <> "}"
  }
}

/// The `try … else` clause `pattern -> ok_expr` matching the `{ResultPackage, St'}` return. The
/// package pattern destructures per `result_encoding` (R4); `St'` is bound (`st2`) only when the
/// export threads it out, else ignored (`_st2`). The result decode runs here — OUTSIDE the catch
/// (R7). A 0-result mutator returns `{:ok, st2}`; other threaded exports `{:ok, {decoded, st2}}`; a
/// pure export `{:ok, decoded}` (`:ok` for 0 results).
fn result_else_clause(e: ExportSig, touches: Bool) -> String {
  let #(pkg_pat, decoded) = case iface.result_encoding(e.results) {
    ResultUnit -> #("_pkg", ":ok")
    ResultBare -> {
      let assert [r] = e.results
      #("pkg", result_decode(r, "pkg"))
    }
    ResultTuple(_) -> {
      let pats = list.index_map(e.results, fn(_r, i) { res_var(i) })
      let convs =
        list.index_map(e.results, fn(r, i) { result_decode(r, res_var(i)) })
      #("{" <> comma(pats) <> "}", "{" <> comma(convs) <> "}")
    }
  }
  let st = case touches {
    True -> "st2"
    False -> "_st2"
  }
  let ok = case touches {
    True ->
      case iface.result_encoding(e.results) {
        ResultUnit -> "{:ok, st2}"
        _ -> "{:ok, {" <> decoded <> ", st2}}"
      }
    False -> "{:ok, " <> decoded <> "}"
  }
  "{" <> pkg_pat <> ", " <> st <> "} -> " <> ok
}

// ───────────────────────────── value-ABI renderers ─────────────────────────────

/// The host-facing Elixir `@spec` type of a `ValType`: `integer()` (signed) / `floatval()` /
/// `binary()` (v128, 16 B) / `term()` (opaque ref).
fn elixir_host_type(vt: ir.ValType) -> String {
  case iface.value_abi(vt) {
    IntAbi(_) -> "integer()"
    FloatAbi(_) -> "floatval()"
    V128Abi -> "binary()"
    RefAbi -> "term()"
  }
}

/// The argument-prep for the `i`-th param: `#(let_line_or_empty, call_arg)`. A `let_line` (empty
/// for identity conversions) binds the raw value with `=` BEFORE the `try` (R7); `call_arg` is what
/// the `.beam` call passes. Ints mask to unsigned; floats encode the `floatval()` tuple to raw
/// bits; v128 / refs pass the host var through unchanged.
fn arg_encode(vt: ir.ValType, i: Int) -> #(String, String) {
  let a = arg_var(i)
  let e = "e" <> int.to_string(i)
  let bind = fn(fun) { #("    " <> e <> " = " <> fun <> "(" <> a <> ")", e) }
  case iface.value_abi(vt) {
    IntAbi(32) -> bind("i32_to_raw")
    IntAbi(_) -> bind("i64_to_raw")
    FloatAbi(32) -> bind("f32_bits")
    FloatAbi(_) -> bind("f64_bits")
    V128Abi -> #("", a)
    RefAbi -> #("", a)
  }
}

/// The raw→native decode of a result bit-pattern held in variable `var`: signed-int decode, guarded
/// float classification (`f*_of_bits`, R18), or v128 / ref identity.
fn result_decode(vt: ir.ValType, var: String) -> String {
  case iface.value_abi(vt) {
    IntAbi(32) -> "i32_of_raw(" <> var <> ")"
    IntAbi(_) -> "i64_of_raw(" <> var <> ")"
    FloatAbi(32) -> "f32_of_bits(" <> var <> ")"
    FloatAbi(_) -> "f64_of_bits(" <> var <> ")"
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
/// fixed order `i32_to_raw, i32_of_raw, i64_to_raw, i64_of_raw, f32_bits, f32_of_bits, f64_bits,
/// f64_of_bits` (only-when-used, so no dead `defp` — an `elixirc` warning; determinism per R25a).
/// The names are drawn from `iface.reserved_names()` so no export `host_name` can collide with a
/// helper. Every helper uses only `:erlang`/bit-syntax/guards (zero Elixir runtime deps, R23).
fn helper_blocks(f: Features) -> List(List(String)) {
  list.flatten([
    case f.enc_i32 {
      True -> [
        [
          "  @spec i32_to_raw(integer()) :: integer()",
          "  defp i32_to_raw(v), do: :erlang.band(v, 0xFFFFFFFF)",
        ],
      ]
      False -> []
    },
    case f.dec_i32 {
      True -> [
        [
          "  @spec i32_of_raw(integer()) :: integer()",
          "  defp i32_of_raw(r) when r >= 0x80000000, do: r - 0x100000000",
          "  defp i32_of_raw(r), do: r",
        ],
      ]
      False -> []
    },
    case f.enc_i64 {
      True -> [
        [
          "  @spec i64_to_raw(integer()) :: integer()",
          "  defp i64_to_raw(v), do: :erlang.band(v, 0xFFFFFFFFFFFFFFFF)",
        ],
      ]
      False -> []
    },
    case f.dec_i64 {
      True -> [
        [
          "  @spec i64_of_raw(integer()) :: integer()",
          "  defp i64_of_raw(r) when r >= 0x8000000000000000, do: r - 0x10000000000000000",
          "  defp i64_of_raw(r), do: r",
        ],
      ]
      False -> []
    },
    case f.enc_f32 {
      True -> [
        [
          "  @spec f32_bits(floatval()) :: integer()",
          "  defp f32_bits({:finite, f}), do: (<<b::32>> = <<f::float-size(32)>>; b)",
          "  defp f32_bits({:nonfinite, bytes}), do: (<<b::32>> = bytes; b)",
        ],
      ]
      False -> []
    },
    case f.dec_f32 {
      True -> [
        [
          "  @spec f32_of_bits(integer()) :: floatval()",
          "  defp f32_of_bits(b) do",
          "    <<_s::1, exp::8, _m::23>> = <<b::32>>",
          "    case exp do",
          "      0xFF -> {:nonfinite, <<b::32>>}",
          "      _ -> (<<f::float-size(32)>> = <<b::32>>; {:finite, f})",
          "    end",
          "  end",
        ],
      ]
      False -> []
    },
    case f.enc_f64 {
      True -> [
        [
          "  @spec f64_bits(floatval()) :: integer()",
          "  defp f64_bits({:finite, f}), do: (<<b::64>> = <<f::float-size(64)>>; b)",
          "  defp f64_bits({:nonfinite, bytes}), do: (<<b::64>> = bytes; b)",
        ],
      ]
      False -> []
    },
    case f.dec_f64 {
      True -> [
        [
          "  @spec f64_of_bits(integer()) :: floatval()",
          "  defp f64_of_bits(b) do",
          "    <<_s::1, exp::11, _m::52>> = <<b::64>>",
          "    case exp do",
          "      0x7FF -> {:nonfinite, <<b::64>>}",
          "      _ -> (<<f::float-size(64)>> = <<b::64>>; {:finite, f})",
          "    end",
          "  end",
        ],
      ]
      False -> []
    },
  ])
}

// ───────────────────────────── small utilities ─────────────────────────────

/// The head/host variable name for the `i`-th argument (`a0`, `a1`, …).
fn arg_var(i: Int) -> String {
  "a" <> int.to_string(i)
}

/// The pattern variable name for the `i`-th multi-value result (`r0`, `r1`, …).
fn res_var(i: Int) -> String {
  "r" <> int.to_string(i)
}

/// Camelize a legalized `[a-z][a-z0-9_]*` base into an Elixir module-alias segment: split on `_`,
/// drop empty segments, upper-case the first character of each, and concatenate
/// (`twocore_wasm_x` → `TwocoreWasmX`). The base starts with `[a-z]`, so the result starts with an
/// upper-case letter — a legal Elixir alias.
fn camelize(base: String) -> String {
  base
  |> string.split("_")
  |> list.filter(fn(s) { s != "" })
  |> list.map(upcase_first)
  |> string.concat
}

/// Upper-case the first grapheme of `s`, leaving the rest unchanged. A digit first-char (from a
/// numeric base segment) is left as-is (uppercasing is a no-op) — harmless mid-alias.
fn upcase_first(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> s
  }
}

/// Escape a string for embedding inside an Elixir `"…"`/`"""…"""` literal: `\` and `"` are
/// backslash-escaped, `#` is escaped (so `#{` cannot start an interpolation), and a literal newline
/// becomes `\n`. Applied to the module atom and every dispatch atom (an arbitrary WASM export
/// string). Order matters — `\` is replaced first so added backslashes are not re-escaped.
fn ex_string_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("#", "\\#")
  |> string.replace("\n", "\\n")
}

/// Render a static remote-call prefix `:"<mod>".<fun>` / `:"<mod>"."<fun>"`. The module atom is
/// always quoted (`mod` is `twocore@wasm@<base>` — the `@` requires it). The dispatch function name
/// is quoted ONLY when it is not a bare unquoted-call token (`[a-z_][A-Za-z0-9_]*`) — so a normal
/// export (`add`, `_start`, `run_test`) renders `.add(…)` (hand-written-quality, no "quotes not
/// required" warning), while an arbitrary WASM name (`run-test`, `foo.bar`, `0`) is quoted for
/// correctness. `mod` is already `ex_string_escape`d by the caller.
fn remote_call(mod_esc: String, dispatch: String) -> String {
  let fun = case dispatch_needs_quote(dispatch) {
    True -> "\"" <> ex_string_escape(dispatch) <> "\""
    False -> dispatch
  }
  ":\"" <> mod_esc <> "\"." <> fun
}

/// `True` iff `name` must be QUOTED to be used as a remote-call function name — i.e. it is empty,
/// does not start with `[a-z_]`, or contains a character outside `[A-Za-z0-9_]`. A bare
/// `[a-z_][A-Za-z0-9_]*` (including Elixir keywords like `when`, which parse fine unquoted after a
/// `.`) does NOT need quotes.
fn dispatch_needs_quote(name: String) -> Bool {
  case string.pop_grapheme(name) {
    Error(_) -> True
    Ok(#(first, rest)) ->
      case is_call_start_char(first) {
        False -> True
        True -> list.any(string.to_graphemes(rest), fn(c) { !is_call_char(c) })
      }
  }
}

/// `True` iff `c` may START an unquoted call name: a lowercase ASCII letter or `_` (an
/// uppercase-start name is an alias, and a digit-start is illegal — both must be quoted).
fn is_call_start_char(c: String) -> Bool {
  c == "_" || string.contains("abcdefghijklmnopqrstuvwxyz", c)
}

/// `True` iff `c` may appear WITHIN an unquoted call name: an ASCII letter (either case), digit, or
/// `_`. (Uses substring membership against the ASCII set — a multi-byte grapheme is never a member.)
fn is_call_char(c: String) -> Bool {
  is_call_start_char(c)
  || string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", c)
}

/// Join strings with `", "` — the argument / field / list-entry separator used throughout.
fn comma(parts: List(String)) -> String {
  string.join(parts, ", ")
}
