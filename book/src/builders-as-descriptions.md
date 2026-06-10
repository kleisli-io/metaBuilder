# Builders As Descriptions

The central move in metaBuilder is to treat a builder as a description before it
is treated as an executable artifact.

A description is typed data. Parameters, sources, dependencies, tools,
operations, outputs, evidence, and runtime declarations are all generated
datatypes with named constructors and fields. A builder spec is an inhabitant of
the base description type, and it is checked against that type before anything is
built. A spec that is missing a required field or carries the wrong shape is
rejected at description time, not at build time.

Because the builder is data, its parts are available to inspect and reinterpret.
A description says which parts exist and how they relate without committing to
the single thing that could be done with them. That separation is what makes
multiple views possible.

## Functions And Descriptions

A function gives an answer when it is called. It can hide everything that
happened on the way to the answer.

A description can be read before any answer is produced. It can be checked,
summarized, documented, or interpreted into a build. The description is not less
precise than a function. It is precise in a form that supports more than one use.

## Typed All The Way Down

The types are not decoration. They are the same descriptions the views read and
the same descriptions the documentation and schemas are generated from. A field
added to a description becomes visible to validation, to dependency analysis, to
the rendered docs, and to materialization at once, because all of them read the
one typed source.

## Structure Before Execution

When a builder is described structurally, its components become available to
generic interpretations. Validation inspects the shape. Dependency analysis
inspects tools and operations. Dry-run summarizes intent. Plan-view renders an
executable plan. Materialization produces the artifact.

The build still happens. metaBuilder adds the structure around it that makes the
builder inspectable before it runs.
