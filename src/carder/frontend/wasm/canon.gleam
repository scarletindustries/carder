//// Iso-recursive type canonicalization for the WebAssembly GC proposal.
////
//// The GC type system is **iso-recursive**: a defined type's identity is not its
//// declared index, but its *structure* rolled up over its recursive type group
//// (`rectype`). Two defined types are equivalent — interchangeable everywhere the
//// spec's structural typing rules compare heap types — iff their rec groups
//// canonicalize to the same descriptor AND they occupy the same position within
//// their group (spec: <https://webassembly.github.io/spec/core/valid/types.html>
//// and the GC proposal's `type equivalence` / canonicalization).
////
//// `canon_ids` collapses this into one **canonical id per type index** such that
//// `canon[i] == canon[j]` **iff** types `i` and `j` are iso-recursively equivalent.
//// The validator's concrete-heap-type matchers then compare canonical ids instead
//// of declared indices, so a `(ref $a)` matches a `(ref $b)` whenever `$a` and `$b`
//// name the same structural type even across different rec groups (fixing the
//// false-rejection of valid cross-rec-group modules), while genuinely-distinct rec
//// groups keep distinct ids (so invalid modules are still rejected).
////
//// The algorithm is a single in-order pass over the rec groups (references point
//// only intra-group — resolved as de-Bruijn positions — or to strictly-earlier
//// groups — resolved to their already-assigned canonical ids), which is sound
//// because the iso-recursive discipline forbids forward references to later groups.
//// It is a pure/total function: it never panics and tolerates malformed input (out
//// of range or forward references are serialized as distinguished "bad" markers so
//// canonicalization stays total even on modules the validator will later reject).

import carder/frontend/wasm/ast
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// One canonical id per type index (aligned with `types`), such that
/// `canon[i] == canon[j]` **iff** types `i` and `j` are iso-recursively equivalent.
///
/// - `types`: the module's flattened defined-type list (rec groups concatenated).
/// - `rec_groups`: the member count of each rec group in section order (partitions
///   `types`). `[]` — or any value whose sum ≠ `length(types)` — is read as
///   **all-singletons** (each index its own group), the non-GC default under which
///   `canon[i] == canon[j]` reduces to `i == j`. This makes the function inert for
///   every non-GC module (which carries no rec groups and no concrete heap types).
///
/// Returns a list the same length as `types`. Only consulted at `HConcrete`
/// comparisons; the ids themselves are opaque (their only meaning is equality).
///
/// Total: never fails. A reference to a later group or an out-of-range index is
/// encoded distinctly (it never spuriously merges two groups), so the result is
/// well-defined even for a module the validator rejects.
pub fn canon_ids(types: List(ast.DefType), rec_groups: List(Int)) -> List(Int) {
  let n = list.length(types)
  case n {
    0 -> []
    _ -> {
      let spans = group_spans(n, rec_groups)
      // Fold the groups in order, assigning each a group ordinal (deduping whole-
      // group descriptors) and each member a canonical id `ord*(n+1) + position`.
      let #(canon_map, _dict, _next) =
        list.fold(spans, #(dict.new(), dict.new(), 0), fn(acc, span) {
          process_group(types, n, span, acc)
        })
      seq(0, n)
      |> list.map(fn(i) {
        case dict.get(canon_map, i) {
          Ok(c) -> c
          // Unreachable: every index in [0,n) is covered by some span.
          Error(_) -> -1 - i
        }
      })
    }
  }
}

