//// Lever 8 — redundant bitwise-AND mask elimination (`emit_core.elim_redundant_masks`, opt-in via
//// `Binding.lazy_mask`, enabled in `profiles.engine()`). Assertions target the ALGEBRA the rewrite
//// relies on, not the impl:
////
//// - **The soundness identity** — `band(band(X, M2), M1) == band(X, M2)` for ALL integers X (incl.
////   negative) whenever `M2 band M1 == M2` (M2's bits ⊆ M1's). Verified against real BEAM `band`
////   semantics both algebraically (`int.bitwise_and`) and END-TO-END (compile the original vs the
////   rewritten Core and compare `f(X)` across a spread of X, including negatives).
//// - **The rewrite fires only when sound** — a non-subset outer mask, a non-`band` node, and a
////   single `band` are left byte-identical (a safe no-op).
//// - **Commutativity + chains** — either operand order is recognized, and a whole chain collapses
////   in one bottom-up pass.
//// - **Gating** — OFF by default (byte-identical Core); ON only under `lazy_mask`.

import carder/backend/build_beam
import carder/backend/core_erlang.{
  type CExpr, type CModule, CApply, CAtom, CCall, CFun, CInt, CModule, CVar,
  FName, FunDef,
}
import carder/backend/emit_core
import carder/runtime/instance
import carder/runtime/profiles
import gleam/erlang/atom.{type Atom}
import gleam/list

