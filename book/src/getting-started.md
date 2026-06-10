# Getting Started

This chapter shows the smallest useful shape. Define a builder spec, turn it into
a program, and ask the program for several views.

## Getting metaBuilder

As a flake input:

```nix
{
  inputs.metaBuilder.url = "github:kleisli-io/metaBuilder";

  outputs = { nixpkgs, metaBuilder, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      mb = metaBuilder.lib.mkMb pkgs;
    in {
      # use mb here
    };
}
```

`mkMb` builds the library against your `pkgs` and supplies the
nix-effects library from the flake's own input. Pin your own
nix-effects with `inputs.metaBuilder.inputs.nix-effects.follows`.

Without flakes, import the source tree with explicit arguments:

```nix
let
  fx = import nix-effects-src { inherit pkgs; lib = pkgs.lib; };
  mb = import metaBuilder-src { inherit pkgs fx; lib = pkgs.lib; };
in ...
```

The rest of this chapter assumes `mb` and `pkgs` are in scope.

```nix
let
  schema = mb.operations.localSource {
    name = "schema.proto";
    path = ./schema.proto;
  };

  protoc = mb.operations.tool {
    name = "protoc";
    package = pkgs.protobuf;
  };

  output = mb.operations.output {
    name = "cpp";
    path = "$out/cpp";
    format = "tree";
  };

  spec = {
    _con = "MetaBuilderSpec";
    name = "example-idl";
    parameters = [ ];
    inputs = [ schema ];
    dependencies = [ ];
    tools = [ protoc ];
    operations = [
      (mb.operations.readSource {
        name = "schema.proto";
        source = schema;
      })
      (mb.operations.declareTool { tool = protoc; })
      (mb.operations.runTool {
        name = "generate-cpp";
        tool = protoc;
        args = [ "--cpp_out=$out/cpp" (toString schema.path) ];
      })
      (mb.operations.transformOutput { inherit output; })
      (mb.operations.materializeDerivation {
        name = "example-idl-generated";
      })
    ];
    outputs = [ output ];
    evidence = [ ];
  };

  program = mb.program.fromSpec spec;
in {
  validation = mb.program.validate.run program;
  dryRun = mb.program."dry-run".run program;
  planView = mb.program."plan-view".run program;
  selfView = mb.program.introspect.run program;
  materialize = mb.program.materialize.run program;
}
```

The same `program` is reused by every view. You do not write one builder for
validation, another for documentation, and another for materialization. You
write the spec once and choose the view that answers the current question.

## First Checks

Start with validation. It returns a record with an `ok` flag and a list of
`diagnostics`, and an empty list means the shape is clean.

```nix
(mb.program.validate.run program).ok
```

Use dry-run when you want to understand the build without producing an artifact.
It returns the ordered `steps` the build would take.

```nix
(mb.program."dry-run".run program).steps
```

Use plan-view to inspect the concrete commands and file writes materialization
will perform.

```nix
(mb.program."plan-view".run program).steps
```

Use materialization when you want the derivation. It returns the derivation
together with the declared outputs.

```nix
(mb.program.materialize.run program).derivation
```

Use introspect to get every view at once as a single self-report.

```nix
mb.program.introspect.run program
```

The important habit is to treat the program as the stable object and choose the
view that answers the current question.
