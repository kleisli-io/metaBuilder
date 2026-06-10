{ api, lib, self, ... }:

let
  value = self.value;
in
api.mk {
  title = "C code generation example";
  description = "Guided C codegen builder tour: schema input, generated C sources, static library, CLI, descriptors, dependency graph, and materialization plan.";
  sourceFiles = [
    {
      name = "builder.nix";
      title = "C codegen builder module";
      relativePath = "examples/c-codegen/builder.nix";
      language = "nix";
      source = ./builder.nix;
      description = "Source for the C codegen builder constructor and worked native demo program.";
      role = ''
        This module defines the `CCodegenBuilder` ornament, the `cCodegen`
        constructor, the concrete `messages-demo` spec, and the exported views
        used by the tour page.
      '';
    }
    {
      name = "messages.def";
      title = "messages.def";
      relativePath = "examples/c-codegen/messages.def";
      language = "text";
      source = ./messages.def;
      description = "Schema fixture consumed by the C code generator in the native demo.";
      role = ''
        This schema is the generator input. The build plan reads each
        `key:value` row and emits declarations plus C functions returning the
        configured text.
      '';
    }
    {
      name = "main.c";
      title = "main.c";
      relativePath = "examples/c-codegen/main.c";
      language = "c";
      source = ./main.c;
      description = "Small CLI source linked against the generated static library.";
      role = ''
        This hand-written CLI proves the generated header and static library
        can be consumed by ordinary C code.
      '';
    }
  ];
  doc = ''
    # C Code Generation Example

    This tour builds a small native artifact from a message schema. The
    example is intentionally compact: one schema file, one hand-written
    `main.c`, generated C sources, a static library, and a CLI that proves the
    generated library links and runs.

    The point is to show how a native builder can expose generated files,
    toolchain steps, descriptors, outputs, and the materialization plan as
    views of one typed program.
  '';
  sections = [
    {
      title = "Start from the artifact";
      body = ''
        The source fixture is `c-codegen/messages.def`, a tiny key/value
        schema. The builder generates:

        - `include/config.h` from typed configuration defines.
        - `include/generated_messages.h` and `generated/generated_messages.c`
          from the schema.
        - `lib/libmessages-demo.a` from the generated object.
        - `bin/messages-demo`, linked against the generated library.
        - `lib/pkgconfig/messages-demo.pc` as metadata for downstream users.
      '';
    }
    {
      title = "Builder vocabulary";
      body = ''
        `CCodegenBuilder` ornaments `BuilderSpec` with the native-builder
        fields that matter here: compiler identity, schema input, config
        defines, and artifact kind. The public constructor keeps the domain
        surface focused on the source inputs and leaves the internal program
        to spell out the build mechanics.
      '';
      code = ''
        cCodegen {
          name = "messages-demo";
          schema = ./c-codegen/messages.def;
          main = ./c-codegen/main.c;
        }
      '';
    }
    {
      title = "Program walkthrough";
      body = ''
        The constructor lowers the spec into a sequence of operations:
        read the schema and `main.c`, declare `bash`, `gcc`, and `ar`, write
        the config header, generate C sources, compile the generated source,
        archive the static library, link the demo CLI, run a smoke test, emit
        pkg-config metadata, and declare each output.

        Because those steps are data, metaBuilder can interpret them without
        rebuilding the builder by hand. Dependency analysis sees the tool-use
        edges, dry-run shows the build actions, plan-view exposes the shell
        plan, and materialization turns the same plan into a derivation.
      '';
    }
    {
      title = "One build, many views";
      body = ''
        The section below is generated from `mb.program.introspect.run
        program`. It is the internalized view of the native build: validation,
        dependency graph, dry-run, plan-view, descriptors, outputs, and
        materialization.

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
    "schema-derived" = {
      expr = (value.builder.schema.oneOf or [ ]) != [ ];
      expected = true;
    };
    "dry-run-has-five-run-steps" = {
      expr =
        builtins.length (lib.filter (s: s.kind == "run") value.dryRun.steps);
      expected = 5;
    };
    "docs-mention-static-library" = {
      expr = lib.hasInfix "static-library" value.docs.markdown;
      expected = true;
    };
    "self-view-showcases-many-views" = {
      expr = {
        validationOk = value.selfView.validation.ok;
        hasDryRun = value.selfView.dryRun.stepCount > 0;
        hasPlan = value.selfView.plan.stepCount > 0;
        hasSelfDocs = value.selfView.documentation.operationCount > 0;
        outputCount = value.selfView.materialization.outputCount;
        markdownNamesThesis = lib.hasInfix "same internalized program" value.selfView.markdown;
      };
      expected = {
        validationOk = true;
        hasDryRun = true;
        hasPlan = true;
        hasSelfDocs = true;
        outputCount = 4;
        markdownNamesThesis = true;
      };
    };
    "materialize-plan-shape" = {
      expr =
        let plan = value.materialize.plan;
        in {
          inherit (plan) name;
          runStepCount = builtins.length (lib.filter (s: s._con == "runStep") plan.steps);
          writeStepCount = builtins.length (lib.filter (s: s._con == "writeStep") plan.steps);
          outputCount = builtins.length plan.outputs;
          toolNames = map (t: t.name) plan.tools;
        };
      expected = {
        name = "messages-demo-artifact";
        runStepCount = 5;
        writeStepCount = 2;
        outputCount = 4;
        toolNames = [ "bash" "gcc" "ar" ];
      };
    };
    "materialize-plan-registers-local-inputs" = {
      expr =
        builtins.length (builtins.attrNames value.materialize.plan.pathMap);
      expected = 2;
    };
    "materialize-shell-script-shape" = {
      expr =
        let script = value.materializeShell;
        in {
          standalone = lib.hasPrefix "#!/usr/bin/env bash\n" script;
          guardsGcc = lib.hasInfix "command -v gcc" script;
          guardsAr = lib.hasInfix "command -v ar" script;
          exportsInputs = lib.hasInfix "export pathMap_" script;
          linksCli = lib.hasInfix ''"$out"/bin/messages-demo'' script;
        };
      expected = {
        standalone = true;
        guardsGcc = true;
        guardsAr = true;
        exportsInputs = true;
        linksCli = true;
      };
    };
    "materialize-dockerfile-shape" = {
      expr =
        let dockerfile = value.materializeDockerfile;
        in {
          parameterizedBase = lib.hasInfix "FROM \${base}" dockerfile;
          copiesSchema = lib.hasInfix "COPY messages.def /inputs/messages.def" dockerfile;
          copiesMain = lib.hasInfix "COPY main.c /inputs/main.c" dockerfile;
          guardsGcc = lib.hasInfix "RUN command -v gcc" dockerfile;
        };
      expected = {
        parameterizedBase = true;
        copiesSchema = true;
        copiesMain = true;
        guardsGcc = true;
      };
    };
    "plan-export-round-trip" = {
      expr =
        # fromJSON requires a context-free string; the export keeps the
        # context of the tool paths it names.
        let decoded = builtins.fromJSON
          (builtins.unsafeDiscardStringContext value.planExport);
        in {
          runStepNames = map (s: s.name)
            (lib.filter (s: s._con == "runStep") decoded.steps);
          toolNames = map (t: t.name) decoded.tools;
          packageFree =
            !builtins.any (t: t ? package) decoded.tools
            && !builtins.any (s: s ? package) decoded.declaredServices;
        };
      expected = {
        runStepNames = [
          "generate-c-sources"
          "compile-generated-object"
          "archive-library"
          "link-demo-cli"
          "smoke-test"
        ];
        toolNames = [ "bash" "gcc" "ar" ];
        packageFree = true;
      };
    };
  };
}