// Test-only FFI (shared with `inline_joins_test`): apply `M:F(Args)`, capturing a trap as
// `Error(text)` instead of crashing the test process.
@external(erlang, "carder_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// ───────────────────────────── plumbing ─────────────────────────────

/// `call 'erlang':'band'(a, b)` — the shape lever 1 emits for a wrapping-arith / `i32.and` mask.
fn band(a: CExpr, b: CExpr) -> CExpr {
  CCall(CAtom("erlang"), CAtom("band"), [a, b])
}

/// A `CModule` with a single def `'f'/0 = fun () -> body`, so the pass can be exercised over `body`.
fn wrap(body: CExpr) -> CModule {
  CModule(name: "carder@lazymask@t", exports: [], attributes: [], defs: [
    FunDef(FName("f", 0), CFun([], body)),
  ])
}

/// Run the peephole over `wrap(body)` and return the (possibly-rewritten) body of `'f'/0`.
fn rewritten(body: CExpr) -> CExpr {
  let assert [FunDef(_, CFun(_, out))] =
    emit_core.elim_redundant_masks(wrap(body)).defs
  out
}

// ═══════════════════════════ AST-level: the rewrite contract ═══════════════════════════

/// A subsumed outer mask is dropped: `band(band(X, 0xFF), 0xFFFF)` → `band(X, 0xFF)` (0xFF ⊆ 0xFFFF).
pub fn subset_outer_mask_dropped_test() {
  let inner = band(CVar("x"), CInt(0xFF))
  assert rewritten(band(inner, CInt(0xFFFF))) == band(CVar("x"), CInt(0xFF))
}

/// The idempotent double-mask collapses: `band(band(X, M), M)` → `band(X, M)` (M ⊆ M trivially).
pub fn idempotent_double_mask_collapses_test() {
  let m = 4_294_967_295
  let inner = band(CVar("x"), CInt(m))
  assert rewritten(band(inner, CInt(m))) == band(CVar("x"), CInt(m))
}

/// Commuted operand orders are recognized (band is commutative): a literal-FIRST inner and a
/// literal-FIRST outer still reduce to `band(X, M2)` (canonicalized value-first).
pub fn commuted_operand_orders_reduce_test() {
  // outer = band(0xFFFF, band(0xFF, X))
  let inner = band(CInt(0xFF), CVar("x"))
  assert rewritten(band(CInt(0xFFFF), inner)) == band(CVar("x"), CInt(0xFF))
}

/// A NON-subset outer mask is left byte-identical — the reduction would change the value, so it must
/// not fire. `band(band(X, 0xFF00), 0x00FF)`: 0xFF00 band 0x00FF == 0 ≠ 0xFF00, so no reduction.
pub fn non_subset_mask_unchanged_test() {
  let node = band(band(CVar("x"), CInt(0xFF00)), CInt(0x00FF))
  assert rewritten(node) == node
}

/// A lone `band` (no inner mask) and a `band` of two non-literals are left unchanged (safe no-op).
pub fn single_band_unchanged_test() {
  assert rewritten(band(CVar("x"), CInt(0xFF))) == band(CVar("x"), CInt(0xFF))
  assert rewritten(band(CVar("x"), CVar("y"))) == band(CVar("x"), CVar("y"))
}

/// A non-`band` call is untouched (the pass only reduces `erlang:band`).
pub fn non_band_call_unchanged_test() {
  let plus = CCall(CAtom("erlang"), CAtom("+"), [CVar("x"), CInt(1)])
  assert rewritten(plus) == plus
}

/// A whole chain collapses in ONE bottom-up pass to the tightest (innermost) mask:
/// `band(band(band(X, 0xF), 0xFF), 0xFFFF)` → `band(X, 0xF)` (0xF ⊆ 0xFF ⊆ 0xFFFF).
pub fn nested_chain_collapses_in_one_pass_test() {
  let l1 = band(CVar("x"), CInt(0xF))
  let l2 = band(l1, CInt(0xFF))
  let l3 = band(l2, CInt(0xFFFF))
  assert rewritten(l3) == band(CVar("x"), CInt(0xF))
}

/// The peephole recurses into nested expression positions (here an `apply` argument), not just the
/// top of a body.
pub fn reduces_inside_nested_position_test() {
  let masked = band(band(CVar("x"), CInt(0xFF)), CInt(0xFFFF))
  let body = CApply(FName("g", 1), [masked])
  assert rewritten(body) == CApply(FName("g", 1), [band(CVar("x"), CInt(0xFF))])
}

// ═══════════════════════════ soundness: real BEAM `band` semantics ═══════════════════════════

/// The identity the rewrite relies on holds on the REAL BEAM `band` (`int.bitwise_and` == `erlang:band`)
/// for every integer X, INCLUDING negatives: for masks with `M2 band M1 == M2`,
/// `(X band M2) band M1 == X band M2`. (Negative X is reachable at runtime — an un-normalized
/// `a - b` before its width mask.)
pub fn identity_holds_for_all_integers_test() {
  let m2 = 0xFF
  let m1 = 0xFFFF
  // Precondition of the reduction.
  assert int_band(m2, m1) == m2
  list.each(
    [-1_000_000, -257, -256, -1, 0, 1, 255, 256, 65_535, 65_536, 1_000_000],
    fn(x) {
      let masked_once = int_band(x, m2)
      assert int_band(masked_once, m1) == masked_once
    },
  )
}

/// End-to-end: compile the ORIGINAL `f(X) = band(band(X, M2), M1)` and the REWRITTEN
/// `f(X) = band(X, M2)`, then assert both produce identical results across a spread of X (incl.
/// negatives) — the rewrite is observably value-preserving on real compiled BEAM code.
pub fn compiled_original_and_rewritten_agree_test() {
  let m2 = 0xFF
  let m1 = 0xFFFF
  let original = band(band(CVar("x"), CInt(m2)), CInt(m1))
  let orig_mod = load(mask_mod("carder@lazymask@orig", original))
  let rewr_mod = load(mask_mod("carder@lazymask@rewr", rewritten(original)))
  // The rewrite MUST have actually fired (else this proves nothing).
  assert rewritten(original) == band(CVar("x"), CInt(m2))
  list.each([-100_000, -257, -1, 0, 1, 255, 256, 70_000, 100_000], fn(x) {
    assert catch_apply(orig_mod, atom.create("f"), [x])
      == catch_apply(rewr_mod, atom.create("f"), [x])
  })
}

// ═══════════════════════════ gating: OFF by default ═══════════════════════════

/// The lever is OFF in the fail-closed default binding and ON in `profiles.engine()` — the toggle a
/// build reads to decide whether to run the pass.
pub fn lever_gating_test() {
  assert instance.safe_default().lazy_mask == False
  assert profiles.engine().lazy_mask == True
}

// ───────────────────────────── end-to-end helpers ─────────────────────────────

/// `erlang:band/2` on the BEAM (the semantics the rewrite is proven against).
@external(erlang, "erlang", "band")
fn int_band(a: Int, b: Int) -> Int

/// A `CModule` exporting `'f'/1 = fun (X) -> body`, ready to compile + run.
fn mask_mod(name: String, body: CExpr) -> CModule {
  CModule(name: name, exports: [FName("f", 1)], attributes: [], defs: [
    FunDef(FName("f", 1), CFun(["x"], body)),
  ])
}

/// Print, compile, and load `cm`; return the loaded module atom.
fn load(cm: CModule) -> Atom {
  let assert Ok(mod) = build_beam.compile_and_load(cm)
  mod
}
