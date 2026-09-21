<img width="128" src="https://github.com/scarletindustries.png" />

### Carder

Compiler backend that targets the BEAM.

[Documentation](https://scarlet.industries/docs/carder)

---

> this is a large experimental project. no promises made. don't use it in production, it's pretty slow right now (that will be fixed in the future)

carder takes a language-neutral IR and compiles it to Core Erlang, then to a real `.beam` you can load and call. it isn't a VM: it converts the code and optimises it for the BEAM and for functional programming.

carder is only the backend. frontends live in their own repos: [scribbler](https://github.com/scarletindustries/scribbler) for WebAssembly and [arc](https://github.com/alii/arc) for JavaScript.

### try it

carder builds with gleam 1.18 on erlang/otp 29. there's a corpus of `.ir` programs under `test/carder/ir/corpus/`:

```shell
$ gleam run -- run test/carder/ir/corpus/add.ir add 3 5
8
```

that compiles `add.ir` all the way to a `.beam`, loads it and calls its `add` export with 3 and 5. `gleam run -- help` lists the other commands, which run or dump each stage of the pipeline on its own.

### writing a frontend

[`specs/FRONTEND-API.md`](specs/FRONTEND-API.md) is the interface. the short version is that you build a `carder/ir.Module` and call:

```gleam
pipeline.compile_ir(module, binding)            // -> loadable .beam bytes
pipeline.run_ir(module, binding, export, args)  // -> compile + run it
```

### contributing

help is welcome. the plan lives in the `specs/` folder, so message me on Discord (@hiett) first and we'll split the work so nothing overlaps.

### license

[Apache License 2.0](LICENSE). see [NOTICE](NOTICE) for attribution.
