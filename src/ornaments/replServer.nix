{ mb, api, ... }:

let
  inherit (mb.operations)
    transports serializations
    lifecycles replModes registrationBackends
    capabilitySet;
  caps = mb.ornaments.capabilities;
  protoOrn = mb.ornaments.protocol;

  define = mb.operations.replServer;

  # Minimal capability baseline for REPL protocols: every REPL exposes
  # service-lifecycle operations (start/stop/health). Consumers extend
  # the carried CapabilitySet via `capabilitySet { categories = [...] }`.
  lifecycleSet = capabilitySet { categories = [ caps.builtins.lifecycle ]; };

  # Built-in REPL protocols. Each is a typed `ProtocolSpec` value over
  # the closed transport/serialization sums. Capabilities carry the
  # shared `lifecycle` baseline. Consumers compose additional
  # `CapabilityCategory` values via `capabilities.category { ... }`.
  protocols = {
    swank = protoOrn.define {
      name = "swank";
      description = "Swank REPL protocol over S-expressions";
      transport = transports.TCP;
      serialization = serializations.Sexp;
      defaultPort = 4005;
      portEnvVar = "SWANK_PORT";
      capabilities = lifecycleSet;
    };

    nrepl = protoOrn.define {
      name = "nrepl";
      description = "Network REPL protocol over Bencode";
      transport = transports.TCP;
      serialization = serializations.Bencode;
      defaultPort = 7888;
      portEnvVar = "NREPL_PORT";
      capabilities = lifecycleSet;
    };

    dap = protoOrn.define {
      name = "dap";
      description = "Debug Adapter Protocol over JSON";
      transport = transports.TCP;
      serialization = serializations.JSON;
      defaultPort = 5678;
      portEnvVar = "DAP_PORT";
      capabilities = lifecycleSet;
    };
  };

  value = {
    inherit define protocols;
    Mode = replModes;
    Registration = registrationBackends;
    Lifecycle = lifecycles;
  };

