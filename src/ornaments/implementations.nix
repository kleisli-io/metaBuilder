{ mb, fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.ornaments.implementations.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  ImplementationDescriptor = H.product "MetaBuilderImpl" [
    (H.field "name" H.string)
    (H.field "capabilities" H.attrs)
  ];

  ProjectBuilder = mb.ornaments."project-builder".ProjectBuilder;

  ImplementationsBuilder = H.ornament ProjectBuilder {
    name = "MetaBuilderImplementations";
    constructors.MetaBuilderSpec.fields = [
      { insert = "implementations"; type = H.listOf ImplementationDescriptor.T; }
      { insert = "defaultImpl"; type = H.string; }
      { insert = "allowUserExtensions"; type = H.bool; }
      { keep = "langName"; }
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

  # impl-level smart constructor for ImplementationDescriptor.
  impl = { name, capabilities ? { } }:
    validateOr "impl" ImplementationDescriptor.T {
      _con = "MetaBuilderImpl";
      inherit name capabilities;
    };

  # define produces a typed ImplementationsBuilder spec. Base
  # BuilderSpec fields default to empty so the user can focus on the
  # impl-level configuration; consumers fold the resulting spec into
  # a fuller builder pipeline via `mb.program` etc.
  define =
    { langName
    , implementations
    , defaultImpl
    , allowUserExtensions ? false
    , name ? "${langName}Builder"
    , parameters ? [ ]
    , inputs ? [ ]
    , dependencies ? [ ]
    , tools ? [ ]
    , operations ? [ ]
    , outputs ? [ ]
    , evidence ? [ ]
    }:
    let
      typedImpls = map (i: if (i._con or "") == "MetaBuilderImpl" then i else impl i) implementations;
      defaultPresent =
        lib.any (i: i.name == defaultImpl) typedImpls;
    in
    if !defaultPresent
    then
      throw "implementations.define: defaultImpl '${defaultImpl}' not among declared implementations [${
        lib.concatStringsSep ", " (map (i: i.name) typedImpls)
      }]"
    else {
      _con = "MetaBuilderSpec";
      inherit langName name parameters inputs dependencies tools operations outputs evidence;
      inherit defaultImpl allowUserExtensions;
      implementations = typedImpls;
    };

  # Typed eliminator: select an implementation by name.
  select = spec: implName:
    let match = lib.findFirst (i: i.name == implName) null spec.implementations;
    in if match == null
    then
      throw "implementations.select: unknown implementation '${implName}'. Available: ${
         lib.concatStringsSep ", " (map (i: i.name) spec.implementations)
       }"
    else match;

  # Filter out impls whose name appears in the excluded list. Used by
  # CI matrix construction: given a list of names broken in the current
  # invocation, return the available impls.
  available = spec: excluded:
    lib.filter (i: !(lib.elem i.name excluded)) spec.implementations;

  # Per-implementation projection. For each declared impl, evaluate `f`
  # against the impl descriptor and collect the results keyed by name.
  perImpl = spec: f:
    builtins.listToAttrs (map (i: { inherit (i) name; value = f i; }) spec.implementations);

  # Extend a spec with additional implementations. Rejected at the
  # boundary if `allowUserExtensions` was set false during `define`.
  extend = spec:
    { implementations ? [ ]
    , defaultImpl ? null
    }:
    if !spec.allowUserExtensions
    then throw "implementations.extend: spec for langName '${spec.langName}' declared allowUserExtensions = false"
    else
      let
        typedNew = map (i: if (i._con or "") == "MetaBuilderImpl" then i else impl i) implementations;
        merged = spec.implementations ++ typedNew;
        newDefault = if defaultImpl == null then spec.defaultImpl else defaultImpl;
        defaultPresent = lib.any (i: i.name == newDefault) merged;
      in
      if !defaultPresent
      then throw "implementations.extend: defaultImpl '${newDefault}' not in extended impl set"
      else spec // { implementations = merged; defaultImpl = newDefault; };

  # capitalize "alpha" -> "Alpha". Used to derive the override function
  # name attached to per-impl variants in `withExtras`. Inlined here
  # because the orn does not depend on a shared `metaBuilder.lib`.
  capitalize = s:
    if s == "" then ""
    else lib.toUpper (lib.substring 0 1 s) + lib.substring 1 (-1) s;

  # filterByName : ImplementationDescriptor -> [Source] -> [Source]
  #
  # Resolves implementation-specific sources/dependencies for a given
  # implementation descriptor. Three input shapes are recognised:
  #
  # 1. Plain values (strings, paths, packages without a per-impl
  #    attribute) pass through unchanged.
  # 2. Derivations carrying a per-impl attribute (e.g. a polymorphic
  #    package exposing `{ impl-a = drv; impl-b = drv; ... }`) are
  #    unwrapped to the impl-specific variant.
  # 3. Non-derivation attrsets are treated as per-impl selectors; the
  #    entry matching `impl.name` wins, falling back to `default` if
  #    present. Entries with neither match nor default are dropped.
  #
  # Matches `metaBuilder.lib.implFilter`.
  filterByName = impl: xs:
    let
      isFilterSet = x: builtins.isAttrs x && !(lib.isDerivation x);
      resolveDep = x:
        if lib.isDerivation x && x ? ${impl.name}
        then x.${impl.name}
        else if isFilterSet x
        then x.${impl.name} or x.default
        else x;
    in
    builtins.map resolveDep
      (builtins.filter
        (x: !(isFilterSet x) || x ? ${impl.name} || x ? default)
        xs);

  # defineSystem : consumer-coordination form.
  #
  # Returns the record `{ impls; withExtras; filterByName } [// { extend; }]`
  # — the shape language-builder consumers historically expect. The
  # typed `ImplementationsBuilder` spec is exposed separately via the
  # existing `define` smart-ctor; `defineSystem` keeps an attrset
  # shape for `implementations` (`{ impl-a = {...}; impl-b = {...}; ... }`)
  # so consumers can produce the coordination record directly without
  # re-shaping their input.
  #
  # `withExtras builderFunction args` wraps a builder function (e.g.
  # `library`/`program`) to project per-impl variants under their names
  # (`result.impl-a`, `result.impl-b`, ...), inject `passthru.repl`
  # when the impl exposes `replWith`, and populate `passthru.meta.ci.targets`
  # with the set of impls (minus current, minus `brokenOn`).
  defineSystem = lib.fix (selfDef:
    { langName
    , implementations
    , defaultImpl
    , makeOverridable
    , allowUserExtensions ? false
    }:
    let
      impls = lib.mapAttrs (name: v: { inherit name; } // v) implementations;
      overrideFnName = "override${capitalize langName}";

      withExtras = builderFunction: args:
        let
          drv = (makeOverridable builderFunction) args;
        in
        lib.fix (selfRec:
          let
            base = drv.${overrideFnName}
              (old:
                let
                  currentDrv = builderFunction old;
                  implementation = old.implementation or impls.${defaultImpl};
                  brokenOn = old.brokenOn or [ ];

                  workingImpls = lib.subtractLists
                    (brokenOn ++ [ implementation.name ])
                    (builtins.attrNames impls);

                  replAttr = lib.optionalAttrs (implementation ? replWith) {
                    repl = implementation.replWith [ currentDrv ];
                  };

                  ciMeta = {
                    meta = ((currentDrv.meta or { }) // (currentDrv.passthru.meta or { })) // {
                      ci = ((currentDrv.meta.ci or { }) // (currentDrv.passthru.meta.ci or { })) // {
                        targets = workingImpls;
                      };
                    };
                  };
                in
                {
                  passthru = (currentDrv.passthru or { })
                    // replAttr
                    // ciMeta;
                  __defaultImplName = implementation.name;
                  __brokenOn = brokenOn;
                });

            defaultImplName = base.__defaultImplName or defaultImpl;
            brokenOn = base.__brokenOn or [ ];

            baseWithoutHelper = builtins.removeAttrs base [ "__defaultImplName" "__brokenOn" ];
            implVariants = builtins.listToAttrs (builtins.map
              (i: {
                inherit (i) name;
                value = selfRec.${overrideFnName} (_: {
                  implementation = i;
                });
              })
              (builtins.filter
                (i: !builtins.elem i.name brokenOn && i.name != defaultImplName)
                (builtins.attrValues impls)));
            defaultVariantAlias = { ${defaultImplName} = baseWithoutHelper; };
          in
          baseWithoutHelper
          // defaultVariantAlias
          // implVariants
          // {
            ${overrideFnName} = new:
              withExtras builderFunction (args // new args);
          });

      extendSystem = userConfig:
        if !allowUserExtensions
        then throw "implementations.defineSystem: langName '${langName}' declared allowUserExtensions = false"
        else
          let
            validateImpl = name: imp:
              if !builtins.isAttrs imp
              then throw "Invalid implementation '${name}': must be an attribute set"
              else imp;
            userImpls = lib.mapAttrs validateImpl (userConfig.implementations or { });
            mergedImplementations = implementations // userImpls;
            newDefaultImpl = userConfig.defaultImpl or defaultImpl;
          in
          if !(mergedImplementations ? ${newDefaultImpl})
          then
            throw "Default implementation '${newDefaultImpl}' not in extended impl set: ${
            toString (builtins.attrNames mergedImplementations)
          }"
          else
            selfDef {
              inherit langName makeOverridable allowUserExtensions;
              implementations = mergedImplementations;
              defaultImpl = newDefaultImpl;
            };
    in
    {
      inherit impls withExtras filterByName;
    } // lib.optionalAttrs allowUserExtensions {
      extend = extendSystem;
    });

  # makeBuilder : { implsSystem; createPublicAPI; baseToolEnv } -> API
  #
  # Recursive full-API wrapper. The user supplies an `implsSystem`
  # (the result of `defineSystem`), a `createPublicAPI` projection
  # that maps an impls-system to the builder's public surface
  # (`{ library; program; ... }`), and an optional `baseToolEnv`.
  #
  # Returns the projected API augmented with:
  #   - `implementations` — the current impls-system,
  #   - `toolEnv` — the current tool environment,
  #   - `extend` — re-projects the full API over an extended
  #     impls-system (null when the impls-system disallows extension),
  #   - `withTools` — re-projects the full API over a tool environment
  #     merged with additional packages.
  #
  # Both `extend` and `withTools` recurse through `buildFullAPI` so
  # downstream consumers receive the full builder surface, not just an
  # impls-system. Cross-ornament dep on `mb.ornaments.toolEnv` for the
  # tool-environment algebra.
  makeBuilder =
    { implsSystem
    , createPublicAPI
    , baseToolEnv ? mb.ornaments.toolEnv.empty
    }:
    let
      buildFullAPI = { currentImpls, currentToolEnv }:
        let
          baseAPI = createPublicAPI currentImpls;
          makeExtend = userConfig:
            buildFullAPI {
              currentImpls = currentImpls.extend userConfig;
              currentToolEnv = currentToolEnv;
            };
          makeWithTools = extraTools:
            let
              newToolEnv = mb.ornaments.toolEnv.merge
                currentToolEnv
                (mb.ornaments.toolEnv.create extraTools);
            in
            buildFullAPI {
              currentImpls = currentImpls;
              currentToolEnv = newToolEnv;
            };
        in
        baseAPI // {
          implementations = currentImpls;
          toolEnv = currentToolEnv;
          extend = if currentImpls ? extend then makeExtend else null;
          withTools = makeWithTools;
        };
    in
    buildFullAPI {
      currentImpls = implsSystem;
      currentToolEnv = baseToolEnv;
    };

  value = {
    inherit ImplementationDescriptor ImplementationsBuilder
      impl define select available perImpl extend
      filterByName defineSystem makeBuilder;
    types.implementationDescriptor = ImplementationDescriptor;
    types.implementationsBuilder = ImplementationsBuilder;
    schemas.implementationDescriptor = G.derive.deriveSchema ImplementationDescriptor;
    schemas.implementationsBuilder = G.derive.deriveSchema ImplementationsBuilder;
  };

