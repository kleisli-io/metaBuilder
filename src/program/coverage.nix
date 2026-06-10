{ mb, lib, ... }:

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
  svc = mb.operations.service {
    name = "api";
    package = stubDrv "api";
    capabilities = lifecycleSet;
    protocols = [ grpc ];
  };
  tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
  source = mb.operations.localSource { name = "schema"; path = "/tmp/schema.proto"; };

  # One minimal well-formed program per constructor, keyed by constructor
  # name. The enumeration below derives from datatypeInfo, so a new
  # constructor extends the grid automatically — and fails it here until a
  # program template is added and every interpreter handles the new case.
  programs = {
    readSource = [ (mb.operations.readSource { name = "schema"; inherit source; }) ];
    resolveDependency = [
      (mb.operations.resolveDependency {
        dependency = mb.operations.dependency { name = "protobuf"; package = stubDrv "protobuf"; };
      })
    ];
    declareTool = [ (mb.operations.declareTool { inherit tool; }) ];
    runTool = [
      (mb.operations.declareTool { inherit tool; })
      (mb.operations.runTool { name = "generate"; inherit tool; args = [ "--version" ]; })
    ];
    writeFile = [
      (mb.operations.writeFile {
        output = mb.operations.output { name = "manifest"; path = "manifest.txt"; };
        text = "hello";
      })
    ];
    copyPath = [
      (mb.operations.copyPath {
        inherit source;
        output = mb.operations.output { name = "copy"; path = "copied"; };
      })
    ];
    transformOutput = [
      (mb.operations.transformOutput {
        output = mb.operations.output { name = "cpp"; path = "$out/cpp"; format = "tree"; };
      })
    ];
    validateValue = [
      (mb.operations.validateValue {
        validation = mb.operations.validation { name = "check"; value = true; };
      })
    ];
    emitDescriptor = [
      (mb.operations.emitDescriptor {
        descriptor = mb.operations.descriptor { name = "idl"; };
      })
    ];
    materializeDerivation = [ (mb.operations.materializeDerivation { name = "demo"; }) ];
    declareEvidence = [
      (mb.operations.declareEvidence {
        evidence = mb.operations.evidence { name = "self-test"; payload = { command = "./check"; }; };
      })
    ];

    declareCapability = [ (mb.operations.declareCapability { category = lifecycleCat; }) ];
    declareProtocol = [ (mb.operations.declareProtocol { protocol = grpc; }) ];
    declareService = [ (mb.operations.declareService { service = svc; }) ];
    materializeUnit = [
      (mb.operations.declareService { service = svc; })
      (mb.operations.materializeUnit { name = "api"; })
    ];
  };

  # Forcing projections: deep enough to prove the handler ran, while
  # keeping real derivations out of the deep walk (a drv attrset is
  # cyclic — `out` points back at the derivation itself).
  interpreters = {
    validate = {
      inherit (mb.program.validate) run dispatch;
      force = r: { inherit (r) ok diagnostics; };
    };
    deps = {
      inherit (mb.program.deps) run dispatch;
      force = r: { inherit (r) nodes edges; serviceNames = builtins.attrNames r.services; };
    };
    "dry-run" = {
      inherit (mb.program."dry-run") run dispatch;
      force = r: r.steps;
    };
    describe = {
      inherit (mb.program.describe) run dispatch;
      force = r: { inherit (r) model markdown; };
    };
    materialize = {
      inherit (mb.program.materialize) run dispatch;
      force = r: r.plan;
    };
  };

  constructorNames =
    mb.operations.builderOperationNames ++ mb.operations.runtimeOperationNames;

  forces = v: (builtins.tryEval (builtins.deepSeq v null)).success;

  handlesTests = builtins.listToAttrs (lib.concatMap
    (iName:
      map
        (ctor: {
          name = "${iName}-handles-${ctor}";
          value = {
            expr = forces (interpreters.${iName}.force
              (interpreters.${iName}.run (mb.program.sequence programs.${ctor})));
            expected = true;
          };
        })
        constructorNames)
    (builtins.attrNames interpreters));

  unknownOpTests = builtins.listToAttrs (lib.concatMap
    (iName:
      map
        (summand: {
          name = "${iName}-throws-on-unknown-${summand.label}-op";
          value = {
            expr = forces (interpreters.${iName}.dispatch {
              op = { _op = { _con = "unknownOp"; }; fn = { ctorIndex = summand.index; }; };
              state = { };
            });
            expected = false;
          };
        })
        [ { label = "builder"; index = 0; } { label = "runtime"; index = 1; } ])
    (builtins.attrNames interpreters));

  # Every ctor resolves a real arm (else-arm throws): handled count = ctor count.
  armCountTests = builtins.listToAttrs (map
    (iName: {
      name = "${iName}-arm-count-equals-ctor-count";
      value = {
        expr = builtins.length (builtins.filter
          (ctor: forces (interpreters.${iName}.force
            (interpreters.${iName}.run (mb.program.sequence programs.${ctor}))))
          constructorNames);
        expected = builtins.length constructorNames;
      };
    })
    (builtins.attrNames interpreters));
in
{
  scope = { };
  tests = lib.mapAttrs'
    (name: test: {
      name = "coverage-${name}";
      value = test;
    })
    (handlesTests // unknownOpTests // armCountTests);
}
