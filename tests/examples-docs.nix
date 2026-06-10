{ api, readSrc, lib, ... }@ctx:

let
  rawExamples = readSrc ../examples ctx;
  examples = api.extractDocs (rawExamples.value or rawExamples);

  sectionBody = name: title:
    let
      matches = lib.filter (section: section.title or "" == title)
        (examples.${name}.sections or [ ]);
    in
    if matches == [ ] then ""
    else (builtins.head matches).body or "";

  nodeSelfView = sectionBody "node-service" "One build, many views";
  cSelfView = sectionBody "c-codegen" "One build, many views";

in
api.mk {
  description = "Example docs extraction contract: public example pages embed the composed builder self-view through api.extractDocs.";
  doc = ''
    # Example Docs Extraction

    Verifies the website-facing docs extraction layer sees the public example
    pages and their embedded builder self-view sections.
  '';
  value = { };
  tests = {
    "examples-docs-list-public-pages" = {
      expr = builtins.sort builtins.lessThan (builtins.attrNames examples);
      expected = [ "bridge" "c-codegen" "idl" "node-service" "oci-image" ];
    };

    "node-service-docs-embed-self-view" = {
      expr = {
        hasManyViews = lib.hasInfix "same internalized program" nodeSelfView;
        hasDependencyGraph = lib.hasInfix "### Dependency Graph" nodeSelfView;
        hasRuntimeServices = lib.hasInfix "### Runtime Services" nodeSelfView;
        hasOutputs = lib.hasInfix "### Materialized Outputs" nodeSelfView;
        noProvenanceBloat = !(lib.hasInfix "Interpreter Provenance" nodeSelfView);
      };
      expected = {
        hasManyViews = true;
        hasDependencyGraph = true;
        hasRuntimeServices = true;
        hasOutputs = true;
        noProvenanceBloat = true;
      };
    };

    "c-codegen-docs-embed-self-view" = {
      expr = {
        hasManyViews = lib.hasInfix "same internalized program" cSelfView;
        hasDependencyGraph = lib.hasInfix "### Dependency Graph" cSelfView;
        hasDescriptors = lib.hasInfix "### Descriptors" cSelfView;
        hasOutputs = lib.hasInfix "### Materialized Outputs" cSelfView;
        noProvenanceBloat = !(lib.hasInfix "Interpreter Provenance" cSelfView);
      };
      expected = {
        hasManyViews = true;
        hasDependencyGraph = true;
        hasDescriptors = true;
        hasOutputs = true;
        noProvenanceBloat = true;
      };
    };

    "bridge-docs-relate-node-and-c" = {
      expr = {
        hasKernelTheorems = lib.hasInfix "node-spec-inhabits-node-ornament" (sectionBody "bridge" "What is proven");
        hasForgetTheorem = lib.hasInfix "\\mathsf{forget}_{Node}(\\mathsf{node.spec}) = \\mathsf{node.baseSpec}" (sectionBody "bridge" "What is proven");
        hasLatexStatement = lib.hasInfix "\\mathsf{forget}_{Node}" (sectionBody "bridge" "What is proven");
        hasType = lib.hasInfix "Type: $\\operatorname{Eq}_{\\mathsf{BuilderSpec.T}}" (sectionBody "bridge" "What is proven");
        hasProof = lib.hasInfix "Proof: $\\mathsf{refl}$" (sectionBody "bridge" "What is proven");
        hasNormalForms = lib.hasInfix "Shared tools" (sectionBody "bridge" "Normal forms");
        hasProofBoundary = lib.hasInfix "Proof boundary" (builtins.toJSON (examples.bridge.sections or [ ]));
        hasSourceFile = examples.bridge.sourceFiles != [ ];
      };
      expected = {
        hasKernelTheorems = true;
        hasForgetTheorem = true;
        hasLatexStatement = true;
        hasType = true;
        hasProof = true;
        hasNormalForms = true;
        hasProofBoundary = true;
        hasSourceFile = true;
      };
    };
  };
}
