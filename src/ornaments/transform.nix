{ mb, fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  ops = mb.operations;
  ToolSpec = mb.descriptions.ToolSpec;

  TransformStep = H.product "MetaBuilderTransformStep" [
    (H.field "name" H.string)
    (H.field "tool" ToolSpec.T)
    (H.field "args" (H.listOf H.string))
    (H.field "env" H.attrs)
  ];

  # `transform` is a smart constructor over BuilderSpec for the
  # transform-output pipeline shape: many tools applied sequentially
  # to a single input flow, each tool producing intermediate output
  # that the next step consumes. Each `TransformStep` becomes a
  # `runTool` operation; each terminal `output` becomes a
  # `transformOutput` operation; tools are deduplicated and emitted as
  # `declareTool` ops; inputs become `readSource` ops. The result is
  # a vanilla typed `BuilderSpec`; consumers needing the typed step
  # list can read `.steps` (preserved on the produced spec).
  transform =
    { name
    , inputs ? [ ]
    , steps
    , outputs ? [ ]
    , parameters ? [ ]
    , dependencies ? [ ]
    , evidence ? [ ]
    }:
    let
      typedSteps = map
        (s: {
          _con = "MetaBuilderTransformStep";
          name = s.name;
          tool =
            if s.tool ? package && s.tool ? name && (s.tool._con or "") != ""
            then s.tool
            else ops.tool s.tool;
          args = s.args or [ ];
          env = s.env or { };
        })
        steps;

      uniqueTools =
        let
          addUnique = acc: tool:
            if lib.any (t: t.name == tool.name) acc
            then acc
            else acc ++ [ tool ];
        in
        lib.foldl' addUnique [ ] (map (s: s.tool) typedSteps);

      readSourceOps = map (src: ops.readSource { name = src.name; source = src; }) inputs;
      declareToolOps = map (tool: ops.declareTool { inherit tool; }) uniqueTools;
      runToolOps = map
        (s: ops.runTool {
          inherit (s) name tool args env;
        })
        typedSteps;
      transformOps = map (output: ops.transformOutput { inherit output; }) outputs;

      descriptorOp = ops.emitDescriptor {
        descriptor = ops.descriptor {
          name = "${name}-transform";
          payload = { kind = "transform"; stepCount = builtins.length steps; };
        };
      };
      materializeOp = ops.materializeDerivation {
        name = "${name}-transformed";
        builder = "runCommand";
      };

      operations =
        readSourceOps
        ++ declareToolOps
        ++ runToolOps
        ++ transformOps
        ++ [ descriptorOp materializeOp ];
    in
    {
      _con = "MetaBuilderSpec";
      inherit name parameters inputs dependencies evidence operations outputs;
      tools = uniqueTools;
      steps = typedSteps;
    };

  value = {
    inherit TransformStep transform;
    types.transformStep = TransformStep;
    schemas.transformStep = G.derive.deriveSchema TransformStep;
  };

in
api.mk {
  description = "metaBuilder transform ornament: typed smart constructor over BuilderSpec for the multi-tool sequential transform-output pipeline shape. Each step becomes a runTool op; each terminal output becomes a transformOutput op.";
  doc = ''
    # Transform

    `transform` builds a typed `BuilderSpec` for a sequential
    transformation pipeline. Each `step` is a `{ name; tool; args ?
    []; env ? {}; }` record carrying a tool (raw or pre-constructed
    via `mb.operations.tool`). Tools are deduplicated and emitted as
    `declareTool` operations; steps become `runTool` operations; the
    `outputs` list expands to `transformOutput` operations.

    The constructor wraps the `transform-output` effect of the new
    framework — no new effect tags are introduced.
  '';
  inherit value;
  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "transform-builds-spec" = {
        expr =
          let
            spec = transform {
              name = "demo";
              steps = [
                { name = "preprocess"; tool = { name = "pp"; package = stubDrv "pp"; }; args = [ "-i" "src" ]; }
                { name = "compile"; tool = { name = "cc"; package = stubDrv "cc"; }; args = [ "-O2" ]; }
              ];
              outputs = [ (ops.output { name = "result"; path = "$out/result"; }) ];
            };
          in
          {
            opCount = builtins.length spec.operations;
            stepCount = builtins.length spec.steps;
            toolCount = builtins.length spec.tools;
          };
        expected = {
          # 0 reads + 2 declares + 2 runs + 1 transform + 1 descriptor + 1 materialize
          opCount = 7;
          stepCount = 2;
          toolCount = 2;
        };
      };

      "transform-deduplicates-shared-tool" = {
        expr =
          let
            tool = ops.tool { name = "tool"; package = stubDrv "tool"; };
            spec = transform {
              name = "shared";
              steps = [
                { name = "a"; tool = tool; args = [ "-a" ]; }
                { name = "b"; tool = tool; args = [ "-b" ]; }
              ];
            };
          in
          builtins.length spec.tools;
        expected = 1;
      };

      "transform-empty-outputs-skips-transform-op" = {
        expr =
          let
            spec = transform {
              name = "no-outputs";
              steps = [
                { name = "step"; tool = { name = "t"; package = stubDrv "t"; }; }
              ];
            };
          in
          lib.any (op: op._con == "transformOutput") spec.operations;
        expected = false;
      };

      "schema-non-empty" = {
        expr = (value.schemas.transformStep.oneOf or [ ]) != [ ];
        expected = true;
      };
    };
}
