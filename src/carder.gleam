//// The carder **CLI** — the backend's own binary, exposing every IR-and-below pipeline stage
//// independently plus an end-to-end `run`. `gleam run -- <subcommand> …` dispatches here.
////
//// carder is a compiler BACKEND. Its input is the shared IR (`carder/ir`, textually a `.ir`
//// file), not a source language: a FRONTEND — `scribbler` for WebAssembly, `arc` for JavaScript
//// — owns its own source format and its own binary, lowers into the IR, and calls carder's
//// public API (`carder/pipeline`, `carder/embed`) to compile and run. So every verb below takes
//// a `.ir`, a `.core`, or a `.beam`; none of them knows what produced it.
////
//// The stage wiring and per-stage error mapping (D4) live in `carder/pipeline`, and the shared
//// axis-flag vocabulary in `carder/cli` (which each frontend's CLI imports too, so the posture
//// flags can never drift between binaries). This module only does argument parsing, file IO,
//// and printing. Every subcommand is total: bad input prints its typed error to **stderr** and
//// the process halts **non-zero** (`halt(1)`) — it never panics.
////
//// ## Subcommands
////
//// | Subcommand                          | Pipeline                                             |
//// |-------------------------------------|------------------------------------------------------|
//// | `run      <in.ir> <export> <args…>` | parse `.ir` → … → load → instantiate → invoke → print |
//// | `ir-lower <in.ir>`                  | parse `.ir` → ir_lower(Safe) → print `.ir`           |
//// | `opt      <in.ir> [--unsafe]`       | parse `.ir` → optimize_ir(profile) → print `.ir`     |
//// | `emit     <in.ir>`                  | parse `.ir` → emit_core(profile) → print `.core`     |
//// | `to-core  <in.ir>`                  | parse `.ir` → ir_lower → optimize → emit → `.core`   |
//// | `to-erl   <in.ir>`                  | parse `.ir` → … → emit → abstract forms → print `.erl` |
//// | `to-beam  <in.ir> [out.beam]`       | parse `.ir` → … → `compile:forms` → write `.beam`    |
//// | `exec     [-n N] <in.beam> …`       | load a PREBUILT `.beam` → invoke (no compile step)   |
//// | `help`                              | print the usage text                                  |
////
//// ## Axis flags (`carder/cli`)
////
//// The compile verbs accept the orthogonal axis flags documented by `cli.axes_usage()`; the
//// default is the fail-closed **Safe / `Cell` / `Paged`** posture (leaving it requires NAMING a
//// flag). `cli.resolve_binding` composes them into one coherent `Binding` and validates it
//// through `profiles.link/1` (the sole `Binding → Instance` seam), so an incoherent posture
//// (`Safe` + `nif` memory, or an uncapped `atomics`/`ceiling` build) is rejected fail-closed
//// (exit non-zero), never silently downgraded.
////
//// `to-beam`/`build` additionally honor `--link` (merge the runtime closure into one
//// self-contained `.beam`) and `--bindings <langs> --out <dir>` (emit typed host-language
//// companion sources next to the `.beam`); every other verb refuses those fail-closed.
////
//// ## Value convention (the run/invoke ABI — `carder/cli`)
////
//// `run`/`exec` arguments and results are **raw UNSIGNED bit patterns in decimal**: an i32 in
//// `[0, 2^32)`, an i64 in `[0, 2^64)`, a float as its raw IEEE-754 bits (D5). So an i32 `-1`
//// argument is written `4294967295`. A trap prints `trap: <reason>` to stderr and halts
//// non-zero — a trap is a runtime outcome, surfaced as a CLI failure; an uncaught exception is
//// reported distinctly (T8).

