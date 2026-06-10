{ fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.lib.dashboard.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  MetricsResult = H.product "MetaBuilderMetricsResult" [
    (H.field "lockHash" H.any)
    (H.field "toolchainSpec" H.any)
    (H.field "fields" H.attrs)
  ];

  WorkspaceSummary = H.product "MetaBuilderWorkspaceSummary" [
    (H.field "lockHash" H.any)
    (H.field "members" H.attrs)
    (H.field "stats" H.attrs)
  ];

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

  splitKnown = projected:
    let
      known = [ "lockHash" "toolchainSpec" ];
      rest = builtins.removeAttrs projected known;
    in
    {
      lockHash = projected.lockHash or null;
      toolchainSpec = projected.toolchainSpec or null;
      fields = rest;
    };

  mkMetrics =
    { project
    , toolchainFields ? null
    , sanitizeToolchain ? null
    , postProcess ? (attrs: attrs)
    }:
    let
      toolchainSanitizer =
        if sanitizeToolchain == null then (spec: spec) else sanitizeToolchain;
      sanitize = metrics:
        let
          projected = project metrics;
          split = splitKnown projected;
          toolchainSpec =
            if split.toolchainSpec != null
            then filterToolchain toolchainFields (toolchainSanitizer split.toolchainSpec)
            else null;
          result = {
            _con = "MetaBuilderMetricsResult";
            inherit (split) lockHash fields;
            inherit toolchainSpec;
          };
          validated = validateOr "mkMetrics.sanitize" MetricsResult.T result;
          flatRaw =
            sanitizeAttrs (validated.fields
              // (if validated.toolchainSpec != null
            then { toolchainSpec = validated.toolchainSpec; }
            else { })
              // (if validated.lockHash != null
            then { lockHash = validated.lockHash; }
            else { }));
        in
        postProcess flatRaw;
    in
    { inherit sanitize; };

  mkWorkspaceSummary =
    { sanitizeMember
    , lockHashField ? "lockHash"
    , collectStats ? (_members: { })
    , postProcess ? (summary: summary)
    }:
    let
      summarize = members:
        let
          sanitizedMembers = lib.mapAttrs sanitizeMember members;
          lockHashes =
            map (member: member.${lockHashField} or null)
              (builtins.attrValues sanitizedMembers);
          lockHash =
            lib.findFirst (hash: hash != null) null lockHashes;
          stats = collectStats sanitizedMembers;
          summary = {
            _con = "MetaBuilderWorkspaceSummary";
            inherit lockHash stats;
            members = sanitizedMembers;
          };
          validated = validateOr "mkWorkspaceSummary.summarize" WorkspaceSummary.T summary;
          flatRaw =
            sanitizeAttrs ({
              inherit (validated) members;
            }
            // (if validated.lockHash != null
            then { inherit (validated) lockHash; }
            else { })
            // (if validated.stats != { }
            then { inherit (validated) stats; }
            else { }));
        in
        postProcess flatRaw;
    in
    { inherit summarize; };

  value = {
    inherit
      MetricsResult
      WorkspaceSummary
      mkMetrics
      mkWorkspaceSummary;
    types = {
      metricsResult = MetricsResult;
      workspaceSummary = WorkspaceSummary;
    };
    schemas = {
      metricsResult = G.derive.deriveSchema MetricsResult;
      workspaceSummary = G.derive.deriveSchema WorkspaceSummary;
    };
  };

in
api.mk {
  description = "metaBuilder dashboard lib: typed lock-metrics and workspace-summary interfaces for cross-language build dashboards.";
  doc = ''
    # Dashboard

    `mkMetrics` produces a typed `sanitize` projection that pulls
    `lockHash` and `toolchainSpec` out of raw lock-file metrics, filters
    the toolchain spec by an optional whitelist of fields, and returns
    a flattened attr-set of the remaining metric fields.

    `mkWorkspaceSummary` produces a typed `summarize` that walks a
    workspace member map, sanitizes each member, discovers the first
    non-null `lockHash`, optionally collects stats, and returns the
    summary record.
  '';
  inherit value;
  tests = {
    "mkMetrics-projects-and-flattens" = {
      expr =
        let
          m = mkMetrics {
            project = raw: {
              lockHash = raw.hash;
              toolchainSpec = { hostTriple = "x86_64-linux"; cargoTarget = "wasm32"; };
              packageCount = raw.pkgCount;
            };
          };
        in
        m.sanitize { hash = "abc"; pkgCount = 42; };
      expected = {
        lockHash = "abc";
        packageCount = 42;
        toolchainSpec = {
          hostTriple = "x86_64-linux";
          cargoTarget = "wasm32";
        };
      };
    };

    "mkMetrics-null-toolchain-omitted" = {
      expr =
        let
          m = mkMetrics {
            project = raw: { lockHash = raw.hash; toolchainSpec = null; };
          };
        in
        m.sanitize { hash = "abc"; };
      expected = { lockHash = "abc"; };
    };

    "mkMetrics-toolchain-fields-whitelist" = {
      expr =
        let
          m = mkMetrics {
            toolchainFields = [ "hostTriple" ];
            project = _: {
              toolchainSpec = { hostTriple = "x86_64-linux"; cargoTarget = "wasm32"; };
            };
          };
        in
        (m.sanitize { }).toolchainSpec;
      expected = { hostTriple = "x86_64-linux"; };
    };

    "mkMetrics-postProcess-runs-last" = {
      expr =
        let
          m = mkMetrics {
            project = raw: { lockHash = raw.hash; };
            postProcess = attrs: attrs // { stamped = true; };
          };
        in
        (m.sanitize { hash = "h"; }).stamped;
      expected = true;
    };

    "mkWorkspaceSummary-collects-first-lock-hash" = {
      expr =
        let
          s = mkWorkspaceSummary {
            sanitizeMember = _: m: m;
          };
        in
        (s.summarize {
          alpha = { lockHash = null; };
          beta = { lockHash = "beta-hash"; };
          gamma = { lockHash = "gamma-hash"; };
        }).lockHash;
      expected = "beta-hash";
    };

    "mkWorkspaceSummary-collects-stats-when-nonempty" = {
      expr =
        let
          s = mkWorkspaceSummary {
            sanitizeMember = _: m: m;
            collectStats = members: { memberCount = builtins.length (builtins.attrNames members); };
          };
        in
        (s.summarize { a = { }; b = { }; }).stats;
      expected = { memberCount = 2; };
    };

    "mkWorkspaceSummary-empty-stats-omitted" = {
      expr =
        let
          s = mkWorkspaceSummary {
            sanitizeMember = _: m: m;
          };
        in
        (s.summarize { a = { lockHash = "x"; }; }) ? stats;
      expected = false;
    };

    "dashboard-schemas-non-empty" = {
      expr =
        (value.schemas.metricsResult.oneOf or [ ]) != [ ]
        && (value.schemas.workspaceSummary.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
