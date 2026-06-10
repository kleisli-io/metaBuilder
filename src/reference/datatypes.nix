{ mb, api, ... }:

let
  value = mb.descriptions.descriptors;
in
api.mk {
  description = "datatype reference: descriptors for builder, runtime, and ornament vocabulary.";
  doc = ''
    Exposes datatype descriptors used by the docs content generator and schema
    derivation. Rendered project documentation is produced by
    `mb.mkDocsContent`.
  '';
  inherit value;
  tests = {
    "builder-op-descriptor-non-empty" = {
      expr = value.op.constructors != [ ];
      expected = true;
    };
    "runtime-op-descriptor-non-empty" = {
      expr = value.runtimeOp.constructors != [ ];
      expected = true;
    };
    "service-descriptor-non-empty" = {
      expr = value.service.constructors != [ ];
      expected = true;
    };
    "builder-documentation-descriptor-non-empty" = {
      expr = value.builderDocumentation.constructors != [ ];
      expected = true;
    };
  };
}
