{ mb, fx, api, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;

  # ProjectBuilder is the super-base for project-level refinements
  # (implementations, vendoring, testing). It inserts a single `langName`
  # field that downstream project ornaments use as the language identifier
  # for per-impl selection, vendoring contracts, and test-suite naming.
  ProjectBuilder = H.ornament mb.descriptions.BuilderSpec {
    name = "MetaBuilderProject";
    constructors.MetaBuilderSpec.fields = [
      { insert = "langName"; type = H.string; }
      { keep = "name"; }
      { keep = "parameters"; }
      { keep = "inputs"; }
      { keep = "dependencies"; }
      { keep = "tools"; }
      { keep = "operations"; }
      { keep = "outputs"; }
      { keep = "evidence"; }
    ];
  };

  value = {
    inherit ProjectBuilder;
    descriptor = G.derive.deriveDescriptor ProjectBuilder;
    schema = G.derive.deriveSchema ProjectBuilder;
  };

in
api.mk {
  description = "ProjectBuilder ornament over BuilderSpec: super-base for project-level refinements (implementations, vendoring, testing). Inserts `langName` as the project's language identifier.";
  doc = ''
    # ProjectBuilder

    `ProjectBuilder` ornaments `BuilderSpec` with a single `langName`
    field, marking a spec as belonging to a language-specific project.
    Downstream ornaments (`implementations`, `vendoring`, `testing`)
    refine `ProjectBuilder` further; `dependencies` ornaments
    `BuilderSpec` directly since it is language-agnostic.
  '';
  inherit value;
  tests = {
    "descriptor-constructor-is-MetaBuilderSpec" = {
      expr = (builtins.head value.descriptor.constructors).name;
      expected = "MetaBuilderSpec";
    };

    "descriptor-has-langName-field" = {
      expr =
        let
          ctor = builtins.head value.descriptor.constructors;
          fieldNames = map (f: f.name) ctor.fields;
        in
        builtins.elem "langName" fieldNames;
      expected = true;
    };

    "schema-non-empty" = {
      expr = (value.schema.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
