# Introduction

Nix builders are often ordinary functions that return derivations. That is a
useful interface for building, but it hides much of the builder's structure.
Which inputs matter, which tools are required, which steps run, what outputs are
promised, and what runtime shape the artifact has are all left implicit.

metaBuilder makes that structure explicit. A builder is written as typed data,
the data is read as a program, and the program can be interpreted several ways.
That is the central idea. One build, many views.

## What A Builder Describes

A metaBuilder builder describes the parts a build author usually cares about.

- parameters that configure the build
- source inputs
- dependency requirements
- tools used by build steps
- operations that define the build workflow
- declared outputs
- evidence about checks or expected behavior
- descriptors for artifacts and runtime surfaces

Those pieces are written once and reused by the views that validate, explain,
debug, and materialize the build.

## One Program Over Fixed Operations

The operations are the heart of the builder. They are drawn from a fixed
signature with two families. Build-time operations cover reading sources,
declaring and running tools, writing files, emitting descriptors, and producing
derivations. Runtime operations cover declaring services, protocols,
capabilities, and units. Every builder, however domain-specific, produces a
program over those same operations, which is why one set of views can interpret
all of them.

## Why This Is Different From A Function

A function answers one question. Given these arguments, what value is returned.

A metaBuilder program answers several questions at once.

- Is the build shape valid?
- Which tools and dependencies does it require?
- What would it do without building anything?
- What plan would materialization execute?
- How does the builder describe itself?
- What artifact or runtime declaration is produced?

The build result still matters. metaBuilder adds the surrounding structure that
makes the builder easier to inspect and evolve.

## Where Examples Fit

The examples are complete tours of concrete builders.

- [Node service example](/metaBuilder/examples/node-service)
- [C code generation example](/metaBuilder/examples/c-codegen)
- [IDL example](/metaBuilder/examples/idl)

Read the manual for the model. Read the examples to see the model applied to
complete artifacts.
