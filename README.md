<img width="128" src="https://github.com/scarletindustries.png" />

### Carder

Compiler backend that targets the BEAM.

[Documentation](https://scarlet.industries)

---

> this is a large experimental project. the mass majority of  the code was written by claude. no promises made. definitely don't use it in anything production as it's pretty slow right now (that will be fixed in the future)

carder takes a shared, language-neutral IR and compiles it to Core Erlang, then to a real `.beam` you can load and call. this isn't a VM — it's trying to actually "convert" the code as much as possible & optimise it for BEAM behaviour and functional programming concepts.

carder is only the **backend**. it has its own IR, and frontends live in their own repos:

| frontend | source language | repo |
|---|---|---|
| [scribbler](https://github.com/scarletindustries/scribbler) | WebAssembly | `wasm -> carder ir` |
| [arc](https://github.com/alii/arc) | JavaScript | `js -> carder ir` |

a frontend lowers its source into `carder/ir` and hands the module to `carder/pipeline`. carder owns everything from there down — the policy pass, the optimizer, Core Erlang codegen, the linker, and the BEAM runtime the emitted code calls into. **no wasm and no js lives in this repo.**

### why?

in theory since this is just going to Core Erlang, and can operate without any [NIF](https://www.erlang.org/doc/system/nif.html) usage, the code runs preemptively. this is also just fun. I've done a lot of reading over the past few months on compilers, and have many optimisation methods planned.

### how?
`ir -> core erlang -> beam`

with a frontend in front of it that's `wasm -> ir -> core erlang -> beam` (scribbler) or `js -> ir -> core erlang -> beam` (arc).

memory is a little messy right now. there are a number of modes the compiler can run in which changes how memory is allocated and accessed. throughout the code and the cli
you will see three modes referenced: (p, o, n). p = pure. runs anywhere. o = uses otp-specifics (atomics), n = custom nif.

the custom nif is the fastest, since it gives a full escape hatch to BEAM-fundamentals. but a) it's not as cool, b) it risks crashing the node.
ideally some optimisations i have planned will close the gap as much as possible. using o mode over p results in a 2-4x speedup right now.

### let me try it

there's a corpus of `.ir` programs under `test/carder/ir/corpus/` if you don't have one to hand. for example,
give this a try:

```shell
$ gleam run -- run test/carder/ir/corpus/add.ir add 3 5
8
```

this command is the "all in one", it'll take the ir, turn it into core erlang, compile it to beam, load that module and run it.
the `.ir` for that file is:

```
module @carder@wasm@add {
  numerics true
  memory none
  export "add" = @f0
  export "mul" = @f1
  func @f0 (%p0:i32, %p1:i32) -> (i32) {
    let (%v1) = num i.add.32 (%p0, %p1)
    values (%v1)
  }
  func @f1 (%p0:i32, %p1:i32) -> (i32) {
    let (%v1) = num i.mul.32 (%p0, %p1)
    values (%v1)
  }
}
```

(so we're calling the add export with params 3 and 5 for the two i32's — arguments and results are raw unsigned bit patterns, so an i32 `-1` is written `4294967295`)

you can also print out each stage of the pipeline. it's all modular. run `gleam run -- help` to see all the commands (e.g. run the policy pass, run just the optimizer, dump the `.core`, dump the erlang abstract forms, or just export to `.beam`).

### writing a frontend

[`specs/FRONTEND-API.md`](specs/FRONTEND-API.md) is the authoritative interface: the value model, the calling convention, every IR node you can emit, and how to lower common constructs. the short version is that you produce a `carder/ir.Module` and call:

```gleam
pipeline.compile_ir(module, binding)   // -> loadable .beam bytes
pipeline.run_ir(module, binding, export, args)  // -> compile + run it
```

`carder/cli` publishes the shared CLI vocabulary (the `--unsafe`/`--portable`/`--tier`/`--cap`/… axis flags and the raw-bit value formatting) so your frontend's binary speaks exactly the same posture language as carder's, and `carder/embed` is the embedder API for running a compiled guest inside a host BEAM program.

### contributing

building this burns a lot of tokens. i'd love help if you have some spare claude tokens and want to contribute! claude works out of the specs/ folder, and maintains a ledger of state and a standard workflow
for planning new phases. that's worked pretty well so far to get to where the project is now. that being said, I leave claude working on it 24/7, so rather than double-work, hit me up on Discord (@hiett) and we can allocate the workload so there's no overlap.

### license

carder is licensed under the [Apache License 2.0](LICENSE). you're free to use, modify, and distribute it — including in commercial and closed-source products — provided you keep the license and attribution notices intact. the Apache license also carries an explicit patent grant. see [LICENSE](LICENSE) and [NOTICE](NOTICE) for the full terms.
