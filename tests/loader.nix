{ api, readSrc, ... }@ctx:

let
  fixturesRoot = ./fixtures;

  load = name: readSrc (fixturesRoot + "/${name}") ctx;

  loadOrFail = name:
    builtins.tryEval (builtins.deepSeq (load name) null);

  plain = load "plain";
  splitOk = load "split-ok";
  subdirOk = load "subdir-ok";
  skipSubtree = load "skip-subtree";
  skip = load "skip";
  splitWrapped = load "split-wrapped";

in
api.mk {
  description = "metaBuilder loader tests: exercise read-dir, import-file, wrap-namespace, load-split-module, skip-subtree, and structural error paths.";
  doc = ''
    # Loader Tests

    Verifies the source loader against filesystem fixtures under
    `tests/fixtures/`:

    - plain namespace loading wraps each `.nix` file under its attr name
    - split-module loading merges part scopes and tests through `module.nix`
    - subdirectories merge into the parent namespace
    - duplicate bindings, duplicate test names, and subdir/scope collisions
      throw at evaluation time
    - `.skip-subtree` markers cause a directory to load as an empty namespace
    - `.skip` markers exclude a directory from traversal and the namespace
  '';
  value = { };
  tests = {
    "plain-namespace-shape" = {
      expr = plain.value;
      expected = { a = 42; b = "hello"; };
    };
    "plain-namespace-type" = {
      expr = plain._type;
      expected = "metaBuilder-api";
    };
    "split-module-scope" = {
      expr = splitOk.value;
      expected = { x = 1; y = 2; };
    };
    "split-module-tests-merged" = {
      expr = builtins.sort builtins.lessThan
        (builtins.attrNames splitOk.tests);
      expected = [ "t-first" "t-second" ];
    };
    "subdir-merges-scope" = {
      expr = subdirOk.value.x;
      expected = 1;
    };
    "subdir-namespace-nested" = {
      expr = subdirOk.value.sub.value.inner;
      expected = 5;
    };
    "duplicate-binding-throws" = {
      expr = (loadOrFail "dup-binding").success;
      expected = false;
    };
    "duplicate-test-throws" = {
      expr = (loadOrFail "dup-test").success;
      expected = false;
    };
    "subdir-collision-throws" = {
      expr = (loadOrFail "subdir-collision").success;
      expected = false;
    };
    "skip-subtree-empties-namespace" = {
      expr = skipSubtree.value.skipped.value;
      expected = { };
    };
    "skip-subtree-keeps-sibling" = {
      expr = skipSubtree.value.visible;
      expected = 1;
    };
    "skip-excludes-directory" = {
      expr = skip.value ? assets;
      expected = false;
    };
    "skip-keeps-sibling" = {
      expr = skip.value.visible;
      expected = 1;
    };
    "split-module-parts-see-unwrapped-values" = {
      expr = splitWrapped.value.y;
      expected = 2;
    };
    "split-module-module-sees-wrapped-values" = {
      expr = splitWrapped.value.x._type;
      expected = "metaBuilder-api";
    };
    "split-module-parts-see-root-mb" = {
      expr = splitWrapped.value.rootHasOperations;
      expected = true;
    };
  };
}
