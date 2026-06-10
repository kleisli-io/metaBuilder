{ api, self, docsCheckProofs ? true, ... }:

let
  bridgeModel = self.bridgeModel.value;

  renderInlineList = values:
    if values == [ ] then "`[]`"
    else builtins.concatStringsSep ", " (map (value: "`${value}`") values);

  inlineMath = value: "$" + value + "$";
  displayMath = value: "$$\n" + value + "\n$$";

  renderTheorem = theorem: ''
    ### `${theorem.name}`

    ${displayMath theorem.statementMath}

    - Type: ${inlineMath theorem.typeMath}
    - Proof: ${inlineMath theorem.proofMath}
    - Kernel result: `${if docsCheckProofs then theorem.resultTag else "skipped"}`
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

      The Node and C examples are related by proof objects checked through the
      nix-effects kernel. The bridge proves how both builders refine
      `BuilderSpec`, how their forget maps compute, and how selected
      intersections over their actual tool and output-format lists normalize.
    '';
    sections = [
      {
        title = "What is proven";
        body = ''
          The bridge relates the Node service builder and the C code generation
          builder through the common `BuilderSpec` surface and the shared
          builder effect language.

          ${proofNote}${renderedTheorems}
        '';
      }
      {
        title = "Normal forms";
        body = ''
          The bridge derives these values from the loaded builder specs:

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
          and derived list computations over strings. The self-views remain
          documentation views over the resulting builder programs; they consume
          these facts but are not themselves proof terms.
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
