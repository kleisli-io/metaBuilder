{ mb, api, ... }:

let
  impls = mb.ornaments.implementations;
  deps = mb.ornaments.dependencies;
  testing = mb.ornaments.testing;
  service = mb.ornaments.service;

  # Stub derivation thunk carrier for ServiceSpec.package. The
  # eliminators exercised below project name/description/capabilities/
  # protocols/config and do not read .package; the stub is supplied
  # only to satisfy the typed shape demanded by `mb.operations.service`.
  stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };

  alphaLifecycle = mb.operations.capabilityCategory {
    name = "lifecycle";
    capabilities = [
      (mb.operations.capability { name = "start"; })
      (mb.operations.capability { name = "stop"; })
    ];
  };
  alphaCaps = mb.operations.capabilitySet { categories = [ alphaLifecycle ]; };
  alphaProto = mb.operations.protocol {
    name = "rpc";
    transport = mb.operations.transports.TCP;
    serialization = mb.operations.serializations.JSON;
    defaultPort = 9000;
    portEnvVar = "ALPHA_PORT";
    capabilities = alphaCaps;
  };

  # Typed ServiceSpec built via the ornament smart-ctor. The eager
  # capability/protocol cross-check fires here (inside `service.define`
  # → `mb.operations.service`); ServiceSpec fields are then layered
  # onto the composed BuilderSpec below.
  alphaService = service.define {
    name = "alphaProject";
    description = "Composed four-way fixture";
    package = stubDrv "alphaProject-binary";
    capabilities = alphaCaps;
    protocols = [ alphaProto ];
  };

  # Four-way composed fixture: a `BuilderSpec`-tagged record that
  # simultaneously carries ImplementationsBuilder, DependenciesBuilder,
  # TestingBuilder, and ServiceSpec fields. The two algebras' typed
  # records cannot share a single _con tag, so the composed value
  # keeps `MetaBuilderSpec` and additively layers the ServiceSpec
  # fields from `alphaService`. Each ornament's eliminators are
  # field-projecting and operate on the shared value without conflict.
  composedSpec = {
    _con = "MetaBuilderSpec";
    langName = "alpha";
    name = alphaService.name;
    description = alphaService.description;
    parameters = [ ];
    inputs = [ ];
    dependencies = [ ];
    tools = [ ];
    operations = alphaService.operations;
    outputs = [ ];
    evidence = [ ];

    # ImplementationsBuilder fields
    implementations = [
      (impls.impl { name = "impl-a"; capabilities = { tag = "impl-a"; }; })
      (impls.impl { name = "impl-b"; })
      (impls.impl { name = "impl-c"; })
    ];
    defaultImpl = "impl-a";
    allowUserExtensions = true;

    # DependenciesBuilder fields
    dependencyShape = deps.uniform { langName = "alpha"; };

    # TestingBuilder fields
    testSuite = testing.testSuite {
      name = "alpha-suite";
      cases = [
        { name = "boot"; body = true; }
        { name = "smoke"; body = (1 + 1) == 2; }
      ];
    };

    # ServiceSpec fields layered from the typed `alphaService`.
    inherit (alphaService) package capabilities protocols config;
  };

in
api.mk {
  description = "Runtime composition test: Implementations × Dependencies × Testing × Service four-way stack on one shared spec. Demonstrates that the builder.* and runtime.* algebras compose at the value level — each ornament's typed eliminators operate on the shared value without conflict.";
  doc = ''
    # Runtime Composition Stack

    Extends `tests/composition.nix` from three ornaments to four by
    layering `Service` (over the runtime.* effect algebra) onto the
    shared `BuilderSpec`-tagged record. The composed spec carries:

    - Bucket-2 fields: `implementations`/`defaultImpl`,
      `dependencyShape`, `testSuite`.
    - ServiceSpec fields: `package`, `capabilities`, `protocols`,
      `config`.
    - Shared base fields: `name`, `description`.
    - `operations`: the runtime-op program emitted by
      `service.define` — `declareCapability(c1) … declareCapability(cN)`
      `+ declareProtocol(p1) … declareProtocol(pM) + declareService +`
      `materializeUnit`.

    The two algebras' typed records keep disjoint `_con` tags
    (`MetaBuilderSpec` vs `MetaBuilderServiceSpec`); the composed
    value keeps the BuilderSpec tag and additively layers the
    ServiceSpec fields from a typed `alphaService` (built via
    `service.define`, so the eager capability/protocol cross-check
    fires at fixture construction). Each ornament's eliminators —
    `impls.select`, `deps.matchShape`, `testing.runPure`,
    `service.compatibility`, `service.descriptor` — are
    field-projecting and operate on the shared value without
    namespace conflict.
  '';
  value = { inherit composedSpec; };
  tests = {
    "impl-eliminator-operates-on-composed-spec" = {
      expr = (impls.select composedSpec "impl-b").name;
      expected = "impl-b";
    };

    "deps-dispatcher-operates-on-composed-spec" = {
      expr = deps.matchShape
        {
          uniform = a: "uniform:${a.langName}";
          partitioned = a: "partitioned:${a.langName}/${a.pathField}";
          multiTyped = a: "multi:${toString (builtins.length a.types)}";
        }
        composedSpec.dependencyShape;
      expected = "uniform:alpha";
    };

    "testing-runPure-evaluates-composed-spec-suite" = {
      expr = (testing.runPure composedSpec.testSuite).allPass;
      expected = true;
    };

    "service-compatibility-operates-on-composed-spec" = {
      expr = (service.compatibility composedSpec).valid;
      expected = true;
    };

    "service-descriptor-operates-on-composed-spec" = {
      expr =
        let d = service.descriptor composedSpec; in {
          inherit (d) name description;
          protoNames = map (p: p.name) d.protocols;
          protoTransport = (builtins.head d.protocols).transport;
          protoSerialization = (builtins.head d.protocols).serialization;
          jsonRoundtrips = builtins.isString (builtins.toJSON d);
        };
      expected = {
        name = "alphaProject";
        description = "Composed four-way fixture";
        protoNames = [ "rpc" ];
        protoTransport = "TCP";
        protoSerialization = "JSON";
        jsonRoundtrips = true;
      };
    };

    "all-four-ornament-fields-coexist" = {
      expr = {
        hasLangName = composedSpec ? langName;
        hasImpls = builtins.length composedSpec.implementations;
        hasDepShape = composedSpec.dependencyShape._con;
        hasTestSuite = composedSpec.testSuite.name;
        hasPackage = composedSpec ? package;
        categoryCount = builtins.length composedSpec.capabilities.categories;
        protoCount = builtins.length composedSpec.protocols;
        opCount = builtins.length composedSpec.operations;
        opSequence = map (o: o._con) composedSpec.operations;
      };
      expected = {
        hasLangName = true;
        hasImpls = 3;
        hasDepShape = "Uniform";
        hasTestSuite = "alpha-suite";
        hasPackage = true;
        categoryCount = 1;
        protoCount = 1;
        opCount = 4;
        opSequence = [
          "declareCapability"
          "declareProtocol"
          "declareService"
          "materializeUnit"
        ];
      };
    };
  };
}
