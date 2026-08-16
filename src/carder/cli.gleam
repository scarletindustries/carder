//// `carder/cli` — the **shared command-line surface** every carder frontend builds on.
////
//// carder is a compiler BACKEND: a frontend (the `scribbler` WebAssembly frontend, arc's
//// JavaScript frontend, …) lowers its source language into `carder/ir` and hands the module to
//// `carder/pipeline`. Each of those frontends ships its own `gleam run --` binary, and each of
//// them needs the *same* posture vocabulary — the `--unsafe`/`--portable`/`--ceiling`/`--engine`
//// base profiles, `--threaded`, `--tier`/`--table-tier`/`--cap`, `--link`, `--bindings`/`--out`,
//// and the raw-bit-pattern value convention. This module is that vocabulary, published once.
////
//// ## Why this is EXTRACTED rather than copied into each frontend
////
//// `resolve_binding/6` is a **security gate**, not a convenience: it composes the axis flags into
//// a `Binding` and then routes it through `profiles.link/1`, the sole sanctioned `Binding →
//// Instance` seam (§B.2 of the Phase-4 CLI spec). A forked copy in a frontend repo could drift
//// into admitting `Safe` + `--tier nif`, or an uncapped `atomics`/`ceiling` build — exactly the
//// "never silently downgraded" invariant the gate exists to hold. The flag tokens are likewise a
//// 1:1 textual encoding of carder-owned types (`instance.MemTier`/`TableTier`,
//// `profiles.safe/unsafe/portable/ceiling/engine`, `bindings.BindingLang`), so a copy would rot
//// the moment carder adds a tier or a profile. One definition, consumed by every frontend.
////
//// ## What lives here
////
//// - **Axis flags** — `Axes`/`BaseSel`, `split_axis_flags`, `base_binding`, `resolve_binding`,
////   `with_binding`, `reject_link`, `reject_output_flags`, `axes_usage`.
//// - **The `--link` packaging gate** — `LinkGateError`, `link_gate`, `describe_link_gate_error`.
//// - **The run/invoke value convention (D5/T8)** — `parse_args`, `format_values`,
////   `format_uncaught`. Both `carder exec` and a frontend's `run` verb print through these, so
////   the same result renders byte-identically whichever binary produced it.
//// - **File IO diagnostics** — `read_bits`, `read_text`, `write_beam`, so the two CLIs report an
////   unreadable path with one wording.
////
//// ## Value convention (D5)
////
//// Arguments and results are **raw UNSIGNED bit patterns in decimal**: an i32 in `[0, 2^32)`, an
//// i64 in `[0, 2^64)`, a float as its raw IEEE-754 bits. So an i32 `-1` argument is written
//// `4294967295`. `format_uncaught` renders an uncaught exception (tag + payload), which is a
//// DISTINCT outcome from a trap (T8).

import carder/backend/bindings
import carder/ir
import carder/runtime/instance.{
  type Binding, type MemTier, type TableTier, Atomics, Binding, Nif, Paged,
  TableAtomics, TableEts, TablePaged, Threaded,
}
import carder/runtime/profiles
import carder/runtime/rt_mem_atomics
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

// ───────────────────────── axis selection (Phase-4 decision #5) ─────────────────────────

/// Which base profile the mutually-exclusive base flags select (§B.1). `BaseSafe` is the
/// fail-closed default (no base flag given): there is no `--safe` token, so `BaseSafe` always
/// means "unset", which lets `set_base` reject a second base flag.
pub type BaseSel {
  BaseSafe
  BaseUnsafe
  BasePortable
  BaseCeiling
  BaseEngine
}

