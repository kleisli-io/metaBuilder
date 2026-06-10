# metaBuilder

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A typed builder DSL built on
[nix-effects](https://github.com/kleisli-io/nix-effects).

Full documentation lives at
[docs.kleisli.io/metaBuilder](https://docs.kleisli.io/metaBuilder):
manual, theory, worked examples, and generated API reference.

metaBuilder describes builders as typed values: parameters, sources,
dependencies, tools, outputs, evidence, validations, descriptors, and
operations are generated datatypes. The same typed spec builds an
internalized program for validation, dependency analysis, dry-run views,
plan views, builder self-documentation, and materialization.

Schemas and project documentation are derived from descriptions through the
nix-effects docs system.

Everything runs at `nix eval` time.

## Small example

Assuming `mb` and `pkgs` are in scope, one typed builder interpreted through
the internalized program package:

```nix
let
  schemaSource = mb.operations.localSource {
    name = "schema";
    path = ./schema.proto;
  };

  protoc = mb.operations.tool {
    name = "protoc";
    package = pkgs.protobuf;
  };

  idlBuilder = {
    _con = "MetaBuilderSpec";
    name = "example-idl";
    parameters = [ (mb.operations.parameter { name = "language"; value = "cpp"; }) ];
    inputs       = [ schemaSource ];
    dependencies = [];
    tools        = [ protoc ];
    operations = [
      (mb.operations.readSource  { name = "schema"; source = schemaSource; })
      (mb.operations.declareTool { tool = protoc; })
      (mb.operations.runTool {
        name = "generate-cpp";
        tool = protoc;
        args = [ "--cpp_out=$out/cpp" (toString schemaSource.path) ];
      })
      (mb.operations.materializeDerivation { name = "example-idl-generated"; })
    ];
    outputs  = [ (mb.operations.output { name = "cpp-sources"; path = "$out/cpp"; format = "tree"; }) ];
    evidence = [];
  };

  program = mb.program.fromSpec idlBuilder;
in {
  validation  = mb.program.validate.run     program;
  deps        = mb.program.deps.run         program;
  dryRun      = mb.program."dry-run".run    program;
  planView    = mb.program."plan-view".run  program;
  docs        = mb.program.describe.run     program;
  selfView    = mb.program.introspect.run   program;
  materialize = mb.program.materialize.run  program;
  schemas     = mb.reference.schemas;
}
```

`mb.program.describe` documents the operation-level builder program.
`mb.program.introspect` composes validation, dependency analysis, dry-run,
plan-view, self-documentation, and materialization into a markdown-safe
"one build, many views" self-view. Project API docs for metaBuilder itself
are generated with `mb.mkDocsContent pkgs`.

## Examples

`mb.examples` contains worked builders with source fixtures, tests,
self-documentation, dry-run plans, and materialized derivations:

- `mb.examples.node-service` defines a Node service builder that emits package
  metadata, a runnable wrapper, an HTTP service descriptor, and a runtime unit.
- `mb.examples.c-codegen` defines a C codegen builder that generates headers
  and sources, builds a static library, links a CLI, and smoke-tests it.
- `mb.examples.idl` demonstrates protobuf IDL generation through the built-in
  IDL ornament.

## Quick start

As a flake input:

```nix
{
  inputs.metaBuilder.url = "github:kleisli-io/metaBuilder";
  # mb = metaBuilder.lib.mkMb pkgs
}
```

From a checkout:

```nix
let
  pkgs = (import ./locked.nix "nixpkgs") { };
  fx   = (import ./locked.nix "nix-effects") { inherit pkgs; lib = pkgs.lib; };
  mb   = import ./. { inherit pkgs fx; lib = pkgs.lib; };
in mb.tests.summary
```

Both `pkgs` and `fx` are required arguments.

## Development

```bash
nix-shell           # nix-unit and just
just test           # run the test suite
just test loader    # run a specific suite
```

Or via flake:

```bash
nix build .#checks.x86_64-linux.default
```

Kernel-heavy checks (long normalizations, minutes to hours) live in a
separate suite excluded from `tests` and `checks`:

```bash
nix-unit --flake .#tests-heavy
```

## License

MIT. See [LICENSE](LICENSE).
