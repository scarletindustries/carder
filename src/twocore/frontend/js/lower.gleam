//// `twocore/frontend/js/lower` — lower an arc JavaScript AST to a 2core IR module.
////
//// This is the middle of a JS AOT compiler: arc parses JS → this lowers the AST to
//// `twocore/ir` → 2core's backend emits native BEAM. JS values are **native BEAM
//// terms** (numbers as int/float, strings as binaries, booleans/null/undefined as
//// atoms, objects as `rt_js` refs), so arithmetic runs on `erlang:'+'` etc.
////
//// SPEED: every polymorphic operator compiles to a GUARDED dispatch —
//// `if IsNumber(a) && IsNumber(b) then NumTerm(native +) else CallHost("js",op)` —
//// so hot numeric code is native BEAM arithmetic and only non-number operands take
//// the `rt_js` cold path (real JS concat/coercion/NaN). Benchmarks put this ~20×
//// over an interpreter with the guards essentially free (BEAM's JIT specialises the
//// guarded arithmetic).
////
//// Supported subset (v1): top-level `function` declarations (recursion, mutual
//// recursion, calls, default + rest parameters, call spread `f(...a)`, and under-/
//// over-application — a missing argument arrives as `undefined`); number/string/
//// boolean/null/undefined/template literals;
//// `+ - * / %`, all comparisons, `&& || ! ??`, bitwise/shift `& | ^ ~ << >> >>>`, unary
//// `- + ! ~ typeof void delete`, `in`, `instanceof`, comma `,`, `?:`, optional chaining
//// `?.`; `let/const/var`, `= += -= *= /=
//// %= **= &= |= ^= <<= >>= >>>=`, logical assignment `&&= ||= ??=`, and `++`/`--`;
//// `if/else`, `while`, `do/while`, `for`,
//// `for-in`, `break/continue` (incl. labeled `break outer`/`continue outer`),
//// `return`, blocks; array/object destructuring (incl. nested) in `let`/`const`/`var`;
//// objects
//// `{}` with `.prop`/`[k]` get/set, spread `{...o}`, and method shorthand; arrays `[…]`
//// with indexing, `.length`, spread `[...a]`; first-class functions — function
//// expressions, arrow functions, closures
//// (value-capture), higher-order calls, IIFEs; classes (constructor, instance methods
//// & fields, static methods, `new`, `this`, method calls, `extends`/`super`
//// inheritance); `console.log`. Control flow threads mutated variables as loop-carried params /
//// phi-merged `If`s.
////
//// Control flow also includes `for-of` (over arrays/strings), `switch` (with
//// fall-through, default in any position, and `break` that targets the switch), and
//// `throw` / `try`/`catch` (a thrown JS value transported via the module's `js_exn`
//// tag; `return`/`break`/`continue` inside a try body transfer out correctly).
////
//// Builtins: the `Math` namespace (functions + constants); array methods (push/pop/
//// shift/unshift, map/filter/forEach/reduce/reduceRight/some/every/find/findIndex,
//// indexOf/includes/join/slice/concat/reverse/sort, flat/fill/at); string `.length`,
//// indexing, and methods (charAt/charCodeAt/codePointAt, toUpperCase/toLowerCase, indexOf/includes/slice/
//// substring, split/trim/repeat/startsWith/endsWith/replace/replaceAll, padStart/
//// padEnd/at); the global functions `parseInt`/`parseFloat`/`isNaN`/`isFinite`/
//// `String`/`Number`/`Boolean`; the global constants `NaN`/`Infinity`/`undefined`
//// (a local binding of the same name shadows them); and the statics `Array.isArray`/`of`/`from`,
//// `Object.keys`/`values`/`entries`/`assign`/`fromEntries`,
//// `Number.isInteger`/`isNaN`/`isFinite`, `JSON.stringify`/`parse`,
//// `String.fromCharCode`/`fromCodePoint`/`String.raw`, and `Date.now`. Tagged templates
//// `` tag`…${e}…` `` (the tag receives the cooked strings array with a `.raw`
//// property, then the substitutions). Regex literals `/pat/flags` (backed by
//// Erlang's PCRE) with `re.test`, `str.match`/`replace`/`split`, and `re.source`/`flags`.
//// `Map`/`Set` (`new Map()`/`new Set()`, `.set`/`.get`/`.add`/`.has`/`.delete`/`.clear`/
//// `.forEach`/`.size`; these method names delegate to a same-named user method on a
//// plain object).
////
//// Not yet (a clean `Unsupported` error / panic): getter/setter and static-field class
//// members, defaulted/rest destructuring, `try`/`finally`, generators/async,
//// and `continue` inside a `do/while`. (Rest params and call spread apply to
//// top-level functions; a rest param on an arrow/method, or a spread INTO a rest
//// function, is a v1 limitation. A derived
//// class needs an explicit constructor that calls `super(…)`; field initializers run
//// before `super()` rather than after — v1 ordering simplifications. A regular function
//// EXPRESSION captures `this` lexically like an arrow. `JSON`/`Object.keys` key order
//// follows the backing map, not insertion order.)
//// (A default value on an arrow/function-EXPRESSION param only applies when it is
//// called with the full arity or through an array method, since a closure call site
//// can't pad; top-level function defaults always apply.) Only an explicit `throw` is
//// caught (a runtime type error propagates), and a variable mutated in a try body
//// before a throw keeps its pre-try value in the handler. Scope is one flat function
//// scope per JS function (block-scoped `let` is treated as function-scoped).
////
//// Known v1 deviations from the spec (intentional, for speed / simplicity):
////   * Integers are native BEAM integers, so `+ - *` on values beyond 2^53 stay exact
////     (arbitrary precision) instead of rounding to the nearest IEEE-754 double. Within
////     the safe-integer range results match JS exactly; this is the price of native
////     arithmetic. (`/ %` always take the `rt_js` double path.)
////   * An assignment that is NOT the outermost expression of a statement (nor a direct
////     `x = y = e` chain) — e.g. `f(x = 1)`, `(x = 1) + 1`, `while ((l = next()) != null)`
////     — computes the right value but does not rebind its target in the env, so a later
////     read of that target sees the old value. Top-level and chained assignments are fine.
////   * A POSTFIX `x++`/`x--` yields the NEW value (not the pre-increment value) when its
////     result is used inside a larger expression. As a statement or a `for` update — where
////     the value is discarded — it is exact.
////   * Closures capture enclosing variables BY VALUE (a snapshot at creation). Capturing a
////     variable that is REASSIGNED in its scope (or by the closure) is rejected with a typed
////     error rather than silently diverging from JS's capture-by-reference; capturing a
////     mutable OBJECT/array is fine (the shared reference is what's captured).
////   * String `.length`/indexing/`charAt`/`slice`/`substring` count Unicode CODE POINTS,
////     not UTF-16 code units, so an astral-plane character counts as 1 (JS counts it as 2).
////     BMP text (the common case) is exact.
////   * `Object.keys`/`values`/`entries` return keys in the backing map's iteration order,
////     not JS property-insertion order.
////   * A class instance method whose name matches a builtin ARRAY/STRING method
////     (`push`/`pop`/`map`/`filter`/`slice`/`indexOf`/…) is shadowed by the builtin at a
////     `obj.method(…)` call site. The collection names `get`/`set`/`has`/`add`/`delete`/
////     `clear`/`forEach` (Map/Set) DO delegate to a same-named user method; the array
////     names do not. Name such methods differently to avoid the collision.
////   * `switch` case-test expressions are evaluated eagerly (all of them, top-to-bottom)
////     to pick the entry point, rather than lazily in order stopping at the first `===`
////     match. Pure/literal tests (the common case) are unaffected; a side-effecting or
////     non-deterministic case test may run when JS would not have reached it.
////   * A `break`/`continue` to a label attached to a `switch` or a plain block that is
////     nested OUTSIDE a loop targets the wrong construct; labels on loops work correctly.

import arc/parser/ast
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import twocore/ir

/// A lowering failure for unsupported syntax.
pub type Error {
  Unsupported(what: String)
}

/// JS variable name → its current IR `Value` (SSA binding).
type Env =
  Dict(String, ir.Value)

/// The enclosing loop (for `break`/`continue`): its IR label, the ordered set of
/// loop-carried variable names (so a transfer re-supplies them), the `for`-loop
/// update expression that a `continue` must run before looping (`None` for
/// `while`/`do-while`), and whether it is a `do-while` (whose back-edge re-tests the
/// condition, which our top-of-loop model can't express for an explicit `continue`).
type Loop {
  Loop(
    label: String,
    carried: List(String),
    update: Option(ast.Expression),
    do_while: Bool,
  )
}

/// Ordered `Let` bindings to emit around a continuation, in evaluation order.
type Bind =
  #(String, ir.Expr)

