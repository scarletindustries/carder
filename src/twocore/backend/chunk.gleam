//// Split a large emitted `CModule` into N smaller BEAM modules that are compiled INDEPENDENTLY,
//// to bound the whole-module `compile:forms` peak to O(largest chunk) rather than O(whole module).
////
//// WHY. The Erlang back-end accumulates growing kernel/SSA/beam-asm state across ALL of a module's
//// functions and does not free per-function IR until the whole module is assembled — measured on the
//// TeaVM gateway: 1 function = 117 MiB, 420 functions = 796 MiB. Compiling N balanced sub-modules
//// sequentially caps the live set at ~1/N of the whole.
////
//// HOW. `split_module` partitions the module's top-level `defs` into N groups balanced by size, keeps
//// the exported functions + the `instantiate` entry in chunk 0 (so the run-ABI module name is
//// unchanged), and rewrites every CROSS-chunk top-level call `apply 'f'/n(args)` into an inter-module
//// `call 'chunkK':'f'(args)`. This is sound and COMPLETE because every reference to a top-level
//// function in the emitted Core is a `CApply(FName, _)` — direct calls, export wrappers, the
//// `instantiate` seeds, `start`, and even `ref.func`/element funcrefs (which eta-wrap to
//// `fun(a) -> apply 'f'/n(a)`). `letrec`-local join/loop atoms (`jN`/`L`) are NOT in the top-level
//// def set, so a rewrite keyed on that set never touches them — they stay intra-function.
////
//// SEMANTICS. A cross-chunk `call 'chunkK':'f'(args)` is a synchronous in-process call, byte-for-byte
//// equivalent to the `apply` it replaces: all chunks load into and run in the ONE instance-owning
//// process, so `Cell` state (a process-dictionary cell) is shared and `Threaded` state (passed as the
//// leading argument) is forwarded unchanged. Below `min_split_defs` the module is returned UNCHANGED
//// (`[cmod]`, N=1) so small guests stay byte-identical.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/set
import twocore/backend/core_erlang.{
  type CExpr, type CModule, type FName, type FunDef, CApply, CApplyExpr, CAtom,
  CBinary, CBitSeg, CCall, CCase, CClause, CCons, CFun, CLet, CLetrec, CModule,
  CPrimop, CTry, CTuple, CValues, FunDef,
}

/// A top-level function identity — its name atom and arity. Two module defs never share one.
type Key =
  #(String, Int)

/// Split `cmod` into at most `target` balanced BEAM sub-modules.
///
/// - `target`: the desired number of chunks (`>= 1`). `1` (or fewer) is a no-op.
/// - `min_split_defs`: only split a module with at least this many top-level defs; a smaller module
///   returns `[cmod]` UNCHANGED (byte-identical output — the gate that keeps small guests untouched).
/// - Returns the chunk `CModule`s, **chunk 0 first**. Chunk 0 keeps `cmod`'s name, its exports, and
///   the `instantiate` entry, so the run-ABI is unchanged; chunks `1..` are named `<name>_c<i>` and
///   export every function they hold (so cross-chunk `call`s resolve). Empty chunks are dropped.
///   Total — never fails.
pub fn split_module(
  cmod: CModule,
  target: Int,
  min_split_defs: Int,
) -> List(CModule) {
  case target <= 1 || list.length(cmod.defs) < min_split_defs {
    True -> [cmod]
    False -> do_split(cmod, target)
  }
}

fn key_of(f: FName) -> Key {
  #(f.name, f.arity)
}

/// The ascending index list `[0, 1, …, n-1]` (stdlib 1.0.3 has no `list.range`).
fn seq(n: Int) -> List(Int) {
  seq_loop(n - 1, [])
}

fn seq_loop(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> seq_loop(i - 1, [i, ..acc])
  }
}

/// The BEAM module atom for chunk `i`: chunk 0 keeps the base name (the run-ABI entry); later chunks
/// get a `_c<i>` suffix (a valid atom-name extension guaranteed distinct from the base).
fn chunk_name(base: String, i: Int) -> String {
  case i {
    0 -> base
    _ -> base <> "_c" <> int.to_string(i)
  }
}

