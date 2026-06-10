{ fx, api, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.lib.bundled.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  BundledSpec = H.product "MetaBuilderBundled" [
    (H.field "langName" H.string)
    (H.field "packageName" H.string)
    (H.field "extraAttrs" H.attrs)
  ];

  create = { langName, packageName, extraAttrs ? { } }:
    validateOr "create" BundledSpec.T {
      _con = "MetaBuilderBundled";
      inherit langName packageName extraAttrs;
    };

  # The typed `_con = "MetaBuilderBundled"` tag is the discriminator:
  # a value is bundled iff it carries that constructor tag.
  isBundled = value:
    builtins.isAttrs value
    && (value._con or null) == "MetaBuilderBundled";

  value = {
    inherit BundledSpec create isBundled;
    types.bundled = BundledSpec;
    schemas.bundled = G.derive.deriveSchema BundledSpec;
  };

in
api.mk {
  description = "metaBuilder bundled lib: typed descriptor for system-bundled packages provided by a language implementation. The constructor tag itself is the bundled-vs-custom discriminator — no sentinel-field convention required.";
  doc = ''
    # Bundled

    `create` builds a typed `BundledSpec` from `{ langName; packageName;
    extraAttrs ? {} }`. The typed record's constructor tag
    (`_con = "MetaBuilderBundled"`) is the discriminator that
    distinguishes bundled descriptors from anything else; callers
    can check membership via `isBundled`.
  '';
  inherit value;
  tests = {
    "create-typed-record-roundtrips" = {
      expr =
        let
          b = create {
            langName = "alpha";
            packageName = "core";
          };
        in
        { inherit (b) langName packageName extraAttrs; };
      expected = {
        langName = "alpha";
        packageName = "core";
        extraAttrs = { };
      };
    };

    "create-hash-stable-on-equal-input" = {
      expr =
        let
          a = create { langName = "alpha"; packageName = "pkg-x"; };
          b = create { langName = "alpha"; packageName = "pkg-x"; };
        in
        a == b;
      expected = true;
    };

    "isBundled-discriminates-by-constructor-tag" = {
      expr = {
        bundled = isBundled (create { langName = "alpha"; packageName = "pkg-y"; });
        untagged = isBundled { langName = "alpha"; packageName = "pkg-y"; };
        wrongTag = isBundled { _con = "Something"; };
      };
      expected = { bundled = true; untagged = false; wrongTag = false; };
    };

    "schema-non-empty" = {
      expr = (value.schemas.bundled.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