/// A lifted function/arrow expression: its generated IR name, parameter names, body
/// (normalised to a statement list), and the enclosing-scope variables it captures
/// (in the order they become the IR function's LEADING parameters, per `MakeClosure`).
type Lambda {
  Lambda(
    name: String,
    params: List(String),
    defaults: List(#(String, ast.Expression)),
    body: List(ast.Statement),
    captures: List(String),
  )
}

/// Immutable per-function context: the set of top-level function names (a call to one
/// is a `CallDirect`); the current loop, if any; every lifted lambda keyed by its
/// source span (so an arrow/function-expression node lowers to a `MakeClosure` of its
/// lifted function); and the set of variables reassigned in the CURRENT function scope
/// (a closure that captures one of these by value would be unsound, so it is rejected).
/// A class's shape for `new C(…)`: its superclass (for `extends`/`super` and inherited
/// methods), how many args its constructor takes, and each instance method's name +
/// arity (its lifted function is `C$constructor` / `C$name`).
type ClassInfo {
  ClassInfo(
    super_class: Option(String),
    ctor_arity: Int,
    methods: List(#(String, Int)),
    statics: List(#(String, Int)),
  )
}

type Ctx {
  Ctx(
    funcs: List(String),
    fn_arity: Dict(String, Int),
    // top-level functions with a rest param → their FIXED param count (a call bundles
    // the trailing args into the rest array passed as the last parameter).
    fn_rest: Dict(String, Int),
    classes: Dict(String, ClassInfo),
    // the superclass name while lowering a class's constructor/methods (for `super`).
    current_super: Option(String),
    loop: Option(Loop),
    brk: Option(#(String, List(String))),
    // JS labels in scope → (break target, loop for `continue`), for labeled loops.
    labels: Dict(String, #(#(String, List(String)), Loop)),
    // a JS label attached to the immediately-following loop (consumed by `lower_loop`).
    pending_label: Option(String),
    lambdas: Dict(ast.Span, Lambda),
    scope_mutated: List(String),
  )
}

// ── entry ───────────────────────────────────────────────────────────────────

/// Lower a parsed JS program to an IR module named `module_name`. Each top-level
/// `function` declaration becomes an exported IR function; the remaining top-level
/// statements become an exported `main/0`.
pub fn program(
  program: ast.Program,
  module_name: String,
) -> Result(ir.Module, Error) {
  let stmts = case program {
    ast.Script(body:) -> list.map(body, fn(w) { w.statement })
    ast.Module(..) -> []
  }
  let decls = list.filter_map(stmts, as_function_decl)
  let fn_names = list.map(decls, fn(d) { d.0 })
  let class_decls = list.filter_map(stmts, as_class_decl)
  let classes =
    dict.from_list(
      list.map(class_decls, fn(c) { #(c.0, class_info(c.1, c.2)) }),
    )
  let top =
    list.filter(stmts, fn(s) {
      as_function_decl(s) == Error(Nil) && as_class_decl(s) == Error(Nil)
    })

  // Pre-pass: lift every function/arrow expression (in top-level code AND inside the
  // declared functions and class methods) to a named IR function, keyed by span.
  let scan =
    list.flatten([
      top,
      list.flat_map(decls, fn(d) { block_stmts(d.2) }),
      list.flat_map(class_decls, fn(c) { class_scan_stmts(c.2) }),
    ])
  use lambdas <- result_try(collect_lambdas(scan, fn_names))
  let fn_arity =
    dict.from_list(list.map(decls, fn(d) { #(d.0, list.length(d.1)) }))
  let fn_rest =
    dict.from_list(
      list.filter_map(decls, fn(d) {
        case list.last(d.1) {
          Ok(ast.RestElement(..)) -> Ok(#(d.0, list.length(d.1) - 1))
          _ -> Error(Nil)
        }
      }),
    )
  let ctx =
    Ctx(
      funcs: fn_names,
      fn_arity:,
      fn_rest:,
      classes:,
      current_super: None,
      loop: None,
      brk: None,
      labels: dict.new(),
      pending_label: None,
      lambdas:,
      scope_mutated: [],
    )

  use funcs <- result_try(
    list.try_map(decls, fn(d) {
      let #(name, params, body) = d
      lower_function(name, params, body, ctx)
    }),
  )
  use main <- result_try(lower_main(top, ctx))
  use lambda_funcs <- result_try(
    list.try_map(dict.values(lambdas), fn(lam) { lower_lambda(lam, ctx) }),
  )
  use class_fn_lists <- result_try(
    list.try_map(class_decls, fn(c) { lower_class(c.0, c.1, c.2, ctx) }),
  )
  let class_funcs = list.flatten(class_fn_lists)

  // The named JS functions (exported) plus the internal lifted lambdas + class
  // methods (not exported).
  let named = [main, ..funcs]
  let functions = list.flatten([named, lambda_funcs, class_funcs])
  Ok(ir.Module(
    name: module_name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(named, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
    // The single exception tag carrying a thrown JS value (`throw x` / `try`/`catch`).
    tags: [ir.TagDecl(js_exn_tag, [ir.TTerm])],
  ))
}

/// The name of the module-level exception tag that transports a thrown JS value.
const js_exn_tag = "js_exn"

/// A class's constructor (params + body, if any), instance methods, static methods
/// (each name + params + body), and instance fields (name + optional initializer).
/// Getters/setters, static fields, and computed keys are `Unsupported`.
type ClassParts {
  ClassParts(
    ctor: Option(#(List(ast.Pattern), ast.Statement)),
    methods: List(#(String, List(ast.Pattern), ast.Statement)),
    statics: List(#(String, List(ast.Pattern), ast.Statement)),
    fields: List(#(String, Option(ast.Expression))),
  )
}

fn as_class_decl(
  s: ast.Statement,
) -> Result(#(String, Option(String), ClassParts), Nil) {
  case s {
    ast.ClassDeclaration(name: Some(name), super_class:, body:, ..) -> {
      let parent = case super_class {
        Some(ast.Identifier(name: p, ..)) -> Some(p)
        _ -> None
      }
      // A non-identifier `extends` (e.g. a mixin expression) isn't supported.
      case super_class, parent {
        Some(_), None -> Error(Nil)
        _, _ ->
          case class_parts(body) {
            Ok(parts) -> Ok(#(name, parent, parts))
            Error(_) -> Error(Nil)
          }
      }
    }
    _ -> Error(Nil)
  }
}

fn class_parts(body: List(ast.ClassElement)) -> Result(ClassParts, Error) {
  list.try_fold(body, ClassParts(None, [], [], []), fn(acc, el) {
    case el {
      ast.ClassMethod(value:, kind: ast.MethodConstructor, is_static: False, ..) -> {
        use #(params, b) <- result_try(method_fn(value))
        Ok(ClassParts(..acc, ctor: Some(#(params, b))))
      }
      // static method — called as `C.method(...)`, no `this`.
      ast.ClassMethod(
        key: ast.Identifier(name:, ..),
        value:,
        kind: ast.MethodMethod,
        is_static: True,
        computed: False,
      ) -> {
        use #(params, b) <- result_try(method_fn(value))
        Ok(
          ClassParts(
            ..acc,
            statics: list.append(acc.statics, [#(name, params, b)]),
          ),
        )
      }
      ast.ClassMethod(
        key: ast.Identifier(name:, ..),
        value:,
        kind: ast.MethodMethod,
        is_static: False,
        computed: False,
      ) -> {
        use #(params, b) <- result_try(method_fn(value))
        Ok(
          ClassParts(
            ..acc,
            methods: list.append(acc.methods, [#(name, params, b)]),
          ),
        )
      }
      ast.ClassField(
        key: ast.Identifier(name:, ..),
        value: init,
        is_static: False,
        computed: False,
      ) ->
        Ok(ClassParts(..acc, fields: list.append(acc.fields, [#(name, init)])))
      _ ->
        Error(Unsupported(
          "class element (static/getter/setter/computed/extends)",
        ))
    }
  })
}

fn method_fn(
  value: ast.Expression,
) -> Result(#(List(ast.Pattern), ast.Statement), Error) {
  case value {
    ast.FunctionExpression(params:, body:, ..) -> Ok(#(params, body))
    _ -> Error(Unsupported("class method value"))
  }
}

/// `this.name = init;` — a field-initializer statement prepended to the constructor.
fn field_init_stmt(
  name: String,
  init: Option(ast.Expression),
) -> ast.Statement {
  let sp = ast.Span(0, 0)
  let value = case init {
    Some(e) -> e
    None -> ast.UndefinedExpression(span: sp)
  }
  ast.ExpressionStatement(
    expression: ast.AssignmentExpression(
      span: sp,
      operator: ast.Assign,
      left: ast.MemberExpression(
        span: sp,
        object: ast.ThisExpression(span: sp),
        property: ast.Identifier(span: sp, name: name),
        computed: False,
      ),
      right: value,
    ),
    directive: None,
  )
}

/// The constructor's statement list: instance field initializers first, then the
/// explicit constructor body (if any).
fn ctor_body_stmts(parts: ClassParts) -> List(ast.Statement) {
  let inits = list.map(parts.fields, fn(f) { field_init_stmt(f.0, f.1) })
  let body = case parts.ctor {
    Some(#(_, b)) -> block_stmts(b)
    None -> []
  }
  list.append(inits, body)
}

/// Every statement list belonging to a class (constructor + method bodies) — used to
/// feed the lambda pre-pass so closures inside methods are collected.
fn class_scan_stmts(parts: ClassParts) -> List(ast.Statement) {
  list.flatten([
    ctor_body_stmts(parts),
    list.flat_map(parts.methods, fn(m) { block_stmts(m.2) }),
    list.flat_map(parts.statics, fn(m) { block_stmts(m.2) }),
  ])
}

/// Lower a class constructor/method to an IR function whose FIRST parameter is `this`.
fn lower_class_method(
  fn_name: String,
  params: List(ast.Pattern),
  body_stmts: List(ast.Statement),
  ctx: Ctx,
) -> Result(ir.Function, Error) {
  use #(pnames, defaults, rest) <- result_try(param_info(params))
  use _ <- result_try(case rest {
    Some(_) -> Error(Unsupported("rest parameter in a class method"))
    None -> Ok(Nil)
  })
  let all = ["this", ..pnames]
  let env =
    list.fold(all, dict.new(), fn(acc, n) { dict.insert(acc, n, ir.Var(n)) })
  let stmts = list.append(default_prologue(defaults), body_stmts)
  let ctx2 = Ctx(..ctx, scope_mutated: assigned_in(stmts))
  use #(body_expr, _ctr) <- result_try(lower_body(stmts, env, ctx2, 0))
  Ok(ir.Function(
    name: fn_name,
    params: list.map(all, fn(n) { ir.Local(n, ir.TTerm) }),
    result: [ir.TTerm],
    locals: [],
    body: body_expr,
  ))
}

/// A class's `ClassInfo` (constructor arity + method arities) computed from its parts,
/// without lowering — so `new C(…)` can resolve before the methods are lowered.
fn class_info(parent: Option(String), parts: ClassParts) -> ClassInfo {
  let ctor_arity = case parts.ctor {
    Some(#(p, _)) -> list.length(p)
    None -> 0
  }
  ClassInfo(
    super_class: parent,
    ctor_arity: ctor_arity,
    methods: list.map(parts.methods, fn(m) { #(m.0, list.length(m.1)) }),
    statics: list.map(parts.statics, fn(m) { #(m.0, list.length(m.1)) }),
  )
}

/// Generate the IR functions for one class: `C$constructor(this, …)` plus
/// `C$name(this, …)` per method. The class's constructor/methods are lowered with
/// `current_super` set to the superclass so `super` resolves.
fn lower_class(
  cname: String,
  parent: Option(String),
  parts: ClassParts,
  ctx: Ctx,
) -> Result(List(ir.Function), Error) {
  let cctx = Ctx(..ctx, current_super: parent)
  let ctor_params = case parts.ctor {
    Some(#(p, _)) -> p
    None -> []
  }
  use ctor_fn <- result_try(lower_class_method(
    cname <> "$constructor",
    ctor_params,
    ctor_body_stmts(parts),
    cctx,
  ))
  use method_fns <- result_try(
    list.try_map(parts.methods, fn(m) {
      let #(mname, mparams, mbody) = m
      lower_class_method(
        cname <> "$" <> mname,
        mparams,
        block_stmts(mbody),
        cctx,
      )
    }),
  )
  // static methods are plain functions (no `this`): reuse the top-level function path.
  use static_fns <- result_try(
    list.try_map(parts.statics, fn(m) {
      let #(mname, mparams, mbody) = m
      lower_function(cname <> "$static$" <> mname, mparams, mbody, cctx)
    }),
  )
  Ok(list.flatten([[ctor_fn], method_fns, static_fns]))
}

/// The instance methods to install for `new C(…)`, ancestors-first (so an overriding
/// child method, installed later, wins): `(defining_class, method_name, arity)`.
/// The class names in `cname`'s inheritance chain (self first, then ancestors) — used
/// to tag an instance for `instanceof`.
fn class_chain(
  cname: String,
  classes: Dict(String, ClassInfo),
) -> List(String) {
  case dict.get(classes, cname) {
    Ok(ClassInfo(super_class: Some(p), ..)) -> [
      cname,
      ..class_chain(p, classes)
    ]
    _ -> [cname]
  }
}

fn chain_methods(
  cname: String,
  classes: Dict(String, ClassInfo),
) -> List(#(String, String, Int)) {
  case dict.get(classes, cname) {
    Error(Nil) -> []
    Ok(info) -> {
      let ancestors = case info.super_class {
        Some(p) -> chain_methods(p, classes)
        None -> []
      }
      let own = list.map(info.methods, fn(m) { #(cname, m.0, m.1) })
      list.append(ancestors, own)
    }
  }
}

fn as_function_decl(
  s: ast.Statement,
) -> Result(#(String, List(ast.Pattern), ast.Statement), Nil) {
  case s {
    ast.FunctionDeclaration(name: Some(name), params:, body:, ..) ->
      Ok(#(name, params, body))
    _ -> Error(Nil)
  }
}

fn lower_function(
  name: String,
  params: List(ast.Pattern),
  body: ast.Statement,
  ctx: Ctx,
) -> Result(ir.Function, Error) {
  use #(pnames, defaults, rest) <- result_try(param_info(params))
  // A rest param is an ordinary trailing parameter bound to an array (the caller
  // bundles the extra args); no default prologue applies to it.
  let all_params = case rest {
    Some(r) -> list.append(pnames, [r])
    None -> pnames
  }
  let env =
    list.fold(all_params, dict.new(), fn(acc, n) {
      dict.insert(acc, n, ir.Var(n))
    })
  let stmts = list.append(default_prologue(defaults), block_stmts(body))
  let ctx2 = Ctx(..ctx, scope_mutated: assigned_in(stmts))
  use #(body_expr, _ctr) <- result_try(lower_body(stmts, env, ctx2, 0))
  Ok(ir.Function(
    name: name,
    params: list.map(all_params, fn(n) { ir.Local(n, ir.TTerm) }),
    result: [ir.TTerm],
    locals: [],
    body: body_expr,
  ))
}

fn lower_main(
  stmts: List(ast.Statement),
  ctx: Ctx,
) -> Result(ir.Function, Error) {
  let ctx2 = Ctx(..ctx, scope_mutated: assigned_in(stmts))
  use #(body, _ctr) <- result_try(lower_body(stmts, dict.new(), ctx2, 0))
  Ok(ir.Function(
    name: "main",
    params: [],
    result: [ir.TTerm],
    locals: [],
    body:,
  ))
}

/// Lower a function/program body: a statement list whose fall-through yields
/// `undefined` (JS functions with no `return`).
fn lower_body(
  stmts: List(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(ir.Expr, Int), Error) {
  lower_stmts(stmts, env, ctx, ctr, fn(_env, ctr) {
    Ok(#(ir.Values([undefined()]), ctr))
  })
}

// ── statements (CPS: `k` is the continuation given the resulting env) ─────────

type Cont =
  fn(Env, Int) -> Result(#(ir.Expr, Int), Error)

fn lower_stmts(
  stmts: List(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case stmts {
    [] -> k(env, ctr)
    [s, ..rest] ->
      lower_stmt(s, env, ctx, ctr, fn(env2, ctr2) {
        lower_stmts(rest, env2, ctx, ctr2, k)
      })
  }
}

fn lower_stmt(
  s: ast.Statement,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case s {
    ast.EmptyStatement -> k(env, ctr)
    ast.BlockStatement(body:) ->
      lower_stmts(list.map(body, fn(w) { w.statement }), env, ctx, ctr, k)

    // `return e;` — terminates (the continuation is dead).
    ast.ReturnStatement(argument: arg) -> {
      let #(e, ctr2) = case arg {
        Some(e) -> #(e, ctr)
        None -> #(ast.UndefinedExpression(span: ast.Span(0, 0)), ctr)
      }
      use #(binds, v, ctr3) <- result_try(lower_expr(e, env, ctx, ctr2))
      Ok(#(emit_lets(binds, ir.Return([v])), ctr3))
    }

    // `let/const/var x = e;` (flat scope) — extend env, continue.
    ast.VariableDeclaration(declarations:, ..) ->
      lower_var_decls(declarations, env, ctx, ctr, k)

    // A bare expression (assignment, call, …) — evaluate for effect, continue. An
    // assignment `x = e` rebinds `x` to the ACTUAL rhs value in the env.
    ast.ExpressionStatement(expression: e, ..) -> {
      use #(binds, v, ctr2) <- result_try(lower_expr(e, env, ctx, ctr))
      use #(rest, ctr3) <- result_try(k(env_after_effect(e, v, env), ctr2))
      Ok(#(emit_lets(binds, rest), ctr3))
    }

    ast.IfStatement(condition:, consequent:, alternate:) ->
      lower_if(condition, consequent, alternate, env, ctx, ctr, k)

    ast.WhileStatement(condition:, body:) ->
      lower_while(condition, body, False, env, ctx, ctr, k)
    ast.DoWhileStatement(condition:, body:) ->
      lower_while(condition, body, True, env, ctx, ctr, k)
    ast.ForStatement(init:, condition:, update:, body:) ->
      lower_for(init, condition, update, body, env, ctx, ctr, k)
    ast.ForOfStatement(left:, right:, body:, ..) ->
      lower_for_of(left, right, body, env, ctx, ctr, k)
    // `for (k in obj)` — iterate the object's own keys (desugar to for-of over
    // `Object.keys(obj)`; order is the backing map's, a documented deviation).
    ast.ForInStatement(left:, right:, body:) -> {
      let sp = ast.Span(0, 0)
      let keys =
        ast.CallExpression(
          span: sp,
          callee: ast.MemberExpression(
            span: sp,
            object: ast.Identifier(span: sp, name: "Object"),
            property: ast.Identifier(span: sp, name: "keys"),
            computed: False,
          ),
          arguments: [right],
        )
      lower_for_of(left, keys, body, env, ctx, ctr, k)
    }
    ast.SwitchStatement(discriminant:, cases:) ->
      lower_switch(discriminant, cases, env, ctx, ctr, k)
    // `throw e` — raise the JS exception tag carrying `e`; the continuation is dead.
    ast.ThrowStatement(argument: arg) -> {
      use #(binds, v, ctr) <- result_try(lower_expr(arg, env, ctx, ctr))
      Ok(#(emit_lets(binds, ir.Throw(js_exn_tag, [v])), ctr))
    }
    ast.TryStatement(block:, handler:, finalizer:) ->
      lower_try(block, handler, finalizer, env, ctx, ctr, k)

    // `label: <loop>` — attach the label to the following loop (via `pending_label`).
    ast.LabeledStatement(label:, body:) ->
      lower_stmt(body, env, Ctx(..ctx, pending_label: Some(label)), ctr, k)

    ast.BreakStatement(label: None) ->
      case ctx.brk {
        // break targets the innermost loop OR switch.
        Some(#(label, carried)) ->
          Ok(#(ir.Break(label, carried_vals(env, carried)), ctr))
        None -> Error(Unsupported("break outside a loop or switch"))
      }
    // `break outer` — target the labeled loop's exit.
    ast.BreakStatement(label: Some(name)) ->
      case dict.get(ctx.labels, name) {
        Ok(#(#(label, carried), _loop)) ->
          Ok(#(ir.Break(label, carried_vals(env, carried)), ctr))
        Error(Nil) ->
          Error(Unsupported("break to unknown label '" <> name <> "'"))
      }
    ast.ContinueStatement(label: None) ->
      case ctx.loop {
        // A do/while back-edge re-tests the condition; our loop's `Continue` re-enters
        // the top of the body, which can't express that for an explicit `continue`.
        Some(Loop(do_while: True, ..)) ->
          Error(Unsupported("`continue` inside a do/while loop"))
        // `for`-loop `continue` must run the update; `continue_edge` handles both it
        // and the plain `while` case.
        Some(loop) -> continue_edge(loop, env, ctx, ctr)
        None -> Error(Unsupported("continue outside a loop"))
      }
    // `continue outer` — re-enter the labeled loop.
    ast.ContinueStatement(label: Some(name)) ->
      case dict.get(ctx.labels, name) {
        Ok(#(_brk, Loop(do_while: True, ..))) ->
          Error(Unsupported("labeled `continue` into a do/while loop"))
        Ok(#(_brk, loop)) -> continue_edge(loop, env, ctx, ctr)
        Error(Nil) ->
          Error(Unsupported("continue to unknown label '" <> name <> "'"))
      }

    ast.FunctionDeclaration(..) -> k(env, ctr)
    // hoisted at the top level
    _ -> Error(Unsupported("statement: " <> string_tag(s)))
  }
}

fn lower_var_decls(
  decls: List(ast.VariableDeclarator),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case decls {
    [] -> k(env, ctr)
    [
      ast.VariableDeclarator(id: ast.IdentifierPattern(name: x, ..), init:),
      ..rest
    ] -> {
      let #(e, _) = case init {
        Some(e) -> #(e, Nil)
        None -> #(ast.UndefinedExpression(span: ast.Span(0, 0)), Nil)
      }
      use #(binds, v, ctr2) <- result_try(lower_expr(e, env, ctx, ctr))
      use #(more, ctr3) <- result_try(lower_var_decls(
        rest,
        dict.insert(env, x, v),
        ctx,
        ctr2,
        k,
      ))
      Ok(#(emit_lets(binds, more), ctr3))
    }
    // `let [a, b] = e` / `let {x, y} = e` — desugar to a temp + simple declarators.
    [ast.VariableDeclarator(id: pattern, init:), ..rest] -> {
      let init_expr = case init {
        Some(e) -> e
        None -> ast.UndefinedExpression(span: ast.Span(0, 0))
      }
      use #(simple, ctr) <- result_try(desugar_destructure(
        pattern,
        init_expr,
        ctr,
      ))
      lower_var_decls(list.append(simple, rest), env, ctx, ctr, k)
    }
  }
}

/// Desugar an array/object destructuring binding `pattern = init` into a temp holding
/// `init` plus one simple declarator per bound name (`a = $d[0]`, `x = $d.x`, …). v1
/// handles a flat pattern of identifiers (holes allowed); nested patterns, defaults,
/// and rest elements are `Unsupported`.
fn desugar_destructure(
  pattern: ast.Pattern,
  init: ast.Expression,
  ctr: Int,
) -> Result(#(List(ast.VariableDeclarator), Int), Error) {
  let sp = ast.Span(0, 0)
  let tmp = "%d_" <> int.to_string(ctr)
  let ctr = ctr + 1
  let d_id = ast.Identifier(span: sp, name: tmp)
  let temp =
    ast.VariableDeclarator(
      id: ast.IdentifierPattern(name: tmp, span: sp),
      init: Some(init),
    )
  case pattern {
    ast.ArrayPattern(elements:) -> {
      let indexed = list.index_map(elements, fn(el, i) { #(el, i) })
      use decls <- result_try(
        list.try_fold(indexed, [], fn(acc, pair) {
          let #(el, i) = pair
          case el {
            None -> Ok(acc)
            Some(ast.AssignmentPattern(..)) ->
              Error(Unsupported("defaulted destructuring element"))
            Some(ast.RestElement(..)) ->
              Error(Unsupported("rest element in a destructuring pattern"))
            // any binding pattern (identifier OR nested array/object) — a nested one is
            // re-desugared by `lower_var_decls` when it processes this declarator.
            Some(pat) -> {
              let access =
                ast.MemberExpression(
                  span: sp,
                  object: d_id,
                  property: ast.NumberLiteral(span: sp, value: int.to_float(i)),
                  computed: True,
                )
              Ok(
                list.append(acc, [
                  ast.VariableDeclarator(id: pat, init: Some(access)),
                ]),
              )
            }
          }
        }),
      )
      Ok(#([temp, ..decls], ctr))
    }
    ast.ObjectPattern(properties:) -> {
      use decls <- result_try(
        list.try_map(properties, fn(p) {
          case p {
            ast.PatternProperty(value: ast.AssignmentPattern(..), ..) ->
              Error(Unsupported("defaulted object destructuring"))
            // any binding pattern for the value — a nested one re-desugars.
            ast.PatternProperty(key:, value: valpat, computed:, ..) -> {
              let access =
                ast.MemberExpression(
                  span: sp,
                  object: d_id,
                  property: key,
                  computed: computed,
                )
              Ok(ast.VariableDeclarator(id: valpat, init: Some(access)))
            }
            ast.RestProperty(..) ->
              Error(Unsupported("rest element in object destructuring"))
          }
        }),
      )
      Ok(#([temp, ..decls], ctr))
    }
    _ -> Error(Unsupported("destructuring pattern"))
  }
}

/// The env after evaluating an expression whose value is `v`: if it is an assignment
/// `x = …` to an identifier, rebind `x` to `v` (the assignment's value, which
/// `lower_expr` already returned). For a chain `x = y = e`, every target receives the
/// same value `v`, so we recurse into the RHS to rebind `y` as well.
///
/// LIMITATION (v1): only the outermost assignment and a direct assignment chain are
/// rebound. An assignment buried in a larger expression (`f(x = 1)`, `(x = 1) + 1`,
/// `while ((line = next()) != null)`) computes the right value but its target's env
/// rebind is not threaded here, so a later read of that target sees the old value.
fn env_after_effect(e: ast.Expression, v: ir.Value, env: Env) -> Env {
  case e {
    ast.AssignmentExpression(left: ast.Identifier(name: x, ..), right: rhs, ..) ->
      env_after_effect(rhs, v, dict.insert(env, x, v))
    // `x++` / `++x` (and `--`): `v` is the new value, so rebind `x` to it.
    ast.UpdateExpression(argument: ast.Identifier(name: x, ..), ..) ->
      dict.insert(env, x, v)
    _ -> env
  }
}

// ── if / else (phi-merge mutated variables) ──────────────────────────────────

fn lower_if(
  cond: ast.Expression,
  consequent: ast.Statement,
  alternate: Option(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  use #(cbinds, cval, ctr) <- result_try(lower_cond(cond, env, ctx, ctr))
  let then_stmts = block_stmts(consequent)
  let else_stmts = case alternate {
    Some(a) -> block_stmts(a)
    None -> []
  }
  // Variables assigned in either branch (and already in scope) are phi-merged.
  let mutated =
    list.append(assigned_in(then_stmts), assigned_in(else_stmts))
    |> list.unique
    |> list.filter(dict.has_key(env, _))

  use #(then_expr, ctr) <- result_try(lower_branch(
    then_stmts,
    env,
    ctx,
    ctr,
    mutated,
  ))
  use #(else_expr, ctr) <- result_try(lower_branch(
    else_stmts,
    env,
    ctx,
    ctr,
    mutated,
  ))

  let #(after, ctr) = fresh_n(list.length(mutated), ctr)
  let env2 =
    list.fold(list.zip(mutated, after), env, fn(acc, p) {
      dict.insert(acc, p.0, ir.Var(p.1))
    })
  use #(rest, ctr) <- result_try(k(env2, ctr))
  let tys = list.map(mutated, fn(_) { ir.TTerm })
  Ok(#(
    emit_lets(
      cbinds,
      ir.Let(
        after,
        ir.If(
          cond: cval,
          result: tys,
          then_branch: then_expr,
          else_branch: else_expr,
        ),
        rest,
      ),
    ),
    ctr,
  ))
}

/// Lower a branch body; on fall-through it yields the `mutated` variables' current
/// values (the phi inputs). A `return`/`break`/`continue` inside terminates instead.
fn lower_branch(
  stmts: List(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  mutated: List(String),
) -> Result(#(ir.Expr, Int), Error) {
  lower_stmts(stmts, env, ctx, ctr, fn(env2, ctr2) {
    Ok(#(ir.Values(carried_vals(env2, mutated)), ctr2))
  })
}

// ── loops (loop-carried mutated variables) ───────────────────────────────────

fn lower_while(
  cond: ast.Expression,
  body: ast.Statement,
  do_while: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  let body_stmts = block_stmts(body)
  let carried =
    assigned_in(body_stmts) |> list.unique |> list.filter(dict.has_key(env, _))
  let #(label, ctr) = fresh_label(ctr)
  lower_loop(
    label,
    carried,
    None,
    do_while,
    fn(loop_env, ctx2, ctr) {
      lower_loop_step(
        cond,
        body_stmts,
        None,
        do_while,
        loop_env,
        ctx2,
        label,
        carried,
        ctr,
      )
    },
    env,
    ctx,
    ctr,
    k,
  )
}

fn lower_for(
  init: Option(ast.ForInit),
  condition: Option(ast.Expression),
  update: Option(ast.Expression),
  body: ast.Statement,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  // `for (init; cond; upd) body` — run init in the current scope, then loop.
  use #(env, init_binds, ctr) <- result_try(lower_for_init(init, env, ctx, ctr))
  let body_stmts = block_stmts(body)
  let upd_assigned = case update {
    Some(u) -> assigned_of_expr(u)
    None -> []
  }
  let carried =
    list.append(assigned_in(body_stmts), upd_assigned)
    |> list.unique
    |> list.filter(dict.has_key(env, _))
  let #(label, ctr) = fresh_label(ctr)
  let cond = option.unwrap(condition, ast.BooleanLiteral(ast.Span(0, 0), True))
  use #(loop_expr, ctr) <- result_try(lower_loop(
    label,
    carried,
    update,
    False,
    fn(loop_env, ctx2, ctr) {
      lower_loop_step(
        cond,
        body_stmts,
        update,
        False,
        loop_env,
        ctx2,
        label,
        carried,
        ctr,
      )
    },
    env,
    ctx,
    ctr,
    k,
  ))
  Ok(#(emit_lets(init_binds, loop_expr), ctr))
}

/// `for (let x of iterable) body` — desugar to an index loop over an array-like:
/// `{ let $arr = iterable; for (let $i = 0; $i < $arr.length; $i = $i + 1) { let x =
/// $arr[$i]; body } }`. `break`/`continue` then target the synthesized `for` loop. v1
/// iterates anything with `.length` + integer indexing (arrays); other iterables fail
/// at runtime.
fn lower_for_of(
  left: ast.ForInit,
  right: ast.Expression,
  body: ast.Statement,
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  use x_name <- result_try(for_of_var(left))
  let id = int.to_string(ctr)
  let arr = "%of_arr_" <> id
  let idx = "%of_idx_" <> id
  let sp = ast.Span(0, 0)
  let ident = fn(n) { ast.Identifier(span: sp, name: n) }
  let decl = fn(n, init) {
    ast.VariableDeclaration(kind: ast.Let, declarations: [
      ast.VariableDeclarator(
        id: ast.IdentifierPattern(name: n, span: sp),
        init: Some(init),
      ),
    ])
  }
  let wrap = fn(s) { ast.StmtWithLine(line: 0, statement: s) }
  let arr_len =
    ast.MemberExpression(
      span: sp,
      object: ident(arr),
      property: ident("length"),
      computed: False,
    )
  let cond =
    ast.BinaryExpression(
      span: sp,
      operator: ast.LessThan,
      left: ident(idx),
      right: arr_len,
    )
  let update =
    ast.AssignmentExpression(
      span: sp,
      operator: ast.Assign,
      left: ident(idx),
      right: ast.BinaryExpression(
        span: sp,
        operator: ast.Add,
        left: ident(idx),
        right: ast.NumberLiteral(span: sp, value: 1.0),
      ),
    )
  let elem =
    ast.MemberExpression(
      span: sp,
      object: ident(arr),
      property: ident(idx),
      computed: True,
    )
  let inner_body =
    ast.BlockStatement(body: [wrap(decl(x_name, elem)), wrap(body)])
  let for_stmt =
    ast.ForStatement(
      init: Some(ast.ForInitDeclaration(decl(idx, ast.NumberLiteral(sp, 0.0)))),
      condition: Some(cond),
      update: Some(update),
      body: inner_body,
    )
  let block = ast.BlockStatement(body: [wrap(decl(arr, right)), wrap(for_stmt)])
  lower_stmt(block, env, ctx, ctr, k)
}

/// The bound loop variable of a `for-of`: `for (let x of …)` / `for (const x of …)` or
/// `for (x of …)` on a pre-declared identifier. Destructuring is not yet supported.
fn for_of_var(left: ast.ForInit) -> Result(String, Error) {
  case left {
    ast.ForInitDeclaration(ast.VariableDeclaration(
      declarations: [
        ast.VariableDeclarator(id: ast.IdentifierPattern(name:, ..), ..),
      ],
      ..,
    )) -> Ok(name)
    ast.ForInitExpression(ast.Identifier(name:, ..)) -> Ok(name)
    _ -> Error(Unsupported("for-of binding (destructuring/other)"))
  }
}

fn lower_for_init(
  init: Option(ast.ForInit),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(Env, List(Bind), Int), Error) {
  case init {
    None -> Ok(#(env, [], ctr))
    Some(ast.ForInitDeclaration(ast.VariableDeclaration(declarations:, ..))) ->
      lower_init_decls(declarations, env, ctx, ctr, [])
    Some(ast.ForInitExpression(e)) -> {
      use #(binds, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
      Ok(#(env_after_effect(e, v, env), binds, ctr))
    }
    _ -> Error(Unsupported("for-init pattern"))
  }
}

fn lower_init_decls(
  decls: List(ast.VariableDeclarator),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  acc: List(Bind),
) -> Result(#(Env, List(Bind), Int), Error) {
  case decls {
    [] -> Ok(#(env, acc, ctr))
    [
      ast.VariableDeclarator(
        id: ast.IdentifierPattern(name: x, ..),
        init: Some(e),
      ),
      ..rest
    ] -> {
      use #(binds, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
      lower_init_decls(
        rest,
        dict.insert(env, x, v),
        ctx,
        ctr,
        list.append(acc, binds),
      )
    }
    _ -> Error(Unsupported("for-init declaration"))
  }
}

/// A run-once labelled block that `break` can exit early — the substrate for `switch`.
/// Unlike a loop it sets ONLY the break target (so a `continue` inside still targets the
/// enclosing loop), and its body's fall-through `Break`s out rather than looping. `carried`
/// are the variables mutated inside the block whose new values must escape it.
fn lower_break_block(
  carried: List(String),
  build_body: fn(Env, Ctx, Cont, Int) -> Result(#(ir.Expr, Int), Error),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  let #(label, ctr) = fresh_label(ctr)
  let inits = carried_vals(env, carried)
  let params =
    list.map2(carried, inits, fn(v, initv) { ir.LoopParam(v, ir.TTerm, initv) })
  let loop_env =
    list.fold(carried, env, fn(acc, v) { dict.insert(acc, v, ir.Var(v)) })
  let blk_ctx = Ctx(..ctx, brk: Some(#(label, carried)))
  // fall-through of the body → break out with the carried vars' current values.
  let fallthrough: Cont = fn(env2, ctr2) {
    Ok(#(ir.Break(label, carried_vals(env2, carried)), ctr2))
  }
  use #(body, ctr) <- result_try(build_body(loop_env, blk_ctx, fallthrough, ctr))
  let tys = list.map(carried, fn(_) { ir.TTerm })
  let #(after, ctr) = fresh_n(list.length(carried), ctr)
  let env2 =
    list.fold(list.zip(carried, after), env, fn(acc, p) {
      dict.insert(acc, p.0, ir.Var(p.1))
    })
  use #(rest, ctr) <- result_try(k(env2, ctr))
  Ok(#(ir.Let(after, ir.Loop(label:, params:, result: tys, body:), rest), ctr))
}

/// `switch (disc) { case v: … default: … }` with fall-through. Desugars to a
/// break-block whose body sets a `$fell` flag on the first matching case (or the
/// default, if none matches — computed via `$any`) and then runs each following
/// consequent while `$fell` holds; a `break` exits the block, a `continue` still
/// targets the enclosing loop.
fn lower_switch(
  disc: ast.Expression,
  cases: List(ast.SwitchCase),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  let id = int.to_string(ctr)
  let dv = "%sw_d_" <> id
  let fell = "%sw_fell_" <> id
  let any = "%sw_any_" <> id
  let sp = ast.Span(0, 0)
  let ident = fn(n) { ast.Identifier(span: sp, name: n) }
  let bool_lit = fn(b) { ast.BooleanLiteral(span: sp, value: b) }
  let wrap = fn(s) { ast.StmtWithLine(line: 0, statement: s) }
  let decl = fn(n, init) {
    ast.VariableDeclaration(kind: ast.Let, declarations: [
      ast.VariableDeclarator(
        id: ast.IdentifierPattern(name: n, span: sp),
        init: Some(init),
      ),
    ])
  }
  let expr_stmt = fn(e) {
    ast.ExpressionStatement(expression: e, directive: None)
  }
  let set_true = fn(n) {
    expr_stmt(ast.AssignmentExpression(
      span: sp,
      operator: ast.Assign,
      left: ident(n),
      right: bool_lit(True),
    ))
  }
  let not_ = fn(e) {
    ast.UnaryExpression(
      span: sp,
      operator: ast.LogicalNot,
      prefix: True,
      argument: e,
    )
  }
  let and_ = fn(l, r) {
    ast.LogicalExpression(span: sp, operator: ast.LogicalAnd, left: l, right: r)
  }
  let eq_d = fn(t) {
    ast.BinaryExpression(
      span: sp,
      operator: ast.StrictEqual,
      left: ident(dv),
      right: t,
    )
  }
  let if_ = fn(c, body) {
    ast.IfStatement(
      condition: c,
      consequent: ast.BlockStatement(body:),
      alternate: None,
    )
  }

  // $any = ($d === t0) || ($d === t1) || … over the non-default case tests.
  let tests =
    list.filter_map(cases, fn(c) {
      case c.condition {
        Some(t) -> Ok(eq_d(t))
        None -> Error(Nil)
      }
    })
  let any_expr = case tests {
    [] -> bool_lit(False)
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, t) {
        ast.LogicalExpression(
          span: sp,
          operator: ast.LogicalOr,
          left: acc,
          right: t,
        )
      })
  }

  // Per case: enter it (set $fell) when it is the start point, then run its body
  // whenever $fell holds (fall-through).
  let case_stmts =
    list.flat_map(cases, fn(c) {
      let start_cond = case c.condition {
        Some(t) -> and_(not_(ident(fell)), eq_d(t))
        None -> and_(not_(ident(fell)), not_(ident(any)))
      }
      [
        if_(start_cond, [wrap(set_true(fell))]),
        if_(ident(fell), c.consequent),
      ]
    })

  let desugared =
    list.flatten([
      [
        decl(dv, disc),
        decl(any, any_expr),
        decl(fell, bool_lit(False)),
      ],
      case_stmts,
    ])

  let consequent_stmts =
    list.flat_map(cases, fn(c) { list.map(c.consequent, fn(w) { w.statement }) })
  let carried =
    assigned_in(consequent_stmts)
    |> list.unique
    |> list.filter(dict.has_key(env, _))

  lower_break_block(
    carried,
    fn(loop_env, blk_ctx, fallthrough, ctr) {
      lower_stmts(desugared, loop_env, blk_ctx, ctr, fallthrough)
    },
    env,
    ctx,
    ctr,
    k,
  )
}

/// `try { B } catch (e) { H }` — lower to the IR `Try`: the body and handler each
/// yield the block's mutated (carried) variables on normal completion, and a `throw`
/// inside `B` (via the `js_exn` tag) transfers to `H` with the thrown value bound to
/// `e`. `return`/`break`/`continue` inside `B`/`H` transfer out of the try as usual.
///
/// v1 limits: `finally` and a non-identifier catch binding are `Unsupported`, and — as
/// with all our SSA-style mutation — variables mutated in `B` before a throw are NOT
/// visible in `H` (the handler sees their pre-try values).
fn lower_try(
  block: ast.Statement,
  handler: Option(ast.CatchClause),
  finalizer: Option(ast.Statement),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  case finalizer, handler {
    Some(_), _ -> Error(Unsupported("try/finally"))
    None, None -> Error(Unsupported("try without catch"))
    None, Some(ast.CatchClause(param:, body: cbody)) -> {
      use e_name <- result_try(case param {
        None -> Ok("%exn")
        Some(ast.IdentifierPattern(name:, ..)) -> Ok(name)
        Some(_) -> Error(Unsupported("destructuring catch binding"))
      })
      let body_stmts = block_stmts(block)
      let catch_stmts = block_stmts(cbody)
      let carried =
        list.append(assigned_in(body_stmts), assigned_in(catch_stmts))
        |> list.unique
        |> list.filter(dict.has_key(env, _))
      let tys = list.map(carried, fn(_) { ir.TTerm })
      // fall-through of either arm yields the carried variables' current values.
      let yield_carried: Cont = fn(env2, ctr2) {
        Ok(#(ir.Values(carried_vals(env2, carried)), ctr2))
      }
      use #(body_expr, ctr) <- result_try(lower_stmts(
        body_stmts,
        env,
        ctx,
        ctr,
        yield_carried,
      ))
      let henv = dict.insert(env, e_name, ir.Var(e_name))
      use #(handler_expr, ctr) <- result_try(lower_stmts(
        catch_stmts,
        henv,
        ctx,
        ctr,
        yield_carried,
      ))
      let try_expr =
        ir.Try(result: tys, body: body_expr, handlers: [
          ir.CatchHandler(
            on: ir.OnTag(js_exn_tag),
            payload: [e_name],
            exnref: None,
            handler: handler_expr,
          ),
        ])
      let #(after, ctr) = fresh_n(list.length(carried), ctr)
      let env2 =
        list.fold(list.zip(carried, after), env, fn(acc, p) {
          dict.insert(acc, p.0, ir.Var(p.1))
        })
      use #(rest, ctr) <- result_try(k(env2, ctr))
      Ok(#(ir.Let(after, try_expr, rest), ctr))
    }
  }
}

/// Shared loop skeleton: bind the carried vars' entry values, run the `Loop`, then
/// rebind them and continue. `step` builds the per-iteration body in the loop env.
fn lower_loop(
  label: String,
  carried: List(String),
  update: Option(ast.Expression),
  do_while: Bool,
  step: fn(Env, Ctx, Int) -> Result(#(ir.Expr, Int), Error),
  env: Env,
  ctx: Ctx,
  ctr: Int,
  k: Cont,
) -> Result(#(ir.Expr, Int), Error) {
  let inits = carried_vals(env, carried)
  let params =
    list.map2(carried, inits, fn(v, initv) { ir.LoopParam(v, ir.TTerm, initv) })
  let loop_env =
    list.fold(carried, env, fn(acc, v) { dict.insert(acc, v, ir.Var(v)) })
  let this_loop = Loop(label, carried, update, do_while)
  // If this loop was labeled (`outer: for …`), register the label → its targets and
  // clear the pending label so a nested loop doesn't inherit it.
  let labels = case ctx.pending_label {
    Some(name) -> dict.insert(ctx.labels, name, #(#(label, carried), this_loop))
    None -> ctx.labels
  }
  let loop_ctx =
    Ctx(
      ..ctx,
      loop: Some(this_loop),
      brk: Some(#(label, carried)),
      labels: labels,
      pending_label: None,
    )
  use #(body, ctr) <- result_try(step(loop_env, loop_ctx, ctr))
  let tys = list.map(carried, fn(_) { ir.TTerm })

  let #(after, ctr) = fresh_n(list.length(carried), ctr)
  let env2 =
    list.fold(list.zip(carried, after), env, fn(acc, p) {
      dict.insert(acc, p.0, ir.Var(p.1))
    })
  use #(rest, ctr) <- result_try(k(env2, ctr))
  Ok(#(
    ir.Let(
      after,
      ir.Loop(label: label, params: params, result: tys, body: body),
      rest,
    ),
    ctr,
  ))
}

/// A loop back-edge for a fall-through or an explicit `for`-loop `continue`: run the
/// `for` update (if any) in `env`, then `Continue` the loop with the carried vars'
/// post-update values. Per JS, `continue` in a `for` loop runs the update, so both
/// the body's fall-through and an explicit `continue` route through here.
fn continue_edge(
  loop: Loop,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(ir.Expr, Int), Error) {
  case loop.update {
    None -> Ok(#(ir.Continue(loop.label, carried_vals(env, loop.carried)), ctr))
    Some(u) -> {
      use #(ubinds, uv, ctr) <- result_try(lower_expr(u, env, ctx, ctr))
      let env2 = env_after_effect(u, uv, env)
      Ok(#(
        emit_lets(
          ubinds,
          ir.Continue(loop.label, carried_vals(env2, loop.carried)),
        ),
        ctr,
      ))
    }
  }
}

/// One loop iteration. For `while`/`for`: `if (cond) { body; update?; continue }
/// else break` — the guard runs first, so the body is skipped when `cond` is false.
/// For `do/while`: `body; if (cond) continue else break` — the body runs first
/// (unconditionally), then the condition is tested at the bottom, so the body always
/// executes at least once (an explicit `continue` inside a do/while is rejected by
/// the statement layer, since our top-of-loop `Continue` can't jump to the bottom test).
fn lower_loop_step(
  cond: ast.Expression,
  body_stmts: List(ast.Statement),
  update: Option(ast.Expression),
  do_while: Bool,
  loop_env: Env,
  loop_ctx: Ctx,
  label: String,
  carried: List(String),
  ctr: Int,
) -> Result(#(ir.Expr, Int), Error) {
  let loop = Loop(label, carried, update, do_while)
  let tys = list.map(carried, fn(_) { ir.TTerm })
  case do_while {
    // do/while: body runs first, then the guard decides continue-vs-break.
    True -> {
      let bottom: Cont = fn(env2, ctr2) {
        use #(cbinds, cval, ctr2) <- result_try(lower_cond(
          cond,
          env2,
          loop_ctx,
          ctr2,
        ))
        use #(cont_expr, ctr2) <- result_try(continue_edge(
          loop,
          env2,
          loop_ctx,
          ctr2,
        ))
        let brk = ir.Break(label, carried_vals(env2, carried))
        Ok(#(
          emit_lets(
            cbinds,
            ir.If(
              cond: cval,
              result: tys,
              then_branch: cont_expr,
              else_branch: brk,
            ),
          ),
          ctr2,
        ))
      }
      lower_stmts(body_stmts, loop_env, loop_ctx, ctr, bottom)
    }
    // while/for: guard first; the body (then update, then continue) runs only if true.
    False -> {
      use #(cbinds, cval, ctr) <- result_try(lower_cond(
        cond,
        loop_env,
        loop_ctx,
        ctr,
      ))
      let cont: Cont = fn(env2, ctr2) {
        continue_edge(loop, env2, loop_ctx, ctr2)
      }
      use #(then_expr, ctr) <- result_try(lower_stmts(
        body_stmts,
        loop_env,
        loop_ctx,
        ctr,
        cont,
      ))
      let else_expr = ir.Break(label, carried_vals(loop_env, carried))
      Ok(#(
        emit_lets(
          cbinds,
          ir.If(
            cond: cval,
            result: tys,
            then_branch: then_expr,
            else_branch: else_expr,
          ),
        ),
        ctr,
      ))
    }
  }
}

// ── expressions (ANF: return ordered Lets + the atomic result Value) ─────────

fn lower_expr(
  e: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case e {
    ast.ParenthesizedExpression(expression: inner, ..) ->
      lower_expr(inner, env, ctx, ctr)

    ast.NumberLiteral(value: v, ..) -> Ok(number_literal(v, ctr))
    ast.StringExpression(value: s, ..) ->
      Ok(#([], ir.ConstBinary(<<s:utf8>>), ctr))
    ast.BooleanLiteral(value: b, ..) ->
      Ok(#([], ir.ConstAtom(bool_to_string(b)), ctr))
    ast.NullLiteral(..) -> Ok(#([], ir.ConstAtom("null"), ctr))
    ast.UndefinedExpression(..) -> Ok(#([], undefined(), ctr))
    ast.TemplateLiteral(quasis:, expressions:, ..) ->
      lower_template(quasis, expressions, env, ctx, ctr)
    ast.TaggedTemplateExpression(tag:, cooked:, raw:, expressions:, ..) ->
      lower_tagged_template(tag, cooked, raw, expressions, env, ctx, ctr)

    ast.Identifier(name: x, ..) ->
      case dict.get(env, x) {
        Ok(v) -> Ok(#([], v, ctr))
        // A local binding shadows a global; the fallbacks below apply only when
        // the name is free in this scope.
        Error(_) ->
          case global_const(x) {
            Some(v) -> Ok(#([], v, ctr))
            // A bare reference to a top-level function is that function as a value.
            None ->
              case list.contains(ctx.funcs, x) {
                True ->
                  Ok(bind1(ir.MakeClosure(x, [], fn_arity_unknown(x)), ctr))
                False -> Error(Unsupported("unbound identifier '" <> x <> "'"))
              }
          }
      }

    ast.BinaryExpression(operator: op, left:, right:, ..) ->
      lower_binary(op, left, right, env, ctx, ctr)
    ast.LogicalExpression(operator: op, left:, right:, ..) ->
      lower_logical(op, left, right, env, ctx, ctr)
    ast.UnaryExpression(operator: ast.Delete, argument:, ..) ->
      lower_delete(argument, env, ctx, ctr)
    ast.UnaryExpression(operator: op, argument:, ..) ->
      lower_unary(op, argument, env, ctx, ctr)
    ast.SequenceExpression(expressions:, ..) ->
      lower_sequence(expressions, env, ctx, ctr)
    ast.ConditionalExpression(condition:, consequent:, alternate:, ..) ->
      lower_ternary(condition, consequent, alternate, env, ctx, ctr)

    ast.AssignmentExpression(operator: op, left:, right:, ..) ->
      lower_assign(op, left, right, env, ctx, ctr)
    ast.UpdateExpression(operator: uop, argument:, ..) ->
      lower_update(uop, argument, env, ctr)

    ast.CallExpression(callee:, arguments:, ..) ->
      lower_call(callee, arguments, env, ctx, ctr)
    ast.NewExpression(callee:, arguments:, ..) ->
      lower_new(callee, arguments, env, ctx, ctr)
    ast.ThisExpression(..) ->
      case dict.get(env, "this") {
        Ok(v) -> Ok(#([], v, ctr))
        Error(Nil) -> Error(Unsupported("`this` outside a method"))
      }
    ast.MemberExpression(object:, property:, computed:, ..) ->
      lower_member(object, property, computed, env, ctx, ctr)
    ast.OptionalMemberExpression(object:, property:, computed:, ..) ->
      lower_optional_member(object, property, computed, env, ctx, ctr)
    ast.OptionalCallExpression(callee:, arguments:, ..) ->
      lower_optional_call(callee, arguments, env, ctx, ctr)
    ast.ObjectExpression(properties:, ..) ->
      lower_object(properties, env, ctx, ctr)
    ast.ArrayExpression(elements:, ..) -> lower_array(elements, env, ctx, ctr)
    // `/pattern/flags` — compile a regex object.
    ast.RegExpLiteral(pattern:, flags:, ..) ->
      Ok(bind1(
        ir.CallHost("js", "new_regex", [
          ir.ConstBinary(<<pattern:utf8>>),
          ir.ConstBinary(<<flags:utf8>>),
        ]),
        ctr,
      ))
    ast.FunctionExpression(span:, ..) -> lower_closure(span, env, ctx, ctr)
    ast.ArrowFunctionExpression(span:, ..) -> lower_closure(span, env, ctx, ctr)

    _ -> Error(Unsupported("expression: " <> string_tag_expr(e)))
  }
}

/// Lower an expression to an **i32 truth value** for a condition position
/// (`if`/`while`/`?:`/`&&`). Comparisons specialise to a guarded i32 compare (no
/// bool-term round-trip); everything else goes through `truthy`.
fn lower_cond(
  e: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case e {
    ast.ParenthesizedExpression(expression: inner, ..) ->
      lower_cond(inner, env, ctx, ctr)
    ast.BinaryExpression(operator: op, left:, right:, ..) ->
      case compare_op(op) {
        Some(_) -> lower_compare_i32(op, left, right, env, ctx, ctr)
        None -> truthy_of(e, env, ctx, ctr)
      }
    ast.UnaryExpression(operator: ast.LogicalNot, argument:, ..) -> {
      // !x as a condition: truthy(x) == 0
      use #(binds, t, ctr) <- result_try(truthy_of(argument, env, ctx, ctr))
      Ok(bind_after(binds, ir.Num(ir.IEqz(ir.W32), [t]), ctr))
    }
    _ -> truthy_of(e, env, ctx, ctr)
  }
}

fn truthy_of(
  e: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
  Ok(bind_after(binds, ir.CallHost("js", "truthy", [v]), ctr))
}

// ── operators ────────────────────────────────────────────────────────────────

fn lower_binary(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // `x instanceof C` needs the class name from the RHS, not its value.
  case op {
    ast.InstanceOf -> lower_instanceof(left, right, env, ctx, ctr)
    _ -> lower_binary_op(op, left, right, env, ctx, ctr)
  }
}

fn lower_binary_op(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
  use #(br, r, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let pre = list.append(bl, br)
  case op {
    // `key in obj` → has_prop(obj, key) as a boolean term.
    ast.In -> {
      let #(binds, i32v, ctr) =
        bind_after(pre, ir.CallHost("js", "has_prop", [r, l]), ctr)
      Ok(bind_after(binds, bool_term(i32v), ctr))
    }
    // `+ - *` — guarded native fast path, rt_js cold path (concat/coerce).
    ast.Add -> Ok(guarded_arith("add", ir.NAdd, l, r, pre, ctr))
    ast.Subtract -> Ok(guarded_arith("sub", ir.NSub, l, r, pre, ctr))
    ast.Multiply -> Ok(guarded_arith("mul", ir.NMul, l, r, pre, ctr))
    // `/ %` — no native NumTerm op; always rt_js (real JS `/0`=Infinity etc.).
    ast.Divide -> Ok(bind_after(pre, ir.CallHost("js", "div", [l, r]), ctr))
    ast.Modulo -> Ok(bind_after(pre, ir.CallHost("js", "mod", [l, r]), ctr))
    // bitwise / shift — always rt_js (JS coerces both sides to int32 first).
    ast.BitwiseAnd ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_and", [l, r]), ctr))
    ast.BitwiseOr ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_or", [l, r]), ctr))
    ast.BitwiseXor ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_xor", [l, r]), ctr))
    ast.LeftShift -> Ok(bind_after(pre, ir.CallHost("js", "shl", [l, r]), ctr))
    ast.RightShift -> Ok(bind_after(pre, ir.CallHost("js", "shr", [l, r]), ctr))
    ast.UnsignedRightShift ->
      Ok(bind_after(pre, ir.CallHost("js", "ushr", [l, r]), ctr))
    // `**` — always rt_js (Number::exponentiate).
    ast.Exponentiation ->
      Ok(bind_after(pre, ir.CallHost("js", "pow", [l, r]), ctr))
    // comparisons in value position → a JS boolean term.
    _ ->
      case compare_op(op) {
        Some(_) -> {
          use #(cbinds, i32v, ctr) <- result_try(lower_compare_i32(
            op,
            left,
            right,
            env,
            ctx,
            ctr,
          ))
          Ok(bind_after(cbinds, bool_term(i32v), ctr))
        }
        None -> Error(Unsupported("binary operator " <> string_binop(op)))
      }
  }
}

/// A comparison lowered to an i32 truth value: guarded native `NumTerm` compare for
/// numbers, else the `rt_js` op (real JS ordering/equality). `!==`/`!=` negate.
fn lower_compare_i32(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
  use #(br, r, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let pre = list.append(bl, br)
  let assert Some(#(js_op, num_op, negate)) = compare_op(op)
  case num_op {
    // ordering: guarded native compare; else rt_js.
    Some(nop) -> {
      let #(res, ctr) = guarded_compare(js_op, nop, l, r, pre, ctr)
      case negate {
        False -> Ok(#(res.0, res.1, ctr))
        True -> Ok(bind_after(res.0, ir.Num(ir.IEqz(ir.W32), [res.1]), ctr))
      }
    }
    // equality: rt_js eq/strict_eq (no cheap native form across types).
    None -> {
      let #(bs, i, ctr) = bind_after(pre, ir.CallHost("js", js_op, [l, r]), ctr)
      case negate {
        False -> Ok(#(bs, i, ctr))
        True -> Ok(bind_after(bs, ir.Num(ir.IEqz(ir.W32), [i]), ctr))
      }
    }
  }
}

/// `js_op`, the native `NumTermOp` (for orderings), and whether to negate the i32.
fn compare_op(
  op: ast.BinaryOp,
) -> Option(#(String, Option(ir.NumTermOp), Bool)) {
  case op {
    ast.LessThan -> Some(#("lt", Some(ir.NLt), False))
    ast.LessThanEqual -> Some(#("le", Some(ir.NLe), False))
    ast.GreaterThan -> Some(#("gt", Some(ir.NGt), False))
    ast.GreaterThanEqual -> Some(#("ge", Some(ir.NGe), False))
    ast.StrictEqual -> Some(#("strict_eq", None, False))
    ast.StrictNotEqual -> Some(#("strict_eq", None, True))
    ast.Equal -> Some(#("eq", None, False))
    ast.NotEqual -> Some(#("eq", None, True))
    _ -> None
  }
}

/// `a <op> b` guarded: `if IsNumber(a) && IsNumber(b) then NumTerm(nop) else
/// CallHost("js", js_op)`. Returns a `TTerm` (arithmetic) result.
fn guarded_arith(
  js_op: String,
  nop: ir.NumTermOp,
  l: ir.Value,
  r: ir.Value,
  pre: List(Bind),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let fast = ir.NumTerm(nop, l, r)
  let slow = ir.CallHost("js", js_op, [l, r])
  guarded(l, r, fast, slow, pre, ctr)
}

/// A guarded numeric COMPARISON → i32 truth on both arms.
fn guarded_compare(
  js_op: String,
  nop: ir.NumTermOp,
  l: ir.Value,
  r: ir.Value,
  pre: List(Bind),
  ctr: Int,
) -> #(#(List(Bind), ir.Value), Int) {
  let fast = ir.NumTerm(nop, l, r)
  let slow = ir.CallHost("js", js_op, [l, r])
  let #(binds, v, ctr) = guarded(l, r, fast, slow, pre, ctr)
  #(#(binds, v), ctr)
}

/// The shared `if IsNumber(l) && IsNumber(r) then fast else slow` builder.
fn guarded(
  l: ir.Value,
  r: ir.Value,
  fast: ir.Expr,
  slow: ir.Expr,
  pre: List(Bind),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let #(ga, ctr) = fresh(ctr)
  let #(gb, ctr) = fresh(ctr)
  let expr =
    ir.Let(
      [ga],
      ir.TermTest(ir.IsNumber, l),
      ir.Let(
        [gb],
        ir.TermTest(ir.IsNumber, r),
        ir.If(
          cond: ir.Var(ga),
          result: [ir.TTerm],
          then_branch: ir.If(
            cond: ir.Var(gb),
            result: [ir.TTerm],
            then_branch: fast,
            else_branch: slow,
          ),
          else_branch: slow,
        ),
      ),
    )
  bind_after(pre, expr, ctr)
}

fn lower_logical(
  op: ast.BinaryOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // Short-circuit: the rhs is evaluated only in the branch that yields it.
  // `a && b` → truthy(a) ? b : a ; `a || b` → truthy(a) ? a : b ;
  // `a ?? b` → is_nullish(a) ? b : a.
  use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
  use #(br, r, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let #(tvar, ctr) = fresh(ctr)
  let l_branch = ir.Values([l])
  // rhs bindings live INSIDE its branch, so a side-effecting rhs isn't run eagerly.
  let r_branch = emit_lets(br, ir.Values([r]))
  // The guard op on `l` and which branch yields the rhs.
  let #(guard_op, then_b, else_b) = case op {
    ast.LogicalAnd -> #("truthy", r_branch, l_branch)
    ast.NullishCoalescing -> #("is_nullish", r_branch, l_branch)
    _ -> #("truthy", l_branch, r_branch)
  }
  let expr =
    ir.Let(
      [tvar],
      ir.CallHost("js", guard_op, [l]),
      ir.If(
        cond: ir.Var(tvar),
        result: [ir.TTerm],
        then_branch: then_b,
        else_branch: else_b,
      ),
    )
  // Only the lhs bindings are unconditional; rhs is inside its branch.
  Ok(bind_after(bl, expr, ctr))
}

/// `x++` / `++x` / `x--` / `--x` on a local variable: `x` becomes `x ± 1`. Yields the
/// NEW value; the statement layer rebinds `x` (via `env_after_effect`). The spec value
/// of a POSTFIX update is the OLD value — a documented deviation that only shows when
/// the result is used inside a larger expression (loop counters / update statements
/// discard it, so those are exact). The `± 1` reuses the guarded native arithmetic path.
fn lower_update(
  uop: ast.UpdateOp,
  argument: ast.Expression,
  env: Env,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case argument {
    ast.Identifier(name: x, ..) ->
      case dict.get(env, x) {
        Error(Nil) ->
          Error(Unsupported("update of unbound identifier '" <> x <> "'"))
        Ok(cur) -> {
          let #(bone, one, ctr) = number_literal(1.0, ctr)
          let #(js_op, nop) = case uop {
            ast.Increment -> #("add", ir.NAdd)
            ast.Decrement -> #("sub", ir.NSub)
          }
          Ok(guarded_arith(js_op, nop, cur, one, bone, ctr))
        }
      }
    _ -> Error(Unsupported("update of a non-identifier target"))
  }
}

fn lower_unary(
  op: ast.UnaryOp,
  argument: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, v, ctr) <- result_try(lower_expr(argument, env, ctx, ctr))
  case op {
    ast.Negate -> Ok(bind_after(binds, ir.CallHost("js", "neg", [v]), ctr))
    ast.TypeOf -> Ok(bind_after(binds, ir.CallHost("js", "type_of", [v]), ctr))
    ast.LogicalNot -> {
      // !x → (truthy(x) == 0) as a boolean term.
      let #(binds2, t, ctr) =
        bind_after(binds, ir.CallHost("js", "truthy", [v]), ctr)
      let #(binds3, i0, ctr) =
        bind_after(binds2, ir.Num(ir.IEqz(ir.W32), [t]), ctr)
      Ok(bind_after(binds3, bool_expr(i0), ctr))
    }
    // `+x` is ToNumber(x): `+"5"`→5, `+"x"`→NaN, `+true`→1, `+""`→0. (The arithmetic
    // `neg` type-errors on non-numbers, so this needs the dedicated coercion op.)
    ast.UnaryPlus ->
      Ok(bind_after(binds, ir.CallHost("js", "to_number", [v]), ctr))
    // `void x` evaluates x for its effects (keep `binds`) and yields `undefined`.
    ast.Void -> Ok(#(binds, undefined(), ctr))
    // `~x` — bitwise NOT of ToInt32(x).
    ast.BitwiseNot ->
      Ok(bind_after(binds, ir.CallHost("js", "bit_not", [v]), ctr))
    _ -> Error(Unsupported("unary operator"))
  }
}

/// `x instanceof C` — true when `x` carries the `@@is_C` tag installed by `new C(…)`
/// (which tags the whole class chain, so it is true for subclasses too).
fn lower_instanceof(
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case right {
    ast.Identifier(name: cname, ..) -> {
      use #(bl, l, ctr) <- result_try(lower_expr(left, env, ctx, ctr))
      let tag = "@@is_" <> cname
      let #(binds, i32v, ctr) =
        bind_after(
          bl,
          ir.CallHost("js", "has_prop", [l, ir.ConstBinary(<<tag:utf8>>)]),
          ctr,
        )
      Ok(bind_after(binds, bool_term(i32v), ctr))
    }
    _ -> Error(Unsupported("instanceof a non-identifier right-hand side"))
  }
}

/// `delete obj.p` / `delete obj[k]` — remove the property; yields `true`. A non-member
/// delete is a no-op that yields `true`.
fn lower_delete(
  argument: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case argument {
    ast.MemberExpression(object:, property:, computed:, ..) -> {
      use #(bo, o, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
      use #(bk, key, ctr) <- result_try(member_key(
        property,
        computed,
        env,
        ctx,
        ctr,
      ))
      Ok(bind_after(
        list.append(bo, bk),
        ir.CallHost("js", "delete_prop", [o, key]),
        ctr,
      ))
    }
    _ -> Ok(#([], ir.ConstAtom("true"), ctr))
  }
}

/// `(a, b, c)` — the comma/sequence operator: evaluate each in order, yield the last.
fn lower_sequence(
  exprs: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  list.try_fold(exprs, #([], undefined(), ctr), fn(acc, e) {
    let #(binds, _v, ctr) = acc
    use #(b, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
    Ok(#(list.append(binds, b), v, ctr))
  })
}

fn lower_ternary(
  cond: ast.Expression,
  consequent: ast.Expression,
  alternate: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(cbinds, cval, ctr) <- result_try(lower_cond(cond, env, ctx, ctr))
  use #(tbinds, tv, ctr) <- result_try(lower_expr(consequent, env, ctx, ctr))
  use #(ebinds, ev, ctr) <- result_try(lower_expr(alternate, env, ctx, ctr))
  let expr =
    ir.If(
      cond: cval,
      result: [ir.TTerm],
      then_branch: emit_lets(tbinds, ir.Values([tv])),
      else_branch: emit_lets(ebinds, ir.Values([ev])),
    )
  Ok(bind_after(cbinds, expr, ctr))
}

fn lower_assign(
  op: ast.AssignmentOp,
  left: ast.Expression,
  right: ast.Expression,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case left {
    // `x op= e` desugars to `x = x op e`; `x` is a pure identifier, so the doubled
    // read in the desugared rhs is harmless. The rhs value IS the assignment's value;
    // the env rebind of `x` is applied by the statement layer (via `env_after_effect`).
    ast.Identifier(..) -> {
      use rhs <- result_try(desugar_compound(op, left, right))
      lower_expr(rhs, env, ctx, ctr)
    }
    // `obj.p op= e` / `obj[k] op= e`. Evaluate the object and key EXACTLY ONCE so a
    // compound assignment (or a side-effecting/computed `getObj()[k()] += e`) doesn't
    // re-run them, then read/write the property through those bound values.
    ast.MemberExpression(object:, property:, computed:, ..) -> {
      use #(bo, o, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
      use #(bk, key, ctr) <- result_try(member_key(
        property,
        computed,
        env,
        ctx,
        ctr,
      ))
      case op {
        // plain `obj.p = e` → set_prop(o, key, e), returns e.
        ast.Assign -> {
          use #(bv, v, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
          let pre = list.flatten([bo, bk, bv])
          Ok(bind_after(pre, ir.CallHost("js", "set_prop", [o, key, v]), ctr))
        }
        // logical `obj.p ||= e` / `&&=` / `??=` — short-circuit: read obj.p once,
        // and only evaluate `e` + assign when the guard says so.
        ast.LogicalOrAssign
        | ast.LogicalAndAssign
        | ast.NullishCoalesceAssign ->
          lower_member_logical_assign(
            op,
            o,
            key,
            right,
            list.flatten([bo, bk]),
            env,
            ctx,
            ctr,
          )
        // compound `obj.p op= e` → set_prop(o, key, get_prop(o, key) op e). Order:
        // object, key, read, rhs — matching JS reference/GetValue/rhs evaluation.
        _ -> {
          let #(bcur, cur, ctr) =
            bind_after(
              list.flatten([bo, bk]),
              ir.CallHost("js", "get_prop", [o, key]),
              ctr,
            )
          use #(brv, rv, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
          use #(bres, resv, ctr) <- result_try(apply_compound(
            op,
            cur,
            rv,
            list.append(bcur, brv),
            ctr,
          ))
          Ok(bind_after(
            bres,
            ir.CallHost("js", "set_prop", [o, key, resv]),
            ctr,
          ))
        }
      }
    }
    _ -> Error(Unsupported("assignment target"))
  }
}

/// Lower a logical assignment to a member target: `obj.p ||= e` / `&&=` / `??=`.
///
/// `o` and `key` are the already-once-evaluated object and property key. The
/// current value is read once (`get_prop`); the rhs `e` and the write are placed
/// INSIDE the branch selected by the guard, so `e` runs (and the property is
/// assigned) only when JS would: `||=` when falsy, `&&=` when truthy, `??=` when
/// nullish. The expression's value is the property's resulting value.
fn lower_member_logical_assign(
  op: ast.AssignmentOp,
  o: ir.Value,
  key: ir.Value,
  right: ast.Expression,
  pre: List(Bind),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  let #(bcur, cur, ctr) =
    bind_after(pre, ir.CallHost("js", "get_prop", [o, key]), ctr)
  use #(be, ev, ctr) <- result_try(lower_expr(right, env, ctx, ctr))
  let assign_branch = emit_lets(be, ir.CallHost("js", "set_prop", [o, key, ev]))
  let cur_branch = ir.Values([cur])
  let #(guard_op, then_b, else_b) = case op {
    ast.LogicalAndAssign -> #("truthy", assign_branch, cur_branch)
    ast.NullishCoalesceAssign -> #("is_nullish", assign_branch, cur_branch)
    // LogicalOrAssign
    _ -> #("truthy", cur_branch, assign_branch)
  }
  let #(tvar, ctr) = fresh(ctr)
  let expr =
    ir.Let(
      [tvar],
      ir.CallHost("js", guard_op, [cur]),
      ir.If(
        cond: ir.Var(tvar),
        result: [ir.TTerm],
        then_branch: then_b,
        else_branch: else_b,
      ),
    )
  Ok(bind_after(bcur, expr, ctr))
}

/// Apply a compound-assignment arithmetic operator (`+= -= *= /= %=`) to two lowered
/// operand Values, emitting the SAME guarded native/`rt_js` dispatch as `lower_binary`.
fn apply_compound(
  op: ast.AssignmentOp,
  l: ir.Value,
  r: ir.Value,
  pre: List(Bind),
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case op {
    ast.AddAssign -> Ok(guarded_arith("add", ir.NAdd, l, r, pre, ctr))
    ast.SubtractAssign -> Ok(guarded_arith("sub", ir.NSub, l, r, pre, ctr))
    ast.MultiplyAssign -> Ok(guarded_arith("mul", ir.NMul, l, r, pre, ctr))
    ast.DivideAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "div", [l, r]), ctr))
    ast.ModuloAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "mod", [l, r]), ctr))
    ast.BitwiseAndAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_and", [l, r]), ctr))
    ast.BitwiseOrAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_or", [l, r]), ctr))
    ast.BitwiseXorAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "bit_xor", [l, r]), ctr))
    ast.LeftShiftAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "shl", [l, r]), ctr))
    ast.RightShiftAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "shr", [l, r]), ctr))
    ast.UnsignedRightShiftAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "ushr", [l, r]), ctr))
    ast.ExponentiationAssign ->
      Ok(bind_after(pre, ir.CallHost("js", "pow", [l, r]), ctr))
    _ -> Error(Unsupported("compound assignment operator"))
  }
}

fn desugar_compound(
  op: ast.AssignmentOp,
  left: ast.Expression,
  right: ast.Expression,
) -> Result(ast.Expression, Error) {
  let sp = ast.Span(0, 0)
  case op {
    ast.Assign -> Ok(right)
    ast.AddAssign -> Ok(ast.BinaryExpression(sp, ast.Add, left, right))
    ast.SubtractAssign ->
      Ok(ast.BinaryExpression(sp, ast.Subtract, left, right))
    ast.MultiplyAssign ->
      Ok(ast.BinaryExpression(sp, ast.Multiply, left, right))
    ast.DivideAssign -> Ok(ast.BinaryExpression(sp, ast.Divide, left, right))
    ast.ModuloAssign -> Ok(ast.BinaryExpression(sp, ast.Modulo, left, right))
    ast.BitwiseAndAssign ->
      Ok(ast.BinaryExpression(sp, ast.BitwiseAnd, left, right))
    ast.BitwiseOrAssign ->
      Ok(ast.BinaryExpression(sp, ast.BitwiseOr, left, right))
    ast.BitwiseXorAssign ->
      Ok(ast.BinaryExpression(sp, ast.BitwiseXor, left, right))
    ast.LeftShiftAssign ->
      Ok(ast.BinaryExpression(sp, ast.LeftShift, left, right))
    ast.RightShiftAssign ->
      Ok(ast.BinaryExpression(sp, ast.RightShift, left, right))
    ast.UnsignedRightShiftAssign ->
      Ok(ast.BinaryExpression(sp, ast.UnsignedRightShift, left, right))
    ast.ExponentiationAssign ->
      Ok(ast.BinaryExpression(sp, ast.Exponentiation, left, right))
    // Logical assignment (§13.15.2): `x ||= e` etc. For a plain variable target
    // (no setters in this runtime) these are observationally `x = (x || e)` with
    // the rhs short-circuited, so desugar to the short-circuiting logical form.
    ast.LogicalOrAssign ->
      Ok(ast.LogicalExpression(sp, ast.LogicalOr, left, right))
    ast.LogicalAndAssign ->
      Ok(ast.LogicalExpression(sp, ast.LogicalAnd, left, right))
    ast.NullishCoalesceAssign ->
      Ok(ast.LogicalExpression(sp, ast.NullishCoalescing, left, right))
  }
}

// ── calls / members / objects ────────────────────────────────────────────────

fn lower_call(
  callee: ast.Expression,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // Call spread `f(...args)` takes a separate runtime-application path; the common
  // fixed-arity call is unchanged (and stays a direct `apply 'f'/n(…)`).
  let has_spread =
    list.any(arguments, fn(a) {
      case a {
        ast.SpreadElement(..) -> True
        _ -> False
      }
    })
  case has_spread {
    True -> lower_spread_call(callee, arguments, env, ctx, ctr)
    False -> lower_call_fixed(callee, arguments, env, ctx, ctr)
  }
}

/// `f(...args)` / `f(a, ...rest)` — build the effective arguments as an array, flatten
/// to a runtime list, and apply. Functions/closures go through `apply_fn`; `console.log`
/// and variadic `Math.*` take the list directly.
fn lower_spread_call(
  callee: ast.Expression,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(barr, arr, ctr) <- result_try(lower_array(
    list.map(arguments, Some),
    env,
    ctx,
    ctr,
  ))
  let #(bl, listv, ctr) =
    bind_after(barr, ir.CallHost("js", "array_to_list", [arr]), ctr)
  case callee {
    ast.MemberExpression(
      object: ast.Identifier(name: "console", ..),
      property: ast.Identifier(name: "log", ..),
      ..,
    ) -> Ok(bind_after(bl, ir.CallHost("js", "console_log", [listv]), ctr))
    ast.MemberExpression(
      object: ast.Identifier(name: "Math", ..),
      property: ast.Identifier(name: method, ..),
      ..,
    ) ->
      case math_arity(method) {
        Some(MathReduce) ->
          Ok(bind_after(
            bl,
            ir.CallHost("js", "math_reduce", [ir.ConstAtom(method), listv]),
            ctr,
          ))
        _ -> Error(Unsupported("Math." <> method <> "(...spread)"))
      }
    ast.Identifier(name: fname, ..) ->
      case list.contains(ctx.funcs, fname) {
        True -> {
          let arity = case dict.get(ctx.fn_arity, fname) {
            Ok(a) -> a
            Error(Nil) -> 0
          }
          let #(bc, closure, ctr) =
            bind_after(bl, ir.MakeClosure(fname, [], arity), ctr)
          Ok(bind_after(
            bc,
            ir.CallHost("js", "apply_fn", [closure, listv]),
            ctr,
          ))
        }
        False ->
          case dict.get(env, fname) {
            Ok(fv) ->
              Ok(bind_after(bl, ir.CallHost("js", "apply_fn", [fv, listv]), ctr))
            Error(Nil) ->
              Error(Unsupported("spread call to unknown '" <> fname <> "'"))
          }
      }
    _ -> {
      use #(bc, cv, ctr) <- result_try(lower_expr(callee, env, ctx, ctr))
      Ok(bind_after(
        list.append(bl, bc),
        ir.CallHost("js", "apply_fn", [cv, listv]),
        ctr,
      ))
    }
  }
}

fn lower_call_fixed(
  callee: ast.Expression,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case callee {
    // console.log(...) → rt_js console_log(cons-list of args).
    ast.MemberExpression(
      object: ast.Identifier(name: "console", ..),
      property: ast.Identifier(name: "log", ..),
      computed: False,
      ..,
    ) -> {
      use #(binds, argvals, ctr) <- result_try(lower_args(
        arguments,
        env,
        ctx,
        ctr,
      ))
      let #(binds2, listv, ctr) = build_list(argvals, binds, ctr)
      Ok(bind_after(binds2, ir.CallHost("js", "console_log", [listv]), ctr))
    }
    // Math.method(...) → a dedicated rt_js Math op (Math is not a value).
    ast.MemberExpression(
      object: ast.Identifier(name: "Math", ..),
      property: ast.Identifier(name: method, ..),
      computed: False,
      ..,
    ) -> lower_math_call(method, arguments, env, ctx, ctr)
    // Array.* / Object.* / Number.* statics (namespaces, not values).
    ast.MemberExpression(
      object: ast.Identifier(name: ns, ..),
      property: ast.Identifier(name: method, ..),
      computed: False,
      ..,
    )
      if ns == "Array"
      || ns == "Object"
      || ns == "Number"
      || ns == "JSON"
      || ns == "String"
      || ns == "Date"
    -> lower_static_call(ns, method, arguments, env, ctx, ctr)
    // `super.method(args)` — call the superclass's method on the current `this`.
    ast.MemberExpression(
      object: ast.SuperExpression(..),
      property: ast.Identifier(name: method, ..),
      computed: False,
      ..,
    ) -> lower_super_call(Some(method), arguments, env, ctx, ctr)
    // recv.method(args) — method dispatch (array/string methods).
    ast.MemberExpression(
      object:,
      property: ast.Identifier(name: method, ..),
      computed: False,
      ..,
    ) -> lower_method(object, method, arguments, env, ctx, ctr)
    // f(args) where f is a top-level function → direct call.
    ast.Identifier(name: fname, ..) ->
      case list.contains(ctx.funcs, fname) {
        True -> {
          use #(binds, argvals, ctr) <- result_try(lower_args(
            arguments,
            env,
            ctx,
            ctr,
          ))
          case dict.get(ctx.fn_rest, fname) {
            // rest param: pass the fixed args (padded) + a rest array of the remainder.
            Ok(fixed) -> {
              let front = fit_args(list.take(argvals, fixed), fixed)
              let #(bl, listv, ctr) =
                build_list(list.drop(argvals, fixed), binds, ctr)
              let #(ba, rest_arr, ctr) =
                bind_after(bl, ir.CallHost("js", "new_array", [listv]), ctr)
              Ok(bind_after(
                ba,
                ir.CallDirect(fname, list.append(front, [rest_arr])),
                ctr,
              ))
            }
            // BEAM funs are arity-strict; JS is not. Pad missing args with `undefined`
            // (so defaults apply) and drop extras, matching the declared arity.
            Error(Nil) -> {
              let arity = case dict.get(ctx.fn_arity, fname) {
                Ok(a) -> a
                Error(Nil) -> list.length(argvals)
              }
              Ok(bind_after(
                binds,
                ir.CallDirect(fname, fit_args(argvals, arity)),
                ctr,
              ))
            }
          }
        }
        // f is a value (a closure in a variable) → CallClosure.
        False ->
          case dict.get(env, fname) {
            Ok(fv) -> {
              use #(binds, argvals, ctr) <- result_try(lower_args(
                arguments,
                env,
                ctx,
                ctr,
              ))
              Ok(bind_after(binds, ir.CallClosure(fv, argvals), ctr))
            }
            Error(_) ->
              case is_global_fn(fname) {
                True -> lower_global_call(fname, arguments, env, ctx, ctr)
                False -> Error(Unsupported("call to unknown '" <> fname <> "'"))
              }
          }
      }
    // `super(args)` — call the superclass constructor on the current `this`.
    ast.SuperExpression(..) -> lower_super_call(None, arguments, env, ctx, ctr)
    // any other callee: evaluate it to a function value and apply it — IIFEs
    // `(x => x)(5)`, a returned/stored closure, `getFn()(…)`, etc.
    _ -> {
      use #(bc, fv, ctr) <- result_try(lower_expr(callee, env, ctx, ctr))
      use #(ba, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
      Ok(bind_after(list.append(bc, ba), ir.CallClosure(fv, argvals), ctr))
    }
  }
}

/// `super(args)` (member `None`) or `super.method(args)` (member `Some(name)`) — a
/// direct call to the superclass's constructor/method, passing the current `this`.
fn lower_super_call(
  member: Option(String),
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case ctx.current_super, dict.get(env, "this") {
    Some(parent), Ok(this_v) -> {
      use #(ba, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
      let fn_name = case member {
        None -> parent <> "$constructor"
        Some(m) -> parent <> "$" <> m
      }
      // Fit args to the target's declared arity: the lifted `parent$m` /
      // `parent$constructor` takes exactly `this` plus its declared parameters,
      // and `CallDirect` is arity-strict, so under-/over-applied `super` calls
      // must be padded with `undefined` / truncated (JS defaults missing args to
      // undefined). The method's param count comes from the parent's ClassInfo
      // (walking the super chain for an inherited method).
      let target_args = case member {
        None ->
          case dict.get(ctx.classes, parent) {
            Ok(info) -> fit_args(argvals, info.ctor_arity)
            Error(Nil) -> argvals
          }
        Some(m) ->
          case super_method_arity(ctx, parent, m) {
            Some(n) -> fit_args(argvals, n)
            None -> argvals
          }
      }
      Ok(bind_after(ba, ir.CallDirect(fn_name, [this_v, ..target_args]), ctr))
    }
    _, _ -> Error(Unsupported("`super` outside a derived class method"))
  }
}

/// The declared parameter count of method `method` as seen from class `class`,
/// walking up the `extends` chain for an inherited method. `None` if no ancestor
/// declares it. Used to arity-fit `super.method(...)` calls.
fn super_method_arity(ctx: Ctx, class: String, method: String) -> Option(Int) {
  case dict.get(ctx.classes, class) {
    Ok(info) ->
      case list.key_find(info.methods, method) {
        Ok(n) -> Some(n)
        Error(Nil) ->
          case info.super_class {
            Some(p) -> super_method_arity(ctx, p, method)
            None -> None
          }
      }
    Error(Nil) -> None
  }
}

/// Whether `name` is a supported global builtin FUNCTION (called as `name(...)`).
fn is_global_fn(name: String) -> Bool {
  case name {
    "String"
    | "Number"
    | "Boolean"
    | "parseInt"
    | "parseFloat"
    | "isNaN"
    | "isFinite" -> True
    _ -> False
  }
}

/// A global builtin function call: `String`/`Number`/`Boolean` coercions and
/// `parseInt`/`parseFloat`/`isNaN`/`isFinite`.
fn lower_global_call(
  name: String,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
  let host = fn(op, args) {
    Ok(bind_after(binds, ir.CallHost("js", op, args), ctr))
  }
  case name, argvals {
    "String", [x, ..] -> host("to_string", [x])
    "String", [] -> Ok(#(binds, ir.ConstBinary(<<>>), ctr))
    "Number", [x, ..] -> host("to_number", [x])
    "Number", [] -> {
      let #(nb, v, ctr) = number_literal(0.0, ctr)
      Ok(#(list.append(binds, nb), v, ctr))
    }
    "Boolean", [x, ..] -> {
      let #(b2, i, ctr) =
        bind_after(binds, ir.CallHost("js", "truthy", [x]), ctr)
      Ok(bind_after(b2, bool_term(i), ctr))
    }
    "Boolean", [] -> Ok(#(binds, ir.ConstAtom("false"), ctr))
    "parseInt", [s] -> host("parse_int", [s, undefined()])
    "parseInt", [s, r, ..] -> host("parse_int", [s, r])
    "parseFloat", [s, ..] -> host("parse_float", [s])
    "isNaN", [x, ..] -> host("is_nan", [x])
    "isFinite", [x, ..] -> host("is_finite", [x])
    _, _ -> Error(Unsupported(name <> "(…)"))
  }
}

/// A static-namespace call: `Array.*`, `Object.*`, `Number.*`.
fn lower_static_call(
  ns: String,
  method: String,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
  let host = fn(op, args) {
    Ok(bind_after(binds, ir.CallHost("js", op, args), ctr))
  }
  case ns, method, argvals {
    "Array", "isArray", [x, ..] -> {
      let #(b2, i, ctr) =
        bind_after(binds, ir.CallHost("js", "is_array", [x]), ctr)
      Ok(bind_after(b2, bool_term(i), ctr))
    }
    "Array", "of", _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, binds, ctr)
      Ok(bind_after(binds2, ir.CallHost("js", "new_array", [listv]), ctr))
    }
    "Object", "keys", [o, ..] -> host("object_keys", [o])
    "Object", "values", [o, ..] -> host("object_values", [o])
    "Object", "entries", [o, ..] -> host("object_entries", [o])
    "Object", "fromEntries", [e, ..] -> host("object_from_entries", [e])
    // Object.assign(target, ...sources) — copy each source into target, return target.
    "Object", "assign", [target, ..sources] -> {
      let #(binds2, ctr) =
        list.fold(sources, #(binds, ctr), fn(acc, src) {
          let #(binds, ctr) = acc
          let #(b2, _r, ctr) =
            bind_after(
              binds,
              ir.CallHost("js", "object_assign_into", [target, src]),
              ctr,
            )
          #(b2, ctr)
        })
      Ok(#(binds2, target, ctr))
    }
    "Number", "isInteger", [x, ..] -> host("number_is_integer", [x])
    "Number", "isNaN", [x, ..] -> host("number_is_nan", [x])
    "Number", "isFinite", [x, ..] -> host("number_is_finite", [x])
    "Number", "parseInt", [s] -> host("parse_int", [s, undefined()])
    "Number", "parseInt", [s, r, ..] -> host("parse_int", [s, r])
    "Number", "parseFloat", [s, ..] -> host("parse_float", [s])
    "JSON", "stringify", [v, ..] -> host("json_stringify", [v])
    "JSON", "parse", [s, ..] -> host("json_parse", [s])
    "Array", "from", [x, ..] -> host("array_from", [x])
    "String", "fromCharCode", _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, binds, ctr)
      Ok(bind_after(
        binds2,
        ir.CallHost("js", "string_from_char_code", [listv]),
        ctr,
      ))
    }
    "String", "fromCodePoint", _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, binds, ctr)
      Ok(bind_after(
        binds2,
        ir.CallHost("js", "string_from_code_point", [listv]),
        ctr,
      ))
    }
    // String.raw(template, ...substitutions) — the default tagged-template tag.
    "String", "raw", [template, ..subs] -> {
      let #(binds2, listv, ctr) = build_list(subs, binds, ctr)
      Ok(bind_after(
        binds2,
        ir.CallHost("js", "string_raw", [template, listv]),
        ctr,
      ))
    }
    "Date", "now", _ -> host("date_now", [])
    _, _, _ -> Error(Unsupported(ns <> "." <> method <> "(…)"))
  }
}

/// `Math.method(args)` — dispatch to the appropriate `rt_js` Math op. The method name
/// is passed as an atom; unary/binary/variadic forms differ in arity.
fn lower_math_call(
  method: String,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
  let m = ir.ConstAtom(method)
  case math_arity(method), argvals {
    Some(MathUnary), [x] ->
      Ok(bind_after(binds, ir.CallHost("js", "math_unary", [m, x]), ctr))
    Some(MathBinary), [a, b] ->
      Ok(bind_after(binds, ir.CallHost("js", "math_binary", [m, a, b]), ctr))
    Some(MathReduce), _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, binds, ctr)
      Ok(bind_after(binds2, ir.CallHost("js", "math_reduce", [m, listv]), ctr))
    }
    Some(MathRandom), [] ->
      Ok(bind_after(binds, ir.CallHost("js", "math_random", []), ctr))
    _, _ -> Error(Unsupported("Math." <> method <> "(…)"))
  }
}

/// How a `Math` method takes its arguments (`None` = not a supported Math method).
type MathArity {
  MathUnary
  MathBinary
  MathReduce
  MathRandom
}

fn math_arity(method: String) -> Option(MathArity) {
  case method {
    "floor"
    | "ceil"
    | "round"
    | "trunc"
    | "abs"
    | "sign"
    | "sqrt"
    | "cbrt"
    | "exp"
    | "log"
    | "log2"
    | "log10"
    | "sin"
    | "cos"
    | "tan"
    | "asin"
    | "acos"
    | "atan" -> Some(MathUnary)
    "pow" | "atan2" -> Some(MathBinary)
    "min" | "max" | "hypot" -> Some(MathReduce)
    "random" -> Some(MathRandom)
    _ -> None
  }
}

/// A `Math` numeric constant (`Math.PI`, `Math.E`, …), inlined at compile time.
fn math_const(name: String) -> Option(ir.Value) {
  case name {
    "PI" -> Some(ir.ConstFloatTerm(3.141592653589793))
    "E" -> Some(ir.ConstFloatTerm(2.718281828459045))
    "LN2" -> Some(ir.ConstFloatTerm(0.6931471805599453))
    "LN10" -> Some(ir.ConstFloatTerm(2.302585092994046))
    "LOG2E" -> Some(ir.ConstFloatTerm(1.4426950408889634))
    "LOG10E" -> Some(ir.ConstFloatTerm(0.4342944819032518))
    "SQRT2" -> Some(ir.ConstFloatTerm(1.4142135623730951))
    "SQRT1_2" -> Some(ir.ConstFloatTerm(0.7071067811865476))
    _ -> None
  }
}

/// `new C(args)` — construct a class instance: a fresh object, each method installed
/// as a `this`-bound closure property, then `C$constructor(this, args)` (which runs the
/// field initializers and the constructor body). Yields the new object.
fn lower_new(
  callee: ast.Expression,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case callee {
    // `new Map()` / `new Set()` — built-in collections (optionally seeded).
    ast.Identifier(name: "Map", ..) ->
      lower_builtin_new("new_map", arguments, env, ctx, ctr)
    ast.Identifier(name: "Set", ..) ->
      lower_builtin_new("new_set", arguments, env, ctx, ctr)
    ast.Identifier(name: cname, ..) ->
      case dict.get(ctx.classes, cname) {
        Error(Nil) ->
          Error(Unsupported("new " <> cname <> "(…) (unknown class)"))
        Ok(info) -> {
          let #(binds, this_v, ctr) =
            bind_after([], ir.CallHost("js", "new_object", []), ctr)
          // install every method in the class chain as a closure over `this`
          // (ancestors first, so an overriding child method wins).
          let #(binds, ctr) =
            list.fold(
              chain_methods(cname, ctx.classes),
              #(binds, ctr),
              fn(acc, m) {
                let #(binds, ctr) = acc
                let #(defclass, mname, marity) = m
                let #(bc, closure_v, ctr) =
                  bind_after(
                    binds,
                    ir.MakeClosure(defclass <> "$" <> mname, [this_v], marity),
                    ctr,
                  )
                let #(bs, _r, ctr) =
                  bind_after(
                    bc,
                    ir.CallHost("js", "set_prop", [
                      this_v,
                      ir.ConstBinary(<<mname:utf8>>),
                      closure_v,
                    ]),
                    ctr,
                  )
                #(bs, ctr)
              },
            )
          // tag the instance with `@@is_<Class>` for every class in the chain, so
          // `instanceof` works (including subclasses).
          let #(binds, ctr) =
            list.fold(
              class_chain(cname, ctx.classes),
              #(binds, ctr),
              fn(acc, k) {
                let #(binds, ctr) = acc
                let tag = "@@is_" <> k
                let #(b2, _r, ctr) =
                  bind_after(
                    binds,
                    ir.CallHost("js", "set_prop", [
                      this_v,
                      ir.ConstBinary(<<tag:utf8>>),
                      ir.ConstAtom("true"),
                    ]),
                    ctr,
                  )
                #(b2, ctr)
              },
            )
          use #(ba, argvals, ctr) <- result_try(lower_args(
            arguments,
            env,
            ctx,
            ctr,
          ))
          let fitted = fit_args(argvals, info.ctor_arity)
          let #(binds2, _r, ctr) =
            bind_after(
              list.append(binds, ba),
              ir.CallDirect(cname <> "$constructor", [this_v, ..fitted]),
              ctr,
            )
          Ok(#(binds2, this_v, ctr))
        }
      }
    _ -> Error(Unsupported("new of a non-identifier callee"))
  }
}

/// `new Map(init?)` / `new Set(init?)` — a built-in collection constructor. Passes the
/// optional first argument (an array seed) to the runtime constructor.
fn lower_builtin_new(
  op: String,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(binds, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
  let init = case argvals {
    [x, ..] -> x
    [] -> undefined()
  }
  Ok(bind_after(binds, ir.CallHost("js", op, [init]), ctr))
}

/// `recv.method(args)` — a method call. Dispatches the built-in array/string/Map/Set
/// methods by name to their `rt_js` ops (Map/Set methods delegate to a same-named user
/// method on a plain object); an unknown method name is a property-lookup-and-call
/// (object/class instance methods). The receiver is evaluated once.
fn lower_method(
  object: ast.Expression,
  method: String,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // `C.staticMethod(args)` — a class's static method is a plain `C$static$name` call.
  case static_method(object, method, ctx) {
    Some(arity) -> {
      use #(binds, argvals, ctr) <- result_try(lower_args(
        arguments,
        env,
        ctx,
        ctr,
      ))
      let cname = object_ident_name(object)
      Ok(bind_after(
        binds,
        ir.CallDirect(cname <> "$static$" <> method, fit_args(argvals, arity)),
        ctr,
      ))
    }
    None -> lower_instance_method(object, method, arguments, env, ctx, ctr)
  }
}

/// The arity of `C.method` if `C` is a known class with static method `method`.
fn static_method(
  object: ast.Expression,
  method: String,
  ctx: Ctx,
) -> Option(Int) {
  case object {
    ast.Identifier(name: cname, ..) ->
      case dict.get(ctx.classes, cname) {
        Ok(info) -> option.from_result(list.key_find(info.statics, method))
        Error(Nil) -> None
      }
    _ -> None
  }
}

fn object_ident_name(object: ast.Expression) -> String {
  case object {
    ast.Identifier(name:, ..) -> name
    _ -> ""
  }
}

fn lower_instance_method(
  object: ast.Expression,
  method: String,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bo, recv, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
  use #(ba, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
  let pre = list.append(bo, ba)
  // A method call to `rt_js` op `name` applied to `[recv, ..extra]`.
  let host = fn(name, extra) {
    Ok(bind_after(pre, ir.CallHost("js", name, [recv, ..extra]), ctr))
  }
  // A collection method `name` applied to `[recv, <cons-list of ALL args>]` — so a
  // delegated user method receives every argument.
  let coll = fn(name) {
    let #(binds2, listv, ctr) = build_list(argvals, pre, ctr)
    Ok(bind_after(binds2, ir.CallHost("js", name, [recv, listv]), ctr))
  }
  case method, argvals {
    // mutators / stack ops
    "push", _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, pre, ctr)
      Ok(bind_after(binds2, ir.CallHost("js", "array_push", [recv, listv]), ctr))
    }
    "pop", _ -> host("array_pop", [])
    "shift", _ -> host("array_shift", [])
    "unshift", _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, pre, ctr)
      Ok(bind_after(
        binds2,
        ir.CallHost("js", "array_unshift", [recv, listv]),
        ctr,
      ))
    }
    "reverse", _ -> host("array_reverse", [])
    "flat", _ -> host("array_flat", [])
    "fill", [v, ..] -> host("array_fill", [v])
    "at", [i, ..] -> host("array_at", [i])
    "padStart", [n] -> host("str_pad_start", [n, ir.ConstBinary(<<" ">>)])
    "padStart", [n, p, ..] -> host("str_pad_start", [n, p])
    "padEnd", [n] -> host("str_pad_end", [n, ir.ConstBinary(<<" ">>)])
    "padEnd", [n, p, ..] -> host("str_pad_end", [n, p])
    // iteration with a callback
    "map", [f, ..] -> host("array_map", [f])
    "filter", [f, ..] -> host("array_filter", [f])
    // forEach + Map/Set methods dispatch on the receiver type in the runtime and
    // delegate (with ALL args) to a same-named user method on a plain object.
    "forEach", _ -> coll("js_m_foreach")
    "get", _ -> coll("js_m_get")
    "set", _ -> coll("js_m_set")
    "add", _ -> coll("js_m_add")
    "has", _ -> coll("js_m_has")
    "delete", _ -> coll("js_m_delete")
    "clear", _ -> coll("js_m_clear")
    "some", [f, ..] -> host("array_some", [f])
    "every", [f, ..] -> host("array_every", [f])
    "find", [f, ..] -> host("array_find", [f])
    "findIndex", [f, ..] -> host("array_find_index", [f])
    "flatMap", [f, ..] -> host("array_flat_map", [f])
    "findLast", [f, ..] -> host("array_find_last", [f])
    "findLastIndex", [f, ..] -> host("array_find_last_index", [f])
    "lastIndexOf", [x, ..] -> host("array_last_index_of", [x])
    "toFixed", [d, ..] -> host("num_to_fixed", [d])
    "toFixed", [] -> host("num_to_fixed", [undefined()])
    "toString", [] -> host("to_string_dispatch", [])
    "toString", [radix, ..] -> host("num_to_string_radix", [radix])
    // regex: `re.test(str)` and `str.match(re)`.
    "test", [s, ..] -> host("regex_test", [s])
    "match", [re, ..] -> host("str_match", [re])
    "reduce", [f] -> host("array_reduce1", [f])
    "reduce", [f, init, ..] -> host("array_reduce", [f, init])
    "reduceRight", [f] -> host("array_reduce_right1", [f])
    "reduceRight", [f, init, ..] -> host("array_reduce_right", [f, init])
    "sort", [] -> host("array_sort", [undefined()])
    "sort", [cmp, ..] -> host("array_sort", [cmp])
    // queries
    "indexOf", [x, ..] -> host("array_index_of", [x])
    "includes", [x, ..] -> host("array_includes", [x])
    "join", [] -> host("array_join", [ir.ConstBinary(<<",">>)])
    "join", [sep, ..] -> host("array_join", [sep])
    "slice", [] -> host("array_slice", [undefined(), undefined()])
    "slice", [s] -> host("array_slice", [s, undefined()])
    "slice", [s, e, ..] -> host("array_slice", [s, e])
    "concat", _ -> {
      let #(binds2, listv, ctr) = build_list(argvals, pre, ctr)
      Ok(bind_after(
        binds2,
        ir.CallHost("js", "array_concat", [recv, listv]),
        ctr,
      ))
    }
    // string methods (charAt/slice/indexOf/includes/concat overlap with arrays and
    // dispatch polymorphically in the runtime).
    "charAt", [i, ..] -> host("str_char_at", [i])
    "charCodeAt", [i, ..] -> host("str_char_code_at", [i])
    // Strings count code POINTS in this model, so codePointAt == charCodeAt.
    "codePointAt", [i, ..] -> host("str_char_code_at", [i])
    "toUpperCase", _ -> host("str_upper", [])
    "toLowerCase", _ -> host("str_lower", [])
    "substring", [] -> host("str_substring", [undefined(), undefined()])
    "substring", [s] -> host("str_substring", [s, undefined()])
    "substring", [s, e, ..] -> host("str_substring", [s, e])
    "split", [] -> host("str_split", [undefined()])
    "split", [sep, ..] -> host("str_split", [sep])
    "trim", _ -> host("str_trim", [])
    "trimStart", _ -> host("str_trim_start", [])
    "trimEnd", _ -> host("str_trim_end", [])
    "repeat", [n, ..] -> host("str_repeat", [n])
    "startsWith", [p, ..] -> host("str_starts_with", [p])
    "endsWith", [s, ..] -> host("str_ends_with", [s])
    "replace", [a, b, ..] -> host("str_replace", [a, b])
    "replaceAll", [a, b, ..] -> host("str_replace_all", [a, b])
    // An unknown method name → look the property up and apply it. This is how a
    // method stored on an object/class instance (a function-valued property) is
    // called; `recv.m` that isn't a function is `undefined` → a runtime bad-call.
    _, _ -> {
      let #(bg, fnv, ctr) =
        bind_after(
          pre,
          ir.CallHost("js", "get_prop", [recv, ir.ConstBinary(<<method:utf8>>)]),
          ctr,
        )
      Ok(bind_after(bg, ir.CallClosure(fnv, argvals), ctr))
    }
  }
}

/// `[e0, e1, …]` — evaluate each element left-to-right (a hole becomes `undefined`),
/// then construct the array from the cons list via `new_array`. With a spread element
/// (`[...a, x]`) it builds incrementally: pushing single values and spreading arrays/
/// strings into a fresh array.
fn lower_array(
  elements: List(Option(ast.Expression)),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  let has_spread =
    list.any(elements, fn(el) {
      case el {
        Some(ast.SpreadElement(..)) -> True
        _ -> False
      }
    })
  case has_spread {
    False -> {
      use #(binds, vals, ctr) <- result_try(
        list.try_fold(elements, #([], [], ctr), fn(acc, el) {
          let #(binds, vals, ctr) = acc
          case el {
            Some(e) -> {
              use #(b, v, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
              Ok(#(list.append(binds, b), list.append(vals, [v]), ctr))
            }
            None -> Ok(#(binds, list.append(vals, [undefined()]), ctr))
          }
        }),
      )
      let #(binds2, listv, ctr) = build_list(vals, binds, ctr)
      Ok(bind_after(binds2, ir.CallHost("js", "new_array", [listv]), ctr))
    }
    True -> {
      let #(bnil, nilv, ctr) = build_list([], [], ctr)
      let #(b0, arr, ctr) =
        bind_after(bnil, ir.CallHost("js", "new_array", [nilv]), ctr)
      list.try_fold(elements, #(b0, arr, ctr), fn(acc, el) {
        let #(binds, arr, ctr) = acc
        case el {
          Some(ast.SpreadElement(argument:, ..)) -> {
            use #(bs, sv, ctr) <- result_try(lower_expr(argument, env, ctx, ctr))
            let #(binds2, _r, ctr) =
              bind_after(
                list.append(binds, bs),
                ir.CallHost("js", "array_spread_into", [arr, sv]),
                ctr,
              )
            Ok(#(binds2, arr, ctr))
          }
          other -> {
            use #(be, v, ctr) <- result_try(case other {
              Some(e) -> lower_expr(e, env, ctx, ctr)
              None -> Ok(#([], undefined(), ctr))
            })
            let #(bl, listv, ctr) = build_list([v], list.append(binds, be), ctr)
            let #(binds2, _r, ctr) =
              bind_after(bl, ir.CallHost("js", "array_push", [arr, listv]), ctr)
            Ok(#(binds2, arr, ctr))
          }
        }
      })
    }
  }
}

/// Fit an argument list to `arity`: pad with `undefined` (so defaults apply) or drop
/// extras. BEAM funs are arity-strict; JS tolerates over-/under-application.
fn fit_args(args: List(ir.Value), arity: Int) -> List(ir.Value) {
  let n = list.length(args)
  case n < arity {
    True -> list.append(args, list.repeat(undefined(), arity - n))
    False ->
      case n > arity {
        True -> list.take(args, arity)
        False -> args
      }
  }
}

fn lower_args(
  args: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), List(ir.Value), Int), Error) {
  list.try_fold(args, #([], [], ctr), fn(acc, a) {
    let #(binds, vals, ctr) = acc
    use #(b, v, ctr) <- result_try(lower_expr(a, env, ctx, ctr))
    Ok(#(list.append(binds, b), list.append(vals, [v]), ctr))
  })
}

/// Build a BEAM cons list from `empty_list()` and `MakeCons`, for `console.log`.
fn build_list(
  vals: List(ir.Value),
  pre: List(Bind),
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let #(binds, nilv, ctr) =
    bind_after(pre, ir.CallHost("js", "empty_list", []), ctr)
  list.fold_right(vals, #(binds, nilv, ctr), fn(acc, v) {
    let #(binds, tail, ctr) = acc
    bind_after(binds, ir.TermOp(ir.MakeCons, [v, tail]), ctr)
  })
}

fn lower_member(
  object: ast.Expression,
  property: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case object, property, computed {
    // Math.PI / Math.E / … — a compile-time numeric constant (Math is not a value).
    ast.Identifier(name: "Math", ..), ast.Identifier(name: c, ..), False ->
      case math_const(c) {
        Some(v) -> Ok(#([], v, ctr))
        None -> Error(Unsupported("Math." <> c))
      }
    _, _, _ -> lower_member_get(object, property, computed, env, ctx, ctr)
  }
}

fn lower_member_get(
  object: ast.Expression,
  property: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bo, o, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
  use #(bk, key, ctr) <- result_try(member_key(
    property,
    computed,
    env,
    ctx,
    ctr,
  ))
  Ok(bind_after(
    list.append(bo, bk),
    ir.CallHost("js", "get_prop", [o, key]),
    ctr,
  ))
}

/// `a?.b` / `a?.[k]` — if `a` is null/undefined the whole access is `undefined` (and
/// the key is not evaluated); otherwise it is a normal property read.
fn lower_optional_member(
  object: ast.Expression,
  property: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bo, o, ctr) <- result_try(lower_expr(object, env, ctx, ctr))
  use #(bk, key, ctr) <- result_try(member_key(
    property,
    computed,
    env,
    ctx,
    ctr,
  ))
  let #(bn, nvar, ctr) =
    bind_after(bo, ir.CallHost("js", "is_nullish", [o]), ctr)
  let #(bg, getv, ctr) =
    bind_after(bk, ir.CallHost("js", "get_prop", [o, key]), ctr)
  let expr =
    ir.If(
      cond: nvar,
      result: [ir.TTerm],
      then_branch: ir.Values([undefined()]),
      else_branch: emit_lets(bg, ir.Values([getv])),
    )
  Ok(bind_after(bn, expr, ctr))
}

/// `f?.(args)` — if `f` is null/undefined the call yields `undefined` (and the args
/// are not evaluated); otherwise it applies `f`.
fn lower_optional_call(
  callee: ast.Expression,
  arguments: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  use #(bc, cv, ctr) <- result_try(lower_expr(callee, env, ctx, ctr))
  use #(ba, argvals, ctr) <- result_try(lower_args(arguments, env, ctx, ctr))
  let #(bn, nvar, ctr) =
    bind_after(bc, ir.CallHost("js", "is_nullish", [cv]), ctr)
  let #(bcall, callv, ctr) = bind_after(ba, ir.CallClosure(cv, argvals), ctr)
  let expr =
    ir.If(
      cond: nvar,
      result: [ir.TTerm],
      then_branch: ir.Values([undefined()]),
      else_branch: emit_lets(bcall, ir.Values([callv])),
    )
  Ok(bind_after(bn, expr, ctr))
}

fn member_key(
  property: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case computed {
    // obj[k] — k is any expression.
    True -> lower_expr(property, env, ctx, ctr)
    // obj.prop — the property is an identifier used as a string key.
    False ->
      case property {
        ast.Identifier(name: p, ..) ->
          Ok(#([], ir.ConstBinary(<<p:utf8>>), ctr))
        _ -> Error(Unsupported("member property"))
      }
  }
}

fn lower_object(
  properties: List(ast.Property),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  let #(binds, obj, ctr) =
    bind_after([], ir.CallHost("js", "new_object", []), ctr)
  list.try_fold(properties, #(binds, obj, ctr), fn(acc, prop) {
    let #(binds, obj, ctr) = acc
    case prop {
      ast.Property(key:, value:, computed:, ..) -> {
        use #(bk, key, ctr) <- result_try(object_key(
          key,
          computed,
          env,
          ctx,
          ctr,
        ))
        use #(bv, v, ctr) <- result_try(lower_expr(value, env, ctx, ctr))
        // set_prop returns the value; we thread the object handle forward (it is a
        // stable ref — set mutates it), so `obj` stays the result.
        let pre = list.flatten([binds, bk, bv])
        let #(binds2, _r, ctr) =
          bind_after(pre, ir.CallHost("js", "set_prop", [obj, key, v]), ctr)
        Ok(#(binds2, obj, ctr))
      }
      // `{...src}` — copy src's own properties in (later keys override earlier ones).
      ast.SpreadProperty(argument:) -> {
        use #(bs, sv, ctr) <- result_try(lower_expr(argument, env, ctx, ctr))
        let #(binds2, _r, ctr) =
          bind_after(
            list.append(binds, bs),
            ir.CallHost("js", "object_assign_into", [obj, sv]),
            ctr,
          )
        Ok(#(binds2, obj, ctr))
      }
    }
  })
}

fn object_key(
  key: ast.Expression,
  computed: Bool,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case computed, key {
    True, _ -> lower_expr(key, env, ctx, ctr)
    False, ast.Identifier(name: p, ..) ->
      Ok(#([], ir.ConstBinary(<<p:utf8>>), ctr))
    False, ast.StringExpression(value: s, ..) ->
      Ok(#([], ir.ConstBinary(<<s:utf8>>), ctr))
    False, ast.NumberLiteral(value: v, ..) ->
      Ok(#([], ir.ConstBinary(<<num_key(v):utf8>>), ctr))
    _, _ -> Error(Unsupported("object key"))
  }
}

/// Lower a tagged template `` tag`c0${e0}c1…` `` to the call
/// `tag(templateObject, e0, e1, …)` (§13.2.8, GetTemplateObject).
///
/// The template object is an array of the COOKED quasi strings (a quasi with an
/// invalid escape cooks to `undefined`) carrying a `raw` property that is the
/// array of the RAW quasi strings. It is built directly in IR (`new_array` +
/// `set_prop`), bound to a synthetic env name, then handed to the ordinary call
/// path as the leading argument — so the tag can be a top-level function
/// (including one with a rest param), a closure, or a method, exactly like any
/// other call.
///
/// v1 deviation: a fresh template object is produced per evaluation rather than
/// one cached per call site, so a tag that keys a Map/WeakMap on the `strings`
/// object's identity across calls will not see the same object; the array is
/// also not frozen. Tags that read `strings`/`strings.raw` and the substitutions
/// (the overwhelming majority, incl. String.raw-style tags) are unaffected.
fn lower_tagged_template(
  tag: ast.Expression,
  cooked: List(Option(String)),
  raw: List(String),
  expressions: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  let cooked_vals =
    list.map(cooked, fn(c) {
      case c {
        Some(s) -> ir.ConstBinary(<<s:utf8>>)
        None -> undefined()
      }
    })
  let raw_vals = list.map(raw, fn(s) { ir.ConstBinary(<<s:utf8>>) })
  // strings = new_array(cooked); strings.raw = new_array(raw)
  let #(b1, cooked_list, ctr) = build_list(cooked_vals, [], ctr)
  let #(b2, strings, ctr) =
    bind_after(b1, ir.CallHost("js", "new_array", [cooked_list]), ctr)
  let #(b3, raw_list, ctr) = build_list(raw_vals, b2, ctr)
  let #(b4, raw_arr, ctr) =
    bind_after(b3, ir.CallHost("js", "new_array", [raw_list]), ctr)
  let #(b5, _, ctr) =
    bind_after(
      b4,
      ir.CallHost("js", "set_prop", [
        strings,
        ir.ConstBinary(<<"raw">>),
        raw_arr,
      ]),
      ctr,
    )
  // Bind the template object under a `%`-prefixed name (collision-proof) and
  // reuse the normal call path with it as the leading argument.
  let tname = "%tt_" <> int.to_string(ctr)
  let env2 = dict.insert(env, tname, strings)
  let sp = ast.Span(0, 0)
  let args = [ast.Identifier(span: sp, name: tname), ..expressions]
  use #(cb, callv, ctr) <- result_try(lower_call(tag, args, env2, ctx, ctr))
  Ok(#(list.append(b5, cb), callv, ctr))
}

fn lower_template(
  quasis: List(String),
  expressions: List(ast.Expression),
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  // `q0 ${e0} q1 ${e1} q2` → q0 + str(e0) + q1 + str(e1) + q2 (rt_js add concat).
  case quasis {
    [] -> Ok(#([], ir.ConstBinary(<<>>), ctr))
    [first, ..rest_q] -> {
      let acc0 = #([], ir.ConstBinary(<<first:utf8>>), ctr)
      use #(binds, acc, ctr) <- result_try(
        list.try_fold(list.zip(expressions, rest_q), acc0, fn(state, pair) {
          let #(binds, acc, ctr) = state
          let #(e, q) = pair
          use #(be, ev, ctr) <- result_try(lower_expr(e, env, ctx, ctr))
          // acc + String(e) + q
          let #(b1, s, ctr) =
            bind_after(
              list.append(binds, be),
              ir.CallHost("js", "to_string", [ev]),
              ctr,
            )
          let #(b2, acc1, ctr) =
            bind_after(b1, ir.CallHost("js", "add", [acc, s]), ctr)
          let #(b3, acc2, ctr) =
            bind_after(
              b2,
              ir.CallHost("js", "add", [acc1, ir.ConstBinary(<<q:utf8>>)]),
              ctr,
            )
          Ok(#(b3, acc2, ctr))
        }),
      )
      Ok(#(binds, acc, ctr))
    }
  }
}

// ── literals / small helpers ─────────────────────────────────────────────────

/// A JS number literal → a native BEAM number term: an integer term when integral
/// (exact + fast fixnum arithmetic), else a native float term.
fn number_literal(v: Float, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  case is_integral(v) {
    True -> {
      let #(name, ctr) = fresh(ctr)
      #(
        [#(name, ir.Convert(ir.BoxInt(ir.W64), ir.ConstI64(float.truncate(v))))],
        ir.Var(name),
        ctr,
      )
    }
    False -> #([], ir.ConstFloatTerm(v), ctr)
  }
}

fn is_integral(v: Float) -> Bool {
  int.to_float(float.truncate(v)) == v
}

/// The JS `undefined` value — the `rt_js` sentinel atom.
fn undefined() -> ir.Value {
  ir.ConstAtom("undefined")
}

/// The value of a free identifier that names a global constant of the JS runtime
/// (`NaN`, `Infinity`, `undefined`), or `None` if `name` is not one. `NaN` and
/// `Infinity` are the `rt_js` numeric sentinels `js_nan` / `js_inf`, which the
/// runtime accepts as number inputs (`num_of`, `js_type`). A local binding of
/// the same name shadows these (checked before this fallback).
fn global_const(name: String) -> Option(ir.Value) {
  case name {
    "NaN" -> Some(ir.ConstAtom("js_nan"))
    "Infinity" -> Some(ir.ConstAtom("js_inf"))
    "undefined" -> Some(undefined())
    _ -> None
  }
}

fn bool_to_string(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

/// An i32 truth `Value` → a JS boolean **term** (`'true'`/`'false'`).
fn bool_term(i32v: ir.Value) -> ir.Expr {
  bool_expr(i32v)
}

fn bool_expr(i32v: ir.Value) -> ir.Expr {
  ir.If(
    cond: i32v,
    result: [ir.TTerm],
    then_branch: ir.Values([ir.ConstAtom("true")]),
    else_branch: ir.Values([ir.ConstAtom("false")]),
  )
}

/// A conservative arity for a bare top-level-function reference used as a value.
/// We don't track arities here (v1), so a plain reference is unsupported precisely.
fn fn_arity_unknown(name: String) -> Int {
  // A closure over a top-level function needs its arity; not tracked in v1.
  panic as {
    "js: first-class use of function '" <> name <> "' not supported yet"
  }
}

fn num_key(v: Float) -> String {
  case is_integral(v) {
    True -> int.to_string(float.truncate(v))
    False -> float.to_string(v)
  }
}

// ── the assigned-variable analysis (mutated set for control flow) ────────────

/// Variable names ASSIGNED (`x = …`, `x += …`, `x++`) anywhere in a statement list,
/// recursing through nested control flow but NOT into nested functions. Declarations
/// (`let x`) are not assignments.
fn assigned_in(stmts: List(ast.Statement)) -> List(String) {
  list.flat_map(stmts, assigned_in_stmt)
}

fn assigned_in_stmt(s: ast.Statement) -> List(String) {
  case s {
    ast.ExpressionStatement(expression: e, ..) -> assigned_of_expr(e)
    ast.BlockStatement(body:) ->
      assigned_in(list.map(body, fn(w) { w.statement }))
    ast.IfStatement(consequent:, alternate:, ..) ->
      list.append(assigned_in_stmt(consequent), case alternate {
        Some(a) -> assigned_in_stmt(a)
        None -> []
      })
    ast.WhileStatement(body:, ..) -> assigned_in_stmt(body)
    ast.DoWhileStatement(body:, ..) -> assigned_in_stmt(body)
    ast.ForStatement(update:, body:, ..) ->
      list.append(assigned_in_stmt(body), case update {
        Some(u) -> assigned_of_expr(u)
        None -> []
      })
    ast.ForOfStatement(body:, ..) -> assigned_in_stmt(body)
    ast.ForInStatement(body:, ..) -> assigned_in_stmt(body)
    ast.LabeledStatement(body:, ..) -> assigned_in_stmt(body)
    ast.SwitchStatement(cases:, ..) ->
      list.flat_map(cases, fn(c) {
        assigned_in(list.map(c.consequent, fn(w) { w.statement }))
      })
    ast.ThrowStatement(argument: a) -> assigned_of_expr(a)
    ast.TryStatement(block:, handler:, finalizer:) ->
      list.flatten([
        assigned_in_stmt(block),
        case handler {
          Some(ast.CatchClause(body:, ..)) -> assigned_in_stmt(body)
          None -> []
        },
        case finalizer {
          Some(f) -> assigned_in_stmt(f)
          None -> []
        },
      ])
    _ -> []
  }
}

fn assigned_of_expr(e: ast.Expression) -> List(String) {
  case e {
    ast.AssignmentExpression(left: ast.Identifier(name: x, ..), ..) -> [x]
    ast.UpdateExpression(argument: ast.Identifier(name: x, ..), ..) -> [x]
    ast.SequenceExpression(expressions:, ..) ->
      list.flat_map(expressions, assigned_of_expr)
    _ -> []
  }
}

// ── closures: lambda collection + free-variable (capture) analysis ────────────

/// A function/arrow expression discovered by the pre-pass, before naming/capture
/// resolution: its source span and its parameter patterns + normalised body.
type RawLambda {
  RawLambda(
    span: ast.Span,
    params: List(ast.Pattern),
    body: List(ast.Statement),
  )
}

/// Normalise an arrow body to a statement list: an expression body `x => e` becomes
/// `{ return e; }`; a block body is its statements.
fn arrow_body_stmts(body: ast.ArrowBody) -> List(ast.Statement) {
  case body {
    ast.ArrowBodyExpression(e) -> [ast.ReturnStatement(argument: Some(e))]
    ast.ArrowBodyBlock(s) -> block_stmts(s)
  }
}

/// Parameter identifier names, skipping unsupported patterns (used only by the capture
/// analysis, which tolerates them — lowering rejects them). A defaulted param `x = e`
/// contributes its name `x`.
fn pattern_names_lax(params: List(ast.Pattern)) -> List(String) {
  list.filter_map(params, fn(p) {
    case p {
      ast.IdentifierPattern(name:, ..) -> Ok(name)
      ast.AssignmentPattern(left: ast.IdentifierPattern(name:, ..), ..) ->
        Ok(name)
      _ -> Error(Nil)
    }
  })
}

/// Parameter names, any defaults (`function f(x, y = 5)`), and an optional trailing
/// rest param (`function f(a, ...rest)`). Each parameter must be a plain identifier
/// (optionally defaulted); destructuring patterns are `Unsupported`.
fn param_info(
  params: List(ast.Pattern),
) -> Result(
  #(List(String), List(#(String, ast.Expression)), Option(String)),
  Error,
) {
  list.try_fold(params, #([], [], None), fn(acc, p) {
    let #(names, defaults, rest) = acc
    case p {
      ast.IdentifierPattern(name:, ..) ->
        Ok(#(list.append(names, [name]), defaults, rest))
      ast.AssignmentPattern(left: ast.IdentifierPattern(name:, ..), right: d) ->
        Ok(#(
          list.append(names, [name]),
          list.append(defaults, [#(name, d)]),
          rest,
        ))
      ast.RestElement(argument: ast.IdentifierPattern(name:, ..)) ->
        Ok(#(names, defaults, Some(name)))
      _ -> Error(Unsupported("parameter pattern (destructuring)"))
    }
  })
}

/// The synthetic prologue statements that apply default parameter values:
/// `if (name === undefined) { name = default; }` for each defaulted param. Combined
/// with call-site arity padding (a missing arg arrives as `undefined`), this gives JS
/// default-parameter semantics.
fn default_prologue(
  defaults: List(#(String, ast.Expression)),
) -> List(ast.Statement) {
  let sp = ast.Span(0, 0)
  list.map(defaults, fn(d) {
    let #(name, expr) = d
    let is_undef =
      ast.BinaryExpression(
        span: sp,
        operator: ast.StrictEqual,
        left: ast.Identifier(span: sp, name: name),
        right: ast.UndefinedExpression(span: sp),
      )
    let assign =
      ast.ExpressionStatement(
        expression: ast.AssignmentExpression(
          span: sp,
          operator: ast.Assign,
          left: ast.Identifier(span: sp, name: name),
          right: expr,
        ),
        directive: None,
      )
    ast.IfStatement(
      condition: is_undef,
      consequent: ast.BlockStatement(body: [
        ast.StmtWithLine(line: 0, statement: assign),
      ]),
      alternate: None,
    )
  })
}

/// The immediate child value-expressions of `e` — the operands that are evaluated.
/// A non-computed member/object property NAME is not a child (it is not a variable
/// read), and a nested function/arrow is handled by the caller (a separate scope).
fn child_exprs(e: ast.Expression) -> List(ast.Expression) {
  case e {
    ast.BinaryExpression(left:, right:, ..) -> [left, right]
    ast.LogicalExpression(left:, right:, ..) -> [left, right]
    ast.UnaryExpression(argument:, ..) -> [argument]
    ast.UpdateExpression(argument:, ..) -> [argument]
    ast.AssignmentExpression(left:, right:, ..) -> [left, right]
    ast.ConditionalExpression(condition:, consequent:, alternate:, ..) -> [
      condition,
      consequent,
      alternate,
    ]
    ast.CallExpression(callee:, arguments:, ..) -> [callee, ..arguments]
    ast.MemberExpression(object:, property:, computed:, ..) ->
      case computed {
        True -> [object, property]
        False -> [object]
      }
    ast.OptionalMemberExpression(object:, property:, computed:, ..) ->
      case computed {
        True -> [object, property]
        False -> [object]
      }
    ast.OptionalCallExpression(callee:, arguments:, ..) -> [callee, ..arguments]
    ast.NewExpression(callee:, arguments:, ..) -> [callee, ..arguments]
    ast.SpreadElement(argument:, ..) -> [argument]
    ast.ObjectExpression(properties:, ..) ->
      list.flat_map(properties, fn(p) {
        case p {
          ast.Property(key:, value:, computed: True, ..) -> [key, value]
          ast.Property(value:, ..) -> [value]
          ast.SpreadProperty(argument:) -> [argument]
        }
      })
    ast.ArrayExpression(elements:, ..) ->
      list.filter_map(elements, option.to_result(_, Nil))
    ast.SequenceExpression(expressions:, ..) -> expressions
    ast.TemplateLiteral(expressions:, ..) -> expressions
    ast.ParenthesizedExpression(expression:, ..) -> [expression]
    _ -> []
  }
}

/// The identifiers READ by expression `e` (i.e. free in `e`). A nested lambda
/// contributes ITS free variables, not its internal reads (a separate scope).
fn reads(e: ast.Expression) -> List(String) {
  case e {
    ast.Identifier(name:, ..) -> [name]
    // `this` reads the enclosing method's binding — a nested arrow captures it.
    ast.ThisExpression(..) -> ["this"]
    ast.ArrowFunctionExpression(params:, body:, ..) ->
      fv_lambda(pattern_names_lax(params), arrow_body_stmts(body))
    ast.FunctionExpression(params:, body:, ..) ->
      fv_lambda(pattern_names_lax(params), block_stmts(body))
    _ -> list.flat_map(child_exprs(e), reads)
  }
}

/// Expressions directly evaluated by a statement (NOT its nested statements).
fn stmt_exprs(s: ast.Statement) -> List(ast.Expression) {
  case s {
    ast.ExpressionStatement(expression:, ..) -> [expression]
    ast.ReturnStatement(argument: Some(e)) -> [e]
    ast.VariableDeclaration(declarations:, ..) ->
      list.filter_map(declarations, fn(d) { option.to_result(d.init, Nil) })
    ast.IfStatement(condition:, ..) -> [condition]
    ast.WhileStatement(condition:, ..) -> [condition]
    ast.DoWhileStatement(condition:, ..) -> [condition]
    ast.ThrowStatement(argument:) -> [argument]
    ast.ForStatement(init:, condition:, update:, ..) ->
      list.flatten([
        for_init_exprs(init),
        option.values([condition]),
        option.values([update]),
      ])
    ast.ForOfStatement(right:, ..) -> [right]
    ast.ForInStatement(right:, ..) -> [right]
    ast.SwitchStatement(discriminant:, cases:) -> [
      discriminant,
      ..list.filter_map(cases, fn(c) { option.to_result(c.condition, Nil) })
    ]
    _ -> []
  }
}

/// Nested statements inside a statement (block body, branch arms, loop body).
fn child_stmts(s: ast.Statement) -> List(ast.Statement) {
  case s {
    ast.BlockStatement(..) -> block_stmts(s)
    ast.IfStatement(consequent:, alternate:, ..) ->
      list.append([consequent], option.values([alternate]))
    ast.WhileStatement(body:, ..) -> [body]
    ast.DoWhileStatement(body:, ..) -> [body]
    ast.ForStatement(body:, ..) -> [body]
    ast.ForOfStatement(body:, ..) -> [body]
    ast.ForInStatement(body:, ..) -> [body]
    ast.LabeledStatement(body:, ..) -> [body]
    ast.SwitchStatement(cases:, ..) ->
      list.flat_map(cases, fn(c) {
        list.map(c.consequent, fn(w) { w.statement })
      })
    ast.TryStatement(block:, handler:, finalizer:) ->
      list.flatten([
        [block],
        case handler {
          Some(ast.CatchClause(body:, ..)) -> [body]
          None -> []
        },
        case finalizer {
          Some(f) -> [f]
          None -> []
        },
      ])
    _ -> []
  }
}

fn for_init_exprs(init: Option(ast.ForInit)) -> List(ast.Expression) {
  case init {
    Some(ast.ForInitExpression(e)) -> [e]
    Some(ast.ForInitDeclaration(d)) -> stmt_exprs(d)
    Some(ast.ForInitPattern(_)) -> []
    None -> []
  }
}

/// All identifiers read anywhere in a statement list.
fn reads_stmts(stmts: List(ast.Statement)) -> List(String) {
  list.flat_map(stmts, fn(s) {
    list.append(
      list.flat_map(stmt_exprs(s), reads),
      list.flat_map(child_stmts(s), fn(c) { reads_stmts([c]) }),
    )
  })
}

/// Variables DECLARED in a statement list (own scope: `let/const/var`, `for`-init
/// declarations, nested function-declaration names). Does not descend into nested
/// function/arrow expression bodies (those are separate scopes).
/// Every identifier BOUND by a binding pattern (handles array/object destructuring,
/// defaults, and rest, recursively). Used to know a scope's locals.
fn pattern_declared(p: ast.Pattern) -> List(String) {
  case p {
    ast.IdentifierPattern(name:, ..) -> [name]
    ast.ArrayPattern(elements:) ->
      list.flat_map(elements, fn(el) {
        case el {
          Some(pp) -> pattern_declared(pp)
          None -> []
        }
      })
    ast.ObjectPattern(properties:) ->
      list.flat_map(properties, fn(pp) {
        case pp {
          ast.PatternProperty(value:, ..) -> pattern_declared(value)
          ast.RestProperty(argument:) -> pattern_declared(argument)
        }
      })
    ast.AssignmentPattern(left:, ..) -> pattern_declared(left)
    ast.RestElement(argument:) -> pattern_declared(argument)
  }
}

fn declared_stmts(stmts: List(ast.Statement)) -> List(String) {
  list.flat_map(stmts, declared_stmt)
}

fn declared_stmt(s: ast.Statement) -> List(String) {
  let here = case s {
    ast.VariableDeclaration(declarations:, ..) ->
      list.flat_map(declarations, fn(d) { pattern_declared(d.id) })
    ast.FunctionDeclaration(name: Some(n), ..) -> [n]
    ast.ForStatement(init: Some(ast.ForInitDeclaration(d)), ..) ->
      declared_stmt(d)
    ast.ForOfStatement(left:, ..) -> for_of_declared(left)
    ast.ForInStatement(left:, ..) -> for_of_declared(left)
    ast.TryStatement(
      handler: Some(ast.CatchClause(
        param: Some(ast.IdentifierPattern(name: n, ..)),
        ..,
      )),
      ..,
    ) -> [n]
    _ -> []
  }
  list.append(here, list.flat_map(child_stmts(s), declared_stmt))
}

/// The variable bound by a `for-of`/`for-in` header (laxly; `[]` if not a simple
/// identifier binding).
fn for_of_declared(left: ast.ForInit) -> List(String) {
  case for_of_var(left) {
    Ok(n) -> [n]
    Error(_) -> []
  }
}

/// Free variables of a lambda body: identifiers read but not bound by the lambda's
/// own parameters or locals. (Top-level function/global names are removed later, when
/// captures are resolved, so this stays independent of the enclosing scope.)
fn fv_lambda(params: List(String), body: List(ast.Statement)) -> List(String) {
  reads_stmts(body)
  |> list.unique
  |> list.filter(fn(v) {
    !list.contains(params, v) && !list.contains(declared_stmts(body), v)
  })
}

/// The captured variables of a lambda: its free variables minus the globals
/// (top-level function names), which are referenced directly rather than captured.
fn lambda_captures(
  params: List(String),
  body: List(ast.Statement),
  globals: List(String),
) -> List(String) {
  fv_lambda(params, body)
  |> list.filter(fn(v) { !list.contains(globals, v) })
}

/// Every function/arrow expression anywhere in a statement list (including nested
/// ones inside other lambdas), in source order.
fn lambda_nodes_stmts(stmts: List(ast.Statement)) -> List(RawLambda) {
  list.flat_map(stmts, fn(s) {
    list.append(
      list.flat_map(stmt_exprs(s), lambda_nodes_expr),
      list.flat_map(child_stmts(s), fn(c) { lambda_nodes_stmts([c]) }),
    )
  })
}

fn lambda_nodes_expr(e: ast.Expression) -> List(RawLambda) {
  case e {
    ast.ArrowFunctionExpression(span:, params:, body:, ..) -> {
      let stmts = arrow_body_stmts(body)
      [RawLambda(span, params, stmts), ..lambda_nodes_stmts(stmts)]
    }
    ast.FunctionExpression(span:, params:, body:, ..) -> {
      let stmts = block_stmts(body)
      [RawLambda(span, params, stmts), ..lambda_nodes_stmts(stmts)]
    }
    _ -> list.flat_map(child_exprs(e), lambda_nodes_expr)
  }
}

/// The pre-pass: assign each lambda a unique lifted name and resolve its captures,
/// keyed by source span. `globals` are the top-level function names.
fn collect_lambdas(
  stmts: List(ast.Statement),
  globals: List(String),
) -> Result(Dict(ast.Span, Lambda), Error) {
  let raws = lambda_nodes_stmts(stmts)
  use #(lambdas, _) <- result_try(
    list.try_fold(raws, #(dict.new(), 0), fn(acc, raw) {
      let #(acc_lambdas, i) = acc
      use #(pnames, defaults, rest) <- result_try(param_info(raw.params))
      use _ <- result_try(case rest {
        Some(_) ->
          Error(Unsupported("rest parameter in a function/arrow expression"))
        None -> Ok(Nil)
      })
      let name = "lambda$" <> int.to_string(i)
      let caps = lambda_captures(pnames, raw.body, globals)
      Ok(#(
        dict.insert(
          acc_lambdas,
          raw.span,
          Lambda(name, pnames, defaults, raw.body, caps),
        ),
        i + 1,
      ))
    }),
  )
  Ok(lambdas)
}

/// Lower one lifted lambda to an IR function: its parameters are the captures FIRST
/// (per `MakeClosure`), then the JS parameters, all bound in a fresh env.
fn lower_lambda(lam: Lambda, ctx: Ctx) -> Result(ir.Function, Error) {
  let all_params = list.append(lam.captures, lam.params)
  let env =
    list.fold(all_params, dict.new(), fn(acc, n) {
      dict.insert(acc, n, ir.Var(n))
    })
  let stmts = list.append(default_prologue(lam.defaults), lam.body)
  let ctx2 = Ctx(..ctx, loop: None, scope_mutated: assigned_in(stmts))
  use #(body_expr, _ctr) <- result_try(lower_body(stmts, env, ctx2, 0))
  Ok(ir.Function(
    name: lam.name,
    params: list.map(all_params, fn(n) { ir.Local(n, ir.TTerm) }),
    result: [ir.TTerm],
    locals: [],
    body: body_expr,
  ))
}

/// Lower a function/arrow expression to a `MakeClosure`: look up its lifted function
/// by span, resolve each captured variable from the enclosing env, and reject a
/// capture that is reassigned in scope (value-capture would be unsound — the shared
/// binding requires a cell, not yet supported).
fn lower_closure(
  span: ast.Span,
  env: Env,
  ctx: Ctx,
  ctr: Int,
) -> Result(#(List(Bind), ir.Value, Int), Error) {
  case dict.get(ctx.lambdas, span) {
    Error(Nil) -> Error(Unsupported("function expression (not collected)"))
    Ok(lam) -> {
      let mutated_captures =
        list.filter(lam.captures, fn(c) {
          list.contains(ctx.scope_mutated, c)
          || list.contains(assigned_in(lam.body), c)
        })
      case mutated_captures {
        [c, ..] ->
          Error(Unsupported("closure over reassigned variable '" <> c <> "'"))
        [] ->
          case
            list.try_map(lam.captures, fn(c) {
              case dict.get(env, c) {
                Ok(v) -> Ok(v)
                Error(Nil) ->
                  Error(Unsupported("closure capture of unbound '" <> c <> "'"))
              }
            })
          {
            Error(e) -> Error(e)
            Ok(capture_vals) ->
              Ok(bind1(
                ir.MakeClosure(lam.name, capture_vals, list.length(lam.params)),
                ctr,
              ))
          }
      }
    }
  }
}

// ── plumbing ──────────────────────────────────────────────────────────────────

fn block_stmts(s: ast.Statement) -> List(ast.Statement) {
  case s {
    ast.BlockStatement(body:) -> list.map(body, fn(w) { w.statement })
    other -> [other]
  }
}

fn carried_vals(env: Env, names: List(String)) -> List(ir.Value) {
  list.map(names, fn(n) {
    case dict.get(env, n) {
      Ok(v) -> v
      Error(_) -> undefined()
    }
  })
}

fn emit_lets(binds: List(Bind), body: ir.Expr) -> ir.Expr {
  list.fold_right(binds, body, fn(acc, b) { ir.Let([b.0], b.1, acc) })
}

/// Append one fresh `Let`-binding of `expr` to `pre`, returning the result `Value`.
fn bind_after(
  pre: List(Bind),
  expr: ir.Expr,
  ctr: Int,
) -> #(List(Bind), ir.Value, Int) {
  let #(name, ctr) = fresh(ctr)
  #(list.append(pre, [#(name, expr)]), ir.Var(name), ctr)
}

fn bind1(expr: ir.Expr, ctr: Int) -> #(List(Bind), ir.Value, Int) {
  bind_after([], expr, ctr)
}

/// Mint a fresh SSA temporary name from the counter `ctr`, returning the name
/// and the advanced counter.
///
/// The `%` prefix is deliberate: `%` (byte 0x25) can never appear in a JS
/// identifier, so a compiler temp can never collide with a user variable,
/// parameter, capture, or loop-carried name (all of which enter the IR under
/// their raw JS spelling). `core_printer.legalize_var` is injective per byte, so
/// `%v0` legalizes to `V_25v0` — disjoint from a user `v0` (`Vv0`). Every
/// synthetic *variable* name in this module carries a `%` for the same reason.
fn fresh(ctr: Int) -> #(String, Int) {
  #("%v" <> int.to_string(ctr), ctr + 1)
}

fn fresh_n(n: Int, ctr: Int) -> #(List(String), Int) {
  case n {
    0 -> #([], ctr)
    _ -> {
      let #(name, ctr) = fresh(ctr)
      let #(rest, ctr) = fresh_n(n - 1, ctr)
      #([name, ..rest], ctr)
    }
  }
}

fn fresh_label(ctr: Int) -> #(String, Int) {
  #("%L" <> int.to_string(ctr), ctr + 1)
}

fn result_try(r: Result(a, e), k: fn(a) -> Result(b, e)) -> Result(b, e) {
  case r {
    Ok(v) -> k(v)
    Error(e) -> Error(e)
  }
}

fn string_tag(_s: ast.Statement) -> String {
  "unsupported"
}

fn string_tag_expr(_e: ast.Expression) -> String {
  "unsupported"
}

fn string_binop(_op: ast.BinaryOp) -> String {
  "unsupported"
}
