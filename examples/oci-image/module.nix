{ api, lib, mb, self, ... }:

let
  value = self.value;
in
api.mk {
  title = "OCI image example";
  description = "Guided OCI image builder tour: busybox layer, digest-chain assembly steps, image descriptor, smoke-test evidence, and materialization plan.";
  sourceFiles = [
    {
      name = "builder.nix";
      title = "OCI image example module";
      relativePath = "examples/oci-image/builder.nix";
      language = "nix";
      source = ./builder.nix;
      description = "Source for the worked busybox image spec and the exported views.";
      role = ''
        This module instantiates the `oci-image` ornament's `ociImage`
        constructor with a static busybox layer and exports the views used
        by the tour page.
      '';
    }
  ];
  doc = ''
    # OCI Image Example

    This tour builds a runnable OCI image layout from one static busybox
    layer. The builder vocabulary lives in the `oci-image` ornament; this
    example only supplies the image fields and shows the resulting views.

    The worked artifact is a spec-conformant OCI layout (`oci-layout`,
    `index.json`, `blobs/sha256/*`) plus an `image.oci.tar` archive of the
    layout, all assembled at build time with the digests computed in the
    build sandbox.
  '';
  sections = [
    {
      title = "Start from the artifact";
      body = ''
        The payload is `pkgsStatic.busybox` — a single musl-static layer
        with no runtime closure. The build produces:

        - `oci-layout` and `index.json`, the layout entry points.
        - `blobs/sha256/<digest>` for the layer tar, the image config, and
          the manifest — each blob named by its own sha256.
        - `image.oci.tar`, a deterministic tar of the layout for transports
          that want a single file.
      '';
    }
    {
      title = "Builder vocabulary";
      body = ''
        `OciImageBuilder` ornaments the generic `BuilderSpec` with the image
        fields (layers, entrypoint, cmd, env, exposedPorts, labels,
        architecture, os). The `ociImage` constructor compiles those fields
        into the assembly program, so the example stays at the domain
        surface.
      '';
      code = ''
        ociImage {
          name = "busybox-shell";
          layers = [
            { name = "busybox"; source = pkgs.pkgsStatic.busybox; }
          ];
          entrypoint = [ "/bin/sh" ];
        }
      '';
    }
    {
      title = "Program walkthrough";
      body = ''
        The constructor lowers the image spec into named steps in
        digest-chain order: assemble the layer rootfs, tar it
        deterministically, render the config (embedding layer diff_ids),
        render the manifest (embedding config and layer digests and sizes),
        write the index last, re-hash every blob against its filename,
        clean the scratch directory, and archive the layout.

        Because the steps are data, every fold renders them by name:
        dependency analysis, dry-run, plan-view, and self-documentation all
        show the same assembly. The smoke-test evidence travels with the
        spec and renders under the documentation's Evidence section.
      '';
    }
    {
      title = "One build, many views";
      body = ''
        The section below is generated from `mb.program.introspect.run
        program`. It is the internalized view of the image build:
        validation, dependency graph, dry-run, plan-view, descriptors,
        outputs, and materialization.

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
    "docs-mention-image" = {
      expr = {
        descriptor = lib.hasInfix "busybox-shell-oci-image" value.docs.markdown;
        evidenceSection = lib.hasInfix "## Evidence" value.docs.markdown;
        smokeTest = lib.hasInfix "smoke-test" value.docs.markdown;
      };
      expected = {
        descriptor = true;
        evidenceSection = true;
        smokeTest = true;
      };
    };
    "dry-run-covers-assembly" = {
      expr =
        let kinds = map (s: s.kind) value.dryRun.steps;
        in {
          runCount = builtins.length (lib.filter (k: k == "run") kinds);
          writeCount = builtins.length (lib.filter (k: k == "write") kinds);
          hasEvidence = lib.any (k: k == "evidence") kinds;
        };
      expected = {
        runCount = 8;
        writeCount = 1;
        hasEvidence = true;
      };
    };
    # One evidence entry lowers to one trailing declareEvidence op.
    "compiled-program-constructor-set-with-evidence" = {
      expr =
        let
          cons = map (o: o.value._con)
            (mb.program.compileSpec value.builder.OciImageBuilder.T self.spec);
        in
        {
          opCount = builtins.length cons;
          byCon = lib.genAttrs (lib.unique cons)
            (c: builtins.length (lib.filter (x: x == c) cons));
        };
      expected = {
        opCount = 19;
        byCon = {
          declareTool = 3;
          writeFile = 1;
          runTool = 8;
          emitDescriptor = 1;
          transformOutput = 4;
          materializeDerivation = 1;
          declareEvidence = 1;
        };
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
        name = "busybox-shell-oci-image";
        runStepCount = 8;
        writeStepCount = 1;
        outputCount = 4;
        toolNames = [ "bash" "tar" "coreutils" ];
      };
    };
  };
}