import argv
import carder/backend/beam_link
import carder/backend/bindings
import carder/backend/build_beam
import carder/backend/core_erlang
import carder/backend/core_printer
import carder/backend/emit_core
import carder/cli
import carder/ir
import carder/ir/printer as ir_printer
import carder/pipeline
import carder/runtime/instance.{type Binding}
import carder/runtime/profiles
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

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
    ["help"] | ["--help"] | ["-h"] -> Ok(usage())
    ["ir-lower", path] -> cmd_ir_lower(path)
    ["opt", "--unsafe", path] -> cmd_opt(path, profiles.unsafe())
    ["opt", path] -> cmd_opt(path, profiles.safe())
    ["emit", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        use <- cli.reject_link(axes.link, "emit")
        use <- cli.reject_output_flags(axes, "emit")
        case pos {
          [path] -> cmd_emit(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-core", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        use <- cli.reject_link(axes.link, "to-core")
        use <- cli.reject_output_flags(axes, "to-core")
        case pos {
          [path] -> cmd_to_core(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-erl", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        use <- cli.reject_link(axes.link, "to-erl")
        use <- cli.reject_output_flags(axes, "to-erl")
        case pos {
          [path] -> cmd_to_erl(path, binding)
          _ -> Error(usage())
        }
      })
    ["to-beam", ..rest] | ["build", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        cmd_to_beam(binding, axes.link, axes.bindings, axes.out, pos)
      })
    ["run", ..rest] ->
      cli.with_binding(rest, fn(binding, axes, pos) {
        use <- cli.reject_link(axes.link, "run")
        use <- cli.reject_output_flags(axes, "run")
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

// ─────────────────────────────── subcommands ───────────────────────────────

/// Read + parse a `.ir` file into an `ir.Module`, mapping both the IO error and the parse error
/// to a CLI diagnostic. The shared front half of every `.ir`-consuming verb.
fn read_ir(path: String) -> Result(ir.Module, String) {
  use text <- result.try(cli.read_text(path))
  pipeline.parse_ir(text)
  |> result.map_error(fn(e) { "parse .ir: " <> string.inspect(e) })
}

/// `ir-lower <in.ir>` — run the IR→IR Safe policy pass (metering + `CallHost` gating) and print
/// the rewritten `.ir`. The stage between `opt` and the frontend's own lowering.
fn cmd_ir_lower(path: String) -> Result(String, String) {
  use m <- result.try(read_ir(path))
  case pipeline.lower_ir(m, profiles.safe()) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(lowered) -> Ok(ir_printer.print_module(lowered))
  }
}

/// `opt <in.ir> [--unsafe]` — run the shared IR→IR optimizer at the level the profile carries
/// (`Safe` → Baseline, `--unsafe` → Aggressive) and print the rewritten `.ir`. Total: the
/// optimizer never fails, so the only error path is reading/parsing the input.
fn cmd_opt(path: String, binding: Binding) -> Result(String, String) {
  use m <- result.try(read_ir(path))
  Ok(ir_printer.print_module(pipeline.optimize_ir(m, binding)))
}

/// `emit <in.ir> [axes]` — run `emit_core` ALONE (no policy pass, no optimizer) over the parsed
/// module and print the Core Erlang. The single-stage inspection surface for codegen.
fn cmd_emit(path: String, binding: Binding) -> Result(String, String) {
  use m <- result.try(read_ir(path))
  case emit_core.emit_module(m, binding) {
    Error(e) -> Error("emit: " <> string.inspect(e))
    Ok(cmod) -> Ok(core_printer.print_module(cmod))
  }
}

/// `to-core <in.ir> [axes]` — the full IR→Core path (`ir_lower` → `optimize` → `emit_core`),
/// printed as `.core` text. This is what `to-beam` compiles, in inspectable form.
fn cmd_to_core(path: String, binding: Binding) -> Result(String, String) {
  use m <- result.try(read_ir(path))
  pipeline.ir_to_core(m, binding)
  |> result.map_error(pipeline.describe)
}

/// `to-erl <in.ir> [axes]` — the full IR→Core path lowered one step further, to Erlang Abstract
/// Format, printed as `.erl`. The last inspection surface before `compile:forms`.
fn cmd_to_erl(path: String, binding: Binding) -> Result(String, String) {
  use m <- result.try(read_ir(path))
  case pipeline.ir_to_cmod(m, binding) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(cmod) ->
      case build_beam.module_to_erl(cmod) {
        Error(e) -> Error("to-erl: " <> string.inspect(e))
        Ok(erl) -> Ok(erl)
      }
  }
}

/// `to-beam|build [axes] [--link] [--bindings <langs> --out <dir>] <in.ir> [<out.beam>]` —
/// compile a `.ir` to a `.beam` under the selected profile, optionally merging the runtime
/// closure into a self-contained artifact (`--link`) and/or emitting typed companion host-language
/// bindings (`--bindings` + `--out`). Prints a confirmation line.
///
/// Branches on `#(out, positionals)` — the two positional forms are mutually exclusive:
/// - **FILE** (`out == None`): `<in.ir>` alone (the `.beam` path is derived by swapping the
///   extension) or `<in.ir> <out.beam>`. `--bindings` here is an error (it needs the `--out`
///   folder to write the companions into).
/// - **FOLDER** (`out == Some(dir)`, one positional `<in.ir>`): compile+emit into `dir` — lower
///   ONCE (R17), write `<dir>/<module.name>.beam` + one companion file per requested language.
///   Two-or-more positionals is an error (the `.beam` name derives from the module atom).
///
/// `--bindings` requires `--threaded` (the default `Cell` binding has no typed-binding surface —
/// `describe` rejects it with the R12 "re-run with `--threaded`" hint). Composes with `--link` on
/// both paths.
fn cmd_to_beam(
  binding: Binding,
  link: Bool,
  langs: List(bindings.BindingLang),
  out: Option(String),
  positionals: List(String),
) -> Result(String, String) {
  case out, positionals {
    None, [input] ->
      case langs {
        [] -> file_to_beam(input, default_beam(input), binding, link)
        _ ->
          Error(
            "--bindings requires --out <dir> (the companion binding files are written into a folder alongside the .beam)",
          )
      }
    None, [input, output] ->
      case langs {
        [] -> file_to_beam(input, output, binding, link)
        _ ->
          Error(
            "--bindings requires --out <dir> (the companion binding files are written into a folder alongside the .beam)",
          )
      }
    None, _ -> Error(usage())
    Some(dir), [input] -> folder_to_beam(input, dir, binding, link, langs)
    Some(_), _ ->
      Error(
        "with --out, pass only <in.ir>; the .beam name derives from the module atom (<module-atom>.beam)",
      )
  }
}

/// The FILE `to-beam` path — `parse .ir → ir_to_cmod → cmod_to_beam → write` (or, under
/// `--link`, the fail-closed `link_gate` then `build_beam.link_beam` merge).
fn file_to_beam(
  input: String,
  output: String,
  binding: Binding,
  link: Bool,
) -> Result(String, String) {
  use m <- result.try(read_ir(input))
  case link {
    False ->
      case pipeline.ir_to_cmod(m, binding) {
        Error(e) -> Error(pipeline.describe(e))
        Ok(cmod) ->
          case pipeline.cmod_to_beam(cmod) {
            Error(e) -> Error(pipeline.describe(e))
            Ok(beam) -> cli.write_beam(output, beam)
          }
      }
    True ->
      case cli.link_gate(binding, m) {
        Error(ge) -> Error(cli.describe_link_gate_error(ge))
        Ok(Nil) ->
          case pipeline.ir_to_cmod(m, binding) {
            Error(e) -> Error(pipeline.describe(e))
            Ok(cmod) ->
              case build_beam.link_beam(cmod) {
                Error(le) -> Error(beam_link.describe_error(le))
                Ok(#(_atom, beam)) -> cli.write_beam(output, beam)
              }
          }
      }
  }
}

/// The FOLDER `to-beam` path (P12-05): compile `<input>` into `<dir>`, emitting the `.beam` + one
/// typed companion binding per requested language. The R17 lower-ONCE seam is the crux —
/// `pipeline.ir_to_lowered_cmod` lowers+optimizes ONCE and returns BOTH the module and its
/// `CModule`; the SAME lowered module is handed to `bindings.emit_bindings` (which runs
/// `iface.describe` over it) while its `CModule` becomes the `.beam`. So `describe` and the
/// `.beam` ABI see identical bodies — a mutation-carrying export cannot be misclassified pure
/// (dropping `St'`). Fail-closed: a rejected module (Cell / import-bearing / mutable-tier) writes
/// NOTHING (describe runs before any IO); a link-gate/link failure surfaces before emit.
///
/// - `input`: the `.ir` source path.
/// - `dir`: the `--out` output folder (created if absent).
/// - `binding`: the resolved build binding (must be Threaded + Paged/TablePaged for `--bindings`).
/// - `link`: the `--link` bit — merge the runtime closure into the emitted `.beam`.
/// - `langs`: the requested target languages (`[]` = write only the `.beam`, no describe/emit).
fn folder_to_beam(
  input: String,
  dir: String,
  binding: Binding,
  link: Bool,
  langs: List(bindings.BindingLang),
) -> Result(String, String) {
  use m <- result.try(read_ir(input))
  // R17: lower + optimize ONCE; the returned `lowered` module is exactly what the `CModule` (hence
  // the `.beam`) is generated from, and it is what `emit_bindings` runs `describe` over.
  use #(lowered, cmod) <- result.try(
    pipeline.ir_to_lowered_cmod(m, binding)
    |> result.map_error(pipeline.describe),
  )
  use beam <- result.try(beam_of_lowered(cmod, lowered, binding, link))
  case bindings.emit_bindings(lowered, binding, beam, dir, langs) {
    Error(be) -> Error(bindings.describe_error(be))
    Ok(paths) -> Ok("wrote " <> string.join(paths, ", "))
  }
}

/// Compile the lowered `CModule` into the `.beam` bytes for the FOLDER path, honoring `--link`.
/// With `link == False` it is a plain `cmod_to_beam`; with `link == True` it runs the fail-closed
/// `link_gate` (tier-N / import-bearing) then merges the runtime closure via `build_beam.link_beam`.
/// Returns the bytes or the rendered CLI diagnostic. `mod`'s `.name`/`.imports` drive the gate + the
/// baked module atom (it is the SAME lowered module `describe` sees).
fn beam_of_lowered(
  cmod: core_erlang.CModule,
  mod: ir.Module,
  binding: Binding,
  link: Bool,
) -> Result(BitArray, String) {
  case link {
    False ->
      pipeline.cmod_to_beam(cmod)
      |> result.map_error(pipeline.describe)
    True ->
      case cli.link_gate(binding, mod) {
        Error(ge) -> Error(cli.describe_link_gate_error(ge))
        Ok(Nil) ->
          case build_beam.link_beam(cmod) {
            Error(le) -> Error(beam_link.describe_error(le))
            Ok(#(_atom, beam)) -> Ok(beam)
          }
      }
  }
}

/// `run [axes] <in.ir> <export> <args…>` — compile the module through the selected profile's
/// pipeline and invoke `export` on the BEAM. Prints the result value(s) (raw bit patterns,
/// space-separated); a trap prints `trap: <reason>` as an error (exit non-zero) and an uncaught
/// exception prints its tag + payload, distinctly (T8).
///
/// This is carder's end-to-end verb WITHOUT a frontend installed: it proves the backend compiles
/// and runs on its own. A frontend's `run` (e.g. `scribbler run foo.wasm`) is the same thing with
/// its own source→IR stage in front, calling `pipeline.run_ir` underneath.
fn cmd_run(
  path: String,
  export: String,
  arg_strs: List(String),
  binding: Binding,
) -> Result(String, String) {
  use m <- result.try(read_ir(path))
  use args <- result.try(cli.parse_args(arg_strs))
  case pipeline.run_ir(m, binding, export, args) {
    Error(e) -> Error(pipeline.describe(e))
    Ok(pipeline.Returned(values)) -> Ok(cli.format_values(values))
    Ok(pipeline.Trapped(reason)) -> Error("trap: " <> reason)
    Ok(pipeline.UncaughtException(tag_id, payload)) ->
      Error(cli.format_uncaught(tag_id, payload))
  }
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
  use beam <- result.try(cli.read_bits(path))
  use args <- result.try(cli.parse_args(arg_strs))
  use repeat <- result.try(parse_count(count_str))
  case pipeline.exec_beam(beam, export, args, repeat) {
    Error(e) -> Error(e)
    Ok(#(_micros, pipeline.Trapped(reason))) -> Error("trap: " <> reason)
    Ok(#(_micros, pipeline.UncaughtException(tag_id, payload))) ->
      Error(cli.format_uncaught(tag_id, payload))
    Ok(#(micros, pipeline.Returned(values))) ->
      Ok(cli.format_values(values) <> "\n" <> timing_line(repeat, micros))
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

/// Default `.beam` output path for `to-beam`: swap a trailing `.ir` for `.beam`, else
/// append `.beam`.
fn default_beam(input: String) -> String {
  case string.ends_with(input, ".ir") {
    True -> string.drop_end(input, 3) <> ".beam"
    False -> input <> ".beam"
  }
}

/// The usage text — printed by `help` (exit 0) and on an unrecognised invocation (stderr, exit
/// non-zero). The `[axes]` block comes from `cli.axes_usage()` so it can never drift from the one
/// flag parser both carder and every frontend CLI share.
fn usage() -> String {
  string.join(
    [
      "carder — IR → Core Erlang → BEAM compiler backend. Usage:",
      "  gleam run -- run      [axes] <in.ir> <export> <args…>  compile + invoke on the BEAM",
      "  gleam run -- ir-lower <in.ir>                   Safe policy pass → .ir",
      "  gleam run -- opt      <in.ir> [--unsafe]        optimizer stage → .ir (Safe=Baseline, Unsafe=Aggressive)",
      "  gleam run -- emit     <in.ir> [axes]            emit_core only → .core",
      "  gleam run -- to-core  <in.ir> [axes]            ir_lower + optimize + emit_core → .core",
      "  gleam run -- to-erl   <in.ir> [axes]            ir_lower + optimize + emit → abstract forms → .erl dump",
      "  gleam run -- to-beam  [axes] [--link] <in.ir> [<out.beam>]   compile → .beam (alias: build)",
      "  gleam run -- to-beam  [axes] --bindings <langs> --out <dir> <in.ir>  + typed host bindings",
      "  gleam run -- exec     [-n N] <in.beam> <export> <args…>  invoke a prebuilt .beam (bench, no compile)",
      "  gleam run -- help                               print this text",
      "",
      "  carder compiles the shared IR. To compile a SOURCE language, use a frontend:",
      "    WebAssembly → scribbler (https://github.com/scarletindustries/scribbler)",
      "    JavaScript  → arc",
      "  A frontend lowers its source into a .ir / an ir.Module and calls carder's public API.",
      "",
      cli.axes_usage(),
      "  opt takes only --unsafe (the optimizer reads no tier).",
    ],
    "\n",
  )
}
