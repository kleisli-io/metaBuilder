{ mb, fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.ornaments.testing.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  # A TestCase carries a name and an opaque `body` — pure Nix value to
  # evaluate, derivation to build, or arbitrary spec interpreted by a
  # downstream runner. The framework typing stops at the case
  # declaration; how the body executes is the runner's contract.
  TestCase = H.product "MetaBuilderTestCase" [
    (H.field "name" H.string)
    (H.field "body" H.any)
  ];

  TestSuite = H.product "MetaBuilderTestSuite" [
    (H.field "name" H.string)
    (H.field "cases" (H.listOf TestCase.T))
  ];

  ProjectBuilder = mb.ornaments."project-builder".ProjectBuilder;

  TestingBuilder = H.ornament ProjectBuilder {
    name = "MetaBuilderTesting";
    constructors.MetaBuilderSpec.fields = [
      { insert = "testSuite"; type = TestSuite.T; }
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

  testCase = { name, body }:
    validateOr "testCase" TestCase.T {
      _con = "MetaBuilderTestCase";
      inherit name body;
    };

  testSuite = { name, cases ? [ ] }:
    let typed = map (c: if (c._con or "") == "MetaBuilderTestCase" then c else testCase c) cases;
    in validateOr "testSuite" TestSuite.T {
      _con = "MetaBuilderTestSuite";
      inherit name;
      cases = typed;
    };

  define =
    { langName
    , testSuite
    , name ? "${langName}Tests"
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
      inherit testSuite;
    };

  # Typed eliminator: select a case by name.
  selectCase = suite: caseName:
    let match = lib.findFirst (c: c.name == caseName) null suite.cases;
    in if match == null
    then throw "testing.selectCase: unknown case '${caseName}' in suite '${suite.name}'"
    else match;

  # Pure-Nix evaluator: runs every case whose body is a `bool` and
  # collects pass/fail summaries. Cases with non-boolean bodies are
  # left to the consumer's runner.
  runPure = suite:
    let
      classify = c:
        let
          t = builtins.tryEval c.body;
          passed = t.success && t.value == true;
        in
        {
          inherit (c) name;
          status =
            if !t.success then "ERROR"
            else if !builtins.isBool t.value then "SKIP"
            else if t.value then "PASS"
            else "FAIL";
          pass = passed;
        };
      classified = map classify suite.cases;
      tally = pred: builtins.length (builtins.filter pred classified);
    in
    {
      suite = suite.name;
      results = classified;
      passed = tally (c: c.status == "PASS");
      failed = tally (c: c.status == "FAIL" || c.status == "ERROR");
      skipped = tally (c: c.status == "SKIP");
      allPass = lib.all (c: c.pass) classified;
    };

  value = {
    inherit TestCase TestSuite TestingBuilder
      testCase testSuite define selectCase runPure;
    types.testCase = TestCase;
    types.testSuite = TestSuite;
    types.testingBuilder = TestingBuilder;
    schemas.testCase = G.derive.deriveSchema TestCase;
    schemas.testSuite = G.derive.deriveSchema TestSuite;
    schemas.testingBuilder = G.derive.deriveSchema TestingBuilder;
  };

in
api.mk {
  description = "TestingBuilder ornament over ProjectBuilder: typed test-suite declarations. `testCase` / `testSuite` smart constructors validate at the boundary; `selectCase` is a typed eliminator; `runPure` evaluates boolean-bodied cases in pure Nix.";
  doc = ''
    # Testing

    A `TestSuite` is a typed list of named `TestCase` records. Each
    case carries an opaque `body` — the framework stops typing at the
    case boundary so consumers can stash pure-Nix booleans, derivation
    builders, or arbitrary runner specs.

    `runPure suite` evaluates every case whose body is a boolean and
    reports per-case `PASS` / `FAIL` / `SKIP` / `ERROR` classification
    plus a `passed` / `failed` / `skipped` tally and an `allPass`
    flag. Non-boolean bodies are skipped — that path is for
    derivation-driven or runner-driven tests handled downstream.
  '';
  inherit value;
  tests = {
    "testCase-validates-at-boundary" = {
      expr = (testCase { name = "trivial"; body = true; }).name;
      expected = "trivial";
    };

    "testSuite-typed-cases-have-tag" = {
      expr =
        let
          s = testSuite {
            name = "demo";
            cases = [
              { name = "a"; body = true; }
              { name = "b"; body = false; }
            ];
          };
        in
        map (c: c._con) s.cases;
      expected = [ "MetaBuilderTestCase" "MetaBuilderTestCase" ];
    };

    "selectCase-finds-named-case" = {
      expr = (selectCase
        (testSuite {
          name = "demo";
          cases = [{ name = "a"; body = 1; } { name = "b"; body = 2; }];
        }) "b").body;
      expected = 2;
    };

    "runPure-tallies-pass-fail-skip" = {
      expr =
        let
          r = runPure (testSuite {
            name = "mixed";
            cases = [
              { name = "p"; body = true; }
              { name = "f"; body = false; }
              { name = "s"; body = "non-bool"; }
            ];
          });
        in
        { inherit (r) passed failed skipped allPass; };
      expected = { passed = 1; failed = 1; skipped = 1; allPass = false; };
    };

    "runPure-allPass-when-all-true" = {
      expr =
        let
          r = runPure (testSuite {
            name = "ok";
            cases = [{ name = "a"; body = true; } { name = "b"; body = (1 + 1) == 2; }];
          });
        in
        r.allPass;
      expected = true;
    };

    "define-builds-testing-spec" = {
      expr =
        let
          s = define {
            langName = "alpha";
            testSuite = testSuite {
              name = "alpha-tests";
              cases = [{ name = "boot"; body = true; }];
            };
          };
        in
        { inherit (s) langName; suiteName = s.testSuite.name; };
      expected = { langName = "alpha"; suiteName = "alpha-tests"; };
    };

    "schemas-non-empty" = {
      expr =
        (value.schemas.testCase.oneOf or [ ]) != [ ]
        && (value.schemas.testSuite.oneOf or [ ]) != [ ]
        && (value.schemas.testingBuilder.oneOf or [ ]) != [ ];
      expected = true;
    };
  };
}
