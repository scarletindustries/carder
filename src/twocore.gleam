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
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/validate
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
      with_binding(rest, fn(binding, pos) {
        case pos {
          [path] -> cmd_emit(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-core", ..rest] ->
      with_binding(rest, fn(binding, pos) {
        case pos {
          [path] -> cmd_to_core(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-beam", input] | ["build", input] ->
      cmd_to_beam(input, default_beam(input))
    ["to-beam", input, output] | ["build", input, output] ->
      cmd_to_beam(input, output)
    ["to-beam-wasm", ..rest] ->
      with_binding(rest, fn(binding, pos) {
        case pos {
          [input, output] -> cmd_to_beam_wasm(input, output, binding)
          _ -> Error(usage())
        }
      })
    ["run", ..rest] ->
      with_binding(rest, fn(binding, pos) {
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
}

/// A parsed axis-flag set: the CLI's requested profile/strategy/tier selection (§B). Each
/// field is set by an EXPLICIT named token — the fail-closed default (`BaseSafe`, no overrides)
/// is the value with no flags. `None` on `mem`/`table`/`cap` means "keep the base profile's".
type Axes {
  Axes(
    base: BaseSel,
    threaded: Bool,
    mem: Option(MemTier),
    table: Option(TableTier),
    cap: Option(Int),
  )
}

/// Parse a compile verb's tokens into the axis flags + the trailing POSITIONAL operands
/// (order-independent among the flags; the positionals keep their given order). Total.
///
/// Recognised flags: `--portable`/`--ceiling`/`--unsafe` (mutually-exclusive base — at most
/// one), `--threaded`, `--tier <t>`, `--table-tier <t>`, `--cap <pages>`. A `--tier`/
/// `--table-tier`/`--cap` with no following value, an unknown `--flag`, an unrecognised tier
/// token, a non-integer cap, or a second base flag all yield `Error(msg)` (fail-closed — the
/// caller exits non-zero). Any non-`--` token is a positional.
///
/// - `tokens`: the verb's arguments after the verb (e.g. `["--tier", "atomics", "f.wasm"]`).
/// - Returns `Ok(#(axes, positionals))` or `Error(msg)`.
fn split_axis_flags(
  tokens: List(String),
) -> Result(#(Axes, List(String)), String) {
  do_split_axis_flags(tokens, Axes(BaseSafe, False, None, None, None), [])
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
    ["--threaded", ..rest] ->
      do_split_axis_flags(rest, Axes(..acc, threaded: True), positionals)
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
    _ -> Error("at most one of --portable / --ceiling / --unsafe")
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
/// - `mem`/`table`: the parsed `--tier`/`--table-tier` selections (`None` = keep the base's).
/// - `cap`: the parsed `--cap` page cap (`None` = keep the base's `safe_max_pages`).
/// - Returns `Ok(binding)` — a coherent, `resolve_tiers`-coupled, `link`-validated `Binding` —
///   for any coherent composition, or `Error(msg)` fail-closed when the result is
///   policy-incoherent (Safe + `nif`, an uncapped `atomics`/`ceiling` build, or a tier/module
///   drift) — surfaced as a CLI error (exit non-zero), NEVER silently downgraded. Total.
pub fn resolve_binding(
  base: Binding,
  threaded: Bool,
  mem: Option(MemTier),
  table: Option(TableTier),
  cap: Option(Int),
) -> Result(Binding, String) {
  let b0 = case threaded {
    True -> Binding(..base, state_strategy: Threaded)
    False -> base
  }
  let b1 = case mem {
    Some(t) -> Binding(..b0, mem_tier: t)
    None -> b0
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
/// alongside the positional operands. The single wiring point where the axis flags become a
/// validated `Binding` (so the fail-closed gate runs once per verb). A flag-parse or link error
/// short-circuits to `Error(msg)` (exit non-zero); `k` receives only a coherent binding.
///
/// - `tokens`: the verb's arguments after the verb.
/// - `k`: the subcommand body, given the validated `binding` + the positional operands.
fn with_binding(
  tokens: List(String),
  k: fn(Binding, List(String)) -> Result(String, String),
) -> Result(String, String) {
  use #(axes, positionals) <- result.try(split_axis_flags(tokens))
  use binding <- result.try(resolve_binding(
    base_binding(axes.base),
    axes.threaded,
    axes.mem,
    axes.table,
    axes.cap,
  ))
  k(binding, positionals)
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

/// `to-beam-wasm [--unsafe] <in.wasm> <out.beam>` — compile a `.wasm` all the way to a `.beam`
/// under the selected profile (Safe = Baseline optimizer + enforcing fuel; `--unsafe` = Aggressive
/// optimizer + `MeterOff` + open runtime), and write it. This is the profile-selecting
/// compile-to-`.beam`-from-`.wasm` path the Phase-3 benchmark (`smoke/bench.sh`) needs: `run`
/// re-compiles every call and `to-beam` takes only `.core`, so neither can produce a persisted,
/// profile-specific `.beam` to hand to `exec`. Prints a confirmation line.
fn cmd_to_beam_wasm(
  input: String,
  output: String,
  binding: Binding,
) -> Result(String, String) {
  use bytes <- result.try(read_bits(input))
  case pipeline.source_to_ir(bytes) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(m) ->
      case pipeline.ir_to_core(m, binding) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(core) ->
          case pipeline.core_to_beam(core, m.name) {
            Error(e) -> Error(pipeline.describe(e))
            Ok(beam) ->
              case simplifile.write_bits(output, beam) {
                Error(fe) ->
                  Error(
                    "write " <> output <> ": " <> simplifile.describe_error(fe),
                  )
                Ok(Nil) -> Ok("wrote " <> output)
              }
          }
      }
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
      "  gleam run -- to-beam-wasm [axes] <in.wasm> <out.beam>  .wasm → .beam under a profile (bench)",
      "  gleam run -- run      [axes] <in.wasm> <export> <args…>  compile + invoke on the BEAM",
      "  gleam run -- exec     [-n N] <in.beam> <export> <args…>  invoke a prebuilt .beam (bench, no compile)",
      "",
      "  [axes] — profile / strategy / tier selection (default: Safe / Cell / Paged, fail-closed):",
      "    base (one of):  --unsafe | --portable | --ceiling",
      "    --threaded                state_strategy: Threaded (the record-threading run-ABI)",
      "    --tier paged|atomics|nif  linear-memory trust tier (nif is Unsafe-only)",
      "    --table-tier paged|ets|atomics   funcref-table trust tier",
      "    --cap PAGES               bounded page cap (required to engage atomics / --ceiling)",
      "  A non-default posture must be NAMED; Safe + --tier nif and an uncapped atomics/ceiling",
      "  build are rejected fail-closed (exit non-zero), never silently downgraded.",
      "  opt takes only --unsafe; to-beam/build take no profile (they compile .core — no Binding).",
      "Values are raw unsigned bit patterns in decimal (i32 -1 is 4294967295).",
    ],
    "\n",
  )
}
