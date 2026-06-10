{ mb, fx, api, ... }:

let
  inherit (fx.state) mkThunk;
  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.operations.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  op = _con: fields: { inherit _con; } // fields;

  builderOperationNames = mb.descriptions.builderKind.opNames.builder;
  runtimeOperationNames = mb.descriptions.builderKind.opNames.runtime;

  transports = {
    TCP = { _con = "TCP"; };
    Unix = { _con = "Unix"; };
    Stdio = { _con = "Stdio"; };
  };

  serializations = {
    JSON = { _con = "JSON"; };
    Protobuf = { _con = "Protobuf"; };
    Sexp = { _con = "Sexp"; };
    MsgPack = { _con = "MsgPack"; };
    Bencode = { _con = "Bencode"; };
  };

  lifecycles = {
    LongRunning = { _con = "LongRunning"; };
    OneShot = { _con = "OneShot"; };
  };

  replModes = {
    Foreground = { _con = "Foreground"; };
    Background = { _con = "Background"; };
  };

  registrationBackends = {
    XDG = { _con = "XDG"; };
    Global = { _con = "Global"; };
    ServiceSpec = { _con = "ServiceSpec"; };
    None = { _con = "None"; };
  };

  seccompStages = {
    Bwrap = { _con = "Bwrap"; };
    Self = { _con = "Self"; };
  };

  runtimeTypes = {
    RTString = { _con = "RTString"; };
    RTInt = { _con = "RTInt"; };
    RTBool = { _con = "RTBool"; };
    RTObject = { _con = "RTObject"; };
    RTArray = { _con = "RTArray"; };
  };

  param = { name, description ? "", type, required ? true }:
    validateOr "param" mb.descriptions.ParamSpec.T {
      _con = "MetaBuilderParam";
      inherit name description type required;
    };

  capability = { name, description ? "", params ? [ ], returns ? runtimeTypes.RTObject }:
    validateOr "capability" mb.descriptions.CapabilitySchema.T {
      _con = "MetaBuilderCapabilitySchema";
      inherit name description params returns;
    };

  capabilityCategory = { name, description ? "", capabilities ? [ ] }:
    validateOr "capabilityCategory" mb.descriptions.CapabilityCategory.T {
      _con = "MetaBuilderCapabilityCategory";
      inherit name description capabilities;
    };

  capabilitySet = { categories ? [ ], custom ? [ ] }:
    validateOr "capabilitySet" mb.descriptions.CapabilitySet.T {
      _con = "MetaBuilderCapabilitySet";
      inherit categories custom;
    };

  protocol =
    { name
    , description ? ""
    , transport
    , serialization
    , defaultPort ? null
    , portEnvVar ? null
    , capabilities
    , options ? { }
    }:
    validateOr "protocol" mb.descriptions.ProtocolSpec.T {
      _con = "MetaBuilderProtocolSpec";
      inherit name description transport serialization
        defaultPort portEnvVar capabilities options;
    };

  service = { name, description ? "", package, capabilities, protocols ? [ ], config ? [ ] }:
    let
      candidate = {
        _con = "MetaBuilderServiceSpec";
        inherit name description capabilities protocols config;
        package = mkThunk package;
      };
      typed = validateOr "service" mb.descriptions.ServiceSpec.T candidate;
      compat = mb.descriptions.runtime.compatibility typed;
    in
    if !compat.valid then
      throw
        ("metaBuilder.operations.service: capability/protocol cross-check failed:\n  - "
          + builtins.concatStringsSep "\n  - " compat.errors)
    else typed;

  inferRegistration = mode:
    if mode._con == "Foreground" then registrationBackends.ServiceSpec
    else registrationBackends.XDG;

  tcpEndpoint = { port, address ? "127.0.0.1" }:
    validateOr "tcpEndpoint" mb.descriptions.TcpEndpoint.T {
      _con = "MetaBuilderTcpEndpoint";
      inherit port address;
    };

  displayConfig = { wayland ? false, x11 ? false, gpu ? false }:
    validateOr "displayConfig" mb.descriptions.DisplayConfig.T {
      _con = "MetaBuilderDisplayConfig";
      inherit wayland x11 gpu;
    };

  dnsConfig = { nsswitch, resolv, extraBinds ? [ ] }:
    validateOr "dnsConfig" mb.descriptions.DnsConfig.T {
      _con = "MetaBuilderDnsConfig";
      nsswitch = mkThunk nsswitch;
      resolv = mkThunk resolv;
      inherit extraBinds;
    };

  sandboxProfile =
    { readOnlyPaths ? [ "/nix/store" ]
    , readWritePaths ? [ ]
    , tmpfs ? [ "/tmp" ]
    , listenTcp ? [ ]
    , connectTcp ? [ ]
    , connectAny ? false
    , display ? null
    , stdio ? true
    , unixSockets ? [ ]
    , allowExecve ? false
    , allowFork ? false
    , lifecycle ? lifecycles.LongRunning
    , daemonMode ? false
    , dns ? null
    , sourceAccess ? false
    , sourceWritePaths ? [ ]
    , coordinationWritePaths ? [ ]
    , storeAccess ? false
    }:
    validateOr "sandboxProfile" mb.descriptions.SandboxProfile.T {
      _con = "MetaBuilderSandboxProfile";
      inherit readOnlyPaths readWritePaths tmpfs
        listenTcp connectTcp connectAny display
        stdio unixSockets
        allowExecve allowFork lifecycle daemonMode
        dns
        sourceAccess sourceWritePaths coordinationWritePaths
        storeAccess;
    };

  toolEnv = { tools ? [ ] }:
    validateOr "toolEnv" mb.descriptions.ToolEnvSpec.T {
      _con = "MetaBuilderToolEnv";
      inherit tools;
    };

  replServer =
    { protocol
    , mode
    , registration ? null
    , port ? null
    , portEnvVar ? null
    , interface ? "127.0.0.1"
    , lifecycle ? lifecycles.LongRunning
    , enable ? true
    , shortLivedFlags ? [ ]
    , extra ? { }
    }:
    let
      resolvedPort =
        if port != null then port
        else if protocol.defaultPort != null then protocol.defaultPort
        else throw "metaBuilder.operations.replServer: port required (protocol '${protocol.name}' has no defaultPort)";
      resolvedEnvVar =
        if portEnvVar != null then portEnvVar
        else if protocol.portEnvVar != null then protocol.portEnvVar
        else throw "metaBuilder.operations.replServer: portEnvVar required (protocol '${protocol.name}' has no portEnvVar)";
      resolvedRegistration =
        if registration != null then registration
        else inferRegistration mode;
    in
    validateOr "replServer" mb.descriptions.REPLServerSpec.T {
      _con = "MetaBuilderREPLServerSpec";
      inherit protocol enable interface mode lifecycle shortLivedFlags extra;
      port = resolvedPort;
      portEnvVar = resolvedEnvVar;
      registration = resolvedRegistration;
    };

  value = {
    parameter = { name, value }: op "MetaBuilderParameter" { inherit name value; };

    localSource = { name, path }: op "localSource" { inherit name path; };
    generatedSource = { name, producer }: op "generatedSource" { inherit name producer; };

    dependency = { name, role ? "runtime", package }:
      op "MetaBuilderDependency" { inherit name role; package = mkThunk package; };
    tool = { name, package }:
      op "MetaBuilderTool" { inherit name; package = mkThunk package; };
    output = { name, path, format ? "path" }: op "MetaBuilderOutput" { inherit name path format; };
    evidence = { name, payload ? { } }: op "MetaBuilderEvidence" { inherit name payload; };
    validation = { name, value }: op "MetaBuilderValidation" { inherit name value; };
    descriptor = { name, payload ? { } }: op "MetaBuilderDescriptor" { inherit name payload; };

    readSource = { name, source }: op "readSource" { inherit name source; };
    resolveDependency = { dependency }: op "resolveDependency" { inherit dependency; };
    declareTool = { tool }: op "declareTool" { inherit tool; };
    runTool = { name, tool, args ? [ ], env ? { } }: op "runTool" { inherit name tool args env; };
    writeFile = { output, text }: op "writeFile" { inherit output text; };
    copyPath = { source, output }: op "copyPath" { inherit source output; };
    transformOutput = { output }: op "transformOutput" { inherit output; };
    validateValue = { validation }: op "validateValue" { inherit validation; };
    emitDescriptor = { descriptor }: op "emitDescriptor" { inherit descriptor; };
    materializeDerivation = { name, builder ? "runCommand" }: op "materializeDerivation" { inherit name builder; };
    declareEvidence = { evidence }: op "declareEvidence" { inherit evidence; };

    inherit transports serializations runtimeTypes
      lifecycles replModes registrationBackends seccompStages;
    inherit param capability capabilityCategory capabilitySet protocol service replServer
      tcpEndpoint displayConfig dnsConfig sandboxProfile
      toolEnv;

    declareCapability = { category }: op "declareCapability" { inherit category; };
    declareProtocol = { protocol }: op "declareProtocol" { inherit protocol; };
    declareService = { service }: op "declareService" { inherit service; };
    materializeUnit = { name }: op "materializeUnit" { inherit name; };

    inherit builderOperationNames runtimeOperationNames;
  };

