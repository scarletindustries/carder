//// A Gleam-native Core Erlang AST (Unit 03 — the backend's output
//// representation).
////
//// Per the high-level spec §5 we model the subset of Core Erlang we emit as
//// ordinary Gleam custom types, rather than driving the Erlang `cerl` record
//// API over FFI (awkward over FFI, loses Gleam's type safety). These types are
//// the `«CORE-AST»` milestone: unit 08 (`emit_core`) builds them from the IR
//// (the binding chokepoint, D3b). The COMPILE path lowers them to Erlang
//// Abstract Format terms (`twocore/backend/eaf`) consumed in-process by
//// `compile:forms/2`; `twocore/backend/core_printer` renders the same AST as
//// `.core` text purely for INSPECTION (the CLI's `to-core`/`emit` dumps and
//// text-shape tests) — the printed text is never re-parsed.
////
//// Phase 1 deliberately OMITS Core Erlang annotations (`-| [...]`) entirely — a
//// zero-annotation module compiles fine on OTP 29 — and omits the
//// `try`/`catch`/`receive`/`after` forms, which the Phase-1 integer op set does
//// not need. The `CBinary` node is kept as a lock-now placeholder but is not
//// exercised by the Phase-1 corpus.
////
//// LEXICAL CONTRACT (honored by the printer, surfaced here so node builders do
//// not have to pre-mangle): every atom-valued field below (`name` on `CAtom`,
//// `CModule`, `FName`, `CCall` module/function via `CAtom`, `CPrimop`,
//// `PAtom`, attribute keys) holds the atom's *logical* characters — the printer
//// always single-quotes and escapes it. Every variable-valued field (`CVar`,
//// `CFun.vars`, `CLet.vars`, `PVar`) holds the *raw* upstream name — the printer
//// legalizes it to a Core-legal variable token. Builders never quote or
//// legalize; that is the printer's guarantee.