fn do_split(cmod: CModule, target: Int) -> List(CModule) {
  let export_keys = cmod.exports |> list.map(key_of) |> set.from_list
  // Exported functions (incl. `instantiate`) MUST live in chunk 0 — that is the module the harness
  // and dance call by name. Everything else is a free-floating internal helper to balance.
  let #(entry_defs, internal_defs) =
    list.partition(cmod.defs, fn(d) {
      set.contains(export_keys, key_of(d.name))
    })

  // Greedy bin-pack internal defs (largest first) into the least-loaded chunk. Bin 0 is pre-loaded
  // with the entry defs' size so it is not over-filled. Balancing by SIZE matters: a naive
  // contiguous slice leaves one chunk nearly as large as the whole module.
  let entry_load = list.fold(entry_defs, 0, fn(acc, d) { acc + def_size(d) })
  let loads0 =
    seq(target)
    |> list.map(fn(i) {
      #(i, case i {
        0 -> entry_load
        _ -> 0
      })
    })
    |> dict.from_list
  let sized =
    internal_defs
    |> list.map(fn(d) { #(def_size(d), d) })
    |> list.sort(fn(a, b) { int.compare(b.0, a.0) })
  let #(_loads, groups) =
    list.fold(sized, #(loads0, dict.new()), fn(acc, sd) {
      let #(loads, groups) = acc
      let #(sz, d) = sd
      let best = least_loaded(loads)
      #(
        dict.insert(loads, best, get_int(loads, best) + sz),
        dict.insert(groups, best, [d, ..get_defs(groups, best)]),
      )
    })

  // Map every def to its chunk: entry defs -> 0, internal defs -> their assigned bin.
  let chunk_of =
    list.fold(entry_defs, dict.new(), fn(acc, d) {
      dict.insert(acc, key_of(d.name), 0)
    })
  let chunk_of =
    dict.fold(groups, chunk_of, fn(acc, chunk, defs) {
      list.fold(defs, acc, fn(a, d) { dict.insert(a, key_of(d.name), chunk) })
    })

  seq(target)
  |> list.map(fn(i) {
    let raw_defs = case i {
      0 -> list.append(entry_defs, get_defs(groups, 0))
      _ -> get_defs(groups, i)
    }
    let rewritten =
      list.map(raw_defs, fn(d) {
        FunDef(d.name, rewrite(d.value, i, chunk_of, cmod.name))
      })
    CModule(
      name: chunk_name(cmod.name, i),
      // Export every function the chunk holds so any cross-chunk `call` resolves. Chunk 0's set is a
      // superset of the original exports (which are all here) — extra exports are harmless.
      exports: list.map(rewritten, fn(d) { d.name }),
      attributes: case i {
        0 -> cmod.attributes
        _ -> []
      },
      defs: rewritten,
    )
  })
  |> list.filter(fn(c) { !list.is_empty(c.defs) })
}

fn get_int(d: Dict(Int, Int), k: Int) -> Int {
  case dict.get(d, k) {
    Ok(v) -> v
    Error(_) -> 0
  }
}

fn get_defs(d: Dict(Int, List(FunDef)), k: Int) -> List(FunDef) {
  case dict.get(d, k) {
    Ok(v) -> v
    Error(_) -> []
  }
}

