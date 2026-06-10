{ mb, api, lib, ... }:

let
  value = {
    builderSpec = mb.descriptions.schemas.spec;
    builderOp = mb.descriptions.schemas.op;
    builderDocumentation = mb.descriptions.schemas.builderDocumentation;
    runtime = {
      capabilitySchema = mb.descriptions.schemas.capabilitySchema;
      capabilityCategory = mb.descriptions.schemas.capabilityCategory;
      capabilitySet = mb.descriptions.schemas.capabilitySet;
      protocol = mb.descriptions.schemas.protocol;
      service = mb.descriptions.schemas.service;
      param = mb.descriptions.schemas.param;
      runtimeType = mb.descriptions.schemas.runtimeType;
      transport = mb.descriptions.schemas.transport;
      serialization = mb.descriptions.schemas.serialization;
      runtimeOp = mb.descriptions.schemas.runtimeOp;
    };
  };

  tests = {
    "builder-schema" = {
      expr = (value.builderSpec.oneOf or [ ]) != [ ];
      expected = true;
    };
    "runtime-service-schema-non-empty" = {
      expr = (value.runtime.service.oneOf or [ ]) != [ ];
      expected = true;
    };
    "builder-documentation-schema-non-empty" = {
      expr = (value.builderDocumentation.oneOf or [ ]) != [ ];
      expected = true;
    };
    "runtime-op-schema-non-empty" = {
      expr = (value.runtime.runtimeOp.oneOf or [ ]) != [ ];
      expected = true;
    };
    "runtime-transport-schema-non-empty" = {
      expr = (value.runtime.transport.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
in
api.mk {
  description = "schema reference: JSON-schema artifacts derived from metaBuilder descriptions.";
  doc = ''
    Exposes generated schemas for builder and runtime datatypes without
    interpreting a program.
  '';
  inherit value tests;
}
