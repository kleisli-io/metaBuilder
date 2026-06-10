{ api, lib, self, ... }:

let
  inherit (self) spec value;
in
api.mk {
  description = "IDL example: multi-language protobuf code generation via the IdlBuilder ornament and internalized program interpreters.";
  sourceFiles = [
    {
      name = "builder.nix";
      title = "IDL builder module";
      relativePath = "examples/idl/builder.nix";
      language = "nix";
      source = ./builder.nix;
      description = "Source for the built-in IDL ornament demo and its worked program.";
      role = ''
        This module constructs the `example-idl` spec with
        `mb.ornaments.idl.fromProtobuf`, then exposes the same interpreter
        views used by the tour page.
      '';
    }
    {
      name = "schema.proto";
      title = "schema.proto";
      relativePath = "examples/idl/schema.proto";
      language = "protobuf";
      source = ./schema.proto;
      description = "Small protobuf schema fixture consumed by the IDL demo.";
      role = ''
        This schema is the source artifact consumed by the IDL builder. The
        builder asks for C++ and Java generated views from the same input.
      '';
    }
  ];
  doc = ''
    # IDL Example

    This tour shows the built-in IDL ornament. It starts from a protobuf-style
    builder spec and asks for generated outputs in two languages. The example
    is smaller than the Node and C tours because the builder vocabulary already
    lives in `mb.ornaments.idl`; the useful part is seeing how that ornament
    still produces the same internalized program views.
  '';
  sections = [
    {
      title = "Start from the artifact";
      body = ''
        The IDL builder describes a generated artifact named
        `example-idl-generated`. The spec declares protobuf as the IDL format
        and asks for C++ and Java outputs. Materialization records both output
        trees in the build plan.
      '';
    }
    {
      title = "Builder vocabulary";
      body = ''
        `mb.ornaments.idl.fromProtobuf` is the public constructor. It produces
        an `IdlBuilder` value with IDL format, proto sources, language targets,
        generated outputs, and tool-backed operations.
      '';
      code = ''
        mb.ornaments.idl.fromProtobuf {
          name = "example-idl";
          protos = [ ./idl/schema.proto ];
          languages = [ "cpp" "java" ];
        }
      '';
    }
    {
      title = "Program walkthrough";
      body = ''
        The ornament lowers the IDL spec into a program that declares the
        protobuf tool, runs one generation step per language, and materializes
        the generated output tree. The same program can be validated, rendered
        as a dry-run, shown as a shell plan, documented, and materialized.
      '';
    }
    {
      title = "One build, many views";
      body = ''
        The section below is generated from `mb.program.introspect.run
        program`. It shows the same interpretation surface as the greenfield
        examples, but for a built-in ornament.

        ${value.selfView.markdown}
      '';
    }
  ];
  inherit value;
  tests = {
    "validation-ok" = {
      expr = value.validation.ok;
      expected = true;
    };
    "dry-run-count" = {
      expr = builtins.length value.dryRun.steps;
      expected = builtins.length spec.operations;
    };
    "dry-run-has-run-step" = {
      expr = lib.any (s: s.kind == "run") value.dryRun.steps;
      expected = true;
    };
    "languages-propagated" = {
      expr = spec.languages;
      expected = [ "cpp" "java" ];
    };
    "idl-format-propagated" = {
      expr = spec.idlFormat;
      expected = "protobuf";
    };
    "schema-non-empty" = {
      expr = (value.schemas.builderSpec.oneOf or [ ]) != [ ];
      expected = true;
    };
    "datatype-reference-has-runtime-op" = {
      expr = value.datatypes.runtimeOp.constructors != [ ];
      expected = true;
    };
    "self-docs-model-validates" = {
      expr = value.docs.model._con;
      expected = "MetaBuilderDocumentation";
    };
    "self-docs-markdown-includes-builder-name" = {
      expr = lib.hasInfix "example-idl-generated" value.docs.markdown;
      expected = true;
    };
    "materialize-plan-shape" = {
      expr =
        let
          plan = value.materialize.plan;
          stepCons = map (s: s._con) plan.steps;
        in
        {
          runStepCount = builtins.length (lib.filter (c: c == "runStep") stepCons);
          writeStepCount = builtins.length (lib.filter (c: c == "writeStep") stepCons);
          copyStepCount = builtins.length (lib.filter (c: c == "copyStep") stepCons);
          toolNames = map (t: t.name) plan.tools;
          outputCount = builtins.length plan.outputs;
          planName = plan.name;
        };
      expected = {
        runStepCount = 2;
        writeStepCount = 0;
        copyStepCount = 0;
        toolNames = [ "protoc" ];
        outputCount = 2;
        planName = "example-idl-generated";
      };
    };
    "materialize-plan-pathmap-includes-proto" = {
      expr =
        let plan = value.materialize.plan;
        in builtins.length (builtins.attrNames plan.pathMap) >= 1;
      expected = true;
    };
  };
}
