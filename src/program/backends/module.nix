{ api, self, partTests, ... }:

api.mk {
  description = "backends: plan translators that emit non-Nix build artifacts from a substrate-neutral BuildPlan.";
  doc = ''
    Backends translate a validated `BuildPlan` into an artifact for another
    build substrate. Unlike the program interpreters they do not fold over
    the operation alphabet — they consume the plan that `materialize`
    produces, so the interpreter coverage grid does not apply. Each backend
    declares the plans it cannot honor through `unsupportedReasons`; nothing
    is miscompiled silently.
  '';
  value = self;
  tests = partTests;
}
