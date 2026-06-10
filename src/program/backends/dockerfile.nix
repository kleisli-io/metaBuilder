{ mb, api, lib, ... }:

let
  renderStep = mb.program.materialize.renderStep;

  pathMapBasenames = plan: map baseNameOf (builtins.attrValues plan.pathMap);

  unsupportedReasons = plan:
    lib.optional (plan.builder != "runCommand")
      "builder '${plan.builder}' has no Dockerfile translation (only runCommand semantics)"
    ++ lib.optional (plan.nativePaths != [ ])
      "nativePaths reference host store paths that do not exist inside an image build"
    ++ lib.optional
      (lib.unique (pathMapBasenames plan) != pathMapBasenames plan)
      "pathMap source basenames clash; a flat build context cannot hold both";

  # Multi-line step bodies need a heredoc RUN; the delimiter is derived from
  # the body so no body line can terminate it early.
  runLine = cmd:
    if lib.hasInfix "\n" cmd
    then
      let marker = "METABUILDER_RUN_${builtins.hashString "sha256" cmd}";
      in "RUN <<'${marker}'\n${cmd}\n${marker}"
    else "RUN ${cmd}";

  # Local inputs come from the build context by basename; the pathMap
  # variable then points each step at the in-image copy.
  copyLines = plan:
    lib.concatLists (lib.mapAttrsToList
      (k: v:
        let base = baseNameOf v;
        in [
          "COPY ${base} /inputs/${base}"
          "ENV ${k}=/inputs/${base}"
        ])
      plan.pathMap);

  artifactNote = a:
    "# runtime artifact ${a.kind}:${a.name} (built outside this image): ${a.storePath}";

  fromPlan = plan:
    let reasons = unsupportedReasons plan;
    in
    if reasons != [ ] then
      throw ("metaBuilder.backends.dockerfile: plan '${plan.name}' is unsupported:\n"
        + lib.concatMapStringsSep "\n" (r: "  - ${r}") reasons)
    else
      lib.concatStringsSep "\n" (lib.flatten [
        "# syntax=docker/dockerfile:1"
        "ARG base=debian:stable-slim"
        "FROM \${base}"
        (map (t: "RUN command -v ${t.name} >/dev/null") plan.tools)
        "ENV out=/out"
        "RUN mkdir -p /out"
        (copyLines plan)
        (map (s: runLine (renderStep s)) plan.steps)
        (map artifactNote plan.runtimeArtifacts)
      ]) + "\n";

  run = program: fromPlan (mb.program.materialize.runChecked program).plan;

  tests =
    let
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
      echoTool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
      simpleProgram = mb.program.sequence [
        (mb.operations.declareTool { tool = echoTool; })
        (mb.operations.runTool { name = "say"; tool = echoTool; args = [ "hello" ]; })
      ];
    in
    {
      "is-parameterized" = {
        expr =
          let dockerfile = run simpleProgram;
          in {
            hasSyntax = lib.hasPrefix "# syntax=docker/dockerfile:1\n" dockerfile;
            hasBaseArg = lib.hasInfix "ARG base=" dockerfile;
            hasFrom = lib.hasInfix "FROM \${base}" dockerfile;
            hasOutEnv = lib.hasInfix "ENV out=/out" dockerfile;
            hasToolGuard = lib.hasInfix "RUN command -v echo" dockerfile;
            hasStep = lib.hasInfix "RUN echo hello" dockerfile;
          };
        expected = {
          hasSyntax = true;
          hasBaseArg = true;
          hasFrom = true;
          hasOutEnv = true;
          hasToolGuard = true;
          hasStep = true;
        };
      };

      "copies-local-inputs-into-context" = {
        expr =
          let
            dockerfile = run (mb.program.sequence [
              (mb.operations.declareTool { tool = echoTool; })
              (mb.operations.runTool {
                name = "use-local";
                tool = echoTool;
                args = [ "/local/path/input.txt" ];
              })
            ]);
          in
          {
            copiesInput = lib.hasInfix "COPY input.txt /inputs/input.txt" dockerfile;
            mapsPathVar = lib.hasInfix "ENV pathMap_" dockerfile;
            mapsToContainerPath = lib.hasInfix "=/inputs/input.txt" dockerfile;
          };
        expected = {
          copiesInput = true;
          mapsPathVar = true;
          mapsToContainerPath = true;
        };
      };

      "multiline-step-becomes-heredoc-run" = {
        expr =
          let
            dockerfile = run (mb.program.sequence [
              (mb.operations.writeFile {
                output = mb.operations.output { name = "manifest"; path = "manifest.txt"; };
                text = "hello";
              })
            ]);
          in
          lib.hasInfix "RUN <<'METABUILDER_RUN_" dockerfile;
        expected = true;
      };

      "rejects-native-paths" = {
        expr =
          let
            plan = (mb.program.materialize.run (mb.program.sequence [
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "zlib";
                  role = "native";
                  package = stubDrv "zlib";
                };
              })
            ])).plan;
          in
          {
            reasonCount = builtins.length (unsupportedReasons plan);
            emits = (builtins.tryEval (builtins.deepSeq (fromPlan plan) null)).success;
          };
        expected = {
          reasonCount = 1;
          emits = false;
        };
      };

      "rejects-foreign-builder" = {
        expr =
          let
            plan = (mb.program.materialize.run simpleProgram).plan // { builder = "make"; };
          in
          builtins.length (unsupportedReasons plan);
        expected = 1;
      };

      "notes-runtime-artifacts" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            svc = mb.operations.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
            };
            dockerfile = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
          in
          lib.hasInfix "# runtime artifact service:api" dockerfile;
        expected = true;
      };

      "supported-plan-has-no-reasons" = {
        expr = unsupportedReasons (mb.program.materialize.run simpleProgram).plan;
        expected = [ ];
      };
    };

  value = { inherit run fromPlan unsupportedReasons; };
in
{
  scope = {
    dockerfile = api.mk {
      description = "dockerfile backend: emits a Dockerfile from a substrate-neutral BuildPlan.";
      doc = ''
        Translates a validated `BuildPlan` into a Dockerfile over a
        parameterizable base image: tool preflight by name, local inputs
        copied from the build context, and one RUN per rendered step. Plans
        it cannot honor are rejected with explicit reasons.
      '';
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "dockerfile-${name}";
      value = test;
    })
    tests;
}
