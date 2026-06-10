{ mb, api, lib, ... }:

let
  requireNonEmpty = effect: field: value:
    if value != "" then [ ]
    else [{
      severity = "error";
      code = "builder.required-non-empty";
      path = [ effect field ];
      message = "${effect}.${field} must be a non-empty string";
    }];

  validateOp = effect: op:
    requireNonEmpty effect "name" op.name;

  pathOf = value: value.path;

  handleBuilder = op: state:
    if op._con == "readSource" then
      state
      ++ validateOp "read-source" op
      ++ validateOp "read-source.source" op.source
    else if op._con == "resolveDependency" then
      state ++ validateOp "resolve-dependency.dependency" op.dependency
    else if op._con == "declareTool" then
      state ++ validateOp "declare-tool.tool" op.tool
    else if op._con == "runTool" then
      state
      ++ validateOp "run-tool" op
      ++ validateOp "run-tool.tool" op.tool
    else if op._con == "writeFile" then
      state ++ requireNonEmpty "write-file.output" "path" (pathOf op.output)
    else if op._con == "copyPath" then
      state ++ requireNonEmpty "copy-path.output" "path" (pathOf op.output)
    else if op._con == "transformOutput" then
      state ++ validateOp "transform-output.output" op.output
    else if op._con == "validateValue" then
      state ++ validateOp "validate-value.validation" op.validation
    else if op._con == "emitDescriptor" then
      state ++ validateOp "emit-descriptor.descriptor" op.descriptor
    else if op._con == "materializeDerivation" then
      state ++ validateOp "materialize-derivation" op
    else if op._con == "declareEvidence" then
      state ++ validateOp "declare-evidence.evidence" op.evidence
    else
      throw "metaBuilder.validate: unknown builder operation '${op._con}'";

  handleRuntime = op: state:
    if op._con == "declareCapability" then
      state ++ validateOp "declare-capability.category" op.category
    else if op._con == "declareProtocol" then
      state ++ validateOp "declare-protocol.protocol" op.protocol
    else if op._con == "declareService" then
      state ++ validateOp "declare-service.service" op.service
    else if op._con == "materializeUnit" then
      state ++ validateOp "materialize-unit" op
    else
      throw "metaBuilder.validate: unknown runtime operation '${op._con}'";

  dispatch = mb.program.dispatchWith {
    label = "validate";
    builder = handleBuilder;
    runtime = handleRuntime;
  };

  run = program:
    let result = mb.program.handle { inherit dispatch program; state = [ ]; };
    in {
      ok = result.state == [ ];
      diagnostics = result.state;
      inherit (result) value;
    };

  tests =
    let
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
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
    in
    {
      "invalid-tool" = {
        expr =
          let
            program = mb.program.sequence [
              (mb.operations.runTool {
                name = "bad";
                tool = mb.operations.tool { name = ""; package = stubDrv "ok"; };
              })
            ];
          in
          (run program).ok;
        expected = false;
      };

      "well-formed-runtime-ops-yield-no-diagnostics" = {
        expr =
          let
            svc = mb.operations.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
              protocols = [ grpc ];
            };
            result = run (mb.program.sequence [
              (mb.operations.declareCapability { category = lifecycleCat; })
              (mb.operations.declareProtocol { protocol = grpc; })
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
          in
          { inherit (result) ok; diagnosticsCount = builtins.length result.diagnostics; };
        expected = { ok = true; diagnosticsCount = 0; };
      };

      "empty-service-name-yields-diagnostic" = {
        expr =
          let
            svc = mb.operations.service {
              name = "";
              package = stubDrv "svc";
              capabilities = lifecycleSet;
            };
            result = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
            ]);
          in
          { inherit (result) ok; diagnosticsCount = builtins.length result.diagnostics; };
        expected = { ok = false; diagnosticsCount = 1; };
      };
    };
  value = { inherit dispatch run; };
in
{
  scope = {
    validate = api.mk {
      description = "validate: interprets builder programs into accumulated diagnostics.";
      doc = "Validation interpreter for typed builder programs.";
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "validate-${name}";
      value = test;
    })
    tests;
}
