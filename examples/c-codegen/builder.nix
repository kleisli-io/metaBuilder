{ mb, fx, lib, pkgs, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  ops = mb.operations;
  eff = mb.program.eff;

  CCodegenBuilder = H.ornament mb.descriptions.BuilderSpec {
    name = "MetaBuilderCCodegen";
    constructors.MetaBuilderSpec.fields = [
      { insert = "compiler"; type = H.string; }
      { insert = "schema"; type = H.any; }
      { insert = "configDefines"; type = H.attrs; }
      { insert = "artifactKind"; type = H.string; }
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

  cCodegen =
    { name
    , schema
    , main
    , compilerPackage ? pkgs.gcc
    , binutilsPackage ? pkgs.binutils
    , compiler ? compilerPackage.pname or "gcc"
    , configDefines ? {
        DEMO_FEATURE = 1;
        MESSAGE_LIMIT = 8;
      }
    , artifactKind ? "static-library-with-cli"
    }:
    let
      schemaSource = ops.localSource {
        name = baseNameOf (toString schema);
        path = schema;
      };
      mainSource = ops.localSource {
        name = baseNameOf (toString main);
        path = main;
      };

      gccTool = ops.tool {
        name = "gcc";
        package = compilerPackage;
      };
      arTool = ops.tool {
        name = "ar";
        package = binutilsPackage;
      };
      bashTool = ops.tool {
        name = "bash";
        package = pkgs.bash;
      };

      cliOutput = ops.output {
        name = "cli";
        path = "$out/bin/${name}";
        format = "elf";
      };
      libraryOutput = ops.output {
        name = "static-library";
        path = "$out/lib/lib${name}.a";
        format = "archive";
      };
      headerOutput = ops.output {
        name = "headers";
        path = "$out/include";
        format = "directory";
      };
      pkgConfigOutput = ops.output {
        name = "pkg-config";
        path = "lib/pkgconfig/${name}.pc";
        format = "text";
      };

      defineLines = lib.concatStringsSep "\n"
        (lib.mapAttrsToList
          (key: value: "#define ${key} ${toString value}")
          configDefines);

      codegenScript = ''
        set -eu
        schema="$1"
        mkdir -p "$out/generated" "$out/include" "$out/lib" "$out/bin" "$out/share/${name}" "$out/lib/pkgconfig"
        header="$out/include/generated_messages.h"
        source="$out/generated/generated_messages.c"
        printf '%s\n' '#pragma once' '#include "config.h"' > "$header"
        printf '%s\n' '#include "generated_messages.h"' > "$source"
        while IFS=: read key text; do
          if [ -z "$key" ]; then
            continue
          fi
          printf 'const char *message_%s(void);\n' "$key" >> "$header"
          printf 'const char *message_%s(void) { return "%s"; }\n' "$key" "$text" >> "$source"
        done < "$schema"
      '';

      smokeScript = ''
        set -eu
        mkdir -p "$out/share/${name}"
        "$out/bin/${name}" > "$out/share/${name}/smoke.txt"
      '';

      packageConfig = ''
        prefix=$out
        exec_prefix=$out
        libdir=$out/lib
        includedir=$out/include

        Name: ${name}
        Description: generated C demo library
        Version: 0.1.0
        Libs: -L$out/lib -l${name}
        Cflags: -I$out/include
      '';

      operations = [
        (eff.builder.readSource {
          name = schemaSource.name;
          source = schemaSource;
        })
        (eff.builder.readSource {
          name = mainSource.name;
          source = mainSource;
        })
        (eff.builder.declareTool { tool = bashTool; })
        (eff.builder.declareTool { tool = gccTool; })
        (eff.builder.declareTool { tool = arTool; })
        (eff.builder.writeFile {
          output = ops.output {
            name = "config-header";
            path = "include/config.h";
            format = "c-header";
          };
          text = "${defineLines}\n";
        })
        (eff.builder.runTool {
          name = "generate-c-sources";
          tool = bashTool;
          args = [ "-c" codegenScript "generate-c-sources" (toString schema) ];
        })
        (eff.builder.runTool {
          name = "compile-generated-object";
          tool = gccTool;
          args = [
            "-I$out/include"
            "-c"
            "$out/generated/generated_messages.c"
            "-o"
            "$out/generated/generated_messages.o"
          ];
        })
        (eff.builder.runTool {
          name = "archive-library";
          tool = arTool;
          args = [
            "rcs"
            "$out/lib/lib${name}.a"
            "$out/generated/generated_messages.o"
          ];
        })
        (eff.builder.runTool {
          name = "link-demo-cli";
          tool = gccTool;
          args = [
            "-I$out/include"
            (toString main)
            "$out/lib/lib${name}.a"
            "-o"
            "$out/bin/${name}"
          ];
        })
        (eff.builder.runTool {
          name = "smoke-test";
          tool = bashTool;
          args = [ "-c" smokeScript "smoke-test" ];
        })
        (eff.builder.writeFile {
          output = pkgConfigOutput;
          text = packageConfig;
        })
        (eff.builder.emitDescriptor {
          descriptor = ops.descriptor {
            name = "${name}-metadata";
            payload = {
              kind = "c-codegen";
              inherit artifactKind compiler configDefines;
              generated = [
                "include/generated_messages.h"
                "generated/generated_messages.c"
                "lib/lib${name}.a"
                "bin/${name}"
              ];
            };
          };
        })
        (eff.builder.transformOutput { output = cliOutput; })
        (eff.builder.transformOutput { output = libraryOutput; })
        (eff.builder.transformOutput { output = headerOutput; })
        (eff.builder.transformOutput { output = pkgConfigOutput; })
        (eff.builder.materializeDerivation {
          name = "${name}-artifact";
          builder = "runCommand";
        })
      ];
    in
    {
      _con = "MetaBuilderSpec";
      inherit name compiler schema configDefines artifactKind operations;
      parameters = [
        (ops.parameter { name = "artifactKind"; value = artifactKind; })
      ];
      inputs = [ schemaSource mainSource ];
      dependencies = [ ];
      tools = [ bashTool gccTool arTool ];
      outputs = [ cliOutput libraryOutput headerOutput pkgConfigOutput ];
      evidence = [
        (ops.evidence {
          name = "smoke-test";
          payload = {
            command = "$out/bin/${name}";
            expectedOutput = "hello from generated C";
          };
        })
      ];
    };

  spec = cCodegen {
    name = "messages-demo";
    schema = ./messages.def;
    main = ./main.c;
  };

  program = mb.program.fromOrnamentedSpec CCodegenBuilder.T spec;

  shellScript = mb.program.backends.shell.run program;

  value = {
    builder = {
      inherit CCodegenBuilder cCodegen;
      descriptor = G.derive.deriveDescriptor CCodegenBuilder;
      schema = G.derive.deriveSchema CCodegenBuilder;
    };
    inherit spec program;
    validation = mb.program.validate.run program;
    deps = mb.program.deps.run program;
    dryRun = mb.program."dry-run".run program;
    planView = mb.program."plan-view".run program;
    docs = mb.program.describe.run program;
    selfView = mb.program.introspect.run program;
    materialize = mb.program.materialize.run program;
    materializeShell = shellScript;
    materializeShellCheck = mb.program.backends.shell.shellcheckFor shellScript;
    # node-service is excluded: its launcher embeds /nix/store paths.
    materializeShellEquality = mb.program.backends.shell.executionCheckFor program;
    materializeDockerfile = mb.program.backends.dockerfile.run program;
    planExport = mb.program."plan-export".json program;
  };

in
{
  scope = {
    inherit CCodegenBuilder cCodegen spec program value;
  };
}
