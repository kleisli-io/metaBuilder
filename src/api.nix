{ lib }:

rec {
  mk =
    { doc ? ""
    , title ? ""
    , description ? ""
    , signature ? ""
    , sections ? [ ]
    , sourceFiles ? [ ]
    , value
    , tests ? { }
    , docHidden ? false
    }:
    {
      _type = "metaBuilder-api";
      inherit title doc description signature sections sourceFiles value tests docHidden;
    } // (lib.optionalAttrs (lib.isFunction value) { __functor = _self: value; });

  leaf = mk;
  namespace = mk;

  extractValue = x:
    if (x._type or null) == "metaBuilder-api" then extractValue x.value
    else if builtins.isAttrs x && !(x ? _tag) && !(x ? _htag)
    then builtins.mapAttrs (_: extractValue) x
    else x;

  isApiChild = v:
    builtins.isAttrs v
    && !(v ? _tag)
    && (v._type or null) == "metaBuilder-api";

  isDocChild = v:
    isApiChild v && !(v.docHidden or false);

  extractTests = x:
    if (x._type or null) == "metaBuilder-api" then
      let
        ownTests = lib.mapAttrs'
          (name: test: {
            name = "test-${name}";
            value = test;
          })
          x.tests;
        childTests =
          if builtins.isAttrs x.value
          then walkNsTests x.value
          else { };
      in
      ownTests // childTests
    else if builtins.isAttrs x && !(x ? _tag)
    then walkNsTests x
    else { };

  # Lazy per namespace: names at each level depend only on that level's
  # attrs, never on subtree contents. Empty namespaces are kept (pruning
  # them would force full-tree assembly to select a single test) and
  # nix-unit's "test*"-name convention is escaped here, where the
  # test-vs-namespace distinction is known without forcing values.
  walkNsTests = ns:
    lib.mapAttrs'
      (name: v: {
        name = if lib.hasPrefix "test" name then "suite-${name}" else name;
        value = extractTests v;
      })
      (lib.filterAttrs (_: v: isApiChild v) ns);

  extractDocs = x:
    if (x._type or null) == "metaBuilder-api" && !(x.docHidden or false)
    then
      { inherit (x) title doc description signature sections sourceFiles tests; } //
      (if builtins.isAttrs x.value && !(x.value ? _tag)
      then walkNsDocs x.value
      else { })
    else if builtins.isAttrs x && !(x ? _tag)
    then walkNsDocs x
    else { };

  walkNsDocs = ns:
    let
      documented = lib.filterAttrs (_: v: isDocChild v) ns;
      rendered = lib.mapAttrs (_: extractDocs) documented;
    in
    lib.filterAttrs (_: v: v != { }) rendered;

  runTests = tests:
    let
      flatten = prefix: attrs:
        lib.foldlAttrs
          (acc: name: value:
            let path = if prefix == "" then name else "${prefix}.${name}";
            in if builtins.isAttrs value && value ? expr && value ? expected
            then acc // { ${path} = value; }
            else if builtins.isAttrs value
            then acc // (flatten path value)
            else acc
          )
          { }
          attrs;
      flat = flatten "" tests;
      results = builtins.mapAttrs
        (name: test:
          let
            tried = builtins.tryEval test.expr;
            actual =
              if tried.success
              then tried.value
              else { __evalFailed = true; };
            compared =
              if tried.success
              then builtins.tryEval (tried.value == test.expected)
              else { success = false; value = false; };
            pass = compared.success && compared.value;
          in
          { inherit name actual; expected = test.expected; inherit pass; }
        )
        flat;
      passedNames = lib.filterAttrs (_: r: r.pass) results;
      failedNames = lib.filterAttrs (_: r: !r.pass) results;
      nPassed = builtins.length (builtins.attrNames passedNames);
      nFailed = builtins.length (builtins.attrNames failedNames);
    in
    {
      inherit results;
      passed = passedNames;
      failed = failedNames;
      allPass = nFailed == 0;
      summary = "${toString nPassed} passed, ${toString nFailed} failed";
    };
}
