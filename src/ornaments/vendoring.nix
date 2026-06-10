{ mb, fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.ornaments.vendoring.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  # VendoringContract captures the structural requirements a vendored
  # package must satisfy. `required` is the list of typed fields the
  # package must declare; `optional` is the list of fields the framework
  # may consume if present. The contract is itself a typed datatype so
  # consumers can introspect and validate against it.
  VendoringContract = H.product "MetaBuilderVendoringContract" [
    (H.field "required" (H.listOf H.string))
    (H.field "optional" (H.listOf H.string))
    (H.field "description" H.string)
  ];

  ProjectBuilder = mb.ornaments."project-builder".ProjectBuilder;

  VendoringBuilder = H.ornament ProjectBuilder {
    name = "MetaBuilderVendoring";
    constructors.MetaBuilderSpec.fields = [
      { insert = "contract"; type = VendoringContract.T; }
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

  mkContract = { required ? [ ], optional ? [ ], description ? "" }:
    validateOr "mkContract" VendoringContract.T {
      _con = "MetaBuilderVendoringContract";
      inherit required optional description;
    };

  # The default contract every language-specific project is expected to
  # satisfy: a typed `name` plus a list of direct dependencies. Optional
  # extensions cover versioning, install path, and registry membership.
  defaultContract = mkContract {
    required = [ "name" "deps" ];
    optional = [ "version" "path" "isSourcePackage" "registry" ];
    description = ''
      Vendored packages declare a typed `name` and a list of direct
      `deps`. Optional fields carry version metadata, install path,
      source-vs-binary marker, and registry membership.
    '';
  };

  define =
    { langName
    , contract ? defaultContract
    , name ? "${langName}Vendoring"
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
      inherit langName name parameters inputs dependencies tools operations outputs evidence;
      inherit contract;
    };

  # Validate that a metadata attrset declares every contract-required
  # field. Returns the list of missing field names (empty list ⇒ valid).
  checkRequired = contract: metadata:
    lib.filter (field: !(builtins.hasAttr field metadata)) contract.required;

  value = {
    inherit VendoringContract VendoringBuilder
      mkContract defaultContract define checkRequired;
    types.vendoringContract = VendoringContract;
    types.vendoringBuilder = VendoringBuilder;
    schemas.vendoringContract = G.derive.deriveSchema VendoringContract;
    schemas.vendoringBuilder = G.derive.deriveSchema VendoringBuilder;
  };

in
api.mk {
  description = "VendoringBuilder ornament over ProjectBuilder: a typed contract describing the structural fields a vendored package must declare. The contract itself is a typed datatype; `checkRequired` reports missing fields against a metadata attrset.";
  doc = ''
    # Vendoring

    `mkContract { required; optional; description; }` builds a typed
    `VendoringContract` declaring the structural requirements a
    vendored package must satisfy. `defaultContract` is the framework's
    standard contract (`name`, `deps` required; `version`, `path`,
    source/registry markers optional).

    `checkRequired contract metadata` returns the list of contract-
    required fields missing from `metadata` (empty list ⇒ valid).

    `define { langName; contract; … }` produces a typed
    `VendoringBuilder` spec for downstream composition.
  '';
  inherit value;
  tests = {
    "defaultContract-declares-name-and-deps" = {
      expr = defaultContract.required;
      expected = [ "name" "deps" ];
    };

    "mkContract-builds-validated-record" = {
      expr =
        let
          c = mkContract {
            required = [ "foo" ];
            optional = [ "bar" ];
            description = "test";
          };
        in
        { inherit (c) required optional description; };
      expected = {
        required = [ "foo" ];
        optional = [ "bar" ];
        description = "test";
      };
    };

    "checkRequired-reports-missing-fields" = {
      expr = checkRequired defaultContract { name = "x"; };
      expected = [ "deps" ];
    };

    "checkRequired-empty-when-all-present" = {
      expr = checkRequired defaultContract { name = "x"; deps = [ ]; };
      expected = [ ];
    };

    "define-builds-vendoring-spec" = {
      expr =
        let s = define { langName = "alpha"; };
        in { inherit (s) langName; required = s.contract.required; };
      expected = { langName = "alpha"; required = [ "name" "deps" ]; };
    };

    "schemas-non-empty" = {
      expr =
        (value.schemas.vendoringContract.oneOf or [ ]) != [ ]
        && (value.schemas.vendoringBuilder.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
