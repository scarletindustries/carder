//// Unit 11c — the 2core **CLI**, exposing EVERY pipeline stage independently (high-level
//// decision #5) plus the end-to-end `run`. `gleam run -- <subcommand> …` dispatches here.
////
//// The stage wiring and per-stage error mapping (D4) live in `twocore/pipeline`; this
//// module only does argument parsing, file IO, and printing. Every subcommand is total:
//// bad input prints its typed error to **stderr** and the process halts **non-zero**
//// (`halt(1)`) — it never panics.
////
//// ## Subcommands
////
//// | Subcommand                         | Pipeline                                              |
//// |------------------------------------|-------------------------------------------------------|
//// | `decode   <in.wasm>`               | decode → print the WASM AST                            |
//// | `validate <in.wasm>`               | decode → validate → print `valid`                     |
//// | `lower    <in.wasm>` (= `to-ir`,`ir`) | decode → validate → lower(10) → print `.ir`        |
//// | `ir-lower <in.ir>`                 | parse `.ir` → ir_lower(Safe) → print `.ir`            |
//// | `opt      <in.ir> [--unsafe]`      | parse `.ir` → optimize_ir(profile) → print `.ir`      |
//// | `emit     <in.ir> [--unsafe]`      | parse `.ir` → emit_core(profile) → print `.core`      |
//// | `to-core  <in.ir> [--unsafe]`      | parse `.ir` → ir_lower → optimize → emit_core → `.core` |
//// | `to-beam  <in.core> [out.beam]` (= `build`) | parse+build `.core` → write `.beam` (no profile) |
//// | `run      [axes] <in.wasm> <export> <args…>` | source → … → ir_lower → optimize → load → invoke → print |
////
//// ## Phase-4 axis flags (decision #5 — every posture is a NAMED token; fail-closed default)
////
//// The compile verbs (`run`/`to-core`/`emit`/`to-beam-wasm`) accept orthogonal axis flags on
//// top of the Phase-3 `--unsafe` policy flag; the default is the fail-closed **Safe / `Cell` /
//// `Paged`** posture (leaving it requires NAMING a flag). `resolve_binding` composes them into
//// one coherent `Binding` and validates it through `profiles.link/1` (the sole `Binding →
//// Instance` seam), so an incoherent posture (`Safe` + `nif` memory, or an uncapped `atomics`/
//// `ceiling` build) is rejected fail-closed (exit non-zero), never silently downgraded:
////   - `--portable` / `--ceiling` — a composed deployment profile (base).
////   - `--unsafe` — the Phase-3 Unsafe policy (base).
////   - `--threaded` — `state_strategy: Threaded` (the record-threading run-ABI).
////   - `--trust-memory` — `trust_memory: True` (lever 3): route ALL memory-0 loads/stores through
////     the bounds-check-free seam for a trusted guest — paged/atomics only; OOB yields a wrong
////     value instead of trapping. Composable with any base.
////   - `--inline-joins` — `inline_joins: True` (lever 6): inline single-use, non-recursive `letrec`
////     join funs (a pure semantics-preserving Core rewrite that shrinks the emitted Core/`.beam`
////     for a large guest). Composable with any base; already on under `--engine`.
////   - `--tier paged|atomics|nif` — the linear-memory trust tier (`nif` is Unsafe-only).
////   - `--table-tier paged|ets|atomics` — the funcref-table trust tier.
////   - `--cap PAGES` — a bounded linear-memory page cap (required to engage `atomics`/`ceiling`).
//// `opt` keeps only `--unsafe` (it drives the optimizer, which reads no tier). `to-beam`/`build`
//// take **no** profile — they compile already-emitted `.core`, which carries no `Binding`.
////
//// ## Value convention (the run/invoke ABI — `pipeline.gleam`)
////
//// `run`'s arguments and results are **raw UNSIGNED bit patterns in decimal**: an i32 in
//// `[0, 2^32)`, an i64 in `[0, 2^64)`, a float as its raw IEEE-754 bits (D5). So
//// `gleam run -- run add.wasm add 2 3` prints `5`, and an i32 `-1` argument is written
//// `4294967295`. A trap (e.g. divide-by-zero) prints `trap: <reason>` to stderr and halts
//// non-zero — a trap is a runtime outcome, surfaced as a CLI failure.

