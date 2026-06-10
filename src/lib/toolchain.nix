{ fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.lib.toolchain.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  ToolchainSpec = H.product "MetaBuilderToolchainSpec" [
    (H.field "name" H.string)
    (H.field "fields" H.attrs)
  ];

  ToolchainManifest = H.product "MetaBuilderToolchainManifest" [
    (H.field "default" H.string)
    (H.field "matrix" H.attrs)
  ];

  HintResult = H.product "MetaBuilderHintResult" [
    (H.field "name" H.string)
    (H.field "priority" H.any)
    (H.field "spec" H.attrs)
    (H.field "sources" (H.listOf H.string))
    (H.field "path" H.any)
  ];

  ToolchainSelection = H.product "MetaBuilderToolchainSelection" [
    (H.field "implementation" H.any)
    (H.field "spec" H.any)
    (H.field "sources" (H.listOf H.string))
    (H.field "path" H.any)
    (H.field "paths" (H.listOf H.any))
    (H.field "hints" (H.listOf HintResult.T))
  ];

  nonEmpty = value:
    if value == null then false
    else if builtins.isList value then value != [ ]
    else if builtins.isAttrs value then builtins.length (builtins.attrNames value) != 0
    else true;

  defaultMergeSpec = existing: addition:
    let
      filtered = lib.filterAttrs (_: v: nonEmpty v) addition;
      missingKeys = lib.filterAttrs (name: _: !(builtins.hasAttr name existing)) filtered;
    in
    existing // missingKeys;

  toList = value:
    if value == null then [ ]
    else if builtins.isList value then value
    else [ value ];

  emptySelection = explicit: {
    _con = "MetaBuilderToolchainSelection";
    implementation = explicit;
    spec = null;
    sources = [ "explicit" ];
    path = null;
    paths = [ ];
    hints = [ ];
  };

  select =
    { defaultImplementation
    , selectImplementation
    , normalizeSpec
    , hintEvaluators
    , explicitImplementation ? null
    , args ? { }
    , mergeSpec ? defaultMergeSpec
    }:
    if explicitImplementation != null then
      validateOr "select" ToolchainSelection.T (emptySelection explicitImplementation)
    else
      let
        evaluatedHints =
          lib.filter (hint: hint != null)
            (map
              (hint:
                let result = hint.evaluate args; in
                if result == null
                then null
                else {
                  _con = "MetaBuilderHintResult";
                  name = hint.name or "manifest";
                  priority = hint.priority or 0;
                  spec = result.spec or { };
                  sources =
                    if result ? sources
                    then toList result.sources
                    else [ (hint.name or "manifest") ];
                  path = result.path or null;
                }
              )
              hintEvaluators);

        sortedHints =
          lib.sort (a: b: a.priority > b.priority) evaluatedHints;

        combined =
          lib.foldl'
            (acc: hint:
              let
                mergedSpec = mergeSpec acc.spec hint.spec;
                mergedSources = lib.unique (acc.sources ++ hint.sources);
                mergedPaths = acc.paths ++ lib.optional (hint.path != null) hint.path;
              in
              {
                spec = mergedSpec;
                sources = mergedSources;
                paths = mergedPaths;
                hints = acc.hints ++ [ hint ];
              }
            )
            { spec = { }; sources = [ ]; paths = [ ]; hints = [ ]; }
            sortedHints;

        normalizedSpec =
          if combined.spec == { }
          then null
          else normalizeSpec combined.spec;

        implementation =
          if normalizedSpec == null
          then defaultImplementation
          else selectImplementation normalizedSpec;

        sources =
          if normalizedSpec == null
          then (if combined.sources == [ ] then [ "default" ] else combined.sources)
          else combined.sources;

        selection = {
          _con = "MetaBuilderToolchainSelection";
          inherit implementation sources;
          spec = normalizedSpec;
          path = lib.findFirst (_: true) null combined.paths;
          paths = combined.paths;
          hints = combined.hints;
        };
      in
      validateOr "select" ToolchainSelection.T selection;

  sanitizeAttrs =
    attrs: lib.filterAttrs
      (_: value:
      value != null
      && (! lib.isAttrs value || (builtins.length (builtins.attrNames value) != 0))
      )
      attrs;

  filterToolchain = fields: spec:
    if spec == null then null
    else if fields == null then spec
    else lib.filterAttrs (name: _: lib.elem name fields) spec;

  mkManifest =
    { defaultName
    , specs
    , normalize
    , defaultHostTriple
    , toolchainFields ? null
    }:
    let
      sanitize = spec:
        let
          normalized = normalize spec;
          allFields = builtins.removeAttrs normalized [ "name" ];
          withDefaults = allFields // {
            hostTriple = normalized.hostTriple or defaultHostTriple;
            targetTriple = normalized.targetTriple or normalized.hostTriple or defaultHostTriple;
            cargoHost = normalized.cargoHost or normalized.hostTriple or defaultHostTriple;
            cargoTarget = normalized.cargoTarget or normalized.targetTriple
              or normalized.hostTriple or defaultHostTriple;
            targets =
              let values = normalized.targets or [ ];
              in if values == [ ] then null else values;
          };
        in
        filterToolchain toolchainFields (sanitizeAttrs withDefaults);

      matrix = lib.listToAttrs (map
        (spec: {
          name = spec.name;
          value = sanitize spec;
        })
        specs);

      manifest = {
        _con = "MetaBuilderToolchainManifest";
        default = defaultName;
        inherit matrix;
      };
    in
    (validateOr "mkManifest" ToolchainManifest.T manifest) // { inherit sanitize; };

  value = {
    inherit
      ToolchainSpec
      ToolchainManifest
      HintResult
      ToolchainSelection
      select
      mkManifest
      defaultMergeSpec;
    types = {
      spec = ToolchainSpec;
      manifest = ToolchainManifest;
      hint = HintResult;
      selection = ToolchainSelection;
    };
    schemas = {
      spec = G.derive.deriveSchema ToolchainSpec;
      manifest = G.derive.deriveSchema ToolchainManifest;
      hint = G.derive.deriveSchema HintResult;
      selection = G.derive.deriveSchema ToolchainSelection;
    };
  };

