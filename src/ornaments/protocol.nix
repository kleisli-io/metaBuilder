{ mb, api, ... }:

let
  inherit (mb.operations) protocol transports serializations capabilitySet;
  caps = mb.ornaments.capabilities;

  satisfies = mb.descriptions.runtime.protocolSatisfies;

  define = protocol;

  # Built-in protocols as typed `ProtocolSpec` values. Each declares
  # the closed kernel sums it speaks (transport, serialization) and
  # the capability set it carries. Consumer extension is through
  # `H.ornament` on the underlying datatype, not via attrset-keyed
  # extension surfaces (`withTransports`/`withSerializations` are
  # deliberately absent).
  builtins' = {
    rpc = protocol {
      name = "rpc";
      description = "Generic RPC over TCP/JSON";
      transport = transports.TCP;
      serialization = serializations.JSON;
      capabilities = capabilitySet {
        categories = [ caps.builtins.lifecycle caps.builtins.crud ];
      };
    };

    jsonRpc = protocol {
      name = "json-rpc";
      description = "JSON-RPC 2.0 over stdio";
      transport = transports.Stdio;
      serialization = serializations.JSON;
      capabilities = capabilitySet {
        categories = [ caps.builtins.lifecycle ];
      };
    };

    dbus = protocol {
      name = "dbus";
      description = "D-Bus inter-process communication";
      transport = transports.Unix;
      serialization = serializations.MsgPack;
      capabilities = capabilitySet {
        categories = [ caps.builtins.lifecycle ];
      };
    };

    grpc = protocol {
      name = "grpc";
      description = "gRPC remote procedure call protocol";
      transport = transports.TCP;
      serialization = serializations.Protobuf;
      capabilities = capabilitySet {
        categories = [
          caps.builtins.lifecycle
          caps.builtins.crud
          caps.builtins.streaming
        ];
      };
    };
  };

  value = {
    inherit define satisfies;
    Transport = transports;
    Serialization = serializations;
    builtins = builtins';
  };

in
api.mk {
  description = "protocol ornament: typed protocol vocabulary over the runtime.* effect algebra. Built-in protocols (rpc/json-rpc/dbus/grpc) as typed `ProtocolSpec` values, plus `define` smart-ctor and `satisfies` eliminator for capability cross-checks.";
  doc = ''
    # Protocol

    Typed communication protocols over the closed kernel sums
    `Transport` (TCP/Unix/Stdio) and `Serialization`
    (JSON/Protobuf/Sexp/MsgPack). Both sums are defined in
    `mb.descriptions` and re-exported here as
    `protocol.Transport` / `protocol.Serialization`.

    - **Smart constructor** `protocol.define { name; description?;
      transport; serialization; defaultPort?; portEnvVar?;
      capabilities; options?; }` proxies to
      `mb.operations.protocol` (eager structural validation against
      `ProtocolSpec.T`).

    - **Built-in protocols** as typed values addressable as
      `protocol.builtins.{rpc,jsonRpc,dbus,grpc}`. Each carries a
      `CapabilitySet` drawn from `capabilities.builtins`.

    - **`satisfies : ProtocolSpec → CapabilitySet → Bool`** is the
      capability cross-check (proxy to
      `mb.descriptions.runtime.protocolSatisfies`).

    Consumer extension is through `H.ornament` on the kernel sums.
    There is no `withTransports`/`withSerializations`/`withProtocols`
    surface — extension via string-keyed attrset merge was a legacy
    idiom and is intentionally absent.
  '';
  inherit value;
  tests =
    let
      lifecycleOnly = capabilitySet { categories = [ caps.builtins.lifecycle ]; };
      lifecycleAndCrud = capabilitySet { categories = [ caps.builtins.lifecycle caps.builtins.crud ]; };
      lifecycleCrudStream = capabilitySet {
        categories = [ caps.builtins.lifecycle caps.builtins.crud caps.builtins.streaming ];
      };
    in
    {
      "rpc-builtin-is-typed-ProtocolSpec" = {
        expr = {
          inherit (builtins'.rpc) _con name;
          transportTag = builtins'.rpc.transport._con;
          serializationTag = builtins'.rpc.serialization._con;
          categoryCount = builtins.length builtins'.rpc.capabilities.categories;
        };
        expected = {
          _con = "MetaBuilderProtocolSpec";
          name = "rpc";
          transportTag = "TCP";
          serializationTag = "JSON";
          categoryCount = 2;
        };
      };

      "grpc-builtin-carries-all-three-built-in-categories" = {
        expr = map (cat: cat.name) builtins'.grpc.capabilities.categories;
        expected = [ "lifecycle" "crud" "streaming" ];
      };

      "rpc-satisfies-its-declared-lifecycle-crud" = {
        expr = satisfies builtins'.rpc lifecycleAndCrud;
        expected = true;
      };

      "jsonRpc-does-not-satisfy-crud-requirement" = {
        expr = satisfies builtins'.jsonRpc lifecycleAndCrud;
        expected = false;
      };

      "grpc-satisfies-full-lifecycle-crud-streaming" = {
        expr = satisfies builtins'.grpc lifecycleCrudStream;
        expected = true;
      };

      "dbus-satisfies-lifecycle-only" = {
        expr = {
          passLifecycle = satisfies builtins'.dbus lifecycleOnly;
          failCrud = satisfies builtins'.dbus lifecycleAndCrud;
        };
        expected = {
          passLifecycle = true;
          failCrud = false;
        };
      };

      "define-proxies-to-operations-protocol-smart-ctor" = {
        expr =
          let
            proto = define {
              name = "alpha";
              description = "alpha protocol";
              transport = transports.TCP;
              serialization = serializations.Sexp;
              capabilities = lifecycleOnly;
            };
          in
          {
            inherit (proto) _con name;
            transportTag = proto.transport._con;
            serializationTag = proto.serialization._con;
          };
        expected = {
          _con = "MetaBuilderProtocolSpec";
          name = "alpha";
          transportTag = "TCP";
          serializationTag = "Sexp";
        };
      };

      "Transport-and-Serialization-are-re-exported-closed-sums" = {
        expr = {
          tcpTag = transports.TCP._con;
          unixTag = transports.Unix._con;
          stdioTag = transports.Stdio._con;
          jsonTag = serializations.JSON._con;
          protobufTag = serializations.Protobuf._con;
          sexpTag = serializations.Sexp._con;
          msgpackTag = serializations.MsgPack._con;
        };
        expected = {
          tcpTag = "TCP";
          unixTag = "Unix";
          stdioTag = "Stdio";
          jsonTag = "JSON";
          protobufTag = "Protobuf";
          sexpTag = "Sexp";
          msgpackTag = "MsgPack";
        };
      };
    };
}