in
api.mk {
  description = "ImplementationsBuilder ornament over ProjectBuilder: typed multi-implementation refinement plus consumer-coordination helpers. `define` produces a typed spec; `select`/`available`/`perImpl` are typed eliminators. `defineSystem` provides the attrset-shaped record (`{ impls; withExtras; filterByName; extend? }`) that language-builder consumers consume directly. `makeBuilder` recursively wraps a publicAPI projection with `extend`/`withTools` propagation.";
  doc = ''
    # Implementations

    Two complementary surfaces live on this ornament: a **typed-spec**
    layer and a **consumer-coordination** layer.

    ## Typed-spec layer

    A `define` call describes a project that supports multiple
    interchangeable implementations under a single `langName`. Each
    `ImplementationDescriptor` carries a `name` and an open
    `capabilities` attrset for impl-specific metadata (e.g. invocation
    flags, version range, supported targets).

    `select spec implName` returns the descriptor or throws if absent.
    `available spec excluded` filters out broken/excluded impls.
    `perImpl spec f` evaluates `f` against each impl and returns the
    results keyed by impl name — the typed analog of dynamic
    `.''${implName}` projections.

    ## Consumer-coordination layer

    `defineSystem { langName; implementations; defaultImpl;
    makeOverridable; allowUserExtensions ? false }` returns
    `{ impls; withExtras; filterByName }` (plus `extend` when
    extensions are allowed). The `implementations` argument is an
    attrset (`{ impl-a = {...}; impl-b = {...}; ... }`) so consumers
    can produce the coordination record without re-shaping input.

    `withExtras builderFunction args` projects per-impl variants under
    `result.''${implName}` attributes, injects `passthru.repl` when an
    impl exposes `replWith`, and populates `passthru.meta.ci.targets`
    with the implementations minus the current one and `brokenOn`.

    `filterByName impl xs` resolves implementation-specific
    sources/dependencies — plain values pass through; non-derivation
    attrsets are treated as per-impl selectors with optional `default`.

    `makeBuilder { implsSystem; createPublicAPI; baseToolEnv }`
    recursively wraps a `createPublicAPI` projection with `extend`
    and `withTools` so downstream consumers receive the full builder
    surface (not just an impls-system) after extension or tool
    augmentation. Cross-ornament dependency on `mb.ornaments.toolEnv`.
  '';
  inherit value;
  tests =
    let
      # Stub `makeOverridable` mirroring the shape language-builder
      # consumers historically produce: applies `f` to args, exposes
      # `override<Lang>` for recursive override. langName "alpha" →
      # `overrideAlpha`.
      mkOverridable = f: orig: (f orig) // {
        overrideAlpha = new: mkOverridable f (orig // (new orig));
      };

      # Pass-through stub builder: preserves all input args so that
      # withExtras's overlay-injected fields (`passthru`/`__defaultImplName`/
      # `__brokenOn`) survive the second-round `f (args // overlay args)`
      # call. Real builders (`library`/`program`) do this via explicit
      # `passthru = (currentPassthru or {}) // ...` merges.
      stubBuilder = { implementation ? null, ... }@args:
        let implName = if implementation == null then "default" else implementation.name;
        in args // {
          name = "out-${implName}";
          passthru = args.passthru or { };
          meta = args.meta or { };
        };

      sampleSystem = defineSystem {
        langName = "alpha";
        implementations = {
          impl-a = { replWith = _: { type = "derivation"; name = "repl-impl-a"; outPath = "/nix/store/fake-repl-impl-a"; }; };
          impl-b = { };
          impl-c = { };
        };
        defaultImpl = "impl-a";
        makeOverridable = mkOverridable;
      };

      sampleExtSystem = defineSystem {
        langName = "alpha";
        implementations = { impl-a = { }; };
        defaultImpl = "impl-a";
        makeOverridable = mkOverridable;
        allowUserExtensions = true;
      };

      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
    in
    {
      "impl-smart-ctor-validates" = {
        expr = (impl { name = "impl-a"; capabilities = { entrypoint = "impl-a"; }; }).name;
        expected = "impl-a";
      };

      "define-builds-validated-spec" = {
        expr =
          let
            spec = define {
              langName = "alpha";
              implementations = [
                { name = "impl-a"; }
                { name = "impl-b"; }
                { name = "impl-c"; }
              ];
              defaultImpl = "impl-a";
            };
          in
          { inherit (spec) langName defaultImpl; implCount = builtins.length spec.implementations; };
        expected = { langName = "alpha"; defaultImpl = "impl-a"; implCount = 3; };
      };

      "define-rejects-default-not-in-impls" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (define {
            langName = "alpha";
            implementations = [{ name = "impl-a"; }];
            defaultImpl = "impl-c";
          })
          null)).success;
        expected = false;
      };

      "select-finds-named-impl" = {
        expr = (select
          (define {
            langName = "alpha";
            implementations = [{ name = "impl-a"; capabilities = { ver = "1.0"; }; } { name = "impl-b"; }];
            defaultImpl = "impl-a";
          }) "impl-b").name;
        expected = "impl-b";
      };

      "select-throws-for-unknown-impl" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (select
            (define {
              langName = "alpha";
              implementations = [{ name = "impl-a"; }];
              defaultImpl = "impl-a";
            }) "nonexistent")
          null)).success;
        expected = false;
      };

      "available-filters-excluded" = {
        expr = map (i: i.name) (available
          (define {
            langName = "alpha";
            implementations = [{ name = "impl-a"; } { name = "impl-b"; } { name = "impl-c"; }];
            defaultImpl = "impl-a";
          }) [ "impl-b" ]);
        expected = [ "impl-a" "impl-c" ];
      };

      "perImpl-projection-builds-typed-attrset" = {
        expr = perImpl
          (define {
            langName = "alpha";
            implementations = [{ name = "impl-a"; } { name = "impl-b"; }];
            defaultImpl = "impl-a";
          })
          (i: "build-${i.name}");
        expected = { "impl-a" = "build-impl-a"; "impl-b" = "build-impl-b"; };
      };

      "extend-rejects-when-user-extensions-disabled" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (extend
            (define {
              langName = "alpha";
              implementations = [{ name = "impl-a"; }];
              defaultImpl = "impl-a";
            })
            { implementations = [{ name = "user-impl"; }]; })
          null)).success;
        expected = false;
      };

      "extend-appends-when-allowed" = {
        expr =
          let
            base = define {
              langName = "alpha";
              implementations = [{ name = "impl-a"; }];
              defaultImpl = "impl-a";
              allowUserExtensions = true;
            };
            extended = extend base { implementations = [{ name = "user-impl"; }]; };
          in
          map (i: i.name) extended.implementations;
        expected = [ "impl-a" "user-impl" ];
      };

      "schemas-non-empty" = {
        expr =
          (value.schemas.implementationDescriptor.oneOf or [ ]) != [ ]
          && (value.schemas.implementationsBuilder.oneOf or [ ]) != [ ];
        expected = true;
      };

      "filterByName-passes-plain-sources" = {
        expr = filterByName { name = "impl-a"; } [ "pkg-x" "pkg-y" ];
        expected = [ "pkg-x" "pkg-y" ];
      };

      "filterByName-selects-per-impl-entry" = {
        expr = filterByName { name = "impl-a"; } [
          "pkg-x"
          { impl-a = "alpha-pkg"; impl-b = "beta-pkg"; }
        ];
        expected = [ "pkg-x" "alpha-pkg" ];
      };

      "filterByName-falls-back-to-default" = {
        expr = filterByName { name = "impl-c"; } [
          { impl-a = "alpha-pkg"; default = "fallback-pkg"; }
        ];
        expected = [ "fallback-pkg" ];
      };

      "filterByName-drops-when-no-match-and-no-default" = {
        expr = filterByName { name = "impl-c"; } [
          "pkg-x"
          { impl-a = "alpha-pkg"; impl-b = "beta-pkg"; }
        ];
        expected = [ "pkg-x" ];
      };

      "defineSystem-injects-name-into-each-impl" = {
        expr = builtins.sort builtins.lessThan (lib.mapAttrsToList (n: v: v.name) sampleSystem.impls);
        expected = [ "impl-a" "impl-b" "impl-c" ];
      };

      "defineSystem-returns-filterByName-helper" = {
        expr = sampleSystem.filterByName { name = "impl-a"; } [ "pkg-x" { impl-a = "alpha-pkg"; impl-b = "beta-pkg"; } ];
        expected = [ "pkg-x" "alpha-pkg" ];
      };

      "defineSystem-without-extensions-omits-extend" = {
        expr = sampleSystem ? extend;
        expected = false;
      };

      "defineSystem-with-extensions-exposes-extend" = {
        expr = sampleExtSystem ? extend;
        expected = true;
      };

      "defineSystem-extend-rebuilds-system" = {
        expr =
          let
            ext = sampleExtSystem.extend {
              implementations = { user-impl = { }; };
            };
          in
          builtins.sort builtins.lessThan (builtins.attrNames ext.impls);
        expected = [ "impl-a" "user-impl" ];
      };

      "withExtras-projects-per-impl-variants" = {
        expr =
          let
            result = sampleSystem.withExtras stubBuilder { srcs = [ ]; };
            implKeys = lib.filter
              (n: n == "impl-a" || n == "impl-b" || n == "impl-c")
              (builtins.attrNames result);
          in
          builtins.sort builtins.lessThan implKeys;
        expected = [ "impl-a" "impl-b" "impl-c" ];
      };

      "withExtras-exposes-override-function" = {
        expr =
          let result = sampleSystem.withExtras stubBuilder { srcs = [ ]; };
          in result ? overrideAlpha;
        expected = true;
      };

      "withExtras-ci-targets-exclude-current-impl" = {
        expr =
          let result = sampleSystem.withExtras stubBuilder { srcs = [ ]; };
          in builtins.sort builtins.lessThan result.passthru.meta.ci.targets;
        expected = [ "impl-b" "impl-c" ];
      };

      "withExtras-brokenOn-filters-ci-targets" = {
        expr =
          let result = sampleSystem.withExtras stubBuilder { srcs = [ ]; brokenOn = [ "impl-b" ]; };
          in result.passthru.meta.ci.targets;
        expected = [ "impl-c" ];
      };

      "withExtras-injects-passthru-repl-when-impl-has-replWith" = {
        expr =
          let result = sampleSystem.withExtras stubBuilder { srcs = [ ]; };
          in result.passthru ? repl;
        expected = true;
      };

      "makeBuilder-exposes-publicAPI-toolEnv-and-withTools" = {
        expr =
          let
            api' = makeBuilder {
              implsSystem = sampleSystem;
              createPublicAPI = _: { greet = "hello"; };
            };
          in
          {
            greet = api'.greet;
            hasToolEnv = api' ? toolEnv;
            hasWithTools = api' ? withTools;
            hasImplementations = api' ? implementations;
          };
        expected = {
          greet = "hello";
          hasToolEnv = true;
          hasWithTools = true;
          hasImplementations = true;
        };
      };

      "makeBuilder-extend-null-when-system-disallows-extensions" = {
        expr =
          let
            api' = makeBuilder {
              implsSystem = sampleSystem;
              createPublicAPI = _: { };
            };
          in
          api'.extend;
        expected = null;
      };

      "makeBuilder-extend-recurses-into-full-api" = {
        expr =
          let
            api' = makeBuilder {
              implsSystem = sampleExtSystem;
              createPublicAPI = _: { greet = "hi"; };
            };
            extended = api'.extend { implementations = { user-impl = { }; }; };
          in
          { greet = extended.greet; canExtendAgain = extended ? extend; };
        expected = { greet = "hi"; canExtendAgain = true; };
      };

      "makeBuilder-withTools-merges-into-toolEnv" = {
        expr =
          let
            api' = makeBuilder {
              implsSystem = sampleSystem;
              createPublicAPI = _: { };
            };
            augmented = api'.withTools { alpha = stubDrv "tool-alpha"; };
          in
          builtins.attrNames (mb.ornaments.toolEnv.toolPackages augmented.toolEnv);
        expected = [ "alpha" ];
      };
    };
}