/// A parsed axis-flag set: the CLI's requested profile/strategy/tier selection (§B). Each
/// field is set by an EXPLICIT named token — the fail-closed default (`BaseSafe`, no overrides)
/// is the value with no flags. `None` on `mem`/`table`/`cap` means "keep the base profile's".
///
/// - `base`: the mutually-exclusive base profile selection.
/// - `threaded`: `--threaded` → `state_strategy: Threaded`.
/// - `trust_memory`: `--trust-memory` → skip bounds checks on memory-0 access (lever 3).
/// - `inline_joins`: `--inline-joins` → inline single-use non-recursive `letrec` join funs.
/// - `mem`/`table`: the `--tier`/`--table-tier` selections.
/// - `cap`: the `--cap PAGES` bounded page cap.
/// - `link`: `True` iff `--link` was named (Phase 11 · P11-04). ORTHOGONAL to the posture/tier
///   axes; absent, output is byte-identical. Consumed only by a **build** verb; every other verb
///   rejects `link == True` fail-closed (`reject_link`) so the flag can never silently no-op.
/// - `bindings`: the `--bindings <langs>` selection (Phase 12 · P12-05), a canonical deduped
///   list (default `[]` = none). Consumed only by a build verb with `--out`.
/// - `out`: the `--out <dir>` folder, `None` when absent.
pub type Axes {
  Axes(
    base: BaseSel,
    threaded: Bool,
    trust_memory: Bool,
    inline_joins: Bool,
    mem: Option(MemTier),
    table: Option(TableTier),
    cap: Option(Int),
    link: Bool,
    bindings: List(bindings.BindingLang),
    out: Option(String),
  )
}

/// Parse a compile verb's tokens into the axis flags + the trailing POSITIONAL operands
/// (order-independent among the flags; the positionals keep their given order). Total.
///
/// Recognised flags: `--portable`/`--ceiling`/`--engine`/`--unsafe` (mutually-exclusive base — at
/// most one), `--threaded`, `--trust-memory`, `--inline-joins`, `--link`, `--tier <t>`,
/// `--table-tier <t>`, `--cap <pages>`, `--bindings <langs>`, `--out <dir>`. A
/// `--tier`/`--table-tier`/`--cap`/`--bindings`/`--out` with no following value, an unknown
/// `--flag`, an unrecognised tier or language token, a non-integer cap, and a second
/// base/`--bindings`/`--out` flag all yield `Error(msg)` (fail-closed — the caller exits
/// non-zero). Any non-`--` token is a positional.
///
/// `--link`/`--bindings`/`--out` only set their `Axes` fields here; whether each is HONORED or
/// REJECTED is decided per-verb by the caller (see `reject_link`/`reject_output_flags`).
///
/// - `tokens`: the verb's arguments after the verb (e.g. `["--tier", "atomics", "f.ir"]`).
/// - Returns `Ok(#(axes, positionals))` or `Error(msg)`.
pub fn split_axis_flags(
  tokens: List(String),
) -> Result(#(Axes, List(String)), String) {
  do_split_axis_flags(
    tokens,
    Axes(BaseSafe, False, False, False, None, None, None, False, [], None),
    [],
  )
}

