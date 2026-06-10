{ fx ? null
, pkgs
, lib ? pkgs.lib
, exposeInternals ? false
  # When false, docs render theorem results as `skipped`; tests still check them.
, docsCheckProofs ? true
, ...
}:

let
  api = import ./src/api.nix { inherit lib; };
  resolvedFx =
    if fx != null then fx
    else throw "metaBuilder: pass `fx` explicitly";

  loader = import ./loader.nix {
    inherit lib api;
    fx = resolvedFx;
  };
  readSrc = loader.readSrc;

  internals = lib.fix (self:
    let
      ctx = {
        inherit api lib pkgs readSrc docsCheckProofs;
        fx = resolvedFx;
        mb = self.lib;
      };
    in
    {
      raw = readSrc ./src ctx;
      lib = api.extractValue self.raw;
      testRaw = readSrc ./tests ctx;
      examplesRaw = readSrc ./examples ctx;
    });

  mb = internals.lib;
  inlineTests = api.extractTests internals.raw
    // api.extractTests internals.testRaw
    // api.extractTests internals.examplesRaw;
  heavyInlineTests = api.extractHeavyTests internals.raw
    // api.extractHeavyTests internals.testRaw
    // api.extractHeavyTests internals.examplesRaw;
  testResults = api.runTests inlineTests;
  docsTree = api.extractDocs internals.raw;
  examplesDocs = api.extractDocs (internals.examplesRaw.value or internals.examplesRaw);
  docsLib =
    if resolvedFx ? docs
    then resolvedFx.docs
    else throw "metaBuilder: fx.docs is required for docs content generation";

  mkDocsContent = pkgs:
    import ./book/gen/docs-content.nix {
      inherit pkgs lib;
      metaBuilder = {
        extractDocs = docsTree;
        examplesDocs = examplesDocs;
        docs = docsLib;
      };
    };
in
mb // {
  inherit api;
  version = "0.1.0";
  examples = api.extractValue internals.examplesRaw;
  tests = testResults // { nix-unit = inlineTests; nix-unit-heavy = heavyInlineTests; };
  extractDocs = docsTree // { examples = examplesDocs; };
  inherit mkDocsContent;
  docs = docsTree // {
    examples = examplesDocs;
    tests = api.extractDocs internals.testRaw;
  };
} // lib.optionalAttrs exposeInternals {
  inherit api internals inlineTests;
}
