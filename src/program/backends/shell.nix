{ mb, api, lib, pkgs, ... }:

let
  renderStep = mb.program.materialize.renderStep;

  unsupportedReasons = plan:
    lib.optional (plan.builder != "runCommand")
      "builder '${plan.builder}' has no shell translation (only runCommand semantics)";

  toolGuard = tool:
    "command -v ${tool.name} >/dev/null 2>&1 || { echo 'backends.shell: missing tool on PATH: ${tool.name}' >&2; exit 1; }";

  artifactNote = a:
    "# runtime artifact ${a.kind}:${a.name} (built outside this script): ${a.storePath}";

  fromPlan = plan:
    let reasons = unsupportedReasons plan;
    in
    if reasons != [ ] then
      throw ("metaBuilder.backends.shell: plan '${plan.name}' is unsupported:\n"
        + lib.concatMapStringsSep "\n" (r: "  - ${r}") reasons)
    else
      lib.concatStringsSep "\n" (lib.flatten [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        ''out="''${out:-$PWD/out}"''
        "export out"
        ''mkdir -p "$out"''
        (map toolGuard plan.tools)
        (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") plan.pathMap)
        (lib.optional (plan.nativePaths != [ ])
          "export LD_LIBRARY_PATH=${lib.makeLibraryPath plan.nativePaths}:\${LD_LIBRARY_PATH:-}")
        (map renderStep plan.steps)
        (map artifactNote plan.runtimeArtifacts)
      ]) + "\n";

  run = program: fromPlan (mb.program.materialize.runChecked program).plan;

  # Local paths don't exist in a sandbox: import them like toDerivation does.
  sandboxScriptFor = plan:
    fromPlan (plan // {
      pathMap = lib.mapAttrs
        (_: path: toString (builtins.path {
          inherit path;
          name = baseNameOf (toString path);
        }))
        plan.pathMap;
    });

  # Run the rendered script in its own sandbox; its tree must match the
  # derivation byte-for-byte.
  executionCheckFor = program:
    let
      mat = mb.program.materialize.runChecked program;
      script = sandboxScriptFor mat.plan;
      packages = map (t: t.package) mat.plan.tools;
    in
    pkgs.runCommand "${mat.plan.name}-shell-execution-equality"
      { nativeBuildInputs = packages; } ''
      bash ${pkgs.writeText "${mat.plan.name}-shell.sh" script}
      diff -r ${mat.derivation} "$out"
    '';

  shellcheckFor = script:
    pkgs.runCommand "shell-backend-shellcheck"
      { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
      shellcheck ${pkgs.writeText "shell-backend.sh" script}
      touch $out
    '';

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
      "script-is-standalone" = {
        expr =
          let script = run simpleProgram;
          in {
            hasShebang = lib.hasPrefix "#!/usr/bin/env bash\n" script;
            hasStrictMode = lib.hasInfix "set -euo pipefail" script;
            hasOutDefault = lib.hasInfix ''out="''${out:-$PWD/out}"'' script;
            hasToolGuard = lib.hasInfix "command -v echo" script;
            hasStep = lib.hasInfix "echo hello" script;
          };
        expected = {
          hasShebang = true;
          hasStrictMode = true;
          hasOutDefault = true;
          hasToolGuard = true;
          hasStep = true;
        };
      };

      "exports-pathmap-and-library-path" = {
        expr =
          let
            script = run (mb.program.sequence [
              (mb.operations.declareTool { tool = echoTool; })
              (mb.operations.runTool {
                name = "use-local";
                tool = echoTool;
                args = [ "/local/path/input.txt" ];
              })
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "zlib";
                  role = "native";
                  package = stubDrv "zlib";
                };
              })
            ]);
          in
          {
            exportsPathMap = lib.hasInfix "export pathMap_" script;
            exportsLdPath = lib.hasInfix "export LD_LIBRARY_PATH=" script;
            ldPathHasLib = lib.hasInfix "/nix/store/fake-zlib/lib" script;
          };
        expected = {
          exportsPathMap = true;
          exportsLdPath = true;
          ldPathHasLib = true;
        };
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
            script = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
          in
          lib.hasInfix "# runtime artifact service:api" script;
        expected = true;
      };

      "rejects-foreign-builder" = {
        expr =
          let
            plan = (mb.program.materialize.run simpleProgram).plan // { builder = "make"; };
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

      "supported-plan-has-no-reasons" = {
        expr = unsupportedReasons (mb.program.materialize.run simpleProgram).plan;
        expected = [ ];
      };
    };

  value = { inherit run fromPlan unsupportedReasons shellcheckFor executionCheckFor; };
in
{
  scope = {
    shell = api.mk {
      description = "shell backend: emits a standalone bash script from a substrate-neutral BuildPlan.";
      doc = ''
        Translates a validated `BuildPlan` into a standalone bash script:
        tool preflight by name, pathMap exports, library-path export, and the
        rendered step commands. Plans it cannot honor are rejected with
        explicit reasons.
      '';
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "shell-${name}";
      value = test;
    })
    tests;
}
