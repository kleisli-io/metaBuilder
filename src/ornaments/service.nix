{ mb, api, lib, ... }:

let
  inherit (mb.descriptions.runtime) compatibility descriptor;

  operationsFor = svc:
    let
      capOps = map
        (cat: mb.operations.declareCapability { category = cat; })
        svc.capabilities.categories;
      protoOps = map
        (p: mb.operations.declareProtocol { protocol = p; })
        svc.protocols;
    in
    capOps
    ++ protoOps
    ++ [ (mb.operations.declareService { service = svc; }) ]
    ++ [ (mb.operations.materializeUnit { name = svc.name; }) ];

  define = args:
    let svc = mb.operations.service args;
    in svc // { operations = operationsFor svc; };

  program = svcOrArgs:
    let svc = if svcOrArgs ? operations then svcOrArgs else define svcOrArgs;
    in mb.program.sequence svc.operations;

  value = {
    inherit define operationsFor program compatibility descriptor;
  };

in
api.mk {
  description = "service ornament: typed service definition over the runtime.* effect algebra. `define` wraps the ServiceSpec smart constructor (with eager capability/protocol cross-check) and expands a typed runtime-op program for materialization.";
  doc = ''
    # Service

    `define { name; description?; package; capabilities; protocols?; config?; }`
    builds a typed `ServiceSpec` and attaches an `operations` field
    holding the runtime-op program that materializes the service:

    ```
    declareCapability(c1) … declareCapability(cN)   # one per category
    declareProtocol(p1)   … declareProtocol(pM)     # one per protocol
    declareService(svc)
    materializeUnit(svc.name)
    ```

    The eager compatibility check fires inside the underlying
    `mb.operations.service` smart constructor — invalid services
    cannot be constructed. `compatibility` and `descriptor` are
    re-exported from `mb.descriptions.runtime` for consumer convenience.

    `program` is a shortcut: pass either a service value or the
    arguments to `define`, and receive an internalized builder program.
  '';
  inherit value;
  tests =
    let
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };

      lifecycle = mb.operations.capabilityCategory {
        name = "lifecycle";
        capabilities = [
          (mb.operations.capability { name = "start"; })
          (mb.operations.capability { name = "stop"; })
        ];
      };
      query = mb.operations.capabilityCategory {
        name = "query";
        capabilities = [
          (mb.operations.capability { name = "get"; })
          (mb.operations.capability { name = "list"; })
        ];
      };
      serviceCaps = mb.operations.capabilitySet { categories = [ lifecycle query ]; };
      rpcProto = mb.operations.protocol {
        name = "rpc";
        transport = mb.operations.transports.TCP;
        serialization = mb.operations.serializations.JSON;
        defaultPort = 9000;
        portEnvVar = "SERVICE_PORT";
        capabilities = serviceCaps;
      };
      svc = define {
        name = "control";
        description = "Generic control-plane service";
        package = stubDrv "control-binary";
        capabilities = serviceCaps;
        protocols = [ rpcProto ];
      };
    in
    {
      "define-attaches-operation-program" = {
        expr = {
          opCount = builtins.length svc.operations;
          firstOp = (builtins.head svc.operations)._con;
          lastOp = (builtins.elemAt svc.operations
            (builtins.length svc.operations - 1))._con;
        };
        expected = {
          opCount = 5;
          firstOp = "declareCapability";
          lastOp = "materializeUnit";
        };
      };

      "operationsFor-emits-cap-proto-service-mat-sequence" = {
        expr = map (o: o._con) (operationsFor svc);
        expected = [
          "declareCapability"
          "declareCapability"
          "declareProtocol"
          "declareService"
          "materializeUnit"
        ];
      };

      "define-roundtrips-typed-service-fields" = {
        expr = {
          inherit (svc) name description;
          protoCount = builtins.length svc.protocols;
          categoryCount = builtins.length svc.capabilities.categories;
        };
        expected = {
          name = "control";
          description = "Generic control-plane service";
          protoCount = 1;
          categoryCount = 2;
        };
      };

      "define-rejects-incompatible-spec" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (define {
            name = "broken";
            package = stubDrv "broken";
            capabilities = serviceCaps;
            protocols = [
              (mb.operations.protocol {
                name = "weak";
                transport = mb.operations.transports.TCP;
                serialization = mb.operations.serializations.JSON;
                capabilities = mb.operations.capabilitySet {
                  categories = [
                    (mb.operations.capabilityCategory {
                      name = "lifecycle";
                      capabilities = [ (mb.operations.capability { name = "start"; }) ];
                    })
                  ];
                };
              })
            ];
          })
          null)).success;
        expected = false;
      };

      "compatibility-eliminator-re-exported" = {
        expr = (compatibility svc).valid;
        expected = true;
      };

      "descriptor-eliminator-re-exported-jsonifies" = {
        expr =
          let d = descriptor svc; in {
            inherit (d) name description;
            protoNames = map (p: p.name) d.protocols;
            protoTransport = (builtins.head d.protocols).transport;
            protoSerialization = (builtins.head d.protocols).serialization;
            jsonRoundtrips = builtins.isString (builtins.toJSON d);
          };
        expected = {
          name = "control";
          description = "Generic control-plane service";
          protoNames = [ "rpc" ];
          protoTransport = "TCP";
          protoSerialization = "JSON";
          jsonRoundtrips = true;
        };
      };

      "end-to-end-emits-service-json-derivation" = {
        expr =
          let
            result = mb.program.materialize.run (program svc);
            artifact = builtins.head result.plan.runtimeArtifacts;
          in
          {
            artifactCount = builtins.length result.plan.runtimeArtifacts;
            storePathSuffix = lib.hasSuffix "-service-control.json" artifact.storePath;
            descriptorPort = (builtins.head artifact.descriptor.protocols).defaultPort;
            descriptorEnvVar = (builtins.head artifact.descriptor.protocols).portEnvVar;
          };
        expected = {
          artifactCount = 1;
          storePathSuffix = true;
          descriptorPort = 9000;
          descriptorEnvVar = "SERVICE_PORT";
        };
      };

      "end-to-end-deps-attaches-package-out-path" = {
        expr =
          let
            graph = mb.program.deps.run (program svc);
            node = builtins.head graph.nodes;
          in
          {
            inherit (node) id role;
            packageOutPath = node.package.outPath;
          };
        expected = {
          id = "service:control";
          role = "service";
          packageOutPath = "/nix/store/fake-control-binary";
        };
      };
    };
}
