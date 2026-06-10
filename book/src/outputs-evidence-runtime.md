# Outputs, Evidence, And Runtime Artifacts

Builders need to communicate more than the fact that a derivation exists. A user
often needs to know what the artifact contains, how it was checked, and how it
should run. metaBuilder gives those concerns explicit places in the build
description.

## Outputs

Outputs name the results a build promises. A generated source tree, a static
library, a CLI binary, a JSON manifest, package metadata, or a service tree are
typical examples. An output should have a name, a path, and a format, which lets
views explain what the build returns without executing it.

## Descriptors

Descriptors are structured metadata. Use them when a builder wants to report
facts about the artifact, such as compiler identity, runtime version, protocol,
generated files, package manager, or artifact kind. Descriptors are better than
conventions hidden in filenames because they are part of the program's data.

## Evidence

Evidence records checks or claims about the artifact. A syntax-check command, a
smoke-test expectation, a generated-artifact invariant, or a compatibility
assertion can each be recorded as evidence. Evidence does not replace tests. It
gives the builder a typed place to report why a produced artifact should be
trusted.

## Runtime Artifacts

Some builders produce things that run as services. For those builders the runtime
shape should be explicit, and it is expressed with the runtime operations for
services, protocols, lifecycle capabilities, and runtime units. These runtime
declarations are kept structure. They survive into the materialized result, so
the same builder describes both build-time and runtime behavior and returns both
from one program.