/// A Core Erlang compilation unit (one `.beam` module).
///
/// Prints as:
/// ```text
/// module 'Name' [Exports]
///     attributes [Attrs]
/// Defs…
/// end
/// ```
///
/// Fields:
/// - `name`: the module atom in logical form (e.g. `"twocore@runtime@rt_num"`);
///   the printer single-quotes and escapes it. Namespacing (`twocore@…`) is the
///   caller's responsibility (overview §5) — this type does not enforce it.
/// - `exports`: the export list. Each `FName` prints as `'atom'/arity`.
/// - `attributes`: `'key' = value` module attributes. Phase 1 emits `[]`; the
///   shape is kept general so a later phase can add e.g. a `file` attribute.
/// - `defs`: the top-level function definitions, in print order. Core Erlang
///   module defs are mutually recursive, so any def may `apply` any other
///   (including itself) by `FName`.
pub type CModule {
  CModule(
    name: String,
    exports: List(FName),
    attributes: List(#(String, CExpr)),
    defs: List(FunDef),
  )
}

/// A function name: an atom plus an arity, printed `'atom'/arity` (e.g.
/// `'fact'/1`). Appears in three positions: the module export list, the LHS of a
/// `FunDef`/`CLetrec` def, and the operand of `CApply`.
///
/// - `name`: the function atom in logical form (printer quotes/escapes it).
/// - `arity`: the number of parameters; must be `>= 0` and must match the
///   `CFun` it names (`core_lint` rejects a mismatch). Not enforced by the type.
pub type FName {
  FName(name: String, arity: Int)
}

/// A top-level (or `letrec`) function definition: `'name'/arity = fun (…) -> …`.
///
/// INVARIANT: `value` is always a `CFun`. Core Erlang requires a `fun` literal on
/// the RHS of a definition, so `emit_core` always supplies one; the printer
/// prints whatever expression it is given but only a `CFun` produces lint-valid
/// output. This invariant is documented rather than type-enforced to keep the
/// AST a single flat `CExpr` sum.
///
/// - `name`: the function's `FName` (its `arity` should equal `value`'s
///   parameter count).
/// - `value`: the defining expression — a `CFun`.
pub type FunDef {
  FunDef(name: FName, value: CExpr)
}

/// A Core Erlang expression. This is the full node set Phase 1 emits: variables,
/// literals (int, float, atom, nil, cons, tuple, binary), value lists, funs, the
/// binding/control forms (`let`/`letrec`/`case`), and the three call forms
/// (`apply`/`call`/`primop`).
///
/// Atom/variable conventions (see the module-level LEXICAL CONTRACT): atom
/// fields hold logical characters (printer quotes), variable fields hold raw
/// names (printer legalizes).
pub type CExpr {
  /// A variable reference. `name` is the raw upstream name (e.g. `"%p0"`,
  /// `"$loop0"`); the printer maps it through `legalize_var` to a Core-legal
  /// token. Apply the same name to the binder (`CFun`/`CLet`/`PVar`) and every
  /// reference so the binding still resolves.
  CVar(name: String)
  /// An integer literal, printed in decimal (`42`, `-3`). Per D5, WASM
  /// `f32`/`f64` values arrive here as their raw IEEE-754 *bit pattern* (an
  /// integer), NOT as a `CFloat` — BEAM doubles cannot represent NaN/Inf.
  CInt(value: Int)
  /// A genuine Erlang double literal (e.g. for a future term-layer frontend).
  /// NOT for WASM floats — see `CInt`/D5. Emitting a Gleam `Float` losslessly as
  /// a Core decimal is itself lossy/hard, so this path is unused in Phase 1.
  CFloat(value: Float)
  /// An atom literal. `name` is the atom's logical characters; the printer
  /// ALWAYS single-quotes and escapes it (there is no unquoted-atom form in Core
  /// Erlang). Use `CAtom("true")` as the unconditional `CClause` guard.
  CAtom(name: String)
  /// The empty list `[]` (Core's `Nil`).
  CNil
  /// A cons cell, printed `[Head|Tail]`.
  CCons(head: CExpr, tail: CExpr)
  /// A tuple, printed `{E1, E2, …}` (the empty tuple is `{}`).
  CTuple(elements: List(CExpr))
  /// A binary/bitstring, printed `#{ Segments }#`. Lock-now placeholder; the
  /// Phase-1 integer corpus does not exercise it.
  CBinary(segments: List(CBitSeg))
  /// A value list `<E1, E2, …>`. Used where Core Erlang expects multiple values
  /// (e.g. a multi-result `case` scrutinee or the RHS of a multi-binder `let`).
  CValues(values: List(CExpr))
  /// A lambda, printed `fun (V1, V2) -> Body`. `vars` are raw binder names
  /// (printer legalizes); on a `FunDef` RHS this is the function body.
  CFun(vars: List(String), body: CExpr)
  /// A same-module function VALUE reference, printed `'f'/N` (a bare `FName`
  /// as an expression). Distinct from `CApply` (which applies it) — this is
  /// the fun VALUE without a wrapping `fun(…) -> apply 'f'/N(…)` lambda.
  /// Used by `MakeClosure(f, [], N)` under the js profile so a zero-capture
  /// closure is the target function directly (BEAM stores it as a local-fun
  /// entry with no wrapper body — one dispatch instead of two on every call).
  CFunRef(name: FName)
  /// A `let`, printed `let X = Arg in Body` when `vars` has length 1, or
  /// `let <V1,V2,…> = Arg in Body` otherwise (length 0 or ≥ 2 → value-list
  /// form). The value-list arity MUST match what `arg` produces or `core_lint`
  /// rejects it (fact 7). `vars` are raw binder names (printer legalizes).
  CLet(vars: List(String), arg: CExpr, body: CExpr)
  /// A `letrec`, printed `letrec Defs… in Body`. Each def is a local recursive
  /// function (same shape as a top-level `FunDef`). Used by unit 08 to lower
  /// WASM structured control (`block`/`loop`) into tail-recursive locals.
  CLetrec(defs: List(FunDef), body: CExpr)
  /// A `case`, printed `case Arg of Clauses… end`. The clause pattern arity must
  /// match `arg`: a single-value `arg` pairs with 1-element value-list patterns
  /// `<P>` (fact 6); a `CValues` scrutinee of arity n pairs with n-element
  /// patterns.
  CCase(arg: CExpr, clauses: List(CClause))
  /// An intra-module function application, printed `apply 'f'/N (Args)`. `name`
  /// names a function in scope (a module def or an enclosing `letrec` def);
  /// `args` length should equal `name.arity`.
  CApply(name: FName, args: List(CExpr))
  /// Application of a fun VALUE (a first-class closure), printed `apply Op(Args)`
  /// where `Op` is an arbitrary expression — typically a `CVar` bound to a `fun`,
  /// or an inline `CFun`. DISTINCT from `CApply`, whose operand is a static `FName`
  /// (`'f'/N`, a same-module / `letrec` name): this node applies a *runtime fun
  /// value* (Phase-8 `CallClosure` — the native-closure headline). The BEAM checks
  /// the value's arity against `list.length(args)` (a `badarity` error on mismatch).
  /// It is NOT `erlang:apply(Mod, Fn, Args)` from data (D3a) — the operand is a
  /// value already in hand, never a program-chosen `module:atom`.
  CApplyExpr(op: CExpr, args: List(CExpr))
  /// An inter-module / BIF call, printed `call 'M':'F'(Args)`. `module` and
  /// `function` are `CExpr` for grammar fidelity (Core allows a computed
  /// module/fun), but per D3a the binding chokepoint ALWAYS supplies `CAtom`s
  /// resolving to a fixed build-controlled module — never program/attacker data.
  CCall(module: CExpr, function: CExpr, args: List(CExpr))
  /// A compiler primop, printed `primop 'Name'(Args)` (e.g.
  /// `primop 'match_fail'(…)`). `name` is the primop atom in logical form.
  CPrimop(name: String, args: List(CExpr))
  /// A `try … catch`, printed (per the verified OTP-29 `core_pp` form, T5):
  /// ```text
  /// try
  ///     <Arg>
  /// of <V1,…> ->
  ///     <Body>
  /// catch <Ec,Er,Es> ->
  ///     <Handler>
  /// ```
  /// with NO outer parentheses and NO Erlang-style `end` (Core Erlang has no general
  /// `( expr )` rule and the `try` form is self-delimiting — both empirically verified
  /// against `core_scan`/`core_parse`). Models cerl's `#c_try{arg, vars, body, evars,
  /// handler}`.
  ///
  /// - `arg`: the protected expression (its exceptions are caught).
  /// - `body_vars`: bind `arg`'s success value(s); P7-06 always uses a SINGLE transparent
  ///   binder (every emitted expr reduces to one packaged value — the try's `of <V> -> V`
  ///   pass-through, §C.1).
  /// - `body`: the success continuation (P7-06 emits `CVar(v)` — the identity).
  /// - `evars`: the THREE exception pattern variables `[Class, Reason, Stack]` bound on a
  ///   raise (all classes caught; the handler dispatches on the term shape). The third is
  ///   the RAW stacktrace token — to re-raise faithfully a caller must first pass it through
  ///   `primop 'build_stacktrace'` (verified: `erlang:raise/3` on the raw token returns
  ///   `badarg`).
  /// - `handler`: the catch body (P7-06's `case`-on-`Reason` tag dispatch + re-raise default).
  CTry(
    arg: CExpr,
    body_vars: List(String),
    body: CExpr,
    evars: List(String),
    handler: CExpr,
  )
}

/// A `case` clause, printed `<P1,P2,…> when Guard -> Body`.
///
/// - `pats`: the clause's pattern list. The printer ALWAYS wraps it in a
///   value-list `<…>` (even for a single pattern) so it matches the scrutinee's
///   value-list shape (fact 6). Length must equal the scrutinee arity.
/// - `guard`: MANDATORY. A guardless clause is a Core Erlang syntax error, so an
///   unconditional arm uses `CAtom("true")`, which prints `when 'true'`.
/// - `body`: the clause body expression.
pub type CClause {
  CClause(pats: List(CPat), guard: CExpr, body: CExpr)
}

/// A Core Erlang pattern (Phase-1 subset — enough to lower `if` and integer
/// `switch`). Variable patterns hold raw names (printer legalizes); atom
/// patterns hold logical characters (printer quotes).
pub type CPat {
  /// A variable pattern, binding `name` (raw; printer legalizes). A fresh unique
  /// name acts as a wildcard — Phase-1 upstream supplies SSA-unique names.
  PVar(name: String)
  /// An integer-literal pattern, printed in decimal.
  PInt(value: Int)
  /// An atom-literal pattern (printer quotes/escapes `name`).
  PAtom(name: String)
  /// A tuple pattern `{P1, P2, …}`.
  PTuple(elements: List(CPat))
  /// A cons pattern `[Head|Tail]`.
  PCons(head: CPat, tail: CPat)
  /// The empty-list pattern `[]`.
  PNil
}

/// A binary segment (lock-now placeholder; the Phase-1 integer corpus does not
/// exercise this, so the printer emits it minimally and it is untested until a
/// binary-using corpus exists).
///
/// Models one segment of a Core Erlang bitstring constructor:
/// `#<Value>(Size, Unit, Type, Flags)`.
/// - `value`: the segment value expression.
/// - `size`: the segment size expression (e.g. `CInt(8)`).
/// - `unit`: the size unit multiplier (bits per size step).
/// - `segtype`: the segment type atom in logical form (e.g. `"integer"`,
///   `"binary"`, `"float"`).
/// - `flags`: endianness/sign flag atoms in logical form (e.g.
///   `["unsigned", "big"]`).
pub type CBitSeg {
  CBitSeg(
    value: CExpr,
    size: CExpr,
    unit: Int,
    segtype: String,
    flags: List(String),
  )
}
