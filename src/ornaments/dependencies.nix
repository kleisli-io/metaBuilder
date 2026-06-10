{ mb, fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.ornaments.dependencies.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  DependencyType = H.product "MetaBuilderDependencyType" [
    (H.field "name" H.string)
    (H.field "transitive" H.bool)
    (H.field "toposort" H.bool)
  ];

  # DependencyShape is a 3-mode sum dispatched by `_con` pattern match.
  # `Uniform` covers single-type identical treatment; `Partitioned`
  # covers custom-vs-bundled splits driven by a sentinel path field;
  # `MultiTyped` covers N-type mixed-language dependency lists.
  DependencyShape = H.datatype "MetaBuilderDependencyShape" [
    (H.con "Uniform" [
      (H.field "langName" H.string)
    ])
    (H.con "Partitioned" [
      (H.field "langName" H.string)
      (H.field "pathField" H.string)
    ])
    (H.con "MultiTyped" [
      (H.field "types" (H.listOf DependencyType.T))
    ])
  ];

  DependenciesBuilder = H.ornament mb.descriptions.BuilderSpec {
    name = "MetaBuilderDependencies";
    constructors.MetaBuilderSpec.fields = [
      { insert = "dependencyShape"; type = DependencyShape.T; }
      { keep = "name"; }
      { keep = "parameters"; }
      { keep = "inputs"; }
      { keep = "dependencies"; }
      { keep = "tools"; }
      { keep = "operations"; }
      { keep = "outputs"; }
      { keep = "evidence"; }
    ];
  };

  # Shape constructors. Each produces a validated DependencyShape value.
  uniform = { langName }:
    validateOr "uniform" DependencyShape.T {
      _con = "Uniform";
      inherit langName;
    };

  partitioned = { langName, pathField }:
    validateOr "partitioned" DependencyShape.T {
      _con = "Partitioned";
      inherit langName pathField;
    };

  typeOf = { name, transitive ? true, toposort ? true }:
    validateOr "typeOf" DependencyType.T {
      _con = "MetaBuilderDependencyType";
      inherit name transitive toposort;
    };

  multiTyped = { types }:
    let typed = map (t: if (t._con or "") == "MetaBuilderDependencyType" then t else typeOf t) types;
    in validateOr "multiTyped" DependencyShape.T {
      _con = "MultiTyped";
      types = typed;
    };

  # Typed-sum dispatcher. Each branch receives the relevant payload
  # fields. Consumers use this to write resolution algorithms without
  # touching `_con` directly.
  matchShape = { uniform, partitioned, multiTyped }: shape:
    let con = shape._con or null; in
    if con == "Uniform" then uniform { inherit (shape) langName; }
    else if con == "Partitioned" then partitioned { inherit (shape) langName pathField; }
    else if con == "MultiTyped" then multiTyped { inherit (shape) types; }
    else throw "matchShape: not a DependencyShape value (got _con = ${toString con})";

  define =
    { dependencyShape
    , name ? "dependenciesBuilder"
    , parameters ? [ ]
    , inputs ? [ ]
    , dependencies ? [ ]
    , tools ? [ ]
    , operations ? [ ]
    , outputs ? [ ]
    , evidence ? [ ]
    }:
    {
      _con = "MetaBuilderSpec";
      inherit name parameters inputs dependencies tools operations outputs evidence;
      inherit dependencyShape;
    };

  # ============================================================================
  # Resolver eliminators
  # ============================================================================

  # Internal helper: transitive flatten via `builtins.genericClosure`
  # (C++ BFS with O(log n) key dedup). Each package contributes an
  # identity key for dedup; the operator returns the package's
  # dependencies as the BFS frontier. Not exposed at the top level —
  # `resolveUniform` is the consumer-facing entry.
  flattenDeps = { packages, getDeps }:
    let
      getKey = pkg:
        pkg.name or
          pkg.drvPath or
            (throw "metaBuilder.ornaments.dependencies.flattenDeps: package has no identity (name/drvPath)");
    in
    map (item: item.pkg) (builtins.genericClosure {
      startSet = map (pkg: { key = getKey pkg; inherit pkg; }) packages;
      operator = item:
        map (dep: { key = getKey dep; pkg = dep; }) (getDeps item.pkg);
    });

  # resolveUniform : { langName; deps } -> [Package]
  #
  # Pre-composed resolution pipeline for uniform dependency models —
  # all packages are treated identically, deps are read from the
  # `${langName}Deps` field on each package. Transitive closure via
  # `flattenDeps`, then toposort so dependencies precede dependents.
  # Throws on cycles. Matches
  # `metaBuilder.patterns.dependencies.resolveUniform`.
  resolveUniform = { langName, deps }:
    let
      allPackages = flattenDeps {
        packages = deps;
        getDeps = pkg: pkg."${langName}Deps" or [ ];
      };
      dependsOn = a: b: lib.elem a (b."${langName}Deps" or [ ]);
      sorted = lib.toposort dependsOn allPackages;
    in
    if sorted ? result
    then sorted.result
    else throw "metaBuilder.ornaments.dependencies.resolveUniform: circular dependency in '${langName}': ${toString sorted.cycle}";

  # markResolved : [Package] -> { __resolvedDeps = true; deps; }
  #
  # Wraps an already-resolved dependency list (flat, toposorted) in a
  # sentinel-tagged record so downstream builders can skip redundant
  # re-resolution. Use `isResolved` / `unwrapDeps` to interrogate the
  # wrapper.
  markResolved = deps: {
    __resolvedDeps = true;
    inherit deps;
  };

  # isResolved : Any -> Bool
  isResolved = x:
    builtins.isAttrs x
    && x ? __resolvedDeps
    && x.__resolvedDeps == true;

  # unwrapDeps : Any -> [Package]
  #
  # Extract the deps list from a marked wrapper; returns unmarked
  # inputs as-is.
  unwrapDeps = x:
    if isResolved x then x.deps else x;

  value = {
    inherit DependencyType DependencyShape DependenciesBuilder
      uniform partitioned multiTyped typeOf matchShape define
      resolveUniform markResolved isResolved unwrapDeps;
    types.dependencyType = DependencyType;
    types.dependencyShape = DependencyShape;
    types.dependenciesBuilder = DependenciesBuilder;
    schemas.dependencyShape = G.derive.deriveSchema DependencyShape;
    schemas.dependenciesBuilder = G.derive.deriveSchema DependenciesBuilder;
  };

in
api.mk {
  description = "DependenciesBuilder ornament over BuilderSpec: typed dependency-resolution strategy plus resolver eliminators. The 3-mode shape (Uniform / Partitioned / MultiTyped) is encoded as a HOAS sum and dispatched via `matchShape`. `resolveUniform` walks the transitive closure and toposorts for the single-typed case; `markResolved`/`isResolved`/`unwrapDeps` form a sentinel-tagged wrapper that lets downstream builders skip redundant re-resolution.";
  doc = ''
    # Dependencies

    Two surfaces live on this ornament: a **typed-shape** layer
    (constructors + dispatcher + spec ctor) and a **resolver
    eliminators** layer (uniform resolution + the resolved-deps marker).

    ## Typed-shape layer

    A `DependencyShape` selects the resolution strategy by
    constructor:

    - `Uniform { langName }` — single-typed, identical treatment
      across all packages.
    - `Partitioned { langName; pathField }` — custom-vs-bundled split
      driven by a sentinel path field.
    - `MultiTyped { types : list DependencyType }` — N-type mix; each
      `DependencyType` declares its own transitive / toposort flags.

    `matchShape { uniform = …; partitioned = …; multiTyped = …; }
    shape` is the typed dispatcher: constructor-driven pattern match
    over the three modes.

    `define { dependencyShape; … }` produces a `DependenciesBuilder`
    spec; consumers fold the spec into the surrounding builder
    pipeline downstream.

    ## Resolver eliminators

    `resolveUniform { langName; deps }` walks the transitive closure of
    `deps` via the `''${langName}Deps` field on each package, then
    toposorts so dependencies precede dependents. Throws on cycles.

    `markResolved deps` wraps an already-resolved list in a
    sentinel-tagged record. `isResolved x` answers the marker check;
    `unwrapDeps x` extracts the list (or returns plain inputs as-is).
    Together they centralise the inline `if ? __resolvedDeps then
    .deps else x` pattern that legacy consumers spelled at every call
    site.
  '';
  inherit value;
  tests = {
    "uniform-shape-ctor-validates" = {
      expr = (uniform { langName = "alpha"; }).langName;
      expected = "alpha";
    };

    "partitioned-shape-carries-path-field" = {
      expr =
        let s = partitioned { langName = "beta"; pathField = "betaPath"; };
        in { inherit (s) langName pathField; };
      expected = { langName = "beta"; pathField = "betaPath"; };
    };

    "multiTyped-shape-validates-types-list" = {
      expr =
        let
          s = multiTyped {
            types = [
              { name = "type-x"; }
              { name = "type-y"; transitive = false; toposort = false; }
            ];
          };
        in
        builtins.length s.types;
      expected = 2;
    };

    "matchShape-dispatches-by-constructor" = {
      expr = map
        (shape: matchShape
          {
            uniform = a: "uniform:${a.langName}";
            partitioned = a: "partitioned:${a.langName}/${a.pathField}";
            multiTyped = a: "multi:${toString (builtins.length a.types)}";
          }
          shape)
        [
          (uniform { langName = "alpha"; })
          (partitioned { langName = "beta"; pathField = "betaPath"; })
          (multiTyped { types = [{ name = "type-x"; } { name = "type-y"; }]; })
        ];
      expected = [ "uniform:alpha" "partitioned:beta/betaPath" "multi:2" ];
    };

    "matchShape-rejects-non-shape-values" = {
      expr = (builtins.tryEval (builtins.deepSeq
        (matchShape
          {
            uniform = _: 1;
            partitioned = _: 2;
            multiTyped = _: 3;
          }
          { _con = "Bogus"; })
        null)).success;
      expected = false;
    };

    "define-builds-validated-spec" = {
      expr =
        let s = define { dependencyShape = uniform { langName = "alpha"; }; };
        in s.dependencyShape._con;
      expected = "Uniform";
    };

    "schemas-non-empty" = {
      expr =
        (value.schemas.dependencyShape.oneOf or [ ]) != [ ]
        && (value.schemas.dependenciesBuilder.oneOf or [ ]) != [ ];
      expected = true;
    };

    "resolveUniform-flattens-transitive-deps" = {
      expr =
        let
          pkgX = { name = "pkg-x"; alphaDeps = [ ]; };
          pkgY = { name = "pkg-y"; alphaDeps = [ pkgX ]; };
          resolved = resolveUniform { langName = "alpha"; deps = [ pkgY ]; };
        in
        map (p: p.name) resolved;
      expected = [ "pkg-x" "pkg-y" ];
    };

    "resolveUniform-toposorts-dependencies-before-dependents" = {
      expr =
        let
          pkgX = { name = "pkg-x"; alphaDeps = [ ]; };
          pkgY = { name = "pkg-y"; alphaDeps = [ pkgX ]; };
          pkgZ = { name = "pkg-z"; alphaDeps = [ pkgY ]; };
          resolved = resolveUniform { langName = "alpha"; deps = [ pkgZ ]; };
        in
        map (p: p.name) resolved;
      expected = [ "pkg-x" "pkg-y" "pkg-z" ];
    };

    "resolveUniform-deduplicates-shared-transitive-deps" = {
      expr =
        let
          pkgX = { name = "pkg-x"; alphaDeps = [ ]; };
          pkgY = { name = "pkg-y"; alphaDeps = [ pkgX ]; };
          pkgZ = { name = "pkg-z"; alphaDeps = [ pkgX ]; };
          resolved = resolveUniform { langName = "alpha"; deps = [ pkgY pkgZ ]; };
        in
        builtins.length resolved;
      expected = 3;
    };

    "resolveUniform-uses-langName-scoped-deps-field" = {
      expr =
        let
          pkgX = { name = "pkg-x"; betaDeps = [ ]; };
          pkgY = { name = "pkg-y"; betaDeps = [ pkgX ]; alphaDeps = [ ]; };
          resolved = resolveUniform { langName = "beta"; deps = [ pkgY ]; };
        in
        map (p: p.name) resolved;
      expected = [ "pkg-x" "pkg-y" ];
    };

    "markResolved-wraps-with-marker-attrs" = {
      expr =
        let m = markResolved [ "pkg-x" "pkg-y" ];
        in { marker = m.__resolvedDeps; depCount = builtins.length m.deps; };
      expected = { marker = true; depCount = 2; };
    };

    "isResolved-true-for-marked-value" = {
      expr = isResolved (markResolved [ "pkg-x" ]);
      expected = true;
    };

    "isResolved-false-for-plain-list" = {
      expr = isResolved [ "pkg-x" "pkg-y" ];
      expected = false;
    };

    "isResolved-false-for-attrs-without-marker" = {
      expr = isResolved { foo = "bar"; };
      expected = false;
    };

    "unwrapDeps-extracts-deps-from-marker" = {
      expr = unwrapDeps (markResolved [ "pkg-x" "pkg-y" ]);
      expected = [ "pkg-x" "pkg-y" ];
    };

    "unwrapDeps-returns-unmarked-input-as-is" = {
      expr = unwrapDeps [ "pkg-x" "pkg-y" ];
      expected = [ "pkg-x" "pkg-y" ];
    };
  };
}