import argv
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import twocore/backend/beam_link
import twocore/backend/bindings
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/ir/printer as ir_printer
import twocore/pipeline
import twocore/runtime/instance.{
  type Binding, type MemTier, type TableTier, Atomics, Binding, Nif, Paged,
  TableAtomics, TableEts, TablePaged, Threaded,
}
import twocore/runtime/profiles
import twocore/runtime/rt_mem_atomics

/// CLI entry point. Reads the subcommand + operands from `argv`, runs the matching stage,
/// and prints the result to stdout (exit 0) or the typed error to stderr (exit non-zero).
/// Never panics on bad input.
pub fn main() -> Nil {
  case run(argv.load().arguments) {
    Ok(out) -> io.println(out)
    Error(msg) -> {
      io.println_error(msg)
      halt(1)
    }
  }
}

/// `erlang:halt/1` — stop the VM with exit status `code`. Used to make a failing subcommand
/// exit non-zero. Never returns (typed generically so the caller's `case` arms unify).
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> a

/// Dispatch a parsed argument vector to its subcommand, returning the text to print on
/// success or the diagnostic to print to stderr on failure. Pure of IO except the file
/// reads/writes each subcommand performs; total — an unrecognised command yields the usage
/// text as `Error`. Exposed so CLI behaviour is unit-testable without spawning a process.
pub fn run(args: List(String)) -> Result(String, String) {
  case args {
    ["decode", path] -> cmd_decode(path)
    ["validate", path] -> cmd_validate(path)
    ["lower", path] | ["to-ir", path] | ["ir", path] -> cmd_to_ir(path)
    ["ir-lower", path] -> cmd_ir_lower(path)
    ["opt", "--unsafe", path] -> cmd_opt(path, profiles.unsafe())
    ["opt", path] -> cmd_opt(path, profiles.safe())
    ["emit", ..rest] ->
      with_binding(rest, fn(binding, axes, pos) {
        use <- reject_link(axes.link, "emit")
        use <- reject_output_flags(axes, "emit")
        case pos {
          [path] -> cmd_emit(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-core", ..rest] ->
      with_binding(rest, fn(binding, axes, pos) {
        use <- reject_link(axes.link, "to-core")
        use <- reject_output_flags(axes, "to-core")
        case pos {
          [path] -> cmd_to_core(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-beam", ..rest] | ["build", ..rest] ->
      // R13: the `.core`-input verbs carry no `Binding`/profile, so `--link` cannot be gated
      // (tier-N / import-bearing are undecidable here). Reject the token explicitly rather than
      // silently no-op it or mistake it for a positional path.
      case list.contains(rest, "--link") {
        True ->
          Error(
            "--link is only valid on to-beam-wasm; the .core-input to-beam/build verbs carry no Binding to gate (R13)",
          )
        False ->
          case rest {
            [input] -> cmd_to_beam(input, default_beam(input))
            [input, output] -> cmd_to_beam(input, output)
            _ -> Error(usage())
          }
      }
    ["to-beam-wasm", ..rest] ->
      with_binding(rest, fn(binding, axes, pos) {
        cmd_to_beam_wasm(binding, axes.link, axes.bindings, axes.out, pos)
      })
    ["run", ..rest] ->
      with_binding(rest, fn(binding, axes, pos) {
        use <- reject_link(axes.link, "run")
        use <- reject_output_flags(axes, "run")
        case pos {
          [path, export, ..arg_strs] -> cmd_run(path, export, arg_strs, binding)
          _ -> Error(usage())
        }
      })
    ["exec", "-n", n, path, export, ..arg_strs]
    | ["exec", "--repeat", n, path, export, ..arg_strs] ->
      cmd_exec(path, export, arg_strs, n)
    ["exec", path, export, ..arg_strs] -> cmd_exec(path, export, arg_strs, "1")
    _ -> Error(usage())
  }
}

// ───────────────────────── Phase-4 axis selection (decision #5) ─────────────────────────

/// Which base profile the mutually-exclusive base flags select (§B.1). `BaseSafe` is the
/// fail-closed default (no base flag given): there is no `--safe` token, so `BaseSafe` always
/// means "unset", which lets `set_base` reject a second base flag.
type BaseSel {
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
/// - `link`: `True` iff `--link` was named (Phase 11 · P11-04). It is ORTHOGONAL to the
///   posture/tier axes and defaults to `False` — absent, output is byte-identical to today. It is
///   consumed ONLY by `to-beam-wasm` (R13); every other compile verb rejects `link == True`
///   fail-closed so the flag can never silently no-op.
/// - `bindings`: the `--bindings <langs>` selection (Phase 12 · P12-05), a canonical deduped list
///   (default `[]` = none). Consumed ONLY by `to-beam-wasm`; the binding-flag-irrelevant verbs
///   reject a non-empty selection via `reject_output_flags`.
/// - `out`: the `--out <dir>` folder (Phase 12 · P12-05), `None` when absent. Absent both flags ⇒
///   `to-beam-wasm` behaves byte-identically to today; consumed ONLY by `to-beam-wasm`.
type Axes {
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
/// Recognised flags: `--portable`/`--ceiling`/`--unsafe` (mutually-exclusive base — at most
/// one), `--threaded`, `--trust-memory`, `--link`, `--tier <t>`, `--table-tier <t>`, `--cap <pages>`,
/// `--bindings <langs>` (P12-05), `--out <dir>` (P12-05). A `--tier`/`--table-tier`/`--cap`/
/// `--bindings`/`--out` with no following value, an unknown `--flag`, an unrecognised tier or
/// language token, a non-integer cap, a second base/`--bindings`/`--out` flag all yield
/// `Error(msg)` (fail-closed — the caller exits non-zero). Any non-`--` token is a positional.
/// `--link`/`--bindings`/`--out` only set their `Axes` fields here; whether each is HONORED or
/// REJECTED is decided per-verb by the caller (`--bindings`/`--out` are `to-beam-wasm`-only).
///
/// - `tokens`: the verb's arguments after the verb (e.g. `["--tier", "atomics", "f.wasm"]`).
/// - Returns `Ok(#(axes, positionals))` or `Error(msg)`.
fn split_axis_flags(
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
/// default; `--portable`/`--ceiling` are unit 07's composed profiles; `--unsafe` the Phase-3
/// policy profile.
fn base_binding(sel: BaseSel) -> Binding {
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
/// `twocore@runtime@*` names live in `profiles`/`instance`, never re-spelled here (D1).
///
/// Routing through `link/1` (rather than `validate_binding` directly) makes `link/1` the ONE
/// sanctioned path from a `Binding` to a `profiles.Instance` in this module — the ungated
/// `profiles.instantiate/1` is never called here — so the fail-closed gate cannot be bypassed
/// (§A sole-seam lock); the validated `Instance`'s `.binding` (which `link` has run
/// `resolve_tiers` over) is unwrapped as the coherent build binding.
///
/// - `base`: the profile chosen by `--portable`/`--ceiling`/`--unsafe`/(default `safe()`).
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
fn describe_link_error(e: profiles.LinkError) -> String {
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
/// alongside the parsed `--link` bit and the positional operands. The single wiring point where
/// the axis flags become a validated `Binding` (so the fail-closed gate runs once per verb). A
/// flag-parse or link error short-circuits to `Error(msg)` (exit non-zero); `k` receives only a
/// coherent binding.
///
/// The flag scoping (R13 · P12-05) is NOT enforced here: this passes the whole `axes` through so
/// each verb decides — `to-beam-wasm` honors `--link`/`--bindings`/`--out`, every other verb calls
/// `reject_link` + `reject_output_flags` to refuse them fail-closed. Enforcing scope centrally would
/// need the verb name, which the continuation already knows.
///
/// - `tokens`: the verb's arguments after the verb.
/// - `k`: the subcommand body, given the validated `binding`, the parsed `axes` (for the per-verb
///   `--link`/`--bindings`/`--out` scoping), and the positional operands.
fn with_binding(
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

/// Refuse `--link` on a verb that does not support it (R13 — `--link` is scoped to
/// `to-beam-wasm`), fail-closed so the flag can never silently no-op. `use`-shaped: on
/// `link == False` it runs the continuation `k`; on `link == True` it short-circuits to a typed
/// `Error` naming `verb`.
///
/// - `link`: the parsed `Axes.link` bit for this invocation.
/// - `verb`: the verb name for the diagnostic (e.g. `"emit"`).
/// - `k`: the rest of the subcommand body, run only when `--link` was NOT given.
fn reject_link(
  link: Bool,
  verb: String,
  k: fn() -> Result(String, String),
) -> Result(String, String) {
  case link {
    True ->
      Error("--link is only valid on to-beam-wasm, not " <> verb <> " (R13/O6)")
    False -> k()
  }
}

/// Refuse `--bindings`/`--out` on a verb that does not support them (P12-05 — the folder-output
/// flags are scoped to `to-beam-wasm`), fail-closed so neither can silently no-op. `use`-shaped: it
/// runs `k` only when BOTH are unset (empty binding list + no `--out`), else short-circuits to a
/// typed `Error` naming `verb`.
///
/// - `axes`: the parsed axis flags for this invocation (its `bindings`/`out` fields are read).
/// - `verb`: the verb name for the diagnostic (e.g. `"emit"`).
/// - `k`: the rest of the subcommand body, run only when neither output flag was given.
fn reject_output_flags(
  axes: Axes,
  verb: String,
  k: fn() -> Result(String, String),
) -> Result(String, String) {
  case axes.bindings, axes.out {
    [], None -> k()
    _, _ ->
      Error(
        "--bindings/--out are only valid on to-beam-wasm, not "
        <> verb
        <> " (P12-05)",
      )
  }
}

// ─────────────────────────────── subcommands ───────────────────────────────

/// `decode <in.wasm>` — decode the binary and dump the WASM AST (unit 05). Inspect text.
fn cmd_decode(path: String) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  case decode.decode(bytes) {
    Ok(m) -> Ok(string.inspect(m))
    Error(e) -> Error("decode: " <> string.inspect(e))
  }
}

/// `validate <in.wasm>` — decode then `full`-validate (unit 10a). Prints `valid` or the
/// rejecting stage's typed error.
fn cmd_validate(path: String) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  case decode.decode(bytes) {
    Error(e) -> Error("decode: " <> string.inspect(e))
    Ok(m) ->
      case validate.validate(m) {
        Error(e) -> Error("validate: " <> string.inspect(e))
        Ok(_typed) -> Ok("valid")
      }
  }
}

/// `lower`/`to-ir`/`ir <in.wasm>` — decode → validate → frontend-lower → print `.ir`
/// (unit 02's printer). The source→IR end-to-end view.
fn cmd_to_ir(path: String) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  case pipeline.source_to_ir(bytes) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m) -> Ok(ir_printer.print_module(m))
  }
}

/// `ir-lower <in.ir>` — parse `.ir` (unit 02) → run the Safe policy pass (unit 11a) →
/// print the rewritten `.ir` (CallHosts gated, metering inserted).
fn cmd_ir_lower(path: String) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) ->
      case pipeline.lower_ir(m, profiles.safe()) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(lowered) -> Ok(ir_printer.print_module(lowered))
      }
  }
}

/// `opt <in.ir> [--unsafe]` — parse `.ir` (unit 02) → run the optimizer stage ALONE at the
/// selected profile's `opt_level` (Safe ⇒ Baseline, Unsafe ⇒ Aggressive) → print the
/// optimized `.ir`. The independently-driveable optimizer stage (decision #5). The output is
/// always valid `.ir` that re-parses (F2 — the optimizer produces well-formed IR); at
/// `OptNone`/freeze it is byte-identical to the input.
fn cmd_opt(path: String, binding: Binding) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) -> Ok(ir_printer.print_module(pipeline.optimize_ir(m, binding)))
  }
}

/// `emit <in.ir> [--unsafe]` — parse `.ir` → `emit_core` ALONE (no policy pass, no optimizer)
/// → print `.core`. The finer backend-only stage, for inspecting raw codegen. Because
/// `emit_core` bodies are posture-agnostic (A.1), the `.core` is identical with or without
/// `--unsafe` in every function body — differing ONLY in `instantiate/0`'s seed lines.
fn cmd_emit(path: String, binding: Binding) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) ->
      case emit_core.emit_module(m, binding) {
        Error(e) -> Error("emit: " <> string.inspect(e))
        Ok(cmod) -> Ok(core_printer.print_module(cmod))
      }
  }
}

