{ mb, fx, api, lib, ... }:

let
  renderStep = mb.program.materialize.renderStep;

  viewStep = step: {
    con = step._con;
    inherit (step) name;
    shell = renderStep step;
    step = step;
  };

  # Store-path basename is "<32-char hash>-<drvname>"; fake test paths lack the hash.
  drvNameOf = path:
    let base = baseNameOf path;
    in if builtins.stringLength base > 33
       then builtins.substring 33 (builtins.stringLength base - 33) base
       else base;

  viewArtifact = artifact: {
    _con = "MetaBuilderRuntimeArtifactView";
    inherit (artifact) kind name;
    summary = "${artifact.kind}:${artifact.name} → ${drvNameOf artifact.storePath}";
    drvName = drvNameOf artifact.storePath;
  };

  fromMaterialize = mat:
    let
      plan = mat.plan;
      steps = map viewStep plan.steps;
      runtimeArtifacts = map viewArtifact plan.runtimeArtifacts;
      shellPreamble =
        if plan.nativePaths == [ ] then [ ]
        else [ "export LD_LIBRARY_PATH=${lib.makeLibraryPath plan.nativePaths}:\${LD_LIBRARY_PATH:-}" ];
      pathMapPreamble = lib.mapAttrsToList
        (k: v: "${k}=${lib.escapeShellArg v}")
        plan.pathMap;
      stepCommands = map (s: s.shell) steps;
      shell = lib.concatStringsSep "\n"
        (pathMapPreamble ++ shellPreamble ++ stepCommands);
    in
    {
      inherit (plan) name builder tools outputs pathMap nativePaths;
      inherit steps runtimeArtifacts shell;
      inherit (mat) value;
    };

  run = program: fromMaterialize (mb.program.materialize.run program);

  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "view-emits-shell-per-step" = {
        expr =
          let
            view = run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
              })
              (mb.operations.runTool {
                name = "say-hi";
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
                args = [ "hello" ];
              })
            ]);
          in
          {
            stepCount = builtins.length view.steps;
            firstCon = (builtins.head view.steps).con;
            firstShellHasBinary = lib.hasPrefix "echo " (builtins.head view.steps).shell;
          };
        expected = {
          stepCount = 1;
          firstCon = "runStep";
          firstShellHasBinary = true;
        };
      };
      "view-shell-includes-pathmap-preamble" = {
        expr =
          let
            view = run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "cat"; package = stubDrv "cat"; };
              })
              (mb.operations.runTool {
                name = "cat-local";
                tool = mb.operations.tool { name = "cat"; package = stubDrv "cat"; };
                args = [ "/local/path/file.txt" ];
              })
            ]);
          in
          lib.hasInfix "pathMap_" view.shell;
        expected = true;
      };
      "view-empty-program-empty-shell" = {
        expr = (run (mb.program.sequence [ ])).shell;
        expected = "";
      };

      "view-surfaces-runtime-artifacts" = {
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
            view = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
            art = builtins.head view.runtimeArtifacts;
          in
          {
            shellCount = builtins.length view.steps;
            artifactCount = builtins.length view.runtimeArtifacts;
            inherit (art) kind name;
            summaryHasService = lib.hasInfix "service:api" art.summary;
          };
        expected = {
          shellCount = 0;
          artifactCount = 1;
          kind = "service";
          name = "api";
          summaryHasService = true;
        };
      };

      "view-artifact-validates-against-description" = {
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
            view = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
            art = builtins.head view.runtimeArtifacts;
          in
          fx.types.validateValue [ ] mb.descriptions.RuntimeArtifactView.T art;
        expected = [ ];
      };
    };
  value = { inherit run fromMaterialize viewStep viewArtifact; };
in
{
  scope = {
    "plan-view" = api.mk {
      description = "plan-view: surfaces typed BuildPlan records and rendered shell commands without forcing derivations.";
      doc = ''
        Returns a diagnostic view of a builder program: the typed plan
        fields, each step with its rendered shell command, runtime artifact
        summaries, and the combined shell transcript. No derivation is
        produced.
      '';
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "plan-view-${name}";
      value = test;
    })
    tests;
}
