# Materialization Model

Materialization turns a builder program into an artifact. It is one
interpretation of the program, not the whole meaning of the builder.

The materialization view is useful because it keeps the executable plan visible
before and after a derivation exists.

## Plans

A plan is the materializable shape of the program. It records the steps that
write files, run tools, transform outputs, and produce final artifacts. Plans let
you inspect order and intent before asking Nix to build.

Materialization works by walking the program and building up a plan state as it
goes. The plan state carries working bookkeeping, such as which tools and
services have been declared so far, so that later steps can be checked against
earlier ones.

## From Plan State To Build Plan

When the walk finishes, the plan state is projected into the final build plan.
This projection forgets the working bookkeeping and keeps what the artifact
needs, which is the outputs, the derivation, and the runtime declarations the
builder promised. The bookkeeping existed only to validate the build as it was
assembled.

## Tool References

Tool references connect command steps to packages. This matters because a plan
should not rely on ambient commands from the user's shell. If a step runs `gcc`,
the program should know which package provides `gcc`.

## Generated Commands

Plan-view exposes command snippets so users can inspect what materialization will
execute. Use this view for debugging. The builder API should still be expressed
in domain terms rather than asking users to manage every command directly.

## Derivation Outputs

Materialization returns derivations and output declarations. The result should
match the outputs the builder promised earlier in the spec.

## Runtime Artifacts

When the program declares runtime services or units, materialization carries
those declarations alongside the derivation result. A builder can therefore
produce both a store artifact and a runtime description from the same program.