/// `to-core <in.ir> [--unsafe]` — parse `.ir` → ir_lower → optimize → emit_core → print
/// `.core` (the policy pass + optimizer ARE in this chain, unlike `emit`). Under `--unsafe`
/// the `.core` differs from Safe by exactly the `charge` lines plus `instantiate/0`'s seed
/// lines (F5, §A.4).
fn cmd_to_core(path: String, binding: Binding) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) ->
      case pipeline.ir_to_core(m, binding) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(core) -> Ok(core)
      }
  }
}

/// `to-beam`/`build <in.core> [out.beam]` — compile `.core` to a `.beam` binary (unit 04)
/// and write it to `output`. Prints a confirmation line.
fn cmd_to_beam(input: String, output: String) -> Result(String, String) {
  use text <- result.try(read_text(input))
  case build_beam.compile_core(bit_array.from_string(text)) {
    Error(e) -> Error("build: " <> string.inspect(e))
    Ok(#(_mod_atom, beam)) ->
      case simplifile.write_bits(output, beam) {
        Error(fe) ->
          Error("write " <> output <> ": " <> simplifile.describe_error(fe))
        Ok(Nil) -> Ok("wrote " <> output)
      }
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
fn describe_link_gate_error(e: LinkGateError) -> String {
  case e {
    LinkTierNif ->
      "--link cannot merge the nif memory tier (tier-N runs native code that cannot be baked into a .beam); --link supports tier-P/O only (name a non-nif --tier)"
    LinkImportBearing(n) ->
      "--link cannot link an import-bearing module ("
      <> int.to_string(n)
      <> " import(s)): a bare node has no providers for the external imports"
  }
}

/// Human-readable rendering of a `beam_link.LinkError` for CLI stderr — the user-facing face of
/// the whole-program linker's fail-closed refusals (P11-03). DISTINCT from `describe_link_error/1`
/// (which renders `profiles.LinkError`, the runtime-binding gate). Diagnostic only; total.
fn describe_beam_link_error(e: beam_link.LinkError) -> String {
  case e {
    beam_link.OffAllowlistRemote(m, f) ->
      "link failed: a call to "
      <> m
      <> ":"
      <> f
      <> " survived to a module outside the OTP-ambient allowlist (missing from the merged closure)"
    beam_link.MissingClosureModule(m) ->
      "link failed: the in-closure module "
      <> m
      <> " could not be located (its .beam was not on the code path)"
    beam_link.AmbientAuthorityFound(detail) ->
      "link failed: refusing to bake ambient authority into the artifact (D3a): "
      <> detail
    beam_link.UnmergeableConstruct(detail) ->
      "link failed: a closure module carries a construct that cannot be merged into a .beam: "
      <> detail
    beam_link.MangleCollision(a, b) ->
      "link failed: mangle-injectivity violated (a module atom contains \"__\"): "
      <> a
      <> " / "
      <> b
    beam_link.MalformedCore(detail) ->
      "link failed: malformed Core Erlang: " <> detail
    beam_link.CoreAcquisitionFailed(m, reason) ->
      "link failed: could not acquire Core for " <> m <> ": " <> reason
  }
}

/// `to-beam-wasm [axes] [--link] [--bindings <langs> --out <dir>] <in.wasm> [<out.beam>]` — compile
/// a `.wasm` to a `.beam` under the selected profile (Safe = Baseline optimizer + enforcing fuel;
/// `--unsafe` = Aggressive optimizer + `MeterOff` + open runtime), and optionally emit typed
/// companion host-language bindings (Phase 12 · P12-05). Prints a confirmation line.
///
/// Branches on `#(out, positionals)` — the two positional forms are mutually exclusive:
/// - **LEGACY** (`out == None`, two positionals `<in> <out.beam>`): today's path EXACTLY
///   (`legacy_to_beam_wasm`) — byte-identical to before P12-05 (no directory, `describe` never
///   reached). `--bindings` here is an error (it needs the `--out` folder). Wrong positional arity
///   is the usage error.
/// - **FOLDER** (`out == Some(dir)`, one positional `<in>`): compile+emit into `dir` — lower ONCE
///   (R17), write `<dir>/<module.name>.beam` + one companion file per requested language. Two-or-more
///   positionals is an error (the `.beam` name derives from the module atom, not a positional).
///
/// `--bindings` requires `--threaded` (the default `Cell` binding has no typed-binding surface this
/// phase — `describe` rejects it with the R12 "re-run with `--threaded`" hint). Composes with
/// `--link` on both paths.
///
/// - `binding`: the resolved build binding.
/// - `link`: the `--link` bit (P11-04) — merge the runtime closure into one self-contained `.beam`.
/// - `langs`: the `--bindings` selection (canonical/deduped; `[]` = none).
/// - `out`: the `--out <dir>` folder (`None` = legacy two-positional mode).
/// - `positionals`: the verb's positional operands.
fn cmd_to_beam_wasm(
  binding: Binding,
  link: Bool,
  langs: List(bindings.BindingLang),
  out: Option(String),
  positionals: List(String),
) -> Result(String, String) {
  case out, positionals {
    // LEGACY — the exact two-positional path (byte-identical); `--bindings` needs `--out`.
    None, [input, output] ->
      case langs {
        [] -> legacy_to_beam_wasm(input, output, binding, link)
        _ ->
          Error(
            "--bindings requires --out <dir> (the companion binding files are written into a folder alongside the .beam)",
          )
      }
    None, _ -> Error(usage())
    // FOLDER — one positional; the .beam name derives from the module atom.
    Some(dir), [input] -> folder_to_beam_wasm(input, dir, binding, link, langs)
    Some(_), _ ->
      Error(
        "with --out, pass only <in.wasm>; the .beam name derives from the module atom (twocore@wasm@<base>.beam)",
      )
  }
}

/// The LEGACY `to-beam-wasm` body (P11-04, unchanged) — `source_to_ir → ir_to_core → core_to_beam →
/// write` (or the `--link` merge). Extracted verbatim so the two-positional path stays
/// byte-identical (proven by `cli_link_flag_test.default_off_byte_identical_test`).
fn legacy_to_beam_wasm(
  input: String,
  output: String,
  binding: Binding,
  link: Bool,
) -> Result(String, String) {
  use bytes <- result.try(read_bits(input))
  case pipeline.source_to_ir_with(bytes, binding.narrow_carried) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m) ->
      case link {
        False ->
          case pipeline.ir_to_core(m, binding) {
            Error(e) -> Error(pipeline.describe(e))
            Ok(core) ->
              case pipeline.core_to_beam(core, m.name) {
                Error(e) -> Error(pipeline.describe(e))
                Ok(beam) -> write_beam(output, beam)
              }
          }
        True ->
          case link_gate(binding, m) {
            Error(ge) -> Error(describe_link_gate_error(ge))
            Ok(Nil) ->
              case pipeline.ir_to_core(m, binding) {
                Error(e) -> Error(pipeline.describe(e))
                Ok(core) ->
                  case
                    build_beam.link_beam(bit_array.from_string(core), m.name)
                  {
                    Error(le) -> Error(describe_beam_link_error(le))
                    Ok(#(_atom, beam)) -> write_beam(output, beam)
                  }
              }
          }
      }
  }
}

/// The FOLDER `to-beam-wasm` path (P12-05): compile `<input>` into `<dir>`, emitting the `.beam` +
/// one typed companion binding per requested language. The R17 lower-ONCE seam is the crux —
/// `pipeline.ir_to_lowered_core` lowers+optimizes ONCE and returns BOTH the module and its `.core`;
/// the SAME lowered module is handed to `bindings.emit_bindings` (which runs `iface.describe` over
/// it) while its `.core` becomes the `.beam`. So `describe` and the `.beam` ABI see identical bodies
/// — a mutation-carrying export cannot be misclassified pure (dropping `St'`). Fail-closed: a
/// rejected module (Cell / import-bearing / mutable-tier) writes NOTHING (describe runs before any
/// IO); a link-gate/link failure surfaces before emit.
///
/// - `input`: the `.wasm` source path.
/// - `dir`: the `--out` output folder (created if absent).
/// - `binding`: the resolved build binding (must be Threaded + Paged/TablePaged for `--bindings`).
/// - `link`: the `--link` bit — merge the runtime closure into the emitted `.beam`.
/// - `langs`: the requested target languages (`[]` = write only the `.beam`, no describe/emit).
fn folder_to_beam_wasm(
  input: String,
  dir: String,
  binding: Binding,
  link: Bool,
  langs: List(bindings.BindingLang),
) -> Result(String, String) {
  use bytes <- result.try(read_bits(input))
  use m <- result.try(
    pipeline.source_to_ir_with(bytes, binding.narrow_carried)
    |> result.map_error(pipeline.describe),
  )
  // R17: lower + optimize ONCE; the returned `lowered` module is exactly what the `.core` (hence the
  // `.beam`) is generated from, and it is what `emit_bindings` runs `describe` over.
  use #(lowered, core) <- result.try(
    pipeline.ir_to_lowered_core(m, binding)
    |> result.map_error(pipeline.describe),
  )
  use beam <- result.try(beam_of_lowered(core, lowered, binding, link))
  case bindings.emit_bindings(lowered, binding, beam, dir, langs) {
    Error(be) -> Error(bindings.describe_error(be))
    Ok(paths) -> Ok("wrote " <> string.join(paths, ", "))
  }
}

/// Compile lowered `.core` text into the `.beam` bytes for the FOLDER path, honoring `--link`. With
/// `link == False` it is a plain `core_to_beam`; with `link == True` it runs the fail-closed
/// `link_gate` (tier-N / import-bearing) then merges the runtime closure via `build_beam.link_beam`.
/// Returns the bytes or the rendered CLI diagnostic. `mod`'s `.name`/`.imports` drive the gate + the
/// baked module atom (it is the SAME lowered module `describe` sees).
fn beam_of_lowered(
  core: String,
  mod: ir.Module,
  binding: Binding,
  link: Bool,
) -> Result(BitArray, String) {
  case link {
    False ->
      pipeline.core_to_beam(core, mod.name)
      |> result.map_error(pipeline.describe)
    True ->
      case link_gate(binding, mod) {
        Error(ge) -> Error(describe_link_gate_error(ge))
        Ok(Nil) ->
          case build_beam.link_beam(bit_array.from_string(core), mod.name) {
            Error(le) -> Error(describe_beam_link_error(le))
            Ok(#(_atom, beam)) -> Ok(beam)
          }
      }
  }
}

/// Write a compiled `.beam` binary to `output`, mapping an IO error to a CLI diagnostic and
/// returning the `"wrote <output>"` confirmation on success. Shared by the linked and non-linked
/// `to-beam-wasm` branches so both report identically.
fn write_beam(output: String, beam: BitArray) -> Result(String, String) {
  case simplifile.write_bits(output, beam) {
    Error(fe) ->
      Error("write " <> output <> ": " <> simplifile.describe_error(fe))
    Ok(Nil) -> Ok("wrote " <> output)
  }
}

/// `run [--unsafe] <in.wasm> <export> <args…>` — compile through the selected profile's
/// pipeline and invoke `export` on the BEAM (D10). Prints the result value(s) (raw bit
/// patterns, space-separated); a trap prints `trap: <reason>` as an error (exit non-zero).
/// `binding` is `profiles.unsafe()` under `--unsafe`, else the fail-closed `profiles.safe()`.
fn cmd_run(
  path: String,
  export: String,
  arg_strs: List(String),
  binding: Binding,
) -> Result(String, String) {
  use bytes <- result.try(read_bits(path))
  use args <- result.try(parse_args(arg_strs))
  case pipeline.run_source(bytes, binding, export, args) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(pipeline.Returned(values)) -> Ok(format_values(values))
    Ok(pipeline.Trapped(reason)) -> Error("trap: " <> reason)
    Ok(pipeline.UncaughtException(tag_id, payload)) ->
      Error(format_uncaught(tag_id, payload))
  }
}

/// Render an uncaught WASM exception for CLI stderr — DISTINCT from a trap (T8): the throwing
/// tag's module-local index + its operand payload. Diagnostic only.
fn format_uncaught(tag_id: Int, payload: List(Int)) -> String {
  "uncaught exception: tag "
  <> int.to_string(tag_id)
  <> " payload "
  <> string.inspect(payload)
}

/// `exec [-n COUNT] <in.beam> <export> <args…>` — load a PREBUILT `.beam` (no compile step)
/// and invoke `export` on the BEAM `COUNT` times (default 1), timing only the invocations. For
/// benchmarking the emitted code in isolation. Prints the (last) result value(s) then a timing
/// line; a trap prints `trap: <reason>` (exit non-zero).
fn cmd_exec(
  path: String,
  export: String,
  arg_strs: List(String),
  count_str: String,
) -> Result(String, String) {
  use beam <- result.try(read_bits(path))
  use args <- result.try(parse_args(arg_strs))
  use repeat <- result.try(parse_count(count_str))
  case pipeline.exec_beam(beam, export, args, repeat) {
    Error(e) -> Error(e)
    Ok(#(_micros, pipeline.Trapped(reason))) -> Error("trap: " <> reason)
    Ok(#(_micros, pipeline.UncaughtException(tag_id, payload))) ->
      Error(format_uncaught(tag_id, payload))
    Ok(#(micros, pipeline.Returned(values))) ->
      Ok(format_values(values) <> "\n" <> timing_line(repeat, micros))
  }
}

// ─────────────────────────────── helpers ───────────────────────────────

/// Render the `exec` benchmark timing: total microseconds and nanoseconds-per-call.
fn timing_line(repeat: Int, micros: Int) -> String {
  let ns_per = micros * 1000 / repeat
  int.to_string(repeat)
  <> " call(s) · "
  <> int.to_string(micros)
  <> " us total · "
  <> int.to_string(ns_per)
  <> " ns/call"
}

/// Parse the `exec -n` repeat count — a positive integer.
fn parse_count(s: String) -> Result(Int, String) {
  case int.parse(s) {
    Ok(n) if n >= 1 -> Ok(n)
    _ -> Error("-n expects a positive integer, got: " <> s)
  }
}

/// Parse each `run` argument string as a decimal integer (a raw unsigned bit pattern).
/// Returns `Error` naming the first non-integer token.
fn parse_args(arg_strs: List(String)) -> Result(List(Int), String) {
  list.try_map(arg_strs, fn(s) {
    int.parse(s) |> result.replace_error("not an integer argument: " <> s)
  })
}

/// Render a result value list as space-separated decimals (`[5] → "5"`, `[] → ""`).
fn format_values(values: List(Int)) -> String {
  values |> list.map(int.to_string) |> string.join(" ")
}

/// Default `.beam` output path for `to-beam`: swap a trailing `.core` for `.beam`, else
/// append `.beam`.
fn default_beam(input: String) -> String {
  case string.ends_with(input, ".core") {
    True -> string.drop_end(input, 5) <> ".beam"
    False -> input <> ".beam"
  }
}

/// Read a file's raw bytes, mapping any IO error to a diagnostic string.
fn read_bits(path: String) -> Result(BitArray, String) {
  simplifile.read_bits(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// Read a file's UTF-8 text, mapping any IO error to a diagnostic string.
fn read_text(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// The usage text printed (to stderr) for an unrecognised invocation.
fn usage() -> String {
  string.join(
    [
      "2core — WASM → Core Erlang compiler (Phase 4). Usage:",
      "  gleam run -- decode   <in.wasm>                 dump the WASM AST",
      "  gleam run -- validate <in.wasm>                 full-validate; print 'valid'",
      "  gleam run -- lower    <in.wasm>                 source → .ir (alias: to-ir, ir)",
      "  gleam run -- ir-lower <in.ir>                   Safe policy pass → .ir",
      "  gleam run -- opt      <in.ir> [--unsafe]        optimizer stage → .ir (Safe=Baseline, Unsafe=Aggressive)",
      "  gleam run -- emit     <in.ir> [axes]            emit_core only → .core",
      "  gleam run -- to-core  <in.ir> [axes]            ir_lower + optimize + emit_core → .core",
      "  gleam run -- to-beam  <in.core> [out.beam]      compile → .beam (alias: build; no profile)",
      "  gleam run -- to-beam-wasm [axes] [--link] <in.wasm> <out.beam>  .wasm → .beam under a profile (bench)",
      "  gleam run -- to-beam-wasm [axes] --bindings <langs> --out <dir> <in.wasm>  + typed host bindings",
      "  gleam run -- run      [axes] <in.wasm> <export> <args…>  compile + invoke on the BEAM",
      "  gleam run -- exec     [-n N] <in.beam> <export> <args…>  invoke a prebuilt .beam (bench, no compile)",
      "",
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
      "    --link                    (to-beam-wasm only) merge the runtime closure into one",
      "                              self-contained .beam; tier-P/O + import-free only, else rejected",
      "    --bindings <langs>        (to-beam-wasm only, with --out) emit typed host bindings —",
      "                              a comma list of gleam|erlang|elixir; requires --threaded",
      "    --out <dir>               (to-beam-wasm only) write <dir>/<module-atom>.beam + the binding",
      "                              files into <dir> (pass only <in.wasm>; the .beam name is derived)",
      "  A non-default posture must be NAMED; Safe + --tier nif and an uncapped atomics/ceiling",
      "  build are rejected fail-closed (exit non-zero), never silently downgraded.",
      "  opt takes only --unsafe; to-beam/build take no profile (they compile .core — no Binding).",
      "Values are raw unsigned bit patterns in decimal (i32 -1 is 4294967295).",
    ],
    "\n",
  )
}
