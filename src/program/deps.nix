{ mb, fx, api, lib, ... }:

let
  inherit (fx.state) forceThunk;

  packageSummary = package: {
    packageName = package.pname or package.name or "package";
    packageOutPath = package.outPath or null;
  };

  dependencyNode = dependency: {
    id = "${dependency.role}:${dependency.name}";
    inherit (dependency) name role;
  } // packageSummary (forceThunk dependency.package);

  toolNode = tool: {
    id = "tool:${tool.name}";
    inherit (tool) name;
    role = "tool";
  } // packageSummary (forceThunk tool.package);

  operationNode = op: {
    id = "operation:${op.name}";
    inherit (op) name;
    role = "operation";
    tool = op.tool.name;
  };

  serviceNode = svc:
    let package = forceThunk svc.package;
    in {
      id = "service:${svc.name}";
      inherit (svc) name;
      role = "service";
      inherit package;
    } // packageSummary package;

  addNode = node: state:
    if state.nodeIds.${node.id} or false then state
    else state // {
      nodes = state.nodes ++ [ node ];
      nodeIds = state.nodeIds // { ${node.id} = true; };
    };

  addEdge = edge: state:
    state // {
      edges = state.edges ++ [ edge ];
    };

  # deps is a projection: constructors carrying no dependency information
  # are named no-ops, so only an unknown constructor reaches the throw.
  handleBuilder = op: state:
    if op._con == "resolveDependency" then
      addNode (dependencyNode op.dependency) state
    else if op._con == "declareTool" then
      addNode (toolNode op.tool) state
    else if op._con == "runTool" then
      addEdge
        {
          from = "tool:${op.tool.name}";
          to = "operation:${op.name}";
          kind = "uses-tool";
        }
        (addNode (operationNode op) state)
    else if op._con == "readSource" then state
    else if op._con == "writeFile" then state
    else if op._con == "copyPath" then state
    else if op._con == "transformOutput" then state
    else if op._con == "validateValue" then state
    else if op._con == "emitDescriptor" then state
    else if op._con == "materializeDerivation" then state
    else if op._con == "declareEvidence" then state
    else
      throw "metaBuilder.deps: unknown builder operation '${op._con}'";

  handleRuntime = op: state:
    if op._con == "declareService" then
      state // {
        services = state.services // { ${op.service.name} = op.service; };
      }
    else if op._con == "materializeUnit" then
      let svc = state.services.${op.name} or null; in
      if svc == null then
        throw ''
          metaBuilder.deps: materializeUnit '${op.name}' references undeclared service.
          Declared so far: [${builtins.concatStringsSep ", " (builtins.attrNames state.services)}].''
      else
        addNode (serviceNode svc) state
    else if op._con == "declareCapability" then state
    else if op._con == "declareProtocol" then state
    else
      throw "metaBuilder.deps: unknown runtime operation '${op._con}'";

  dispatch = mb.program.dispatchWith {
    label = "deps";
    builder = handleBuilder;
    runtime = handleRuntime;
  };

  run = program:
    let
      result = mb.program.handle {
        inherit dispatch program;
        state = { nodes = [ ]; nodeIds = { }; edges = [ ]; services = { }; };
      };
    in
    {
      inherit (result.state) nodes edges services;
      inherit (result) value;
    };

  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "dependency-node" = {
        expr =
          let
            graph = run (mb.program.sequence [
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "protobuf";
                  role = "tool";
                  package = stubDrv "protobuf";
                };
              })
            ]);
          in
          (builtins.head graph.nodes).id;
        expected = "tool:protobuf";
      };

      "tool-and-operation-nodes-are-explicit" = {
        expr =
          let
            tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
            graph = run (mb.program.sequence [
              (mb.operations.declareTool { inherit tool; })
              (mb.operations.runTool {
                name = "generate";
                inherit tool;
              })
            ]);
          in
          {
            nodeIds = map (node: node.id) graph.nodes;
            edges = graph.edges;
          };
        expected = {
          nodeIds = [ "tool:protoc" "operation:generate" ];
          edges = [{
            from = "tool:protoc";
            to = "operation:generate";
            kind = "uses-tool";
          }];
        };
      };

      "service-node-attaches-package-out-path" = {
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
            graph = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
            node = builtins.head graph.nodes;
          in
          {
            inherit (node) id role;
            packageOutPath = node.package.outPath;
          };
        expected = {
          id = "service:api";
          role = "service";
          packageOutPath = "/nix/store/fake-api";
        };
      };

      "service-materialize-without-declare-throws" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (run (mb.program.sequence [
            (mb.operations.materializeUnit { name = "ghost"; })
          ]))
          null)).success;
        expected = false;
      };
    };
  value = { inherit dispatch run; };
in
{
  scope = {
    deps = api.mk {
      description = "deps: interprets builder programs into dependency and provenance graphs.";
      doc = "Dependency graph interpreter for typed builder programs.";
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "deps-${name}";
      value = test;
    })
    tests;
}
