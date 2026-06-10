# Ornaments And Domain Surfaces

An ornament enriches a base description with domain-specific structure.

For metaBuilder the base description is the shared builder shape. A domain
builder adds fields for its own vocabulary while keeping the ability to become an
ordinary builder program. A service ornament can add a runtime, a port, and a
health path. A code-generator ornament can add a compiler identity, a set of
defines, and a generated artifact kind.

## Refining Data, Not Operations

An ornament refines the data of a description. It does not change the operation
alphabet. The shared signature of build-time and runtime operations stays fixed
for every builder, ornamented or not. A domain builder still produces a program
over the same operations, so every view that understands the base program
understands the ornamented one without modification.

This is the discipline that keeps domains from fragmenting the model. New
vocabulary enters as new fields, and those fields are lowered into the shared
operations by the builder's constructor. The operation alphabet is never extended
per domain.

## Preserving The Base Shape

The enriched builder still carries the shared pieces. Those pieces are inputs,
tools, operations, outputs, and evidence. The common views know how to read
exactly those pieces, which is why they keep working across domains.

## Adding Domain Meaning

The added fields should be meaningful in the domain. Service protocol, health
path, compiler identity, generated artifact kind, and language target are good
examples. They let a builder author speak in domain terms without giving up the
shared program model.

## Surface And Forgetting

The domain surface is what users write. The shared builder shape is what the
views understand.

Moving between them is a real, typed map called forgetting. It projects an
ornamented builder onto the shared shape by dropping the domain-only fields and
keeping the shared pieces. Those shared pieces are inputs, tools, operations,
outputs, and evidence. Because the operations live in the shared shape,
forgetting preserves them. The program you get from a forgotten spec is the same
program the ornamented spec describes. Nothing the build needs is lost by
speaking in domain terms.

This forget map is checked, not informal. The projection is certified to land in
the base builder type, so an ornamented builder always forgets to a genuine
shared builder.

Forgetting recurs later in the pipeline. Materialization carries a working plan
state with derived bookkeeping, and the final build plan forgets that bookkeeping
while keeping only the outputs and runtime declarations the builder promised.
Each stage forgets exactly what the next stage does not need.
