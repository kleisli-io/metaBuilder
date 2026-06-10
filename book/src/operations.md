# Operations

Operations are the steps of a build expressed as data. They keep the build
workflow visible to validation, dry-run, plan-view, self-documentation, and
materialization.

An operation states intent at the builder level. The materialized command is one
view of that intent, not the only meaning of the operation.

Operations come from a fixed signature with two families. Build-time operations
shape the derivation. Runtime operations describe how an artifact runs. A program
is a sequence drawn from both families, and every operation is one or the other.

## Build-Time Operations

The build-time family covers the work that produces a derivation.

- `readSource` names a file or tree the build consumes
- `resolveDependency` records a required package
- `declareTool` introduces a tool before it is used
- `runTool` runs a declared tool with arguments
- `writeFile` writes generated content
- `copyPath` copies a path into the build
- `transformOutput` declares an intended result shape
- `validateValue` checks a value during the build
- `emitDescriptor` attaches structured metadata
- `materializeDerivation` marks where the program becomes a derivation

## Reading Inputs

Use source operations to name files or trees the build consumes.

```nix
mb.operations.readSource {
  name = "schema";
  source = schemaInput;
}
```

The view layer can then report that the build uses `schema` instead of only
showing a later command line.

## Declaring And Running Tools

Declare a tool before running it, then connect a named step to it.

```nix
mb.operations.declareTool { tool = compiler; }

mb.operations.runTool {
  name = "compile";
  tool = compiler;
  args = [ "-c" "$out/generated.c" "-o" "$out/generated.o" ];
}
```

Dependency analysis can show the edge from the tool to the operation, and
plan-view can show the concrete command.

## Writing Files

Generated files should be explicit where possible.

```nix
mb.operations.writeFile {
  output = configHeader;
  text = "#define FEATURE 1\n";
}
```

This is useful for builders that generate metadata, config headers, manifests, or
service descriptors.

## Emitting Descriptors And Transforming Outputs

Descriptors attach structured metadata for downstream tools or documentation to
read without parsing shell scripts. Output transformations declare the intended
result shape, such as a tree, an archive, an ELF binary, JSON, text, or a header
directory.

## Runtime Operations

The runtime family describes how an artifact runs rather than how it is built.

- `declareCapability` records a lifecycle or query capability
- `declareProtocol` records a transport and serialization
- `declareService` records a service the artifact provides
- `materializeUnit` marks where the program produces a runtime unit

A builder that produces a service uses these alongside the build-time operations,
so one program describes both the store artifact and the way it should run.

## Materializing

Materialization operations mark where the program becomes a concrete result.
`materializeDerivation` produces a derivation, and `materializeUnit` produces a
runtime unit. They are the boundary between a described build and a build that
can be realized.
