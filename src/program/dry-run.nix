{ mb, api, lib, ... }:

let
  addStep = step: state: state // { steps = state.steps ++ [ step ]; };

  handleBuilder = op: state:
    if op._con == "readSource" then
      addStep { kind = "source"; inherit (op) name; } state
    else if op._con == "resolveDependency" then
      addStep { kind = "dependency"; inherit (op.dependency) name role; } state
    else if op._con == "declareTool" then
      addStep { kind = "tool"; inherit (op.tool) name; } state
    else if op._con == "runTool" then
      addStep { kind = "run"; inherit (op) name args env; tool = op.tool.name; } state
    else if op._con == "writeFile" then
      addStep { kind = "write"; path = op.output.path; } state
    else if op._con == "copyPath" then
      addStep { kind = "copy"; to = op.output.path; } state
    else if op._con == "transformOutput" then
      addStep { kind = "transform"; inherit (op.output) name format; } state
    else if op._con == "validateValue" then
      addStep { kind = "validate"; inherit (op.validation) name; } state
    else if op._con == "emitDescriptor" then
      addStep { kind = "descriptor"; inherit (op.descriptor) name; } state
    else if op._con == "materializeDerivation" then
      addStep { kind = "materialize"; inherit (op) name builder; } state
    else if op._con == "declareEvidence" then
      addStep { kind = "evidence"; inherit (op.evidence) name; } state
    else
      throw "metaBuilder.dry-run: unknown builder operation '${op._con}'";

  handleRuntime = op: state:
    if op._con == "declareCapability" then
      addStep { kind = "declare-capability"; inherit (op.category) name; } state
    else if op._con == "declareProtocol" then
      addStep { kind = "declare-protocol"; inherit (op.protocol) name; } state
    else if op._con == "declareService" then
      addStep { kind = "declare-service"; inherit (op.service) name; } state
    else if op._con == "materializeUnit" then
      addStep { kind = "materialize-unit"; inherit (op) name; } state
    else
      throw "metaBuilder.dry-run: unknown runtime operation '${op._con}'";

  dispatch = mb.program.dispatchWith {
    label = "dry-run";
    builder = handleBuilder;
    runtime = handleRuntime;
  };

  run = program:
    let
      result = mb.program.handle { inherit dispatch program; state = { steps = [ ]; }; };
    in
    result.state // { inherit (result) value; };

  value = { inherit dispatch run; };
  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "step-count" = {
        expr =
          let
            plan = run (mb.program.sequence [
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "protobuf";
                  package = stubDrv "protobuf";
                };
              })
              (mb.operations.runTool {
                name = "generate";
                tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
              })
            ]);
          in
          builtins.length plan.steps;
        expected = 2;
      };

      "runtime-ops-record-distinct-kinds" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            grpc = mb.operations.protocol {
              name = "grpc";
              transport = mb.operations.transports.TCP;
              serialization = mb.operations.serializations.Protobuf;
              capabilities = lifecycleSet;
            };
            svc = mb.operations.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
              protocols = [ grpc ];
            };
            plan = run (mb.program.sequence [
              (mb.operations.declareCapability { category = lifecycleCat; })
              (mb.operations.declareProtocol { protocol = grpc; })
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
          in
          map (s: s.kind) plan.steps;
        expected = [
          "declare-capability"
          "declare-protocol"
          "declare-service"
          "materialize-unit"
        ];
      };
    };
in
{
  scope = {
    "dry-run" = api.mk {
      description = "dry-run: interprets builder programs into operation summaries without materializing derivations.";
      doc = "Dry-run interpreter for typed builder programs.";
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "dry-run-${name}";
      value = test;
    })
    tests;
}
