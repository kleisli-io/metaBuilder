# Authoring Production Builders

Production builders should grow from a small domain surface into a reliable
program, not from a large compatibility wrapper. Start with the artifact, name the
domain concepts, then expose the standard views that make the builder
inspectable.

## Begin With The Smallest Useful Constructor

A first constructor should accept only the choices needed to produce the artifact.
More options can be added when the builder has a real domain reason for them.

## Add Typed Configuration Deliberately

Typed configuration is valuable when it clarifies the build vocabulary. Avoid
adding fields only because an underlying command happens to have many flags. A
field earns its place when a view becomes more meaningful for having it.

## Prefer Descriptors Over Hidden Conventions

If downstream users need to know something, put it in a descriptor. Do not make
them infer important facts from path names or shell snippets.

## Keep Views In The Contract

Validation, dependency graph, dry-run, plan-view, describe, introspect, and
materialize are not only development helpers. They are part of how users learn and
trust the builder, so treat their output as a public contract.

## Test The Views That Matter

Tests should pin the views that define the builder's public contract. Useful
anchors are that validation succeeds for supported specs, that the dependency
graph includes the expected tools and operations, that dry-run explains the
intended workflow, that plan-view includes the expected materialization shape, and
that materialization produces the promised outputs.

## Avoid Compatibility Before Release

Do not add compatibility shims before there is a public compatibility problem.
Early builders should be shaped around the model you want users to learn.
