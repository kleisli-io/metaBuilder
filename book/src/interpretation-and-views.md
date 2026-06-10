# Interpretation And Views

A view is an interpretation of a program. The program is a sequence of operations
and says nothing about their meaning on its own. A view supplies the meaning by
handling each operation as the sequence is walked.

Because every view reads the same program over the same fixed operation alphabet,
the views agree by construction. They differ only in how each operation is
handled, not in which operations exist.

## Validation

Validation interprets the program as a shape to check. It walks the operations
and collects diagnostics, then reports whether the program is acceptable before
any artifact is produced. An empty diagnostic list means the build shape is
clean.

## Dependency Graph

Dependency analysis interprets the program as a graph of requirements and uses.
It records nodes for tools, dependencies, services, and operations, and edges for
how they relate, so a grown builder can be checked against what it claims to
need.

## Dry-Run

Dry-run interprets the program as a user-facing summary. It turns each operation
into a short statement of intent and produces the ordered list of steps the build
would take, without performing them.

## Plan-View

Plan-view interprets the program as an executable plan. It builds the same typed
plan that materialization uses and renders the concrete commands and file writes,
so command order and shape can be inspected before Nix is asked to build.

## Documentation

Documentation interprets the program as an explanation. It reads the operations
and the declared outputs and renders a description of how the build presents
itself to a user.

## Materialization

Materialization interprets the program as an artifact-producing plan. It handles
build-time operations into a derivation and runtime operations into runtime
declarations, returning the derivation together with the outputs and runtime
descriptions the builder promised.

## One Program, Many Answers

The views are different, and their agreement comes from sharing one program. The
final derivation is one interpretation among several. A builder that reads well
under validation, dependency analysis, dry-run, and documentation is a builder
whose meaning is understood before it is built.
