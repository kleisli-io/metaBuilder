# Changelog

All notable changes to metaBuilder are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Headline changes

#### Typed prototype on top of nix-effects

- **Description-backed builder language.** `BuilderSpec`, `BuilderOp`, and the
  domain datatypes for parameters, sources, dependencies, tools, outputs,
  evidence, validations, and descriptors are generated through
  `nix-effects` HOAS datatypes. Program interpreters and reference artifacts
  share the same typed payloads.
- **Direct source loader.** Source-tree traversal loads plain namespaces,
  split modules, recursive sub-namespaces, and `.skip-subtree` exclusions
  without a legacy string-tag effect layer.
- **Loader regression coverage.** Filesystem fixtures exercise the loader
  for plain-namespace shape, split-module scope and test merging,
  subdirectory composition, duplicate bindings, duplicate test names,
  subdir/scope collisions, and `.skip-subtree` empty-namespace behavior.
- **Internalized builder program.** Smart constructors build typed operation
  records; `mb.program` injects them into the closed desc-interp
  `BuilderOp + RuntimeOp` signature and runs execution interpretations
  through typed dispatch packages.
- **Builder self-documentation.** `mb.program.describe` interprets a builder's
  own operation program into a typed documentation model and markdown view.

### Added

- Generated `ParameterSpec`, `SourceSpec`, `DependencySpec`, `ToolSpec`,
  `OutputSpec`, `EvidenceSpec`, `ValidationSpec`, `DescriptorSpec`,
  `BuilderOp`, and `BuilderSpec` datatypes with derived descriptors and
  schemas.
- Program interpreters: `validate`, `deps`, `dry-run`, `plan-view`,
  `describe`, and `materialize` over typed operation programs.
- Reference artifacts: generated schemas and datatype markdown rendered
  through the nix-effects docs system.
- Code-gen and IDL ornaments refining the base builder spec.
- End-to-end IDL builder example running program interpreters against one
  typed builder spec.
- Loader test suite with filesystem fixtures.
- Standalone scaffold: `flake.nix`, `flake.lock`, `locked.nix`,
  `shell.nix`, `Justfile`, `tests.nix`, `internal.nix`, and
  `version.sexp`.

### Notes

- `pkgs` and `fx` have no defaults in the public surface; callers must
  pass them explicitly so the public interface does not assume a
  particular nix-effects or nixpkgs source.
- The loader honors `.skip-subtree` by returning an empty namespace for
  the marked directory.