in
api.mk {
  description = "metaBuilder toolchain lib: typed hint-based implementation selection and toolchain matrix construction.";
  doc = ''
    # Toolchain

    `select` resolves an implementation from prioritized hint evaluators
    and returns a typed `ToolchainSelection`. An explicit override
    short-circuits the hint pipeline.

    `mkManifest` builds a typed `ToolchainManifest` whose `matrix` maps
    each spec name to its sanitized, default-applied field set.
    Builder-specific extension fields pass through unchanged.
  '';
  inherit value;
  tests = {
    "select-explicit-override-short-circuits" = {
      expr =
        let
          result = select {
            defaultImplementation = "impl-a";
            selectImplementation = _: "should-not-run";
            normalizeSpec = _: throw "should not normalize";
            hintEvaluators = [{
              name = "explode";
              evaluate = _: throw "hint must not run";
            }];
            explicitImplementation = "impl-b";
          };
        in
        { inherit (result) implementation sources spec; };
      expected = {
        implementation = "impl-b";
        sources = [ "explicit" ];
        spec = null;
      };
    };

    "select-merges-hints-by-priority" = {
      expr =
        let
          result = select {
            defaultImplementation = "impl-a";
            selectImplementation = spec: spec.impl or "fallback";
            normalizeSpec = spec: spec;
            hintEvaluators = [
              {
                name = "low";
                priority = 1;
                evaluate = _: { spec = { impl = "low-impl"; flavour = "lo"; }; };
              }
              {
                name = "high";
                priority = 10;
                evaluate = _: { spec = { impl = "high-impl"; }; };
              }
            ];
          };
        in
        {
          inherit (result) implementation;
          flavour = result.spec.flavour or null;
          impl = result.spec.impl or null;
        };
      expected = {
        implementation = "high-impl";
        impl = "high-impl";
        flavour = "lo";
      };
    };

    "select-falls-back-to-default-when-no-hints" = {
      expr =
        let
          result = select {
            defaultImplementation = "impl-a";
            selectImplementation = _: "unused";
            normalizeSpec = _: throw "no hints, no normalize";
            hintEvaluators = [{
              name = "absent";
              evaluate = _: null;
            }];
          };
        in
        { inherit (result) implementation sources; };
      expected = {
        implementation = "impl-a";
        sources = [ "default" ];
      };
    };

    "mkManifest-triple-defaults-applied" = {
      expr =
        let
          manifest = mkManifest {
            defaultName = "stable";
            defaultHostTriple = "x86_64-unknown-linux-gnu";
            normalize = spec: spec;
            specs = [
              { name = "stable"; }
              { name = "nightly"; cargoHost = "aarch64-apple-darwin"; }
            ];
          };
        in
        {
          default = manifest.default;
          stable = manifest.matrix.stable;
          nightlyHost = manifest.matrix.nightly.hostTriple;
          nightlyCargoHost = manifest.matrix.nightly.cargoHost;
        };
      expected = {
        default = "stable";
        stable = {
          hostTriple = "x86_64-unknown-linux-gnu";
          targetTriple = "x86_64-unknown-linux-gnu";
          cargoHost = "x86_64-unknown-linux-gnu";
          cargoTarget = "x86_64-unknown-linux-gnu";
        };
        nightlyHost = "x86_64-unknown-linux-gnu";
        nightlyCargoHost = "aarch64-apple-darwin";
      };
    };

    "mkManifest-extension-fields-pass-through" = {
      expr =
        let
          manifest = mkManifest {
            defaultName = "build-a";
            defaultHostTriple = "x86_64-unknown-linux-gnu";
            normalize = spec: spec;
            specs = [
              { name = "build-a"; runtime = "engine"; engineVersion = "1.0"; }
            ];
          };
        in
        {
          inherit (manifest.matrix."build-a") runtime engineVersion;
        };
      expected = {
        runtime = "engine";
        engineVersion = "1.0";
      };
    };

    "mkManifest-toolchain-fields-whitelist" = {
      expr =
        let
          manifest = mkManifest {
            defaultName = "stable";
            defaultHostTriple = "x86_64-unknown-linux-gnu";
            normalize = spec: spec;
            toolchainFields = [ "hostTriple" "targetTriple" ];
            specs = [
              { name = "stable"; cargoHost = "ignored"; targets = [ "wasm32" ]; }
            ];
          };
        in
        builtins.attrNames manifest.matrix.stable;
      expected = [ "hostTriple" "targetTriple" ];
    };

    "toolchain-schema-non-empty" = {
      expr = (value.schemas.manifest.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
