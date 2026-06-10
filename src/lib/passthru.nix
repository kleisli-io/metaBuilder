{ fx, api, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.lib.passthru.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  PassthruSpec = H.product "MetaBuilderPassthru" [
    (H.field "langName" H.string)
    (H.field "baseName" H.string)
    (H.field "baseDeps" (H.listOf H.any))
    (H.field "extensions" H.attrs)
  ];

  create = { langName, baseName, baseDeps, extensions ? { } }:
    validateOr "create" PassthruSpec.T {
      _con = "MetaBuilderPassthru";
      inherit langName baseName baseDeps extensions;
    };

  value = {
    inherit PassthruSpec create;
    types.passthru = PassthruSpec;
    schemas.passthru = G.derive.deriveSchema PassthruSpec;
  };

in
api.mk {
  description = "metaBuilder passthru lib: typed language-tagged package metadata. PassthruSpec carries `langName`, `baseName`, `baseDeps`, and an open `extensions` attrset; the typed record itself is the API — consumers read fields directly rather than through dynamic field names.";
  doc = ''
    # Passthru

    `create` builds a typed `PassthruSpec` from `{ langName; baseName;
    baseDeps; extensions ? {} }`. The spec is the canonical structured
    representation of language-tagged package metadata.

    Hash stability invariant: a `PassthruSpec` depends only on its
    constructor arguments. Two `create` calls with equal inputs produce
    equal specs; no ambient state, no derivation references at the
    spec level.
  '';
  inherit value;
  tests = {
    "create-typed-record-roundtrips" = {
      expr =
        let
          p = create {
            langName = "alpha";
            baseName = "myPkg";
            baseDeps = [ "dep-x" "dep-y" ];
            extensions = { installPath = "$out/share/alpha/myPkg"; };
          };
        in
        { inherit (p) langName baseName baseDeps extensions; };
      expected = {
        langName = "alpha";
        baseName = "myPkg";
        baseDeps = [ "dep-x" "dep-y" ];
        extensions = { installPath = "$out/share/alpha/myPkg"; };
      };
    };

    "create-hash-stable-on-equal-input" = {
      expr =
        let
          a = create { langName = "alpha"; baseName = "p"; baseDeps = [ ]; };
          b = create { langName = "alpha"; baseName = "p"; baseDeps = [ ]; };
        in
        a == b;
      expected = true;
    };

    "create-rejects-non-string-langName" = {
      expr = (builtins.tryEval (builtins.deepSeq
        (create { langName = 42; baseName = "p"; baseDeps = [ ]; })
        null)).success;
      expected = false;
    };

    "schema-non-empty" = {
      expr = (value.schemas.passthru.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
