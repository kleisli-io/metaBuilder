{ mb, api, lib, ... }:

let
  impls = mb.ornaments.implementations;
  deps = mb.ornaments.dependencies;
  testing = mb.ornaments.testing;

  # Composition fixture: a spec that simultaneously satisfies the
  # ImplementationsBuilder, DependenciesBuilder, and TestingBuilder
  # ornament fields. Each ornament's typed eliminators operate on the
  # same value, demonstrating that the three project-level
  # refinements stack without conflict at the value level.
  composedSpec = {
    _con = "MetaBuilderSpec";
    langName = "alpha";
    name = "alphaProject";
    parameters = [ ];
    inputs = [ ];
    dependencies = [ ];
    tools = [ ];
    operations = [ ];
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
  };

in
api.mk {
  description = "Composition test: Implementations × Dependencies × Testing stack on one typed spec. Each ornament's typed eliminators operate on the shared value without conflict, demonstrating that project-level refinements compose at the value level.";
  doc = ''
    # Composition Stack

    Demonstrates that three ornament-shaped refinements
    (`Implementations`, `Dependencies`, `Testing`) can coexist on a
    single typed `BuilderSpec` value. The fixture below carries fields
    from all three ornaments simultaneously; each ornament's typed
    eliminators (`select`, `matchShape`, `runPure`) operate on the
    same value without conflict.

    `Dependencies` ornaments `BuilderSpec` directly while the other
    three refine `ProjectBuilder`. At the value level, both branches
    contribute disjoint fields to the same record, so a fully-
    composed project simply carries the union.
  '';
  value = { inherit composedSpec; };
  tests = {
    "impl-eliminator-operates-on-composed-spec" = {
      expr = (impls.select composedSpec "impl-b").name;
      expected = "impl-b";
    };

    "available-filters-broken-on-composed-spec" = {
      expr = map (i: i.name) (impls.available composedSpec [ "impl-b" ]);
      expected = [ "impl-a" "impl-c" ];
    };

    "perImpl-projection-on-composed-spec" = {
      expr = impls.perImpl composedSpec (i: "${i.name}-built");
      expected = { "impl-a" = "impl-a-built"; "impl-b" = "impl-b-built"; "impl-c" = "impl-c-built"; };
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

    "all-three-ornament-fields-coexist" = {
      expr = {
        hasLangName = composedSpec ? langName;
        hasImpls = builtins.length composedSpec.implementations;
        hasDepShape = composedSpec.dependencyShape._con;
        hasTestSuite = composedSpec.testSuite.name;
      };
      expected = {
        hasLangName = true;
        hasImpls = 3;
        hasDepShape = "Uniform";
        hasTestSuite = "alpha-suite";
      };
    };
  };
}
