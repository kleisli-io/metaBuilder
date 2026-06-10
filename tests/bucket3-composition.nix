{ mb, api, ... }:

let
  caps = mb.ornaments.capabilities;
  protoOrn = mb.ornaments.protocol;
  replOrn = mb.ornaments.replServer;
  sandboxOrn = mb.ornaments.sandbox;

  inherit (mb.operations)
    capability capabilityCategory capabilitySet
    transports serializations
    replModes
    tcpEndpoint sandboxProfile;

  # Custom CapabilityCategory layered alongside the lifecycle/crud
  # built-ins. The ornament's typed `category` smart-ctor is the only
  # extension surface — no string-keyed taxonomy merge.
  alphaCategory = capabilityCategory {
    name = "alpha";
    description = "alpha-specific operations";
    capabilities = [
      (capability { name = "ping"; description = "alpha ping"; })
      (capability { name = "echo"; description = "alpha echo"; })
    ];
  };

  composedCaps = capabilitySet {
    categories = [
      caps.builtins.lifecycle
      caps.builtins.crud
      alphaCategory
    ];
  };

  # Typed ProtocolSpec built via the ornament smart-ctor. Carries the
  # full composed capability set so `protocol.satisfies` is positive on
  # the composite below.
  alphaProto = protoOrn.define {
    name = "rpc";
    description = "alpha rpc protocol";
    transport = transports.TCP;
    serialization = serializations.JSON;
    defaultPort = 9000;
    portEnvVar = "ALPHA_PORT";
    capabilities = composedCaps;
  };

  # Typed REPLServerSpec over the built-in `swank` open protocol. Mode
  # `Background` exercises the registration-inference rule (XDG).
  alphaRepl = replOrn.define {
    protocol = replOrn.protocols.swank;
    mode = replModes.Background;
  };

  # Typed SandboxProfile with a listenTcp endpoint so the
  # `toLandlock` eliminator has a non-empty port list to project.
  alphaSandbox = sandboxProfile {
    listenTcp = [ (tcpEndpoint { port = 9000; }) ];
  };

  # Four-way composed fixture: a `BuilderSpec`-tagged record that
  # additively layers the bucket-3 ornament fields (capabilities,
  # protocols, replServer, sandbox). Each ornament's eliminators are
  # field-projecting and operate on the shared value without conflict.
  composedSpec = {
    _con = "MetaBuilderSpec";
    langName = "alpha";
    name = "alphaService";
    description = "Bucket-3 four-way composition fixture";
    parameters = [ ];
    inputs = [ ];
    dependencies = [ ];
    tools = [ ];
    operations = [ ];
    outputs = [ ];
    evidence = [ ];

    capabilities = composedCaps;
    protocols = [ alphaProto ];
    replServer = alphaRepl;
    sandbox = alphaSandbox;
  };