/// The chunk with the smallest accumulated size (ties broken by lowest index, for determinism).
/// `loads` is non-empty here (`target >= 2` in `do_split`), so the `let assert` cannot fail.
fn least_loaded(loads: Dict(Int, Int)) -> Int {
  let assert Ok(#(k, _)) =
    dict.to_list(loads)
    |> list.sort(fn(a, b) {
      case int.compare(a.1, b.1) {
        order.Eq -> int.compare(a.0, b.0)
        other -> other
      }
    })
    |> list.first
  k
}

/// Rewrite every CROSS-chunk top-level `CApply` in `e` into an inter-module `CCall`, leaving
/// same-chunk calls and `letrec`-local (`jN`/`L`) applies as `CApply`. Recurses through the ENTIRE
/// expression — including nested `letrec` join bodies, `case` clauses, `try`, and binary segments —
/// so no reference site is missed.
fn rewrite(
  e: CExpr,
  this_chunk: Int,
  chunk_of: Dict(Key, Int),
  base: String,
) -> CExpr {
  let go = fn(x) { rewrite(x, this_chunk, chunk_of, base) }
  case e {
    CApply(fname, args) -> {
      let args2 = list.map(args, go)
      case dict.get(chunk_of, key_of(fname)) {
        // A top-level def in a DIFFERENT chunk -> inter-module call.
        Ok(tc) ->
          case tc == this_chunk {
            True -> CApply(fname, args2)
            False ->
              CCall(CAtom(chunk_name(base, tc)), CAtom(fname.name), args2)
          }
        // Not a top-level def (a letrec-local join/loop atom) -> leave intra-function.
        Error(_) -> CApply(fname, args2)
      }
    }
    CCons(h, t) -> CCons(go(h), go(t))
    CTuple(es) -> CTuple(list.map(es, go))
    CValues(vs) -> CValues(list.map(vs, go))
    CBinary(segs) ->
      CBinary(
        list.map(segs, fn(s) {
          CBitSeg(go(s.value), go(s.size), s.unit, s.segtype, s.flags)
        }),
      )
    CFun(vars, body) -> CFun(vars, go(body))
    CLet(vars, arg, body) -> CLet(vars, go(arg), go(body))
    CLetrec(defs, body) ->
      CLetrec(
        list.map(defs, fn(fd) { FunDef(fd.name, go(fd.value)) }),
        go(body),
      )
    CCase(arg, clauses) ->
      CCase(
        go(arg),
        list.map(clauses, fn(c) { CClause(c.pats, go(c.guard), go(c.body)) }),
      )
    CApplyExpr(op, args) -> CApplyExpr(go(op), list.map(args, go))
    CCall(m, f, args) -> CCall(go(m), go(f), list.map(args, go))
    CPrimop(name, args) -> CPrimop(name, list.map(args, go))
    CTry(arg, bvars, body, evars, handler) ->
      CTry(go(arg), bvars, go(body), evars, go(handler))
    _ -> e
  }
}

/// A cheap node-count proxy for a def's compile cost, used only to balance chunk sizes.
fn def_size(d: FunDef) -> Int {
  count(d.value)
}

fn count(e: CExpr) -> Int {
  case e {
    CCons(h, t) -> 1 + count(h) + count(t)
    CTuple(es) -> 1 + sum_counts(es)
    CValues(vs) -> 1 + sum_counts(vs)
    CBinary(segs) ->
      1
      + list.fold(segs, 0, fn(acc, s) { acc + count(s.value) + count(s.size) })
    CFun(_, body) -> 1 + count(body)
    CLet(_, arg, body) -> 1 + count(arg) + count(body)
    CLetrec(defs, body) ->
      1 + list.fold(defs, 0, fn(acc, d) { acc + count(d.value) }) + count(body)
    CCase(arg, clauses) ->
      1
      + count(arg)
      + list.fold(clauses, 0, fn(acc, c) {
        acc + count(c.guard) + count(c.body)
      })
    CApply(_, args) -> 1 + sum_counts(args)
    CApplyExpr(op, args) -> 1 + count(op) + sum_counts(args)
    CCall(m, f, args) -> 1 + count(m) + count(f) + sum_counts(args)
    CPrimop(_, args) -> 1 + sum_counts(args)
    CTry(arg, _, body, _, handler) ->
      1 + count(arg) + count(body) + count(handler)
    _ -> 1
  }
}

fn sum_counts(es: List(CExpr)) -> Int {
  list.fold(es, 0, fn(acc, e) { acc + count(e) })
}