/// Partition `[0, n)` into rec-group spans `#(start, end)` (end exclusive), in
/// order. If `rec_groups` is empty or its member counts do not sum to `n` (a stale
/// or absent value), every index becomes its own singleton span — the non-GC
/// default. An empty rec group (`(rec)` with no members) yields an empty span
/// `#(s, s)`, which is harmless (it contributes no members).
pub fn group_spans(n: Int, rec_groups: List(Int)) -> List(#(Int, Int)) {
  let sum = list.fold(rec_groups, 0, fn(a, b) { a + b })
  case rec_groups != [] && sum == n {
    True -> {
      let #(spans, _) =
        list.fold(rec_groups, #([], 0), fn(acc, cnt) {
          let #(sp, start) = acc
          #([#(start, start + cnt), ..sp], start + cnt)
        })
      list.reverse(spans)
    }
    False -> seq(0, n) |> list.map(fn(i) { #(i, i + 1) })
  }
}

/// Assign a canonical id to every member of one rec group.
///
/// Serializes the whole group into a structural descriptor (each member's composite
/// + supertype + finality, with every `HConcrete` rewritten to a de-Bruijn position
/// for intra-group references or the earlier group's canonical id for external
/// references), then interns the descriptor in `group_dict` to obtain a group
/// ordinal (equal descriptors ⇒ equal ordinal ⇒ the group's members are equivalent
/// to the earlier group's). Each member index `i` receives `ord*(n+1) + (i - s)`, so
/// two indices share a canonical id iff they are in equivalent groups at the same
/// position.
fn process_group(
  types: List(ast.DefType),
  n: Int,
  span: #(Int, Int),
  acc: #(Dict(Int, Int), Dict(String, Int), Int),
) -> #(Dict(Int, Int), Dict(String, Int), Int) {
  let #(canon_map, group_dict, next_ord) = acc
  let #(s, e) = span
  let members = span_indices(s, e)
  let key =
    "G"
    <> int.to_string(e - s)
    <> "{"
    <> {
      members
      |> list.map(fn(i) { member_key(types, i, s, e, canon_map) })
      |> string.join("|")
    }
    <> "}"
  let #(ord, group_dict2, next2) = case dict.get(group_dict, key) {
    Ok(o) -> #(o, group_dict, next_ord)
    Error(_) -> #(
      next_ord,
      dict.insert(group_dict, key, next_ord),
      next_ord + 1,
    )
  }
  let canon_map2 =
    list.fold(members, canon_map, fn(cm, i) {
      dict.insert(cm, i, ord * { n + 1 } + { i - s })
    })
  #(canon_map2, group_dict2, next2)
}

/// The indices `[s, e)` in order (empty when `e <= s`).
fn span_indices(s: Int, e: Int) -> List(Int) {
  seq(s, e)
}

/// The ascending integers `[from, to)` (`[]` when `to <= from`). Hand-rolled — this
/// stdlib has no `list.range`, and this avoids any descending-range edge behaviour.
fn seq(from: Int, to: Int) -> List(Int) {
  build_seq(from, to, [])
}

fn build_seq(from: Int, to: Int, acc: List(Int)) -> List(Int) {
  case from >= to {
    True -> list.reverse(acc)
    False -> build_seq(from + 1, to, [from, ..acc])
  }
}

/// The structural descriptor of the defined type at index `i`, as a string key. Two
/// members produce the same key iff their finality, supertype (rewritten), and
/// composite (rewritten) coincide. `s`/`e` bound the current group (for the intra-
/// group de-Bruijn rewrite) and `canon_map` resolves external references.
fn member_key(
  types: List(ast.DefType),
  i: Int,
  s: Int,
  e: Int,
  canon_map: Dict(Int, Int),
) -> String {
  case ast.def_type_at(types, i) {
    Ok(dt) -> {
      let rw = fn(t) { idx_marker(t, s, e, canon_map) }
      let fin = case dt.final {
        True -> "f1"
        False -> "f0"
      }
      let sup = case dt.supertype {
        option.None -> "s_"
        option.Some(t) -> "s" <> rw(t)
      }
      fin <> sup <> comp_key(dt.comp, rw)
    }
    // Unreachable for i in [s,e); kept total.
    Error(_) -> "?"
  }
}