in
api.mk {
  description = "replServer ornament: typed REPL-server specification over the locked runtime.* algebra. `define` smart-ctor produces a `REPLServerSpec` with eager structural validation; built-in protocols (swank/nrepl/dap) carry transport/serialization/port over closed kernel sums. No string-keyed taxonomy — consumers compose CapabilityCategory values directly.";
  doc = ''
    # REPL Server

    Typed REPL-server vocabulary built on the locked runtime.* algebra.

    - **Smart constructor** `replServer.define { protocol; mode;
      registration?; port?; portEnvVar?; interface?; lifecycle?;
      enable?; shortLivedFlags?; extra?; }` proxies to
      `mb.operations.replServer`. Port and `portEnvVar` default from
      the protocol's `defaultPort`/`portEnvVar`. Registration defaults
      from `mode` via the inference rule
      `Foreground → ServiceSpec`, `Background → XDG`.
      Lifecycle defaults to `LongRunning`.

    - **Closed-sum re-exports** for consumer ergonomics:
      `Mode = Foreground | Background`,
      `Registration = XDG | Global | ServiceSpec | None`,
      `Lifecycle = LongRunning | OneShot`.

    - **Built-in protocols** as typed `ProtocolSpec` values:
      `protocols.{swank,nrepl,dap}`. Each carries a baseline
      `CapabilitySet` of `lifecycle` only; consumers extend via
      `capabilitySet { categories = [...] }`. The legacy string-keyed
      taxonomy (`universal`/`common`/`discovery`/...) is intentionally
      absent.

    Registration backend names map to runtime conventions:
    `XDG` → `$XDG_RUNTIME_DIR/repl/<protocol>/<name>.json`,
    `Global` → `$XDG_RUNTIME_DIR/repl/<protocol>/shared/<name>.json`,
    `ServiceSpec` → discovery via NixOS configuration,
    `None` → no automatic registration.
  '';
  inherit value;
  tests =
    let
      swankBg = define {
        protocol = protocols.swank;
        mode = replModes.Background;
      };
      swankFg = define {
        protocol = protocols.swank;
        mode = replModes.Foreground;
      };
      dapExplicit = define {
        protocol = protocols.dap;
        mode = replModes.Background;
        port = 9999;
        portEnvVar = "ALPHA_DAP_PORT";
        interface = "0.0.0.0";
        lifecycle = lifecycles.OneShot;
        registration = registrationBackends.None;
        shortLivedFlags = [ "--once" "--query" ];
      };
    in
    {
      "swank-builtin-protocol-shape" = {
        expr = {
          inherit (protocols.swank) _con name defaultPort portEnvVar;
          transportTag = protocols.swank.transport._con;
          serializationTag = protocols.swank.serialization._con;
        };
        expected = {
          _con = "MetaBuilderProtocolSpec";
          name = "swank";
          defaultPort = 4005;
          portEnvVar = "SWANK_PORT";
          transportTag = "TCP";
          serializationTag = "Sexp";
        };
      };

      "nrepl-builtin-protocol-bencode-wire" = {
        expr = {
          inherit (protocols.nrepl) name defaultPort;
          serializationTag = protocols.nrepl.serialization._con;
        };
        expected = {
          name = "nrepl";
          defaultPort = 7888;
          serializationTag = "Bencode";
        };
      };

      "dap-builtin-protocol-json-wire" = {
        expr = {
          inherit (protocols.dap) name defaultPort portEnvVar;
          serializationTag = protocols.dap.serialization._con;
        };
        expected = {
          name = "dap";
          defaultPort = 5678;
          portEnvVar = "DAP_PORT";
          serializationTag = "JSON";
        };
      };

      "define-defaults-port-from-protocol" = {
        expr = swankBg.port;
        expected = 4005;
      };

      "define-defaults-portEnvVar-from-protocol" = {
        expr = swankBg.portEnvVar;
        expected = "SWANK_PORT";
      };

      "define-background-mode-infers-XDG-registration" = {
        expr = swankBg.registration._con;
        expected = "XDG";
      };

      "define-foreground-mode-infers-ServiceSpec-registration" = {
        expr = swankFg.registration._con;
        expected = "ServiceSpec";
      };

      "define-defaults-lifecycle-to-LongRunning" = {
        expr = swankBg.lifecycle._con;
        expected = "LongRunning";
      };

      "define-defaults-interface-to-localhost" = {
        expr = swankBg.interface;
        expected = "127.0.0.1";
      };

      "define-typed-shape" = {
        expr = swankBg._con;
        expected = "MetaBuilderREPLServerSpec";
      };

      "define-honours-explicit-overrides" = {
        expr = {
          inherit (dapExplicit) port portEnvVar interface;
          modeTag = dapExplicit.mode._con;
          registrationTag = dapExplicit.registration._con;
          lifecycleTag = dapExplicit.lifecycle._con;
          flagCount = builtins.length dapExplicit.shortLivedFlags;
        };
        expected = {
          port = 9999;
          portEnvVar = "ALPHA_DAP_PORT";
          interface = "0.0.0.0";
          modeTag = "Background";
          registrationTag = "None";
          lifecycleTag = "OneShot";
          flagCount = 2;
        };
      };

      "define-rejects-protocol-without-port-when-not-supplied" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (define {
            protocol = protoOrn.define {
              name = "portless";
              transport = transports.Unix;
              serialization = serializations.Sexp;
              capabilities = lifecycleSet;
            };
            mode = replModes.Background;
          })
          null)).success;
        expected = false;
      };

      "define-rejects-malformed-mode" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (define {
            protocol = protocols.swank;
            mode = { _con = "BogusMode"; };
          })
          null)).success;
        expected = false;
      };

      "Mode-re-exports-closed-sum-values" = {
        expr = {
          fg = replModes.Foreground._con;
          bg = replModes.Background._con;
        };
        expected = {
          fg = "Foreground";
          bg = "Background";
        };
      };

      "Registration-re-exports-all-four-backends" = {
        expr = builtins.sort builtins.lessThan
          (map (b: b._con) (builtins.attrValues registrationBackends));
        expected = [ "Global" "None" "ServiceSpec" "XDG" ];
      };
    };
}
