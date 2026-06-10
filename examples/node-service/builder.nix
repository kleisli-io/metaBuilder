{ mb, fx, lib, pkgs, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  ops = mb.operations;
  eff = mb.program.eff;

  NodeServiceBuilder = H.ornament mb.descriptions.BuilderSpec {
    name = "MetaBuilderNodeService";
    constructors.MetaBuilderSpec.fields = [
      { insert = "runtimeVersion"; type = H.string; }
      { insert = "entrypoint"; type = H.string; }
      { insert = "packageManager"; type = H.string; }
      { insert = "scripts"; type = H.attrs; }
      { insert = "testCommand"; type = H.string; }
      { insert = "service"; type = mb.descriptions.ServiceSpec.T; }
      { keep = "name"; }
      { keep = "parameters"; }
      { keep = "inputs"; }
      { keep = "dependencies"; }
      { keep = "tools"; }
      { keep = "operations"; }
      { keep = "outputs"; }
      { keep = "evidence"; }
    ];
  };

  nodeService =
    { name
    , source
    , version ? "0.1.0"
    , runtimePackage ? pkgs.nodejs
    , runtimeVersion ? runtimePackage.version or "node"
    , entrypoint ? baseNameOf (toString source)
    , packageManager ? "npm"
    , port ? 3000
    , healthPath ? "/health"
    }:
    let
      sourceFile = ops.localSource {
        name = entrypoint;
        path = source;
      };

      nodeTool = ops.tool {
        name = "node";
        package = runtimePackage;
      };
      bashTool = ops.tool {
        name = "bash";
        package = pkgs.bash;
      };

      lifecycleSet = ops.capabilitySet {
        categories = [ mb.ornaments.capabilities.builtins.lifecycle ];
      };
      protocol = ops.protocol {
        name = "http";
        description = "HTTP service protocol";
        transport = ops.transports.TCP;
        serialization = ops.serializations.JSON;
        defaultPort = port;
        portEnvVar = "PORT";
        capabilities = lifecycleSet;
        options = {
          inherit healthPath;
        };
      };
      service = ops.service {
        name = "${name}-service";
        description = "Runnable Node service artifact";
        package = runtimePackage;
        capabilities = lifecycleSet;
        protocols = [ protocol ];
        config = [
          (ops.param {
            name = "port";
            description = "TCP port for the HTTP server";
            type = ops.runtimeTypes.RTInt;
            required = false;
          })
          (ops.param {
            name = "healthPath";
            description = "HTTP path used for health checks";
            type = ops.runtimeTypes.RTString;
            required = false;
          })
        ];
      };

      scripts = {
        start = "node ${entrypoint}";
        test = "node --check ${entrypoint}";
      };
      testCommand = scripts.test;

      appOutput = ops.output {
        name = "service-tree";
        path = "$out";
        format = "tree";
      };
      packageOutput = ops.output {
        name = "package-json";
        path = "share/${name}/package.json";
        format = "json";
      };

      packageJson = builtins.toJSON {
        inherit name version;
        type = "module";
        main = entrypoint;
        private = true;
        inherit scripts;
      };

      installScript = ''
        set -eu
        src="$1"
        mkdir -p "$out/bin" "$out/lib/${name}" "$out/share/${name}"
        cp "$src" "$out/lib/${name}/${entrypoint}"
        cat > "$out/bin/${name}" <<EOF
        #!${pkgs.runtimeShell}
        exec ${runtimePackage}/bin/node "$out/lib/${name}/${entrypoint}" "$@"
        EOF
        chmod +x "$out/bin/${name}"
      '';

      # Builder and runtime operations share one ordered carrier over the
      # full signature: builder ops first, then the runtime declarations.
      operations =
        [
          (eff.builder.readSource {
            name = entrypoint;
            source = sourceFile;
          })
          (eff.builder.declareTool { tool = nodeTool; })
          (eff.builder.declareTool { tool = bashTool; })
          (eff.builder.writeFile {
            output = packageOutput;
            text = packageJson;
          })
          (eff.builder.runTool {
            name = "syntax-check";
            tool = nodeTool;
            args = [ "--check" (toString source) ];
          })
          (eff.builder.runTool {
            name = "install-service";
            tool = bashTool;
            args = [ "-c" installScript "install-node-service" (toString source) ];
          })
          (eff.builder.emitDescriptor {
            descriptor = ops.descriptor {
              name = "${name}-metadata";
              payload = {
                kind = "node-service";
                inherit entrypoint packageManager runtimeVersion port healthPath;
              };
            };
          })
          (eff.builder.transformOutput { output = appOutput; })
          (eff.builder.transformOutput { output = packageOutput; })
          (eff.builder.materializeDerivation {
            name = "${name}-artifact";
            builder = "runCommand";
          })
        ]
        ++ map (category: eff.runtime.declareCapability { inherit category; })
          lifecycleSet.categories
        ++ [
          (eff.runtime.declareProtocol { inherit protocol; })
          (eff.runtime.declareService { inherit service; })
          (eff.runtime.materializeUnit { name = service.name; })
        ];
    in
    {
      _con = "MetaBuilderSpec";
      inherit name runtimeVersion entrypoint packageManager scripts testCommand service operations;
      parameters = [
        (ops.parameter { name = "port"; value = port; })
        (ops.parameter { name = "healthPath"; value = healthPath; })
      ];
      inputs = [ sourceFile ];
      dependencies = [ ];
      tools = [ nodeTool bashTool ];
      outputs = [ appOutput packageOutput ];
      evidence = [
        (ops.evidence {
          name = "self-test";
          payload = {
            command = testCommand;
          };
        })
      ];
    };

  spec = nodeService {
    name = "node-service-demo";
    source = ./server.js;
  };

  program = mb.program.fromOrnamentedSpec NodeServiceBuilder.T spec;

  shellScript = mb.program.backends.shell.run program;

  value = {
    builder = {
      inherit NodeServiceBuilder nodeService;
      descriptor = G.derive.deriveDescriptor NodeServiceBuilder;
      schema = G.derive.deriveSchema NodeServiceBuilder;
    };
    inherit spec program;
    specValidation = fx.types.validateValue [ ] NodeServiceBuilder.T spec;
    validation = mb.program.validate.run program;
    deps = mb.program.deps.run program;
    dryRun = mb.program."dry-run".run program;
    planView = mb.program."plan-view".run program;
    docs = mb.program.describe.run program;
    selfView = mb.program.introspect.run program;
    materialize = mb.program.materialize.run program;
    materializeShell = shellScript;
    materializeShellCheck = mb.program.backends.shell.shellcheckFor shellScript;
    materializeDockerfile = mb.program.backends.dockerfile.run program;
    planExport = mb.program."plan-export".json program;
  };

in
{
  scope = {
    inherit NodeServiceBuilder nodeService spec program value;
  };
}
