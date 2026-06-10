{ api, lib, self, docsCheckProofs ? true, ... }:

let
  bridgeModel = self.bridgeModel.value;

  renderInlineList = values:
    if values == [ ] then "`[]`"
    else builtins.concatStringsSep ", " (map (value: "`${value}`") values);

  inlineMath = value: "$" + value + "$";
  displayMath = value: "$$\n" + value + "\n$$";

  # Heavy theorems (long normalizations) are never forced in docs builds;
  # their kernel checks run in the heavy test suite.
  renderTheorem = theorem:
    let checked = docsCheckProofs && !(theorem.heavy or false);
    in ''
      ### `${theorem.name}`

      ${displayMath theorem.statementMath}

      - Type: ${inlineMath theorem.typeMath}
      - Proof: ${inlineMath theorem.proofMath}
      - Kernel result: `${if checked then theorem.resultTag else "skipped"}`${
          lib.optionalString (docsCheckProofs && (theorem.heavy or false))
            " (long normalization; verified in the heavy test suite)"}
    '';

  renderedTheorems =
    builtins.concatStringsSep "\n\n" (map renderTheorem bridgeModel.theoremList);

  proofNote =
    if docsCheckProofs then ""
    else ''
      Kernel checks are skipped in this build; each theorem below is
      verified by the test suite (one test per theorem).

    '';

  bridge = api.mk {
    title = "Bridge example";
    description = "Relates the shipped builder kinds — Node service, C code generation, OCI image, and IDL — through kernel-checked ornament, effect, and list-computation theorems.";
    sourceFiles = [
      {
        name = "bridge.nix";
        title = "Bridge proof module";
        relativePath = "examples/bridge.nix";
        language = "nix";
        source = ./bridge.nix;
        description = "Source for the kernel-checked bridge theorem set.";
        role = ''
          This module checks the bridge theorems and exposes their normal
          forms.
        '';
      }
    ];
    doc = ''
      # Bridge Example

      The shipped builder kinds are related by proof objects checked through
      the nix-effects kernel. For each of the four example builders — Node
      service, C code generation, OCI image, and IDL — the bridge proves how
      the ornament refines its base, how its forget map computes, and how
      program compilation factors through forget. It also pins the shared
      effect language, internalizes the materialize and dry-run step folds,
      and proves their tag agreement for every program.
    '';
    sections = [
      {
        title = "What is proven";
        body = ''
          The bridge relates all four example builders — Node service, C code
          generation, OCI image, and IDL — through the common `BuilderSpec`
          surface and the shared builder effect language. Each kind carries
          the same theorem family: ornament membership, forget codomain and
          computation, and program compilation factoring through forget with
          no bypass. The IDL theorems track the two-level forget through
          `CodeGenBuilder` down to `BuilderSpec`. The final group internalizes
          the materialize and dry-run step folds and proves they agree on
          step tags for every program; the Node and C builders additionally
          carry intersection theorems over their actual tool and
          output-format lists.

          ${proofNote}${renderedTheorems}
        '';
      }
      {
        title = "Normal forms";
        body = ''
          The list-intersection theorems run over the Node and C builders'
          actual lists. The bridge derives these values from the loaded
          builder specs:

          - BuilderSpec fields: ${renderInlineList bridgeModel.normalForms.builderSpecFields}
          - Node base name: `${bridgeModel.normalForms.node.baseName}`
          - C base name: `${bridgeModel.normalForms.c.baseName}`
          - Node tools: ${renderInlineList bridgeModel.normalForms.node.tools}
          - C tools: ${renderInlineList bridgeModel.normalForms.c.tools}
          - Shared tools: ${renderInlineList bridgeModel.normalForms.sharedTools}
          - Node output formats: ${renderInlineList bridgeModel.normalForms.node.outputFormats}
          - C output formats: ${renderInlineList bridgeModel.normalForms.c.outputFormats}
          - Shared output formats: ${renderInlineList bridgeModel.normalForms.sharedOutputFormats}
        '';
      }
      {
        title = "Proof boundary";
        body = ''
          The checked bridge covers the relationships currently resident in the
          kernel: ornament membership, forget maps, the common effect carrier,
          derived list computations over strings, and the internalized
          materialize and dry-run tag folds together with their agreement
          theorem. The self-views remain documentation views over the
          resulting builder programs; they consume these facts but are not
          themselves proof terms.
        '';
      }
    ];
    value = bridgeModel;
    tests = self.bridgeModel.tests;
  };
in
api.mk {
  docHidden = true;
  value = (removeAttrs self [ "bridgeModel" ]) // { inherit bridge; };
}
