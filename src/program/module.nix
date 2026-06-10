{ api, mb, self, partTests, ... }:

api.mk {
  description = "program: internalized desc-interp builder signature with execution interpretations.";
  doc = ''
    Builder and runtime operations inject into the closed `BuilderEff`
    signature. The same namespace owns program construction, trampoline
    execution, validation, dependency analysis, materialization, dry-run, plan
    views, and builder self-documentation. Plan translators targeting other
    build substrates live under `backends`. Schema and project documentation
    artifacts live under `reference` and `mkDocsContent` because they are
    derived from descriptions, not programs.
  '';
  value = self;
  tests = partTests;
}
