{ api, lib, self, ... }:

let
  value = self.value;
in
api.mk {
  title = "Node service example";
  description = "Guided Node service builder tour: runnable package, HTTP service descriptor, runtime unit, dependency graph, and materialization plan.";
  sourceFiles = [
    {
      name = "builder.nix";
      title = "Node service builder module";
      relativePath = "examples/node-service/builder.nix";
      language = "nix";
      source = ./builder.nix;
      description = "Source for the Node service builder constructor and worked demo program.";
      role = ''
        This module defines the `NodeServiceBuilder` ornament, the
        `nodeService` constructor, the concrete `node-service-demo` spec, and
        the exported views used by the tour page.
      '';
    }
    {
      name = "server.js";
      title = "server.js";
      relativePath = "examples/node-service/server.js";
      language = "javascript";
      source = ./server.js;
      description = "HTTP service fixture copied into the materialized Node demo package.";
      role = ''
        This is the full service source consumed by the builder. The
        materialization plan copies it into the package tree and wraps it with
        a generated executable.
      '';
    }
  ];
  doc = ''
    # Node Service Example

    This tour builds a tiny HTTP service from `server.js`. The point is not
    to mimic a full Node packaging API; it is to show how a builder can name
    its domain concepts and then expose several views of the same build.

    The worked artifact is a runnable package with a copied service source,
    generated package metadata, a wrapper script, an HTTP service descriptor,
    a runtime unit declaration, and a materialization plan.
  '';
  sections = [
    {
      title = "Start from the artifact";
      body = ''
        The source fixture is one file: `node-service/server.js`. The builder
        turns that file into a runnable tree:

        - `bin/node-service-demo` starts the service with Node.
        - `lib/node-service-demo/server.js` contains the copied source.
        - `share/node-service-demo/package.json` is generated from the typed
          builder spec.
        - the runtime view describes the service as HTTP on port 3000 with a
          `/health` endpoint.
      '';
    }
    {
      title = "Builder vocabulary";
      body = ''
        `NodeServiceBuilder` ornaments the generic `BuilderSpec` with the
        fields a service builder cares about: runtime version, entrypoint,
        package manager, script table, test command, service descriptor, and
        runtime operations. The constructor keeps the public surface small.
      '';
      code = ''
        nodeService {
          name = "node-service-demo";
          source = ./node-service/server.js;
        }
      '';
    }
    {
      title = "Program walkthrough";
      body = ''
        The constructor lowers the service spec into an internalized program.
        The builder-facing operations read the source, declare `node` and
        `bash`, generate `package.json`, run a syntax check, install the
        runnable tree, emit metadata, and declare the materialized outputs.

        The runtime operations are part of the same program. They declare the
        lifecycle capability set, the HTTP protocol, the concrete service, and
        the runtime unit. That is why dependency analysis, dry-run output,
        plan-view output, and self-documentation all see the service shape.
      '';
    }
    {
      title = "One build, many views";
      body = ''
        The section below is generated from `mb.program.introspect.run
        program`. It is not a hand-written summary. It validates the program,
        extracts the dependency graph, renders dry-run and plan-view output,
        includes service descriptors, and reports the materialized outputs.

        ${value.selfView.markdown}
      '';
    }
  ];
  inherit value;
  tests = {
    "spec-type-valid" = {
      expr = value.specValidation;
      expected = [ ];
    };
    "validation-ok" = {
      expr = value.validation.ok;
      expected = true;
    };
    "schema-derived" = {
      expr = (value.builder.schema.oneOf or [ ]) != [ ];
      expected = true;
    };
    "service-protocol-is-http" = {
      expr = (builtins.head value.spec.service.protocols).name;
      expected = "http";
    };
    "dry-run-covers-builder-and-runtime" = {
      expr =
        let kinds = map (s: s.kind) value.dryRun.steps;
        in {
          hasRun = lib.any (k: k == "run") kinds;
          hasService = lib.any (k: k == "declare-service") kinds;
          hasUnit = lib.any (k: k == "materialize-unit") kinds;
        };
      expected = {
        hasRun = true;
        hasService = true;
        hasUnit = true;
      };
    };
    "self-docs-include-runtime-service" = {
      expr = lib.hasInfix "node-service-demo-service" value.docs.markdown;
      expected = true;
    };
    "self-view-showcases-many-views" = {
      expr = {
        validationOk = value.selfView.validation.ok;
        hasRuntimeService = value.selfView.dependencies.serviceCount == 1;
        hasDryRun = value.selfView.dryRun.stepCount > 0;
        hasPlan = value.selfView.plan.stepCount > 0;
        hasSelfDocs = value.selfView.documentation.runtimeServiceCount == 1;
        hasMaterialization = value.selfView.materialization.runtimeArtifactCount == 1;
        markdownNamesThesis = lib.hasInfix "same internalized program" value.selfView.markdown;
      };
      expected = {
        validationOk = true;
        hasRuntimeService = true;
        hasDryRun = true;
        hasPlan = true;
        hasSelfDocs = true;
        hasMaterialization = true;
        markdownNamesThesis = true;
      };
    };
    "materialize-plan-includes-service-artifact" = {
      expr =
        let plan = value.materialize.plan;
        in {
          inherit (plan) name;
          artifactCount = builtins.length plan.runtimeArtifacts;
          toolNames = map (t: t.name) plan.tools;
        };
      expected = {
        name = "node-service-demo-artifact";
        artifactCount = 1;
        toolNames = [ "node" "bash" ];
      };
    };
    "materialize-plan-preserves-run-tools" = {
      expr = map (step: step.tool.name)
        (lib.filter (step: step._con == "runStep") value.materialize.plan.steps);
      expected = [ "node" "bash" ];
    };
    "materialize-shell-script-shape" = {
      expr =
        let script = value.materializeShell;
        in {
          standalone = lib.hasPrefix "#!/usr/bin/env bash\n" script;
          guardsNode = lib.hasInfix "command -v node" script;
          installsTree = lib.hasInfix "install-node-service" script;
          notesServiceArtifact =
            lib.hasInfix "# runtime artifact service:node-service-demo-service" script;
        };
      expected = {
        standalone = true;
        guardsNode = true;
        installsTree = true;
        notesServiceArtifact = true;
      };
    };
    "materialize-dockerfile-shape" = {
      expr =
        let dockerfile = value.materializeDockerfile;
        in {
          parameterizedBase = lib.hasInfix "FROM \${base}" dockerfile;
          copiesSource = lib.hasInfix "COPY server.js /inputs/server.js" dockerfile;
          guardsNode = lib.hasInfix "RUN command -v node" dockerfile;
        };
      expected = {
        parameterizedBase = true;
        copiesSource = true;
        guardsNode = true;
      };
    };
    "plan-export-round-trip" = {
      expr =
        # fromJSON requires a context-free string; the export keeps the
        # context of the tool paths it names.
        let decoded = builtins.fromJSON
          (builtins.unsafeDiscardStringContext value.planExport);
        in {
          serviceNames = map (s: s.name) decoded.declaredServices;
          toolNames = map (t: t.name) decoded.tools;
          packageFree =
            !builtins.any (t: t ? package) decoded.tools
            && !builtins.any (s: s ? package) decoded.declaredServices;
        };
      expected = {
        serviceNames = [ "node-service-demo-service" ];
        toolNames = [ "node" "bash" ];
        packageFree = true;
      };
    };
  };
}