/// Tail-recursive worker for `split_axis_flags`, accumulating `acc` (the axes so far) and
/// `positionals` (reversed). Total.
fn do_split_axis_flags(
  tokens: List(String),
  acc: Axes,
  positionals: List(String),
) -> Result(#(Axes, List(String)), String) {
  case tokens {
    [] -> Ok(#(acc, list.reverse(positionals)))
    ["--unsafe", ..rest] ->
      result.try(set_base(acc, BaseUnsafe), do_split_axis_flags(
        rest,
        _,
        positionals,
      ))
    ["--portable", ..rest] ->
      result.try(set_base(acc, BasePortable), do_split_axis_flags(
        rest,
        _,
        positionals,
      ))
    ["--ceiling", ..rest] ->
      result.try(set_base(acc, BaseCeiling), do_split_axis_flags(
        rest,
        _,
        positionals,
      ))
    ["--engine", ..rest] ->
      result.try(set_base(acc, BaseEngine), do_split_axis_flags(
        rest,
        _,
        positionals,
      ))
    ["--threaded", ..rest] ->
      do_split_axis_flags(rest, Axes(..acc, threaded: True), positionals)
    ["--trust-memory", ..rest] ->
      do_split_axis_flags(rest, Axes(..acc, trust_memory: True), positionals)
    ["--inline-joins", ..rest] ->
      do_split_axis_flags(rest, Axes(..acc, inline_joins: True), positionals)
    ["--link", ..rest] ->
      do_split_axis_flags(rest, Axes(..acc, link: True), positionals)
    ["--bindings", v, ..rest] ->
      // A second `--bindings` is rejected (fail-closed). A value-LESS `--bindings` (no following
      // token) does not match this arm and falls through to the `"--"` catch-all below.
      case acc.bindings {
        [] ->
          result.try(bindings.parse_langs(v), fn(langs) {
            do_split_axis_flags(rest, Axes(..acc, bindings: langs), positionals)
          })
        _ -> Error("--bindings given more than once")
      }
    ["--out", v, ..rest] ->
      case acc.out {
        None ->
          do_split_axis_flags(rest, Axes(..acc, out: Some(v)), positionals)
        Some(_) -> Error("--out given more than once")
      }
    ["--tier", v, ..rest] ->
      result.try(parse_mem_tier(v), fn(t) {
        do_split_axis_flags(rest, Axes(..acc, mem: Some(t)), positionals)
      })
    ["--table-tier", v, ..rest] ->
      result.try(parse_table_tier(v), fn(t) {
        do_split_axis_flags(rest, Axes(..acc, table: Some(t)), positionals)
      })
    ["--cap", v, ..rest] ->
      result.try(parse_cap(v), fn(n) {
        do_split_axis_flags(rest, Axes(..acc, cap: Some(n)), positionals)
      })
    [tok, ..rest] ->
      case string.starts_with(tok, "--") {
        True -> Error("unknown or malformed flag: " <> tok)
        False -> do_split_axis_flags(rest, acc, [tok, ..positionals])
      }
  }
}

/// Set the base profile, rejecting a SECOND base flag (the bases are mutually exclusive,
/// §B.1). `Error` if a base other than the default `BaseSafe` was already chosen.
fn set_base(acc: Axes, base: BaseSel) -> Result(Axes, String) {
  case acc.base {
    BaseSafe -> Ok(Axes(..acc, base: base))
    _ -> Error("at most one of --portable / --ceiling / --engine / --unsafe")
  }
}

/// Parse a `--tier` token into a `MemTier`. `Error` names the bad token fail-closed.
fn parse_mem_tier(v: String) -> Result(MemTier, String) {
  case v {
    "paged" -> Ok(Paged)
    "atomics" -> Ok(Atomics)
    "nif" -> Ok(Nif)
    _ -> Error("--tier expects paged|atomics|nif, got: " <> v)
  }
}

/// Parse a `--table-tier` token into a `TableTier`. `Error` names the bad token fail-closed.
fn parse_table_tier(v: String) -> Result(TableTier, String) {
  case v {
    "paged" -> Ok(TablePaged)
    "ets" -> Ok(TableEts)
    "atomics" -> Ok(TableAtomics)
    _ -> Error("--table-tier expects paged|ets|atomics, got: " <> v)
  }
}

/// Parse a `--cap` token into a non-negative page count. `Error` on a non-integer / negative.
fn parse_cap(v: String) -> Result(Int, String) {
  case int.parse(v) {
    Ok(n) if n >= 0 -> Ok(n)
    _ -> Error("--cap expects a non-negative page count, got: " <> v)
  }
}

/// The base `Binding` the chosen base flag selects (§B.1). `BaseSafe` is the fail-closed
/// default; `--portable`/`--ceiling`/`--engine` are the composed deployment profiles;
/// `--unsafe` the Phase-3 policy profile.
pub fn base_binding(sel: BaseSel) -> Binding {
  case sel {
    BaseSafe -> profiles.safe()
    BaseUnsafe -> profiles.unsafe()
    BasePortable -> profiles.portable()
    BaseCeiling -> profiles.ceiling()
    BaseEngine -> profiles.engine()
  }
}

/// Compose the CLI's requested `Binding` from a base profile + the orthogonal axis overrides,
/// couple the declared tiers to their modules, then validate it fail-closed through the SOLE
/// `Binding → Instance` seam `profiles.link/1` (G6/P5, §B.2). Each axis is a plain field set by
/// record-spread (`--threaded` → `state_strategy`, `--tier`/`--table-tier` → `mem_tier`/
/// `table_tier`, `--cap` → `safe_max_pages`); `profiles.resolve_tiers` is then the single source
/// that makes `mem_module`/`table_module` follow the declared tiers — so a `--tier atomics` build
/// actually links `rt_mem_atomics`, never the base's stale `paged` module (P5). The
/// `carder@runtime@*` names live in `profiles`/`instance`, never re-spelled here (D1).
///
/// Routing through `link/1` (rather than `validate_binding` directly) makes `link/1` the ONE
/// sanctioned path from a `Binding` to a `profiles.Instance` in this module — the ungated
/// `profiles.instantiate/1` is never called here — so the fail-closed gate cannot be bypassed
/// (§A sole-seam lock); the validated `Instance`'s `.binding` (which `link` has run
/// `resolve_tiers` over) is unwrapped as the coherent build binding.
///
/// **Every frontend must compose its binding through THIS function.** It is the shared security
/// gate; a frontend-local reimplementation would fork it (see this module's header).
///
/// - `base`: the profile chosen by `--portable`/`--ceiling`/`--engine`/`--unsafe`/(default
///   `safe()`).
/// - `threaded`: `True` iff `--threaded` was given → `state_strategy: Threaded`.
/// - `trust_memory`: `True` iff `--trust-memory` was given → `trust_memory: True` (lever 3, the
///   opt-in unchecked-linear-memory toggle). Orthogonal to the base profile and to every other
///   axis — composable with any of them; honored only on a BEAM-memory-safe tier at emit time.
/// - `mem`/`table`: the parsed `--tier`/`--table-tier` selections (`None` = keep the base's).
/// - `cap`: the parsed `--cap` page cap (`None` = keep the base's `safe_max_pages`).
/// - Returns `Ok(binding)` — a coherent, `resolve_tiers`-coupled, `link`-validated `Binding` —
///   for any coherent composition, or `Error(msg)` fail-closed when the result is
///   policy-incoherent (Safe + `nif`, an uncapped `atomics`/`ceiling` build, or a tier/module
///   drift) — surfaced as a CLI error (exit non-zero), NEVER silently downgraded. Total.
pub fn resolve_binding(
  base: Binding,
  threaded: Bool,
  trust_memory: Bool,
  mem: Option(MemTier),
  table: Option(TableTier),
  cap: Option(Int),
) -> Result(Binding, String) {
  let b0 = case threaded {
    True -> Binding(..base, state_strategy: Threaded)
    False -> base
  }
  let b_trust = case trust_memory {
    True -> Binding(..b0, trust_memory: True)
    False -> b0
  }
  let b1 = case mem {
    Some(t) -> Binding(..b_trust, mem_tier: t)
    None -> b_trust
  }
  let b2 = case table {
    Some(t) -> Binding(..b1, table_tier: t)
    None -> b1
  }
  let b3 = case cap {
    Some(p) -> Binding(..b2, safe_max_pages: p)
    None -> b2
  }
  // Couple the declared tiers to their modules BEFORE linking (P5) — `link`'s own
  // `validate_binding` guards the load-bearing `mem_module`, so it must already agree with the
  // declared tier. Then `link/1` (the sole seam) re-validates + re-resolves + assembles the
  // Instance; its `.binding` is the coherent build binding.
  case profiles.link(profiles.resolve_tiers(b3)) {
    Ok(inst) -> Ok(inst.binding)
    Error(e) -> Error("incoherent profile: " <> describe_link_error(e))
  }
}

/// A human-readable rendering of a `profiles.LinkError` for CLI stderr — the user-facing face of
/// the fail-closed link gate (§B.3). Total; the text is diagnostic only.
pub fn describe_link_error(e: profiles.LinkError) -> String {
  case e {
    profiles.SafeForbidsNif ->
      "Safe forbids the nif memory tier (tier-N runs native code that can crash the node); name --unsafe or --ceiling to use --tier nif"
    profiles.TierModuleMismatch ->
      "the linked memory module disagrees with the declared --tier (internal tier→module coupling error)"
    profiles.AtomicsCapRequired ->
      "the atomics memory tier requires a bounded cap (--cap PAGES with PAGES <= "
      <> int.to_string(rt_mem_atomics.atomics_reserve_cap_pages)
      <> "); an uncapped build would eagerly pre-allocate up to 4 GiB"
  }
}

/// Parse a compile verb's tokens, resolve+validate the composed `Binding`, and hand it to `k`
/// alongside the parsed `Axes` and the positional operands. The single wiring point where the
/// axis flags become a validated `Binding` (so the fail-closed gate runs once per verb). A
/// flag-parse or link error short-circuits to `Error(msg)` (exit non-zero); `k` receives only a
/// coherent binding.
///
/// The flag scoping (R13 · P12-05) is NOT enforced here: this passes the whole `axes` through so
/// each verb decides — a **build** verb honors `--link`/`--bindings`/`--out`, every other verb
/// calls `reject_link` + `reject_output_flags` to refuse them fail-closed. Enforcing scope
/// centrally would need the verb name, which the continuation already knows.
///
/// - `tokens`: the verb's arguments after the verb.
/// - `k`: the subcommand body, given the validated `binding`, the parsed `axes` (for the
///   per-verb `--link`/`--bindings`/`--out` scoping), and the positional operands.
pub fn with_binding(
  tokens: List(String),
  k: fn(Binding, Axes, List(String)) -> Result(String, String),
) -> Result(String, String) {
  use #(axes, positionals) <- result.try(split_axis_flags(tokens))
  use binding <- result.try(resolve_binding(
    base_binding(axes.base),
    axes.threaded,
    axes.trust_memory,
    axes.mem,
    axes.table,
    axes.cap,
  ))
  // `--inline-joins` (lever 6) is applied AFTER the fail-closed `link/1` validation in
  // `resolve_binding`: it is a pure compile-time codegen toggle, orthogonal to every policy/tier
  // axis the gate guards, so setting it here cannot change the validated posture.
  let binding = case axes.inline_joins {
    True -> Binding(..binding, inline_joins: True)
    False -> binding
  }
  k(binding, axes, positionals)
}

/// Refuse `--link` on a verb that does not support it (R13 — `--link` is scoped to the **build**
/// verb, the only one that writes a `.beam`), fail-closed so the flag can never silently no-op.
/// `use`-shaped: on `link == False` it runs the continuation `k`; on `link == True` it
/// short-circuits to a typed `Error` naming `verb`.
///
/// - `link`: the parsed `Axes.link` bit for this invocation.
/// - `verb`: the verb name for the diagnostic (e.g. `"emit"`).
/// - `k`: the rest of the subcommand body, run only when `--link` was NOT given.
pub fn reject_link(
  link: Bool,
  verb: String,
  k: fn() -> Result(String, String),
) -> Result(String, String) {
  case link {
    True ->
      Error(
        "--link is only valid on a build verb (one that writes a .beam), not "
        <> verb
        <> " (R13/O6)",
      )
    False -> k()
  }
}

/// Refuse `--bindings`/`--out` on a verb that does not support them (P12-05 — the folder-output
/// flags are scoped to the **build** verb), fail-closed so neither can silently no-op.
/// `use`-shaped: it runs `k` only when BOTH are unset (empty binding list + no `--out`), else
/// short-circuits to a typed `Error` naming `verb`.
///
/// - `axes`: the parsed axis flags for this invocation (its `bindings`/`out` fields are read).
/// - `verb`: the verb name for the diagnostic (e.g. `"emit"`).
/// - `k`: the rest of the subcommand body, run only when neither output flag was given.
pub fn reject_output_flags(
  axes: Axes,
  verb: String,
  k: fn() -> Result(String, String),
) -> Result(String, String) {
  case axes.bindings, axes.out {
    [], None -> k()
    _, _ ->
      Error(
        "--bindings/--out are only valid on a build verb, not "
        <> verb
        <> " (P12-05)",
      )
  }
}

// ───────────────────────── Phase 11 · P11-04 — the `--link` fail-closed gate ─────────────────────────

/// Why the pre-link gate refuses a `--link` build (R13/R14). Each is a fail-closed refusal
/// surfaced as a non-zero-exit CLI error, NEVER a silent downgrade to a non-linked or
/// bare-node-broken artifact. The gate is a CLI/linker-boundary check (R13) — it is NOT folded
/// into `profiles.link/1`, which is runtime instantiation and legitimately admits the shapes
/// rejected here for the ordinary (non-`--link`) build path.
pub type LinkGateError {
  /// The linear-memory tier is tier-N (`Nif`): native code cannot be merged into a `.beam`
  /// (O4/O8), and its C ceiling does not exist yet. DISTINCT from `profiles.SafeForbidsNif` —
  /// this fires for tier-N under ANY mode (Unsafe+Nif too), because "no NIF under `--link`" is a
  /// packaging constraint, not a runtime-posture one.
  LinkTierNif
  /// The module declares ≥1 import → it compiles to `instantiate/1(Imports)`, which needs
  /// providers a bare node lacks (R14). `count` is the number of declared imports (diagnostic).
  /// Conservative superset: rejects even an import that is never called (whose arity would in
  /// fact stay 0) — fail-closed.
  LinkImportBearing(count: Int)
}

/// Fail-closed gate run BEFORE a `--link` build (R13/R14). Two checks, in order:
///   1. `Error(LinkTierNif)` iff `binding.mem_tier == Nif` — input-independent; deliberately NOT
///      delegated to `profiles.link/1` (R13), which legitimately ADMITS Unsafe+Nif for the
///      non-linked path.
///   2. `Error(LinkImportBearing(n))` iff `m.imports != []` — any import decl means unmet
///      external providers on a bare node (conservative: also rejects import-but-uncalled).
/// Returns `Ok(Nil)` for a tier-P/O, import-free module. Total; reads only build-time fields, so
/// it is testable without spawning a process.
///
/// - `binding`: the resolved, `profiles.link`-validated build binding (its `mem_tier` is the
///   declared linear-memory trust tier).
/// - `m`: the source `ir.Module` (its `imports` field carries the import decls).
pub fn link_gate(binding: Binding, m: ir.Module) -> Result(Nil, LinkGateError) {
  case binding.mem_tier {
    Nif -> Error(LinkTierNif)
    _ ->
      case m.imports {
        [] -> Ok(Nil)
        imports -> Error(LinkImportBearing(list.length(imports)))
      }
  }
}

/// Human-readable rendering of a `LinkGateError` for CLI stderr (mirrors `describe_link_error/1`).
/// Diagnostic only; total.
pub fn describe_link_gate_error(e: LinkGateError) -> String {
  case e {
    LinkTierNif ->
      "--link cannot merge the nif memory tier (tier-N runs native code that cannot be baked into a .beam); --link supports tier-P/O only (name a non-nif --tier)"
    LinkImportBearing(n) ->
      "--link cannot link an import-bearing module ("
      <> int.to_string(n)
      <> " import(s)): a bare node has no providers for the external imports"
  }
}

// ───────────────────────── the run/invoke value convention (D5/T8) ─────────────────────────

/// Parse each `run`/`exec` argument string as a decimal integer (a raw unsigned bit pattern,
/// D5 — an i32 `-1` is written `4294967295`). Returns `Error` naming the first non-integer
/// token. Total.
pub fn parse_args(arg_strs: List(String)) -> Result(List(Int), String) {
  list.try_map(arg_strs, fn(s) {
    int.parse(s) |> result.replace_error("not an integer argument: " <> s)
  })
}

/// Render a result value list as space-separated decimals (`[5] → "5"`, `[] → ""`). Every
/// frontend's `run` and carder's `exec` print through this, so the same result renders
/// identically whichever binary produced it. Total.
pub fn format_values(values: List(Int)) -> String {
  values |> list.map(int.to_string) |> string.join(" ")
}

/// Render an uncaught exception for CLI stderr — DISTINCT from a trap (T8): the throwing tag's
/// module-local index + its operand payload. Diagnostic only; total.
pub fn format_uncaught(tag_id: Int, payload: List(Int)) -> String {
  "uncaught exception: tag "
  <> int.to_string(tag_id)
  <> " payload "
  <> string.inspect(payload)
}

// ───────────────────────── file IO with one shared diagnostic wording ─────────────────────────

/// Read a file's raw bytes, mapping any IO error to the shared `"read <path>: …"` diagnostic.
/// Total.
pub fn read_bits(path: String) -> Result(BitArray, String) {
  simplifile.read_bits(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// Read a file's UTF-8 text, mapping any IO error to the shared `"read <path>: …"` diagnostic.
/// Total.
pub fn read_text(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// Write a compiled `.beam` binary to `output`, mapping an IO error to a CLI diagnostic and
/// returning the `"wrote <output>"` confirmation on success. Shared by every build verb (linked
/// and non-linked, in carder and in each frontend) so all of them report identically. Total.
pub fn write_beam(output: String, beam: BitArray) -> Result(String, String) {
  case simplifile.write_bits(output, beam) {
    Error(fe) ->
      Error("write " <> output <> ": " <> simplifile.describe_error(fe))
    Ok(Nil) -> Ok("wrote " <> output)
  }
}

// ───────────────────────── shared usage text ─────────────────────────

/// The `[axes]` block of the usage text, documenting the flags `split_axis_flags` parses.
/// Every frontend CLI splices this into its own usage so the two can never drift from the one
/// parser. Returned WITHOUT a trailing newline; callers join it with their own verb table.
pub fn axes_usage() -> String {
  string.join(
    [
      "  [axes] — profile / strategy / tier selection (default: Safe / Cell / Paged, fail-closed):",
      "    base (one of):  --unsafe | --portable | --ceiling | --engine",
      "    --engine        Safe + Atomics memory/table + Cell (fast node-safe trusted-engine profile)",
      "    --threaded                state_strategy: Threaded (the record-threading run-ABI)",
      "    --trust-memory            skip bounds checks on ALL memory-0 loads/stores for a trusted",
      "                              guest (paged/atomics only; OOB → wrong value, not a trap)",
      "    --inline-joins            inline single-use, non-recursive letrec join funs (lever 6):",
      "                              smaller emitted Core/.beam for a large guest; on by default under",
      "                              --engine (a pure semantics-preserving Core rewrite)",
      "    --tier paged|atomics|nif  linear-memory trust tier (nif is Unsafe-only)",
      "    --table-tier paged|ets|atomics   funcref-table trust tier",
      "    --cap PAGES               bounded page cap (required to engage atomics / --ceiling)",
      "    --link                    (build verbs only) merge the runtime closure into one",
      "                              self-contained .beam; tier-P/O + import-free only, else rejected",
      "    --bindings <langs>        (build verbs only, with --out) emit typed host bindings —",
      "                              a comma list of gleam|erlang|elixir; requires --threaded",
      "    --out <dir>               (build verbs only) write <dir>/<module-atom>.beam + the binding",
      "                              files into <dir>",
      "  A non-default posture must be NAMED; Safe + --tier nif and an uncapped atomics/ceiling",
      "  build are rejected fail-closed (exit non-zero), never silently downgraded.",
      "Values are raw unsigned bit patterns in decimal (i32 -1 is 4294967295).",
    ],
    "\n",
  )
}