in
api.mk {
  description = "metaBuilder operations: smart constructors for typed builder and runtime operation records.";
  doc = ''
    # Operations

    Constructors build typed operation records. Execution is handled by
    the internalized `mb.program` desc-interp signature.
  '';
  inherit value;
  tests =
    let
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
      lifecycleCat = value.capabilityCategory {
        name = "lifecycle";
        capabilities = [
          (value.capability { name = "start"; })
          (value.capability { name = "stop"; })
        ];
      };
      lifecycleSet = value.capabilitySet { categories = [ lifecycleCat ]; };
      grpcProto = value.protocol {
        name = "grpc";
        transport = value.transports.TCP;
        serialization = value.serializations.Protobuf;
        capabilities = lifecycleSet;
      };
    in
    {
      "builder-operation-names-cover-description" = {
        expr = value.builderOperationNames;
        expected = map (c: c.name)
          (fx.tc.generic.datatype.datatypeInfo mb.descriptions.BuilderOp.T).constructors;
      };

      "runtime-operation-names-cover-description" = {
        expr = value.runtimeOperationNames;
        expected = map (c: c.name)
          (fx.tc.generic.datatype.datatypeInfo mb.descriptions.RuntimeOp.T).constructors;
      };

      "capability-ctor-defaults-returns-to-RTObject" = {
        expr = (value.capability { name = "ping"; }).returns._con;
        expected = "RTObject";
      };

      "param-ctor-required-defaults-true" = {
        expr = (value.param { name = "id"; type = value.runtimeTypes.RTString; }).required;
        expected = true;
      };

      "protocol-ctor-defaults-port-to-null" = {
        expr = (value.protocol {
          name = "stdio-rpc";
          transport = value.transports.Stdio;
          serialization = value.serializations.JSON;
          capabilities = value.capabilitySet { };
        }).defaultPort;
        expected = null;
      };

      "service-ctor-typed-package-rides-thunk" = {
        expr = fx.state.isThunk (value.service {
          name = "api";
          package = stubDrv "api";
          capabilities = lifecycleSet;
          protocols = [ grpcProto ];
        }).package;
        expected = true;
      };

      "service-ctor-passes-compatible-spec" = {
        expr = (value.service {
          name = "api";
          package = stubDrv "api";
          capabilities = lifecycleSet;
          protocols = [ grpcProto ];
        }).name;
        expected = "api";
      };

      "service-ctor-rejects-incompatible-spec" = {
        expr =
          let
            partialProto = value.protocol {
              name = "weak";
              transport = value.transports.TCP;
              serialization = value.serializations.JSON;
              capabilities = value.capabilitySet {
                categories = [
                  (value.capabilityCategory {
                    name = "lifecycle";
                    capabilities = [ (value.capability { name = "start"; }) ];
                  })
                ];
              };
            };
          in
          (builtins.tryEval (builtins.deepSeq
            (value.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
              protocols = [ partialProto ];
            })
            null)).success;
        expected = false;
      };

      "service-ctor-allows-no-protocols" = {
        expr = (value.service {
          name = "internal";
          package = stubDrv "internal";
          capabilities = lifecycleSet;
        }).name;
        expected = "internal";
      };

      "declare-capability-op-validates-against-runtime-op" = {
        expr = fx.types.validateValue [ ] mb.descriptions.RuntimeOp.T
          (value.declareCapability { category = lifecycleCat; });
        expected = [ ];
      };

      "declare-service-op-validates-against-runtime-op" = {
        expr = fx.types.validateValue [ ] mb.descriptions.RuntimeOp.T
          (value.declareService {
            service = value.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
              protocols = [ grpcProto ];
            };
          });
        expected = [ ];
      };

      "materialize-unit-op-validates-against-runtime-op" = {
        expr = fx.types.validateValue [ ] mb.descriptions.RuntimeOp.T
          (value.materializeUnit { name = "api"; });
        expected = [ ];
      };

      "tcp-endpoint-defaults-address-to-localhost" = {
        expr = (value.tcpEndpoint { port = 8080; }).address;
        expected = "127.0.0.1";
      };

      "tcp-endpoint-typed-shape" = {
        expr = (value.tcpEndpoint { port = 8080; })._con;
        expected = "MetaBuilderTcpEndpoint";
      };

      "display-config-defaults-all-false" = {
        expr = let d = value.displayConfig { }; in
          [ d.wayland d.x11 d.gpu ];
        expected = [ false false false ];
      };

      "sandbox-profile-defaults-empty-shape" = {
        expr = let p = value.sandboxProfile { }; in {
          inherit (p) _con readOnlyPaths tmpfs allowExecve allowFork stdio daemonMode storeAccess;
          lifecycleTag = p.lifecycle._con;
          displayIsNull = p.display == null;
          dnsIsNull = p.dns == null;
        };
        expected = {
          _con = "MetaBuilderSandboxProfile";
          readOnlyPaths = [ "/nix/store" ];
          tmpfs = [ "/tmp" ];
          allowExecve = false;
          allowFork = false;
          stdio = true;
          daemonMode = false;
          storeAccess = false;
          lifecycleTag = "LongRunning";
          displayIsNull = true;
          dnsIsNull = true;
        };
      };

      "sandbox-profile-rejects-malformed-listen-endpoint" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (value.sandboxProfile { listenTcp = [{ port = "not-an-int"; address = "127.0.0.1"; }]; })
          null)).success;
        expected = false;
      };

      "seccomp-stages-closed-sum-values" = {
        expr = {
          bwrapTag = value.seccompStages.Bwrap._con;
          selfTag = value.seccompStages.Self._con;
        };
        expected = {
          bwrapTag = "Bwrap";
          selfTag = "Self";
        };
      };
    };
}
