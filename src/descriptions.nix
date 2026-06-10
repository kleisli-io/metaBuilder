{ fx, api, mb, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;

  ParameterSpec = H.product "MetaBuilderParameter" [
    (H.field "name" H.string)
    (H.field "value" H.any)
  ];

  SourceSpec = H.datatype "MetaBuilderSource" [
    (H.con "localSource" [
      (H.field "name" H.string)
      (H.field "path" H.any)
    ])
    (H.con "generatedSource" [
      (H.field "name" H.string)
      (H.field "producer" H.string)
    ])
  ];

  DependencySpec = H.product "MetaBuilderDependency" [
    ((H.field "name" H.string) // {
      role = "dependency";
      source = { path = "dependency.name"; };
    })
    (H.field "role" H.string)
    (H.field "package" (H.thunk H.derivation))
  ];

  ToolSpec = H.product "MetaBuilderTool" [
    (H.field "name" H.string)
    (H.field "package" (H.thunk H.derivation))
  ];

  # Post-finalize `ToolSpec`: `package` projected to its store path.
  FinalizedToolSpec = H.product "MetaBuilderFinalizedTool" [
    (H.field "name" H.string)
    (H.field "package" H.string)
  ];

  ToolEnvSpec = H.product "MetaBuilderToolEnv" [
    (H.field "tools" (H.listOf ToolSpec.T))
  ];

  OutputSpec = H.product "MetaBuilderOutput" [
    (H.field "name" H.string)
    (H.field "path" H.string)
    (H.field "format" H.string)
  ];

  EvidenceSpec = H.product "MetaBuilderEvidence" [
    (H.field "name" H.string)
    (H.field "payload" H.attrs)
  ];

  ValidationSpec = H.product "MetaBuilderValidation" [
    (H.field "name" H.string)
    (H.field "value" H.any)
  ];

  DescriptorSpec = H.product "MetaBuilderDescriptor" [
    (H.field "name" H.string)
    (H.field "payload" H.attrs)
  ];

  BuilderOp = H.datatype "MetaBuilderOp" [
    (H.con "readSource" [
      (H.field "name" H.string)
      (H.field "source" SourceSpec.T)
    ])
    (H.con "resolveDependency" [
      (H.field "dependency" DependencySpec.T)
    ])
    (H.con "declareTool" [
      (H.field "tool" ToolSpec.T)
    ])
    (H.con "runTool" [
      (H.field "name" H.string)
      (H.field "tool" ToolSpec.T)
      (H.field "args" (H.listOf H.string))
      (H.field "env" H.attrs)
    ])
    (H.con "writeFile" [
      (H.field "output" OutputSpec.T)
      (H.field "text" H.string)
    ])
    (H.con "copyPath" [
      (H.field "source" SourceSpec.T)
      (H.field "output" OutputSpec.T)
    ])
    (H.con "transformOutput" [
      (H.field "output" OutputSpec.T)
    ])
    (H.con "validateValue" [
      (H.field "validation" ValidationSpec.T)
    ])
    (H.con "emitDescriptor" [
      (H.field "descriptor" DescriptorSpec.T)
    ])
    (H.con "materializeDerivation" [
      (H.field "name" H.string)
      (H.field "builder" H.string)
    ])
    (H.con "declareEvidence" [
      (H.field "evidence" EvidenceSpec.T)
    ])
  ];

  BuilderSpec = H.product "MetaBuilderSpec" [
    ((H.field "name" H.string) // {
      role = "dependency";
      source = { path = "builder.name"; };
    })
    (H.field "parameters" (H.listOf ParameterSpec.T))
    (H.field "inputs" (H.listOf SourceSpec.T))
    (H.field "dependencies" (H.listOf DependencySpec.T))
    (H.field "tools" (H.listOf ToolSpec.T))
    (H.field "operations" (H.listOf BuilderEff))
    (H.field "outputs" (H.listOf OutputSpec.T))
    (H.field "evidence" (H.listOf EvidenceSpec.T))
  ];

  BuildPlanStep = H.datatype "MetaBuilderPlanStep" [
    (H.con "runStep" [
      (H.field "name" H.string)
      (H.field "tool" FinalizedToolSpec.T)
      (H.field "args" (H.listOf H.string))
      (H.field "env" H.attrs)
    ])
    (H.con "writeStep" [
      (H.field "name" H.string)
      (H.field "path" H.string)
      (H.field "text" H.string)
    ])
    (H.con "copyStep" [
      (H.field "name" H.string)
      (H.field "source" SourceSpec.T)
      (H.field "path" H.string)
    ])
    (H.con "mkdirStep" [
      (H.field "path" H.string)
    ])
  ];

  # `storePath`: projected output of the artifact derivation.
  RuntimeArtifact = H.product "MetaBuilderRuntimeArtifact" [
    (H.field "kind" H.string)
    (H.field "name" H.string)
    (H.field "descriptor" H.attrs)
    (H.field "storePath" H.string)
  ];

  # Return shape of `mb.program.materialize.run`. `value` is the
  # program's effect-return payload (caller-defined, hence `H.any`);
  # `derivation` is the lowered `runCommand`.
  MaterializeResult = H.product "MetaBuilderMaterializeResult" [
    (H.field "plan" BuildPlan.T)
    (H.field "value" H.any)
    (H.field "derivation" H.derivation)
  ];

  # Diagnostic projection of `RuntimeArtifact` produced by
  # `mb.program.plan-view.viewArtifact`. All four fields are strings —
  # this is a display surface, not a structural witness.
  RuntimeArtifactView = H.product "MetaBuilderRuntimeArtifactView" [
    (H.field "kind" H.string)
    (H.field "name" H.string)
    (H.field "summary" H.string)
    (H.field "drvName" H.string)
  ];

  BuildPlan = H.product "MetaBuilderPlan" [
    (H.field "name" H.string)
    (H.field "builder" H.string)
    (H.field "tools" (H.listOf FinalizedToolSpec.T))
    (H.field "outputs" (H.listOf OutputSpec.T))
    (H.field "pathMap" H.attrs)
    (H.field "nativePaths" (H.listOf H.string))
    (H.field "steps" (H.listOf BuildPlanStep.T))
    (H.field "declaredCapabilities" (H.listOf CapabilityCategory.T))
    (H.field "declaredProtocols" (H.listOf ProtocolSpec.T))
    (H.field "declaredServices" (H.listOf FinalizedServiceSpec.T))
    (H.field "runtimeArtifacts" (H.listOf RuntimeArtifact.T))
  ];

  # Boxed live derivation → store-path string. The string carries eval
  # context (derivation edges survive); lossy, so no section.
  storePathOrnament = H.leafOrnament {
    primitive = H.thunk H.derivation;
    forget = t: toString (fx.state.forceThunk t);
    section = _: throw "metaBuilder.storePathOrnament: a store path does not determine a derivation";
    meta = { name = "MetaBuilderStorePath"; inner = H.string; };
  };

  # As `storePathOrnament`, but projects the `lib` output root.
  libRootOrnament = H.leafOrnament {
    primitive = H.thunk H.derivation;
    forget = t: toString (lib.getLib (fx.state.forceThunk t));
    section = _: throw "metaBuilder.libRootOrnament: a store path does not determine a derivation";
    meta = { name = "MetaBuilderLibRoot"; inner = H.string; };
  };

  # As `storePathOrnament`, but projects the `dev` output root — what
  # mkDerivation would select for a derivation in `nativeBuildInputs`.
  devRootOrnament = H.leafOrnament {
    primitive = H.thunk H.derivation;
    forget = t: toString (lib.getDev (fx.state.forceThunk t));
    section = _: throw "metaBuilder.devRootOrnament: a store path does not determine a derivation";
    meta = { name = "MetaBuilderDevRoot"; inner = H.string; };
  };

  # State-side records reuse the base constructor name (kernel ornament
  # convention) and keep `package` boxed; `forget` projects it.
  ToolStateForget = G.ornaments.ornament FinalizedToolSpec {
    name = "MetaBuilderToolForget";
    constructors.MetaBuilderFinalizedTool.fields = [
      { keep = "name"; }
      { keep = "package"; sub = devRootOrnament; }
    ];
  };

  ServiceStateForget = G.ornaments.ornament FinalizedServiceSpec {
    name = "MetaBuilderServiceForget";
    constructors.MetaBuilderFinalizedService.fields = [
      { keep = "name"; }
      { keep = "description"; }
      { keep = "package"; sub = storePathOrnament; }
      { keep = "capabilities"; }
      { keep = "protocols"; }
      { keep = "config"; }
    ];
  };

  toToolState = tool: {
    _con = "MetaBuilderFinalizedTool";
    inherit (tool) name package;
  };

  toServiceState = svc: {
    _con = "MetaBuilderFinalizedService";
    inherit (svc) name description package capabilities protocols config;
  };

  # Steps are born finalized: a recorded step never holds a live drv.
  finalizeTool = tool: {
    _con = "MetaBuilderFinalizedTool";
    inherit (tool) name;
    package = devRootOrnament.forget tool.package;
  };

  RuntimeArtifactStateForget = G.ornaments.ornament RuntimeArtifact {
    name = "MetaBuilderRuntimeArtifactForget";
    constructors.MetaBuilderRuntimeArtifact.fields = [
      { keep = "kind"; }
      { keep = "name"; }
      { keep = "descriptor"; }
      { keep = "storePath"; sub = storePathOrnament; }
    ];
  };

  # The builder kind: op-coproduct and state-ornament derived together by
  # `mkBuilderKind` so they cannot drift. Sole binding site — `signature`,
  # `operations`, and `materialize` consume the derived surface.
  #
  # The state spec ornaments `BuildPlan`: derivation carriers stay boxed
  # in-flight and forget to store-path strings; `declaredTools`/
  # `serviceIndex` lookup inserts the forget drops.
  builderKind = mb.program.former.mkBuilderKind {
    name = "metaBuilder";
    base = BuildPlan;
    builderOps = BuilderOp;
    runtimeOps = RuntimeOp;
    stateSpec = {
      name = "MetaBuilderPlanState";
      constructors.MetaBuilderPlan.fields = [
        { keep = "name"; }
        { keep = "builder"; }
        { keep = "tools"; sub = G.ornaments.lift.list ToolStateForget; }
        { keep = "outputs"; }
        { keep = "pathMap"; }
        { keep = "nativePaths"; sub = G.ornaments.lift.list libRootOrnament; }
        { keep = "steps"; }
        { keep = "declaredCapabilities"; }
        { keep = "declaredProtocols"; }
        { keep = "declaredServices"; sub = G.ornaments.lift.list ServiceStateForget; }
        { keep = "runtimeArtifacts"; sub = G.ornaments.lift.list RuntimeArtifactStateForget; }
        { insert = "declaredTools"; type = H.attrs; }
        { insert = "serviceIndex"; type = H.attrs; }
      ];
    };
  };

  PlanState = builderKind.State;

  Transport = H.datatype "MetaBuilderTransport" [
    (H.con "TCP" [ ])
    (H.con "Unix" [ ])
    (H.con "Stdio" [ ])
  ];

  Serialization = H.datatype "MetaBuilderSerialization" [
    (H.con "JSON" [ ])
    (H.con "Protobuf" [ ])
    (H.con "Sexp" [ ])
    (H.con "MsgPack" [ ])
    (H.con "Bencode" [ ])
  ];

  RuntimeType = H.datatype "MetaBuilderRuntimeType" [
    (H.con "RTString" [ ])
    (H.con "RTInt" [ ])
    (H.con "RTBool" [ ])
    (H.con "RTObject" [ ])
    (H.con "RTArray" [ ])
  ];

  ParamSpec = H.product "MetaBuilderParam" [
    (H.field "name" H.string)
    (H.field "description" H.string)
    (H.field "type" RuntimeType.T)
    (H.field "required" H.bool)
  ];

  CapabilitySchema = H.product "MetaBuilderCapabilitySchema" [
    (H.field "name" H.string)
    (H.field "description" H.string)
    (H.field "params" (H.listOf ParamSpec.T))
    (H.field "returns" RuntimeType.T)
  ];

  CapabilityCategory = H.product "MetaBuilderCapabilityCategory" [
    (H.field "name" H.string)
    (H.field "description" H.string)
    (H.field "capabilities" (H.listOf CapabilitySchema.T))
  ];

  CapabilitySet = H.product "MetaBuilderCapabilitySet" [
    (H.field "categories" (H.listOf CapabilityCategory.T))
    (H.field "custom" (H.listOf CapabilitySchema.T))
  ];

  ProtocolSpec = H.product "MetaBuilderProtocolSpec" [
    (H.field "name" H.string)
    (H.field "description" H.string)
    (H.field "transport" Transport.T)
    (H.field "serialization" Serialization.T)
    (H.field "defaultPort" (H.maybe H.int_))
    (H.field "portEnvVar" (H.maybe H.string))
    (H.field "capabilities" CapabilitySet.T)
    (H.field "options" H.attrs)
  ];

  ServiceSpec = H.product "MetaBuilderServiceSpec" [
    (H.field "name" H.string)
    (H.field "description" H.string)
    (H.field "package" (H.thunk H.derivation))
    (H.field "capabilities" CapabilitySet.T)
    (H.field "protocols" (H.listOf ProtocolSpec.T))
    (H.field "config" (H.listOf ParamSpec.T))
  ];

  # Post-finalize `ServiceSpec`: `package` projected to its store path.
  FinalizedServiceSpec = H.product "MetaBuilderFinalizedService" [
    (H.field "name" H.string)
    (H.field "description" H.string)
    (H.field "package" H.string)
    (H.field "capabilities" CapabilitySet.T)
    (H.field "protocols" (H.listOf ProtocolSpec.T))
    (H.field "config" (H.listOf ParamSpec.T))
  ];

  RuntimeOp = H.datatype "MetaBuilderRuntimeOp" [
    (H.con "declareCapability" [
      (H.field "category" CapabilityCategory.T)
    ])
    (H.con "declareProtocol" [
      (H.field "protocol" ProtocolSpec.T)
    ])
    (H.con "declareService" [
      (H.field "service" ServiceSpec.T)
    ])
    (H.con "materializeUnit" [
      (H.field "name" H.string)
    ])
  ];

  # Total operation signature: the coproduct over which programs range.
  # Named here so the spec carrier can speak the kernel's alphabet.
  BuilderEff = builderKind.Eff;

  BuilderDocOperation = H.product "MetaBuilderDocOperation" [
    (H.field "domain" H.string)
    (H.field "constructor" H.string)
    (H.field "name" H.string)
    (H.field "summary" H.string)
  ];

  BuilderDocumentation = H.product "MetaBuilderDocumentation" [
    (H.field "name" H.string)
    (H.field "builder" H.string)
    (H.field "inputs" (H.listOf SourceSpec.T))
    (H.field "dependencies" (H.listOf DependencySpec.T))
    (H.field "tools" (H.listOf ToolSpec.T))
    (H.field "outputs" (H.listOf OutputSpec.T))
    (H.field "descriptors" (H.listOf DescriptorSpec.T))
    (H.field "evidence" (H.listOf EvidenceSpec.T))
    (H.field "operations" (H.listOf BuilderDocOperation.T))
    (H.field "runtimeCapabilities" (H.listOf CapabilityCategory.T))
    (H.field "runtimeProtocols" (H.listOf ProtocolSpec.T))
    (H.field "runtimeServices" (H.listOf ServiceSpec.T))
    (H.field "materializedUnits" (H.listOf H.string))
  ];

  Lifecycle = H.datatype "MetaBuilderLifecycle" [
    (H.con "LongRunning" [ ])
    (H.con "OneShot" [ ])
  ];

  REPLMode = H.datatype "MetaBuilderREPLMode" [
    (H.con "Foreground" [ ])
    (H.con "Background" [ ])
  ];

  RegistrationBackend = H.datatype "MetaBuilderRegistrationBackend" [
    (H.con "XDG" [ ])
    (H.con "Global" [ ])
    (H.con "ServiceSpec" [ ])
    (H.con "None" [ ])
  ];

  REPLServerSpec = H.product "MetaBuilderREPLServerSpec" [
    (H.field "protocol" ProtocolSpec.T)
    (H.field "enable" H.bool)
    (H.field "port" H.int_)
    (H.field "portEnvVar" H.string)
    (H.field "interface" H.string)
    (H.field "mode" REPLMode.T)
    (H.field "registration" RegistrationBackend.T)
    (H.field "lifecycle" Lifecycle.T)
    (H.field "shortLivedFlags" (H.listOf H.string))
    (H.field "extra" H.attrs)
  ];

  SeccompStage = H.datatype "MetaBuilderSeccompStage" [
    (H.con "Bwrap" [ ])
    (H.con "Self" [ ])
  ];

  DisplayConfig = H.product "MetaBuilderDisplayConfig" [
    (H.field "wayland" H.bool)
    (H.field "x11" H.bool)
    (H.field "gpu" H.bool)
  ];

  TcpEndpoint = H.product "MetaBuilderTcpEndpoint" [
    (H.field "port" H.int_)
    (H.field "address" H.string)
  ];

  DnsConfig = H.product "MetaBuilderDnsConfig" [
    (H.field "nsswitch" (H.thunk H.derivation))
    (H.field "resolv" (H.thunk H.derivation))
    (H.field "extraBinds" (H.listOf H.string))
  ];

  SandboxProfile = H.product "MetaBuilderSandboxProfile" [
    (H.field "readOnlyPaths" (H.listOf H.string))
    (H.field "readWritePaths" (H.listOf H.string))
    (H.field "tmpfs" (H.listOf H.string))
    (H.field "listenTcp" (H.listOf TcpEndpoint.T))
    (H.field "connectTcp" (H.listOf TcpEndpoint.T))
    (H.field "connectAny" H.bool)
    (H.field "display" (H.maybe DisplayConfig.T))
    (H.field "stdio" H.bool)
    (H.field "unixSockets" (H.listOf H.string))
    (H.field "allowExecve" H.bool)
    (H.field "allowFork" H.bool)
    (H.field "lifecycle" Lifecycle.T)
    (H.field "daemonMode" H.bool)
    (H.field "dns" (H.maybe DnsConfig.T))
    (H.field "sourceAccess" H.bool)
    (H.field "sourceWritePaths" (H.listOf H.string))
    (H.field "coordinationWritePaths" (H.listOf H.string))
    (H.field "storeAccess" H.bool)
  ];

  LandlockProfile = H.product "MetaBuilderLandlockProfile" [
    (H.field "readOnlyPaths" (H.listOf H.string))
    (H.field "readWritePaths" (H.listOf H.string))
    (H.field "listenPorts" (H.listOf H.int_))
    (H.field "connectPorts" (H.listOf H.int_))
    (H.field "connectAny" H.bool)
    (H.field "allowExecve" H.bool)
  ];

  SystemdHardening = H.product "MetaBuilderSystemdHardening" [
    (H.field "protectSystem" H.string)
    (H.field "protectHome" H.bool)
    (H.field "privateTmp" H.bool)
    (H.field "noNewPrivileges" H.bool)
    (H.field "readOnlyPaths" (H.listOf H.string))
    (H.field "readWritePaths" (H.listOf H.string))
    (H.field "systemCallFilter" (H.listOf H.string))
    (H.field "restrictNamespaces" H.bool)
    (H.field "privateDevices" H.bool)
  ];

  allCapabilityNames = capSet:
    let
      fromCats = builtins.concatMap
        (cat: map (cap: cap.name) cat.capabilities)
        capSet.categories;
      fromCustom = map (cap: cap.name) capSet.custom;
    in
    fromCats ++ fromCustom;

  hasCapability = capSet: capName:
    builtins.elem capName (allCapabilityNames capSet);

  protocolSatisfies = proto: requiredCapSet:
    builtins.all
      (n: hasCapability proto.capabilities n)
      (allCapabilityNames requiredCapSet);

  compatibility = svc:
    let
      capNames = allCapabilityNames svc.capabilities;
      hasProtocols = builtins.length svc.protocols > 0;
      hasCapabilities = builtins.length capNames > 0;
      anySatisfies = builtins.any
        (p: protocolSatisfies p svc.capabilities)
        svc.protocols;
      unsatisfied = builtins.filter
        (p: !(protocolSatisfies p svc.capabilities))
        svc.protocols;
      errorFor = p:
        let
          missing = builtins.filter
            (n: !(hasCapability p.capabilities n))
            capNames;
        in
        "Protocol '${p.name}' cannot satisfy capabilities: "
        + builtins.concatStringsSep ", " missing;
    in
    if !hasProtocols then { valid = true; errors = [ ]; }
    else if !hasCapabilities then { valid = true; errors = [ ]; }
    else if anySatisfies then { valid = true; errors = [ ]; }
    else { valid = false; errors = map errorFor unsatisfied; };

  # Generic value-level projection: walk a typed value via `G.datatypeInfo`
  # and produce a JSON-shaped attrset.
  #  - Pure enum datatypes (all constructors empty): flatten `_con` to its tag.
  #  - Single-constructor records: walk each declared field; drop fields whose
  #    declared type is `H.thunk ...` (non-JSON state, deferred by Thunk-lift).
  #  - Multi-constructor datatypes: dispatch on `_con`, emit `{ _con }` plus
  #    that constructor's projected fields (same thunk-drop rule).
  #  - `H.listOf X`: map projection over elements.
  #  - `H.maybe X`: null passes through; otherwise project on `X`.
  #  - Primitives (string/int/attrs/derivation/any) and non-attrset Nix
  #    values (bools, numbers reaching a `mu`-typed slot): pass through.
  projectValue =
    let
      isPureEnum = info:
        builtins.all (c: (c.fields or [ ]) == [ ]) info.constructors;

      projectMu = ty: value:
        if !(builtins.isAttrs value) then value
        else
          let
            info = G.datatype.datatypeInfo ty;
            keepField = f: (f.type._htag or null) != "thunk";
            projectCon = con:
              builtins.listToAttrs (map
                (f: {
                  inherit (f) name;
                  value = go f.type value.${f.name};
                })
                (builtins.filter keepField (con.fields or [ ])));
            conNamed = name:
              let matches = builtins.filter (c: c.name == name) info.constructors;
              in
              if matches == [ ]
              then
                throw ("runtime.projectValue: value constructor "
                  + "'${toString name}' not in datatype '${info.name}'")
              else builtins.head matches;
          in
          if isPureEnum info then value._con
          else if builtins.length info.constructors == 1 then
            projectCon (builtins.head info.constructors)
          else
            let
              conName = value._con or
                (throw ("runtime.projectValue: multi-constructor value "
                  + "lacks `_con` (datatype '${info.name}')"));
            in
            { _con = conName; } // projectCon (conNamed conName);

      go = ty: value:
        let htag = ty._htag or null; in
        if htag == "string" then value
        else if htag == "int" then value
        else if htag == "attrs" then value
        else if htag == "derivation" then value
        else if htag == "any" then value
        else if htag == "thunk" then null
        else if htag == "maybe" then
          if value == null then null else go ty.inner value
        else if htag == "app" then
          let headName = ty.fn._dtypeMeta.name or null; in
          if headName == "List" then map (go ty.arg) value
          else
            throw ("runtime.projectValue: unsupported app head "
              + "'${toString headName}'")
        else if htag == "mu" then projectMu ty value
        else throw "runtime.projectValue: unsupported _htag '${toString htag}'";
    in
    go;

  descriptor = projectValue ServiceSpec.T;

  value = {
    inherit
      ParameterSpec
      SourceSpec
      DependencySpec
      ToolSpec
      FinalizedToolSpec
      ToolEnvSpec
      OutputSpec
      EvidenceSpec
      ValidationSpec
      DescriptorSpec
      BuilderOp
      BuilderEff
      BuilderSpec
      BuildPlanStep
      RuntimeArtifact
      RuntimeArtifactStateForget
      ToolStateForget
      ServiceStateForget
      storePathOrnament
      libRootOrnament
      devRootOrnament
      RuntimeArtifactView
      BuildPlan
      builderKind
      PlanState
      MaterializeResult
      Transport
      Serialization
      RuntimeType
      ParamSpec
      CapabilitySchema
      CapabilityCategory
      CapabilitySet
      ProtocolSpec
      ServiceSpec
      FinalizedServiceSpec
      RuntimeOp
      BuilderDocOperation
      BuilderDocumentation
      Lifecycle
      REPLMode
      RegistrationBackend
      REPLServerSpec
      SeccompStage
      DisplayConfig
      TcpEndpoint
      DnsConfig
      SandboxProfile
      LandlockProfile
      SystemdHardening;
    types = {
      parameter = ParameterSpec;
      source = SourceSpec;
      dependency = DependencySpec;
      tool = ToolSpec;
      finalizedTool = FinalizedToolSpec;
      toolEnv = ToolEnvSpec;
      output = OutputSpec;
      evidence = EvidenceSpec;
      validation = ValidationSpec;
      descriptor = DescriptorSpec;
      op = BuilderOp;
      spec = BuilderSpec;
      planStep = BuildPlanStep;
      runtimeArtifact = RuntimeArtifact;
      runtimeArtifactView = RuntimeArtifactView;
      plan = BuildPlan;
      materializeResult = MaterializeResult;
      transport = Transport;
      serialization = Serialization;
      runtimeType = RuntimeType;
      param = ParamSpec;
      capabilitySchema = CapabilitySchema;
      capabilityCategory = CapabilityCategory;
      capabilitySet = CapabilitySet;
      protocol = ProtocolSpec;
      service = ServiceSpec;
      finalizedService = FinalizedServiceSpec;
      runtimeOp = RuntimeOp;
      builderDocOperation = BuilderDocOperation;
      builderDocumentation = BuilderDocumentation;
      lifecycle = Lifecycle;
      replMode = REPLMode;
      registrationBackend = RegistrationBackend;
      replServer = REPLServerSpec;
      seccompStage = SeccompStage;
      displayConfig = DisplayConfig;
      tcpEndpoint = TcpEndpoint;
      dnsConfig = DnsConfig;
      sandboxProfile = SandboxProfile;
      landlockProfile = LandlockProfile;
      systemdHardening = SystemdHardening;
    };
    descriptors = {
      parameter = G.derive.deriveDescriptor ParameterSpec;
      source = G.derive.deriveDescriptor SourceSpec;
      dependency = G.derive.deriveDescriptor DependencySpec;
      tool = G.derive.deriveDescriptor ToolSpec;
      finalizedTool = G.derive.deriveDescriptor FinalizedToolSpec;
      toolEnv = G.derive.deriveDescriptor ToolEnvSpec;
      output = G.derive.deriveDescriptor OutputSpec;
      evidence = G.derive.deriveDescriptor EvidenceSpec;
      validation = G.derive.deriveDescriptor ValidationSpec;
      descriptor = G.derive.deriveDescriptor DescriptorSpec;
      op = G.derive.deriveDescriptor BuilderOp;
      spec = G.derive.deriveDescriptor BuilderSpec;
      planStep = G.derive.deriveDescriptor BuildPlanStep;
      runtimeArtifact = G.derive.deriveDescriptor RuntimeArtifact;
      runtimeArtifactView = G.derive.deriveDescriptor RuntimeArtifactView;
      plan = G.derive.deriveDescriptor BuildPlan;
      materializeResult = G.derive.deriveDescriptor MaterializeResult;
      transport = G.derive.deriveDescriptor Transport;
      serialization = G.derive.deriveDescriptor Serialization;
      runtimeType = G.derive.deriveDescriptor RuntimeType;
      param = G.derive.deriveDescriptor ParamSpec;
      capabilitySchema = G.derive.deriveDescriptor CapabilitySchema;
      capabilityCategory = G.derive.deriveDescriptor CapabilityCategory;
      capabilitySet = G.derive.deriveDescriptor CapabilitySet;
      protocol = G.derive.deriveDescriptor ProtocolSpec;
      service = G.derive.deriveDescriptor ServiceSpec;
      finalizedService = G.derive.deriveDescriptor FinalizedServiceSpec;
      runtimeOp = G.derive.deriveDescriptor RuntimeOp;
      builderDocOperation = G.derive.deriveDescriptor BuilderDocOperation;
      builderDocumentation = G.derive.deriveDescriptor BuilderDocumentation;
      lifecycle = G.derive.deriveDescriptor Lifecycle;
      replMode = G.derive.deriveDescriptor REPLMode;
      registrationBackend = G.derive.deriveDescriptor RegistrationBackend;
      replServer = G.derive.deriveDescriptor REPLServerSpec;
      seccompStage = G.derive.deriveDescriptor SeccompStage;
      displayConfig = G.derive.deriveDescriptor DisplayConfig;
      tcpEndpoint = G.derive.deriveDescriptor TcpEndpoint;
      dnsConfig = G.derive.deriveDescriptor DnsConfig;
      sandboxProfile = G.derive.deriveDescriptor SandboxProfile;
      landlockProfile = G.derive.deriveDescriptor LandlockProfile;
      systemdHardening = G.derive.deriveDescriptor SystemdHardening;
    };
    schemas = {
      parameter = G.derive.deriveSchema ParameterSpec;
      source = G.derive.deriveSchema SourceSpec;
      dependency = G.derive.deriveSchema DependencySpec;
      tool = G.derive.deriveSchema ToolSpec;
      finalizedTool = G.derive.deriveSchema FinalizedToolSpec;
      toolEnv = G.derive.deriveSchema ToolEnvSpec;
      output = G.derive.deriveSchema OutputSpec;
      evidence = G.derive.deriveSchema EvidenceSpec;
      validation = G.derive.deriveSchema ValidationSpec;
      descriptor = G.derive.deriveSchema DescriptorSpec;
      op = G.derive.deriveSchema BuilderOp;
      spec = G.derive.deriveSchema BuilderSpec;
      planStep = G.derive.deriveSchema BuildPlanStep;
      runtimeArtifact = G.derive.deriveSchema RuntimeArtifact;
      runtimeArtifactView = G.derive.deriveSchema RuntimeArtifactView;
      plan = G.derive.deriveSchema BuildPlan;
      materializeResult = G.derive.deriveSchema MaterializeResult;
      transport = G.derive.deriveSchema Transport;
      serialization = G.derive.deriveSchema Serialization;
      runtimeType = G.derive.deriveSchema RuntimeType;
      param = G.derive.deriveSchema ParamSpec;
      capabilitySchema = G.derive.deriveSchema CapabilitySchema;
      capabilityCategory = G.derive.deriveSchema CapabilityCategory;
      capabilitySet = G.derive.deriveSchema CapabilitySet;
      protocol = G.derive.deriveSchema ProtocolSpec;
      service = G.derive.deriveSchema ServiceSpec;
      finalizedService = G.derive.deriveSchema FinalizedServiceSpec;
      runtimeOp = G.derive.deriveSchema RuntimeOp;
      builderDocOperation = G.derive.deriveSchema BuilderDocOperation;
      builderDocumentation = G.derive.deriveSchema BuilderDocumentation;
      lifecycle = G.derive.deriveSchema Lifecycle;
      replMode = G.derive.deriveSchema REPLMode;
      registrationBackend = G.derive.deriveSchema RegistrationBackend;
      replServer = G.derive.deriveSchema REPLServerSpec;
      seccompStage = G.derive.deriveSchema SeccompStage;
      displayConfig = G.derive.deriveSchema DisplayConfig;
      tcpEndpoint = G.derive.deriveSchema TcpEndpoint;
      dnsConfig = G.derive.deriveSchema DnsConfig;
      sandboxProfile = G.derive.deriveSchema SandboxProfile;
      landlockProfile = G.derive.deriveSchema LandlockProfile;
      systemdHardening = G.derive.deriveSchema SystemdHardening;
    };
    runtime = {
      inherit allCapabilityNames hasCapability protocolSatisfies compatibility
        descriptor projectValue;
    };
    inherit toToolState toServiceState finalizeTool;
  };

