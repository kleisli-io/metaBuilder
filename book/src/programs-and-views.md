# Programs And Views

A builder spec becomes a program. The program is the reusable value that
different views interpret.

Common entry points are the following.

```nix
mb.program.fromSpec spec
mb.program.fromOrnamentedSpec builderType spec
mb.program.sequence operations
```

Use `fromSpec` when you already have a base builder spec. Use
`fromOrnamentedSpec` when a domain builder extends the base shape. Use `sequence`
when the program is already expressed as operations.

Each view below is a reading of the same `program`. None of them rebuilds it.

## Validation

Validation answers whether the program is structurally acceptable. It returns a
record with an `ok` flag and a list of `diagnostics`.

```nix
mb.program.validate.run program
```

Use it before relying on any other view.

## Dependency Graph

Dependency analysis answers which tools, dependencies, services, and operations
are involved. It returns a graph of `nodes` and `edges`.

```nix
mb.program.deps.run program
```

This view is useful when a builder grows and you need to see whether it still
says what it depends on.

## Dry-Run

Dry-run answers what would happen without materializing the artifact. It returns
the ordered `steps` of the workflow.

```nix
mb.program."dry-run".run program
```

Use it as a fast explanation of the builder's workflow.

## Plan View

Plan-view answers what materialization would execute. It returns the typed plan
steps and the rendered commands.

```nix
mb.program."plan-view".run program
```

Use it when you need to inspect command order, generated file writes, and the
shape of the materialization plan.

## Describe

Describe answers how the builder program documents itself. It returns a rendered,
operation-level explanation of the builder.

```nix
mb.program.describe.run program
```

## Introspect

Introspect composes the main views into one self-view, so a single call returns
validation, dependencies, dry-run, plan, documentation, and materialization
together.

```nix
mb.program.introspect.run program
```

Use it when you want the complete one build, many views report.

## Materialize

Materialization returns the build artifact. The result carries the `derivation`
along with the declared outputs and any runtime declarations.

```nix
mb.program.materialize.run program
```

Use materialization only after the views show the build says what you intend.
