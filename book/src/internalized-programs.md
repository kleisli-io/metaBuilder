# Internalized Programs

An internalized program is a build workflow represented as a value. The value is
not a script and not a derivation. It is typed data that records the steps of a
build and the order they run in.

This is the object every view shares. Validation, dependency analysis, dry-run,
plan-view, documentation, introspection, and materialization are all readings of
the same program value.

## Operations As A Signature

A program is built from operations, and the operations are not an open-ended set
of arbitrary effects. They come from a fixed signature with two families.
Build-time operations read sources, declare tools, write files, run commands,
emit descriptors, and produce derivations. Runtime operations declare services,
protocols, capabilities, and units.

The signature is the sum of those two families. Every operation in a program is
either a build-time operation or a runtime operation and nothing else. Because
the alphabet is fixed and total, a view always knows the full set of cases it
must handle, and a builder can never smuggle in an effect the views do not
understand.

## Programs Are Free

The program is the free sequencing of operations over that signature. Free means
the program records only which operations occur and in what order. It does not
decide what they mean. Meaning is supplied later by a view.

This is why one program supports many readings. The program commits to the
build's structure and leaves interpretation open. A function would have collapsed
that structure into a single answer the moment it was called.

## Meaning By Interpretation

A view gives the program meaning by handling each operation. Validation handles
an operation by checking it. Dependency analysis handles it by recording what it
mentions. Materialization handles it by turning it into part of a derivation.

No view owns the program. Each one walks the same sequence of operations and
answers a different question. The final derivation is one such answer, not the
whole meaning of the builder.