/// Rewrite a concrete type index into a canonical marker.
///
/// - intra-group (`s <= t < e`): `"R"<pos>` — a de-Bruijn position within this group
///   (so two equivalent groups referencing their own members match structurally).
/// - earlier group (`0 <= t < s`): `"E"<canon>` — the already-assigned canonical id.
/// - otherwise (a forward reference to a later group, or out of range): `"B"<t>` —
///   a distinguished "bad" marker that never merges two groups (the module is
///   invalid; canonicalization stays total).
fn idx_marker(t: Int, s: Int, e: Int, canon_map: Dict(Int, Int)) -> String {
  case t >= s && t < e {
    True -> "R" <> int.to_string(t - s)
    False ->
      case t >= 0 && t < s {
        True ->
          case dict.get(canon_map, t) {
            Ok(c) -> "E" <> int.to_string(c)
            Error(_) -> "B" <> int.to_string(t)
          }
        False -> "B" <> int.to_string(t)
      }
  }
}

/// The structural key of a composite type (func / struct / array), with `HConcrete`
/// references rewritten by `rw`.
fn comp_key(comp: ast.CompositeType, rw: fn(Int) -> String) -> String {
  case comp {
    ast.CtFunc(ast.FuncType(params, results)) ->
      "F("
      <> { params |> list.map(fn(v) { vt_key(v, rw) }) |> string.join(",") }
      <> "->"
      <> { results |> list.map(fn(v) { vt_key(v, rw) }) |> string.join(",") }
      <> ")"
    ast.CtStruct(fields) ->
      "S("
      <> {
        fields |> list.map(fn(fld) { field_key(fld, rw) }) |> string.join(",")
      }
      <> ")"
    ast.CtArray(element) -> "A(" <> field_key(element, rw) <> ")"
  }
}

/// The structural key of a struct field / array element: mutability then storage
/// type (`rw`-rewritten for a concrete value type).
fn field_key(field: ast.FieldType, rw: fn(Int) -> String) -> String {
  let mut = case field.mutable {
    True -> "m"
    False -> "i"
  }
  mut <> storage_key(field.storage, rw)
}

/// The structural key of a storage type: the packed forms `i8`/`i16`, or a value
/// type.
fn storage_key(storage: ast.StorageType, rw: fn(Int) -> String) -> String {
  case storage {
    ast.StI8 -> "p8"
    ast.StI16 -> "p16"
    ast.StVal(v) -> "v" <> vt_key(v, rw)
  }
}

/// The structural key of a value type, **normalizing** the reference forms so the
/// abstract shorthands (`funcref`/`externref`/`exnref`) and their explicit `(ref
/// null? ht)` spellings collapse to one key (they denote the same type). Concrete
/// heap references route through `rw`.
fn vt_key(vt: ast.ValType, rw: fn(Int) -> String) -> String {
  case ast.normalize_reftype(vt) {
    Ok(ast.RefType(nullable, heap)) -> {
      let null = case nullable {
        True -> "?"
        False -> ""
      }
      "ref" <> null <> heap_key(heap, rw)
    }
    Error(_) ->
      case vt {
        ast.I32 -> "i32"
        ast.I64 -> "i64"
        ast.F32 -> "f32"
        ast.F64 -> "f64"
        ast.V128 -> "v128"
        // Unreachable: every non-reference valtype is a number/vector above.
        _ -> "?"
      }
  }
}

/// The structural key of a heap type: the abstract roots/leaves by name, or a
/// `rw`-rewritten concrete reference.
fn heap_key(heap: ast.HeapType, rw: fn(Int) -> String) -> String {
  case heap {
    ast.HAny -> "any"
    ast.HEq -> "eq"
    ast.HI31 -> "i31"
    ast.HStruct -> "struct"
    ast.HArray -> "array"
    ast.HNone -> "none"
    ast.HFunc -> "func"
    ast.HNoFunc -> "nofunc"
    ast.HExtern -> "extern"
    ast.HNoExtern -> "noextern"
    ast.HExn -> "exn"
    ast.HNoExn -> "noexn"
    ast.HConcrete(t) -> "c" <> rw(t)
  }
}