in
api.mk {
  description = "Bucket-3 composition test: capabilities × protocol × replServer × sandbox four-way stack on one shared spec. Demonstrates that the runtime-vocabulary ornaments compose at the value level — each ornament's typed eliminators operate on the shared value without conflict.";
  doc = ''
    # Bucket-3 Composition Stack

    Closes the four-way composition story for the bucket-3 ornaments by
    layering `capabilities`, `protocol`, `replServer`, and `sandbox` on
    one shared `BuilderSpec`-tagged record. The composed spec carries:

    - Shared base fields: `_con`, `name`, `description`, `langName`.
    - `capabilities`: a `CapabilitySet` with three categories
      (`lifecycle`, `crud`, and a custom `alpha`).
    - `protocols`: a typed `ProtocolSpec` list whose head covers all
      three categories of the composed set.
    - `replServer`: a typed `REPLServerSpec` over the built-in `swank`
      open protocol in `Background` mode.
    - `sandbox`: a typed `SandboxProfile` carrying a listenTcp endpoint.

    Each ornament's eliminators (`capabilities.setSchemas`,
    `protocol.satisfies`, `sandbox.toLandlock`, `sandbox.toSystemd`)
    operate on the shared value without namespace conflict. The
    `replServer` field round-trips its typed shape including the
    inferred `XDG` registration.
  '';
  value = { inherit composedSpec; };
  tests = {
    "capabilities-setSchemas-flattens-composed-spec-capabilities" = {
      expr =
        let
          flat = caps.setSchemas composedSpec.capabilities;
        in
        {
          keys = builtins.sort builtins.lessThan (builtins.attrNames flat);
          startCategory = flat.start.category;
          createCategory = flat.create.category;
          pingCategory = flat.ping.category;
          echoCategory = flat.echo.category;
        };
      expected = {
        keys = [ "create" "delete" "echo" "health" "ping" "read" "start" "stop" "update" ];
        startCategory = "lifecycle";
        createCategory = "crud";
        pingCategory = "alpha";
        echoCategory = "alpha";
      };
    };

    "protocol-satisfies-on-composed-spec" = {
      expr = protoOrn.satisfies
        (builtins.head composedSpec.protocols)
        composedSpec.capabilities;
      expected = true;
    };

    "replServer-typed-shape-on-composed-spec" = {
      expr = {
        inherit (composedSpec.replServer) _con port portEnvVar interface;
        protocolName = composedSpec.replServer.protocol.name;
        modeTag = composedSpec.replServer.mode._con;
        registrationTag = composedSpec.replServer.registration._con;
        lifecycleTag = composedSpec.replServer.lifecycle._con;
      };
      expected = {
        _con = "MetaBuilderREPLServerSpec";
        port = 4005;
        portEnvVar = "SWANK_PORT";
        interface = "127.0.0.1";
        protocolName = "swank";
        modeTag = "Background";
        registrationTag = "XDG";
        lifecycleTag = "LongRunning";
      };
    };

    "sandbox-toLandlock-projects-listenPorts-from-composed-spec" = {
      expr =
        let
          ll = sandboxOrn.toLandlock composedSpec.sandbox;
        in
        {
          inherit (ll) _con listenPorts connectPorts allowExecve;
        };
      expected = {
        _con = "MetaBuilderLandlockProfile";
        listenPorts = [ 9000 ];
        connectPorts = [ ];
        allowExecve = false;
      };
    };

    "sandbox-toSystemd-emits-hardening-from-composed-spec" = {
      expr =
        let
          sd = sandboxOrn.toSystemd composedSpec.sandbox;
        in
        {
          inherit (sd) _con protectSystem privateTmp noNewPrivileges;
          execFiltered = builtins.elem "~execve" sd.systemCallFilter;
        };
      expected = {
        _con = "MetaBuilderSystemdHardening";
        protectSystem = "strict";
        privateTmp = true;
        noNewPrivileges = true;
        execFiltered = true;
      };
    };

    "all-four-ornament-fields-coexist" = {
      expr = {
        hasLangName = composedSpec ? langName;
        capCategoryCount = builtins.length composedSpec.capabilities.categories;
        capCategoryNames = map (c: c.name) composedSpec.capabilities.categories;
        protoCount = builtins.length composedSpec.protocols;
        protoNames = map (p: p.name) composedSpec.protocols;
        replConTag = composedSpec.replServer._con;
        replProtocolName = composedSpec.replServer.protocol.name;
        sandboxConTag = composedSpec.sandbox._con;
        sandboxListenPorts = map (e: e.port) composedSpec.sandbox.listenTcp;
      };
      expected = {
        hasLangName = true;
        capCategoryCount = 3;
        capCategoryNames = [ "lifecycle" "crud" "alpha" ];
        protoCount = 1;
        protoNames = [ "rpc" ];
        replConTag = "MetaBuilderREPLServerSpec";
        replProtocolName = "swank";
        sandboxConTag = "MetaBuilderSandboxProfile";
        sandboxListenPorts = [ 9000 ];
      };
    };
  };
}
