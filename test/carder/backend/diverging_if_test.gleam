//// Repro: `switch` where one arm `break`s (assigning) and another `return`s
//// — arc emits nested Blocks whose inner block's body always breaks to an
//// outer label; emit_core reports ArityMismatch(0, 1).

import carder/pipeline
import carder/runtime/instance.{DirectHost, HostOp, Pure}
import carder/runtime/profiles
import gleam/dict

const src = "module @r16 {
  numerics true
  memory none
  tag @js_exn (term)
  export \"js_main\" = @jsf_0_s
  func @jsf_0_s (%_p0:term) -> (term) {
    let (%js_local_4) = values (%_p0)
    let (%_t12) = block $_L0 : (term) {
      let (%_t10) = block $_L2 : (term) {
        let (%_t7) = block $_L1 : (term) {
          let (%_t2) = call_host \"js\" \"strict_eq\" (%js_local_4, binary 0x61)
          let (%_t3) = call_host \"js\" \"truthy\" (%_t2)
          if %_t3 : () {
            break $_L1 (%js_local_4)
          } else {
            let (%_t5) = call_host \"js\" \"strict_eq\" (%js_local_4, binary 0x62)
            let (%_t6) = call_host \"js\" \"truthy\" (%_t5)
            if %_t6 : () {
              break $_L2 (%js_local_4)
            } else {
              break $_L0 (%js_local_4)
            }
          }
        }
        let (%_t8) = convert box.i32 i32.const 1
        break $_L0 (%_t8)
      }
      let (%_t11) = convert box.i32 i32.const 5
      return (%_t11)
    }
    return (%_t12)
  }
}"

fn binding() {
  profiles.direct(DirectHost(
    capability: "js",
    ops: dict.from_list([
      #("strict_eq", HostOp("erlang", "'=:='", Pure)),
      #("truthy", HostOp("erlang", "'=:='", Pure)),
    ]),
  ))
}

pub fn if_with_all_arms_diverging_is_bottom_test() {
  let assert Ok(module) = pipeline.parse_ir(src)
  let assert Ok(_core) = pipeline.ir_to_core(module, binding())
}
