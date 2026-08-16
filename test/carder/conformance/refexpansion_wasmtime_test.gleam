//// The new-surface Tier-B `wasmtime` differential (unit P5-11 §F.2) — OUR compiled output for the
//// self-contained bulk-memory / multi-memory functions agrees with the pinned `wasmtime` 46
//// (vendor/PIN) on authored inputs. Tier-B: `wasmtime` prints ints as signed decimal (not raw
//// bits), so it confirms a VALUE, complementing the Tier-A spec-sourced `.expected` (a stronger,
//// bit-exact check). SKIPS gracefully when `wasmtime` is not installed (recorded), like the existing
//// `wasmtime_test`. The functions are SELF-CONTAINED (one invoke each) because `wasmtime run
//// --invoke` runs one function per FRESH instance — no cross-call state.

import carder/conformance/driver
import carder/conformance/ffi
import carder/conformance/fixture.{I32Val}
import carder/conformance/reference/wasmtime
import carder/conformance/runner.{Returned}
import gleam/int
import gleam/io
import gleam/list

const wasm_path = "test/carder/conformance/corpus/newsurface_check.wasm"

/// For each self-contained new-surface function: our pipeline's result == `wasmtime`'s result
/// (bulk memmove overlap, memory.init, and a cross-memory copy). A divergence — a wrong overlap
/// direction, a mis-routed memory index, a bad eager-bounds write — goes red naming the function.
pub fn new_surface_agrees_with_wasmtime_test() {
  case wasmtime.available() {
    False -> {
      io.println(
        "\n[refexpansion-wasmtime] wasmtime not installed — Tier-B differential SKIPPED (recorded)",
      )
      Nil
    }
    True ->
      case ffi.read_file(wasm_path) {
        Error(e) -> {
          io.println("[refexpansion-wasmtime] cannot read fixture: " <> e)
          Nil
        }
        Ok(bytes) -> {
          let assert Ok(inst) = driver.pipeline().instantiate(bytes)
          list.each(
            ["bulk_check", "overlap_check", "multimem_check"],
            fn(field) {
              let ours = ours_i32(driver.pipeline(), inst, field)
              let theirs = theirs_i32(field)
              assert ours == theirs
            },
          )
        }
      }
  }
}

/// Our pipeline's i32 result for the 0-arg export `field` (or a sentinel on any non-i32 outcome).
fn ours_i32(d: runner.Driver, inst: runner.Instance, field: String) -> Int {
  case d.invoke(inst, field, []) {
    Returned([I32Val(b)]) -> b
    _ -> -1
  }
}

/// `wasmtime`'s i32 result for the 0-arg export `field` (signed decimal; positive here, so equal to
/// our unsigned bits). A sentinel distinct from `ours_i32`'s on any non-value outcome.
fn theirs_i32(field: String) -> Int {
  case wasmtime.invoke(wasm_path, field, []) {
    wasmtime.Value(line) ->
      case int.parse(line) {
        Ok(n) -> n
        Error(_) -> -2
      }
    _ -> -2
  }
}