in
api.mk {
  description = "metaBuilder descriptions: generated datatypes for typed builder specifications and builder operations.";
  doc = ''
    # Descriptions

    `BuilderSpec` and `BuilderOp` are generated datatypes. They are the
    typed backing for validation, schemas, docs, dependency views, and
    program interpretation.

    Domain datatypes keep payloads typed before programs interpret them:
    sources, dependencies, tools, outputs, evidence, validations,
    descriptors, and parameters.
  '';
  inherit value;
  tests =
    let
      capSchema = name: { _con = "MetaBuilderCapabilitySchema"; inherit name; description = ""; params = [ ]; returns = { _con = "RTObject"; }; };
      category = name: caps: { _con = "MetaBuilderCapabilityCategory"; inherit name; description = ""; capabilities = caps; };
      capSet = categories: custom: { _con = "MetaBuilderCapabilitySet"; inherit categories custom; };
      proto = name: caps: {
        _con = "MetaBuilderProtocolSpec";
        inherit name; description = "";
        transport = { _con = "TCP"; };
        serialization = { _con = "JSON"; };
        defaultPort = null;
        portEnvVar = null;
        capabilities = caps;
        options = { };
      };
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
    in
    {
      "builder-op-datatype" = {
        expr = value.BuilderOp ? T;
        expected = true;
      };
      "builder-spec-schema" = {
        expr = (value.schemas.spec.oneOf or [ ]) != [ ];
        expected = true;
      };
      "build-plan-datatype" = {
        expr = value.BuildPlan ? T;
        expected = true;
      };
      "build-plan-step-datatype" = {
        expr = value.BuildPlanStep ? T;
        expected = true;
      };
      "finalized-tool-datatype" = {
        expr = value.FinalizedToolSpec ? T;
        expected = true;
      };
      "finalized-service-datatype" = {
        expr = value.FinalizedServiceSpec ? T;
        expected = true;
      };
      "store-path-ornament-projects-boxed-derivation" = {
        expr = storePathOrnament.forget (fx.state.mkThunk (stubDrv "cc"));
        expected = "/nix/store/fake-cc";
      };
      "lib-root-ornament-selects-lib-output" = {
        expr = libRootOrnament.forget
          (fx.state.mkThunk (stubDrv "ssl" // { lib = stubDrv "ssl-lib"; }));
        expected = "/nix/store/fake-ssl-lib";
      };
      "lib-root-ornament-defaults-to-out-path" = {
        expr = libRootOrnament.forget (fx.state.mkThunk (stubDrv "zlib"));
        expected = "/nix/store/fake-zlib";
      };
      "tool-state-forget-projects-package" = {
        expr = G.ornaments.forget ToolStateForget (toToolState {
          name = "cc";
          package = fx.state.mkThunk (stubDrv "cc");
        });
        expected = {
          _con = "MetaBuilderFinalizedTool";
          name = "cc";
          package = "/nix/store/fake-cc";
        };
      };
      "service-state-forget-projects-package" = {
        expr =
          let
            svc = toServiceState {
              name = "api";
              description = "";
              package = fx.state.mkThunk (stubDrv "api");
              capabilities = capSet [ ] [ ];
              protocols = [ ];
              config = [ ];
            };
            forgotten = G.ornaments.forget ServiceStateForget svc;
          in
          { inherit (forgotten) _con name package; };
        expected = {
          _con = "MetaBuilderFinalizedService";
          name = "api";
          package = "/nix/store/fake-api";
        };
      };
      "finalize-tool-is-born-projected" = {
        expr = finalizeTool {
          _con = "MetaBuilderTool";
          name = "cc";
          package = fx.state.mkThunk (stubDrv "cc");
        };
        expected = {
          _con = "MetaBuilderFinalizedTool";
          name = "cc";
          package = "/nix/store/fake-cc";
        };
      };
      "build-plan-type-mentions-no-derivation" = {
        expr =
          let
            mentions = seen: ty:
              let htag = ty._htag or null; in
              if htag == "derivation" then true
              else if htag == "thunk" || htag == "maybe" then mentions seen ty.inner
              else if htag == "app" then mentions seen ty.arg
              else if htag == "mu" then
                let info = G.datatype.datatypeInfo ty; in
                if builtins.elem info.name seen then false
                else builtins.any
                  (c: builtins.any
                    (f: mentions (seen ++ [ info.name ]) f.type)
                    (c.fields or [ ]))
                  info.constructors
              else false;
          in
          mentions [ ] value.BuildPlan.T;
        expected = false;
      };
      "runtime-artifact-datatype" = {
        expr = value.RuntimeArtifact ? T;
        expected = true;
      };
      "runtime-artifact-state-forget-ornament" = {
        expr = value.RuntimeArtifactStateForget ? T
          && value.RuntimeArtifactStateForget ? _ornMeta;
        expected = true;
      };
      "plan-state-datatype" = {
        expr = value.PlanState ? T
          && value.PlanState ? _ornMeta;
        expected = true;
      };
      # Keep-markers cover BuildPlan's fields exactly; inserts add the two index fields.
      "plan-state-ornament-covers-base-field-set" = {
        expr =
          let
            names = ty: map (f: f.name)
              (builtins.head (G.datatype.datatypeInfo ty).constructors).fields;
            base = names value.BuildPlan.T;
            state = names value.PlanState.T;
            inserts = builtins.filter (n: !(builtins.elem n base)) state;
            dropped = builtins.filter (n: !(builtins.elem n state)) base;
          in
          { inherit inserts dropped; coversInOrder = state == base ++ inserts; };
        expected = {
          inserts = [ "declaredTools" "serviceIndex" ];
          dropped = [ ];
          coversInOrder = true;
        };
      };
      "build-plan-schema-non-empty" = {
        expr = (value.schemas.plan.oneOf or [ ]) != [ ];
        expected = true;
      };
      "runtime-artifact-schema-non-empty" = {
        expr = (value.schemas.runtimeArtifact.oneOf or [ ]) != [ ];
        expected = true;
      };
      "materialize-result-datatype" = {
        expr = value.MaterializeResult ? T;
        expected = true;
      };
      "materialize-result-schema-non-empty" = {
        expr = (value.schemas.materializeResult.oneOf or [ ]) != [ ];
        expected = true;
      };
      "runtime-artifact-view-datatype" = {
        expr = value.RuntimeArtifactView ? T;
        expected = true;
      };
      "runtime-artifact-view-schema-non-empty" = {
        expr = (value.schemas.runtimeArtifactView.oneOf or [ ]) != [ ];
        expected = true;
      };

      "sandbox-seccomp-stage-datatype" = { expr = value.SeccompStage ? T; expected = true; };
      "sandbox-display-config-datatype" = { expr = value.DisplayConfig ? T; expected = true; };
      "sandbox-tcp-endpoint-datatype" = { expr = value.TcpEndpoint ? T; expected = true; };
      "sandbox-dns-config-datatype" = { expr = value.DnsConfig ? T; expected = true; };
      "sandbox-profile-datatype" = { expr = value.SandboxProfile ? T; expected = true; };
      "sandbox-landlock-profile-datatype" = { expr = value.LandlockProfile ? T; expected = true; };
      "sandbox-systemd-hardening-datatype" = { expr = value.SystemdHardening ? T; expected = true; };
      "sandbox-profile-schema-non-empty" = {
        expr = (value.schemas.sandboxProfile.oneOf or [ ]) != [ ];
        expected = true;
      };
      "sandbox-seccomp-stage-schema-non-empty" = {
        expr = (value.schemas.seccompStage.oneOf or [ ]) != [ ];
        expected = true;
      };

      "runtime-transport-datatype" = { expr = value.Transport ? T; expected = true; };
      "runtime-serialization-datatype" = { expr = value.Serialization ? T; expected = true; };
      "runtime-type-datatype" = { expr = value.RuntimeType ? T; expected = true; };
      "runtime-param-datatype" = { expr = value.ParamSpec ? T; expected = true; };
      "runtime-capability-schema-datatype" = { expr = value.CapabilitySchema ? T; expected = true; };
      "runtime-capability-category-datatype" = { expr = value.CapabilityCategory ? T; expected = true; };
      "runtime-capability-set-datatype" = { expr = value.CapabilitySet ? T; expected = true; };
      "runtime-protocol-spec-datatype" = { expr = value.ProtocolSpec ? T; expected = true; };
      "runtime-service-spec-datatype" = { expr = value.ServiceSpec ? T; expected = true; };

      "runtime-transport-schema-non-empty" = {
        expr = (value.schemas.transport.oneOf or [ ]) != [ ];
        expected = true;
      };
      "runtime-service-schema-non-empty" = {
        expr = (value.schemas.service.oneOf or [ ]) != [ ];
        expected = true;
      };
      "runtime-capability-set-schema-non-empty" = {
        expr = (value.schemas.capabilitySet.oneOf or [ ]) != [ ];
        expected = true;
      };

      "compatibility-no-protocols-is-valid" = {
        expr = (compatibility {
          capabilities = capSet [ (category "lifecycle" [ (capSchema "start") ]) ] [ ];
          protocols = [ ];
        }).valid;
        expected = true;
      };
      "compatibility-no-capabilities-is-valid" = {
        expr = (compatibility {
          capabilities = capSet [ ] [ ];
          protocols = [ (proto "rpc" (capSet [ ] [ ])) ];
        }).valid;
        expected = true;
      };
      "compatibility-protocol-satisfies-all-is-valid" = {
        expr =
          let caps = capSet [ (category "lifecycle" [ (capSchema "start") (capSchema "stop") ]) ] [ ];
          in (compatibility {
            capabilities = caps;
            protocols = [ (proto "grpc" caps) ];
          }).valid;
        expected = true;
      };
      "compatibility-multi-protocol-some-satisfy-is-valid" = {
        expr =
          let
            full = capSet [ (category "lifecycle" [ (capSchema "start") (capSchema "stop") ]) ] [ ];
            partial = capSet [ (category "lifecycle" [ (capSchema "start") ]) ] [ ];
          in
          (compatibility {
            capabilities = full;
            protocols = [ (proto "weak" partial) (proto "grpc" full) ];
          }).valid;
        expected = true;
      };

      "compatibility-no-protocol-satisfies-is-invalid" = {
        expr =
          let
            full = capSet [ (category "lifecycle" [ (capSchema "start") (capSchema "stop") ]) ] [ ];
            partial = capSet [ (category "lifecycle" [ (capSchema "start") ]) ] [ ];
          in
          (compatibility {
            capabilities = full;
            protocols = [ (proto "weak" partial) ];
          }).valid;
        expected = false;
      };
      "compatibility-error-lists-missing-capability" = {
        expr =
          let
            full = capSet [ (category "lifecycle" [ (capSchema "start") (capSchema "stop") ]) ] [ ];
            partial = capSet [ (category "lifecycle" [ (capSchema "start") ]) ] [ ];
            result = compatibility {
              capabilities = full;
              protocols = [ (proto "weak" partial) ];
            };
          in
          builtins.head result.errors;
        expected = "Protocol 'weak' cannot satisfy capabilities: stop";
      };
      "compatibility-custom-capabilities-roll-into-allNames" = {
        expr = allCapabilityNames (capSet [ ] [ (capSchema "ping") (capSchema "pong") ]);
        expected = [ "ping" "pong" ];
      };
      "compatibility-hasCapability-finds-categorised" = {
        expr = hasCapability
          (capSet [ (category "lifecycle" [ (capSchema "start") ]) ] [ ])
          "start";
        expected = true;
      };

      "descriptor-roundtrips-service-shape" = {
        expr =
          let
            startCap = capSchema "start";
            lifecycle = category "lifecycle" [ startCap ];
            caps = capSet [ lifecycle ] [ ];
            grpc = (proto "grpc" caps) // {
              transport = { _con = "Unix"; };
              serialization = { _con = "Protobuf"; };
              defaultPort = 1234;
              portEnvVar = "GRPC_PORT";
              options = { tls = true; };
            };
            svc = {
              name = "api";
              description = "demo";
              package = fx.state.mkThunk (stubDrv "api");
              capabilities = caps;
              protocols = [ grpc ];
              config = [ ];
            };
            d = descriptor svc;
          in
          {
            inherit (d) name description;
            capCount = builtins.length d.capabilities.categories;
            protoTransport = (builtins.head d.protocols).transport;
            protoSerialization = (builtins.head d.protocols).serialization;
            protoPort = (builtins.head d.protocols).defaultPort;
            protoOptions = (builtins.head d.protocols).options;
            isJson = builtins.isString (builtins.toJSON d);
          };
        expected = {
          name = "api";
          description = "demo";
          capCount = 1;
          protoTransport = "Unix";
          protoSerialization = "Protobuf";
          protoPort = 1234;
          protoOptions = { tls = true; };
          isJson = true;
        };
      };

      "project-value-multi-con-dispatches-on-con" = {
        expr = projectValue BuildPlanStep.T {
          _con = "runStep";
          name = "gen";
          tool = {
            _con = "MetaBuilderFinalizedTool";
            name = "protoc";
            package = "/nix/store/fake-protoc";
          };
          args = [ "--version" ];
          env = { PATH = "/bin"; };
        };
        expected = {
          _con = "runStep";
          name = "gen";
          tool = { name = "protoc"; package = "/nix/store/fake-protoc"; };
          args = [ "--version" ];
          env = { PATH = "/bin"; };
        };
      };

      "project-value-multi-con-rejects-foreign-con" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (projectValue BuildPlanStep.T { _con = "ghostStep"; })
          null)).success;
        expected = false;
      };

      "descriptor-drops-thunked-package" = {
        expr =
          let
            svc = {
              name = "api";
              description = "";
              package = fx.state.mkThunk (stubDrv "api");
              capabilities = capSet [ ] [ ];
              protocols = [ ];
              config = [ ];
            };
          in
          (descriptor svc) ? package;
        expected = false;
      };

      "descriptor-flattens-runtime-type-enum" = {
        expr =
          let
            paramOf = type: { name = "x"; description = ""; type = { _con = type; }; required = false; };
            customCap = {
              name = "c";
              description = "";
              params = [ (paramOf "RTInt") (paramOf "RTString") ];
              returns = { _con = "RTBool"; };
            };
            svc = {
              name = "s";
              description = "";
              package = fx.state.mkThunk (stubDrv "s");
              capabilities = capSet [ ] [ customCap ];
              protocols = [ ];
              config = [ (paramOf "RTObject") ];
            };
            d = descriptor svc;
            custom = builtins.head d.capabilities.custom;
          in
          {
            customReturns = custom.returns;
            customParamTypes = map (p: p.type) custom.params;
            configType = (builtins.head d.config).type;
          };
        expected = {
          customReturns = "RTBool";
          customParamTypes = [ "RTInt" "RTString" ];
          configType = "RTObject";
        };
      };

      "descriptor-maybe-null-passes-through" = {
        expr =
          let
            grpc = (proto "g" (capSet [ ] [ ])) // {
              defaultPort = null;
              portEnvVar = null;
            };
            svc = {
              name = "s";
              description = "";
              package = fx.state.mkThunk (stubDrv "s");
              capabilities = capSet [ ] [ ];
              protocols = [ grpc ];
              config = [ ];
            };
            p = builtins.head (descriptor svc).protocols;
          in
          { inherit (p) defaultPort portEnvVar; };
        expected = { defaultPort = null; portEnvVar = null; };
      };

      "descriptor-empty-list-fields" = {
        expr =
          let
            svc = {
              name = "s";
              description = "";
              package = fx.state.mkThunk (stubDrv "s");
              capabilities = capSet [ ] [ ];
              protocols = [ ];
              config = [ ];
            };
            d = descriptor svc;
          in
          {
            inherit (d) protocols config;
            categories = d.capabilities.categories;
            custom = d.capabilities.custom;
          };
        expected = {
          protocols = [ ];
          config = [ ];
          categories = [ ];
          custom = [ ];
        };
      };

      "compatibility-typed-service-spec-roundtrip" = {
        expr =
          let
            startCap = { _con = "MetaBuilderCapabilitySchema"; name = "start"; description = "Start the service"; params = [ ]; returns = { _con = "RTObject"; }; };
            lifecycle = { _con = "MetaBuilderCapabilityCategory"; name = "lifecycle"; description = ""; capabilities = [ startCap ]; };
            caps = { _con = "MetaBuilderCapabilitySet"; categories = [ lifecycle ]; custom = [ ]; };
            grpc = {
              _con = "MetaBuilderProtocolSpec";
              name = "grpc";
              description = "";
              transport = { _con = "TCP"; };
              serialization = { _con = "Protobuf"; };
              defaultPort = null;
              portEnvVar = null;
              capabilities = caps;
              options = { };
            };
            svc = {
              _con = "MetaBuilderServiceSpec";
              name = "api";
              description = "";
              package = fx.state.mkThunk (stubDrv "api");
              capabilities = caps;
              protocols = [ grpc ];
              config = [ ];
            };
            errs = fx.types.validateValue [ ] ServiceSpec.T svc;
          in
          if errs != [ ] then throw "ServiceSpec failed structural validation (${toString (builtins.length errs)} errors)"
          else (compatibility svc).valid;
        expected = true;
      };
    };
}
