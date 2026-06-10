# Builder Specs

A builder spec is the public shape of a build. It gathers the pieces a builder
author wants to make explicit before materialization happens.

The base shape is `MetaBuilderSpec`. Every spec is a typed value, and the `_con`
field names which description constructor the value inhabits. A spec is checked
against its description before it becomes a program, so a missing or wrong-shaped
field is reported up front.

```nix
{
  _con = "MetaBuilderSpec";
  name = "example";
  parameters = [ ];
  inputs = [ ];
  dependencies = [ ];
  tools = [ ];
  operations = [ ];
  outputs = [ ];
  evidence = [ ];
}
```

The fields are populated with smart constructors from `mb.operations`. A smart
constructor builds a well-typed value for a field, so you rarely write raw
records by hand beyond the top-level spec.

## Name

The `name` identifies the build in views and materialized artifacts. Choose a
name that describes the artifact rather than the implementation technique.

## Parameters

Parameters are the configuration surface. They should represent choices the
builder user can understand, such as language target, runtime version, feature
flags, artifact kind, or service port.

## Inputs

Inputs are source values the build consumes. Naming inputs makes dry-run,
dependency, and plan views understandable, because the build is no longer a black
box around anonymous paths.

## Dependencies

Dependencies describe package requirements that are part of the build design.
They give dependency views a place to report what the builder needs.

## Tools

Tools describe commands used by operations. A tool is more than a string name. It
connects a build step to the package that provides it, so a plan never relies on
a command from the user's ambient shell.

## Operations

Operations are the workflow. They are the build-time and runtime steps the
builder performs, and they are the field the program is sequenced from. Reading
inputs, declaring tools, generating files, running commands, emitting
descriptors, declaring outputs, declaring runtime structure, and materializing
artifacts all appear here as operation values.

## Outputs

Outputs are promises about what the build produces. A named output can be shown
in documentation, checked in plans, and returned from materialization.

## Evidence

Evidence records checks or expected behavior. It is useful when a builder wants
to say why an artifact should be trusted, not only how it is built.
