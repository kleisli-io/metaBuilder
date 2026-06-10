# Evidence, Descriptors, And Runtime Structure

Build systems often treat metadata as something outside the build. metaBuilder
treats important metadata as part of the description, because a builder's meaning
is not exhausted by its store path.

## Evidence

Evidence gives checks and claims a place in the description. A smoke test, an
expected behavior, or an invariant can be represented as data that views surface.
Evidence does not replace tests. It gives the builder a typed place to say why a
produced artifact should be trusted.

## Descriptors

Descriptors carry structured facts about an artifact. Compiler identity, runtime
version, protocol, generated files, and artifact kind are facts a builder should
state directly rather than hide in path names or shell scripts. Because a
descriptor is part of the program's data, downstream tools and documentation can
read it without parsing conventions.

## Runtime Structure

Some artifacts are meant to run. Runtime services, protocols, capabilities, and
units describe that operational shape. These come from the runtime half of the
operation signature, so a builder declares its runtime structure with the same
program it uses to build.

The runtime declarations are kept structure, not forgotten bookkeeping. They
survive into the materialized result, which is why the same program can produce a
store artifact and a runtime description together.

## Why They Belong Together

Evidence, descriptors, and runtime declarations all answer questions about the
artifact beyond whether it built. They belong in the same descriptive model
because users need them to evaluate, compose, and operate builders.
