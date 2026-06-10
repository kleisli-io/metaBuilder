{ mb, fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  ops = mb.operations;
  eff = mb.program.eff;

  CodeGenBuilder = H.ornament mb.descriptions.BuilderSpec {
    name = "MetaBuilderCodeGen";
    constructors.MetaBuilderSpec.fields = [
      { insert = "generator"; type = H.string; }
      { insert = "languages"; type = H.listOf H.string; }
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

  perLanguageOutput = lang: ops.output {
    name = lang;
    path = "$out/${lang}";
    format = "tree";
  };

  codeGen =
    { name
    , generator
    , languages
    , tool
    , invocations
    , inputs ? [ ]
    , dependencies ? [ ]
    , parameters ? [ ]
    , evidence ? [ ]
    }:
    let
      toolOp =
        if tool ? package && tool ? name && (tool._con or "") != ""
        then tool
        else ops.tool tool;

      perLangOutputs = map perLanguageOutput languages;

      readSourceOps = map
        (src: eff.builder.readSource {
          name = src.name;
          source = src;
        })
        inputs;

      declareToolOp = eff.builder.declareTool { tool = toolOp; };

      resolveDepOps = map (dep: eff.builder.resolveDependency { dependency = dep; }) dependencies;

      runToolOps = lib.imap0
        (i: inv: eff.builder.runTool {
          name = "${generator}-${toString i}";
          tool = toolOp;
          args = inv.args;
          env = inv.env or { };
        })
        invocations;

      transformOps = map (output: eff.builder.transformOutput { inherit output; }) perLangOutputs;

      descriptorOp = eff.builder.emitDescriptor {
        descriptor = ops.descriptor {
          name = "${name}-codegen";
          payload = { kind = "codegen"; inherit generator languages; };
        };
      };

      materializeOp = eff.builder.materializeDerivation {
        name = "${name}-generated";
        builder = "runCommand";
      };

      operations =
        readSourceOps
        ++ resolveDepOps
        ++ [ declareToolOp ]
        ++ runToolOps
        ++ transformOps
        ++ [ descriptorOp materializeOp ];
    in
    {
      _con = "MetaBuilderSpec";
      inherit name generator languages parameters inputs dependencies evidence operations;
      tools = [ toolOp ];
      outputs = perLangOutputs;
    };

  # Bridge eliminator: validate the typed spec against `CodeGenBuilder.T`,
  # sequence its operations into a program, and run materialization.
  # Returns the materialization record `{ plan; value; derivation }` so
  # consumers may inspect the build plan (for tests / debugging) and the
  # produced `pkgs.runCommand` derivation. Validation and dependency
  # analysis compose analogously through the same
  # `mb.program.fromOrnamentedSpec` boundary.
  materialize = spec:
    mb.program.materialize.run
      (mb.program.fromOrnamentedSpec CodeGenBuilder.T spec);

  value = {
    inherit CodeGenBuilder codeGen perLanguageOutput materialize;
    descriptor = G.derive.deriveDescriptor CodeGenBuilder;
    schema = G.derive.deriveSchema CodeGenBuilder;
  };

in
api.mk {
  description = "CodeGenBuilder ornament over BuilderSpec, with a `codeGen` smart constructor that produces typed multi-language code-generation specs.";
  doc = ''
    # Code Generation Builder

    `CodeGenBuilder` refines `BuilderSpec` with `generator` and
    `languages` so multi-language generators (protoc, openapi-generator,
    graphql-codegen) carry their target metadata in the type.

    The `codeGen` smart constructor expands a single config record into
    a fully-typed spec: per-language outputs, read-source / declare-tool
    / resolve-dependency / run-tool / transform-output / emit-descriptor
    / materialize-derivation operations.
  '';
  inherit value;
  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "descriptor-constructor" = {
        expr = (builtins.head value.descriptor.constructors).name;
        expected = "MetaBuilderSpec";
      };
      "code-gen-builds-spec" = {
        expr =
          let
            spec = codeGen {
              name = "demo";
              generator = "demo-gen";
              languages = [ "a" "b" ];
              tool = { name = "demo-gen"; package = stubDrv "demo-gen"; };
              invocations = [{ args = [ "--ok" ]; }];
            };
          in
          {
            inherit (spec) generator languages;
            opCount = builtins.length spec.operations;
            outCount = builtins.length spec.outputs;
          };
        expected = {
          generator = "demo-gen";
          languages = [ "a" "b" ];
          # 0 reads + 0 resolves + 1 declare + 1 run + 2 transforms + 1 descriptor + 1 materialize
          opCount = 6;
          outCount = 2;
        };
      };

      "materialize-yields-plan-and-derivation" = {
        expr =
          let
            spec = codeGen {
              name = "demo";
              generator = "demo-gen";
              languages = [ "alpha" ];
              tool = { name = "demo-gen"; package = stubDrv "demo-gen"; };
              invocations = [{ args = [ "--ok" ]; }];
            };
            result = materialize spec;
          in
          {
            hasPlan = result ? plan;
            hasDerivation = result ? derivation;
            planName = result.plan.name;
            planBuilder = result.plan.builder;
          };
        expected = {
          hasPlan = true;
          hasDerivation = true;
          planName = "demo-generated";
          planBuilder = "runCommand";
        };
      };

      "materialize-routes-each-invocation-to-run-step" = {
        expr =
          let
            spec = codeGen {
              name = "multi";
              generator = "demo-gen";
              languages = [ "alpha" "beta" ];
              tool = { name = "demo-gen"; package = stubDrv "demo-gen"; };
              invocations = [
                { args = [ "--first" ]; }
                { args = [ "--second" ]; }
              ];
            };
            result = materialize spec;
            runSteps = lib.filter (s: s._con == "runStep") result.plan.steps;
          in
          {
            runStepCount = builtins.length runSteps;
            firstArgs = (builtins.head runSteps).args;
            firstToolName = (builtins.head runSteps).tool.name;
            outputCount = builtins.length result.plan.outputs;
          };
        expected = {
          runStepCount = 2;
          firstArgs = [ "--first" ];
          firstToolName = "demo-gen";
          outputCount = 2;
        };
      };

      "materialize-routes-native-deps-into-plan-native-paths" = {
        expr =
          let
            spec = codeGen {
              name = "with-deps";
              generator = "demo-gen";
              languages = [ "alpha" ];
              tool = { name = "demo-gen"; package = stubDrv "demo-gen"; };
              invocations = [{ args = [ "--ok" ]; }];
              dependencies = [
                (mb.operations.dependency {
                  name = "alpha-headers";
                  role = "native";
                  package = stubDrv "alpha-headers";
                })
              ];
            };
            result = materialize spec;
          in
          {
            nativeCount = builtins.length result.plan.nativePaths;
            firstNativePath = builtins.head result.plan.nativePaths;
          };
        expected = {
          nativeCount = 1;
          firstNativePath = "/nix/store/fake-alpha-headers";
        };
      };

      "materialize-rejects-malformed-spec" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (materialize { _con = "MetaBuilderSpec"; name = "missing-fields"; })
          null)).success;
        expected = false;
      };
    };
}
