{ mb, fx, api, lib, pkgs, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  ops = mb.operations;
  eff = mb.program.eff;
  cg = mb.ornaments."code-gen";

  pythonGrpcioTools = pkgs.python3Packages.grpcio-tools or null;

  IdlBuilder = H.ornament cg.CodeGenBuilder {
    name = "MetaBuilderIdl";
    constructors.MetaBuilderSpec.fields = [
      { insert = "idlFormat"; type = H.string; }
      { insert = "idlSource"; type = H.any; }
      { keep = "generator"; }
      { keep = "languages"; }
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

  defaultProtobufLanguages = {
    go = {
      args = lang: [ "--${lang}_out=$out/${lang}" "--${lang}-grpc_out=$out/${lang}" ];
      native = [ ];
    };
    python = {
      args = lang: [ "--${lang}_out=$out/${lang}" "--grpc_python_out=$out/${lang}" ];
      native = lib.optional (pythonGrpcioTools != null) pythonGrpcioTools;
    };
    cpp = {
      args = lang: [ "--${lang}_out=$out/${lang}" ];
      native = [ ];
    };
    java = {
      args = lang: [ "--${lang}_out=$out/${lang}" ];
      native = [ ];
    };
  };

  protoBaseName = proto: baseNameOf (toString proto);

  fromProtobuf =
    { name
    , protos
    , languages ? [ "cpp" ]
    , options ? { }
    , languageConfigs ? defaultProtobufLanguages
    , protobufPackage ? pkgs.protobuf
    , includes ? [ ]
    }:
    let
      protoList = if builtins.isList protos then protos else [ protos ];

      protocTool = ops.tool { name = "protoc"; package = protobufPackage; };

      includeArgs = map (i: "-I${toString i}") includes;

      langCfgFor = lang:
        languageConfigs.${lang}
          or (throw "idl.fromProtobuf: unknown language '${lang}' (known: ${
              toString (builtins.attrNames languageConfigs)
            })");

      langArgsFor = lang: (langCfgFor lang).args lang;

      nativeFor = lang: (langCfgFor lang).native or [ ];

      allNatives = lib.unique (lib.concatMap nativeFor languages);

      optionArgsFor = lang:
        map (opt: "--${lang}_opt=${opt}") (options.${lang} or [ ]);

      protoSources = map
        (proto: ops.localSource {
          name = protoBaseName proto;
          path = proto;
        })
        protoList;

      runOps = lib.concatMap
        (lang:
          map
            (proto: eff.builder.runTool {
              name = "protoc-${lang}-${protoBaseName proto}";
              tool = protocTool;
              args = includeArgs ++ (langArgsFor lang) ++ (optionArgsFor lang)
                ++ [ (toString proto) ];
              env = { };
            })
            protoList
        )
        languages;

      readSourceOps = map
        (src: eff.builder.readSource {
          inherit (src) name;
          source = src;
        })
        protoSources;

      nativeDeps = map
        (pkg: ops.dependency {
          name = pkg.pname or pkg.name or "native";
          role = "native";
          package = pkg;
        })
        allNatives;

      resolveDepOps = map (dep: eff.builder.resolveDependency { dependency = dep; }) nativeDeps;

      perLangOutputs = map cg.perLanguageOutput languages;

      transformOps = map (output: eff.builder.transformOutput { inherit output; }) perLangOutputs;

      declareToolOp = eff.builder.declareTool { tool = protocTool; };

      descriptorOp = eff.builder.emitDescriptor {
        descriptor = ops.descriptor {
          name = "${name}-idl";
          payload = {
            kind = "idl";
            format = "protobuf";
            inherit languages;
            sources = map protoBaseName protoList;
          };
        };
      };

      materializeOp = eff.builder.materializeDerivation {
        name = "${name}-generated";
        builder = "runCommand";
      };

      operations =
        readSourceOps
        ++ resolveDepOps
        ++ [ declareToolOp ]
        ++ runOps
        ++ transformOps
        ++ [ descriptorOp materializeOp ];
    in
    {
      _con = "MetaBuilderSpec";
      idlFormat = "protobuf";
      idlSource = protoList;
      generator = "protoc";
      inherit name languages operations;
      parameters = [ ];
      inputs = protoSources;
      dependencies = nativeDeps;
      tools = [ protocTool ];
      outputs = perLangOutputs;
      evidence = [ ];
    };

  value = {
    inherit IdlBuilder fromProtobuf defaultProtobufLanguages;
    descriptor = G.derive.deriveDescriptor IdlBuilder;
    schema = G.derive.deriveSchema IdlBuilder;
  };

in
api.mk {
  description = "IdlBuilder ornament over CodeGenBuilder, with a `fromProtobuf` smart constructor that produces typed multi-language protobuf code-generation specs.";
  doc = ''
    # IDL Builder

    `IdlBuilder` refines `CodeGenBuilder` with `idlFormat` and
    `idlSource`, encoding "this generator is driven by an IDL document"
    in the type.

    `fromProtobuf { name; protos; languages; options?; languageConfigs?; }`
    builds a fully-typed `IdlBuilder` spec for `protoc`. The default
    language config covers the standard protoc backends; pass
    `languageConfigs` to override or extend.
  '';
  inherit value;
  tests = {
    "schema-derived" = {
      expr = (value.schema.oneOf or [ ]) != [ ];
      expected = true;
    };
    "from-protobuf-shape" = {
      expr =
        let
          spec = fromProtobuf {
            name = "demo";
            protos = [ "/tmp/a.proto" "/tmp/b.proto" ];
            languages = [ "cpp" "java" ];
          };
        in
        {
          inherit (spec) idlFormat generator languages;
          inputCount = builtins.length spec.inputs;
          outputCount = builtins.length spec.outputs;
        };
      expected = {
        idlFormat = "protobuf";
        generator = "protoc";
        languages = [ "cpp" "java" ];
        inputCount = 2;
        outputCount = 2;
      };
    };
    "from-protobuf-runtool-count" = {
      expr =
        let
          spec = fromProtobuf {
            name = "demo";
            protos = [ "/tmp/a.proto" "/tmp/b.proto" ];
            languages = [ "cpp" "java" ];
          };
        in
        builtins.length (lib.filter (op: op.value._con == "runTool") spec.operations);
      expected = 4;
    };
    "from-protobuf-rejects-unknown-language" = {
      expr = (builtins.tryEval (builtins.deepSeq
        (fromProtobuf {
          name = "demo";
          protos = [ "/tmp/a.proto" ];
          languages = [ "klingon" ];
        })
        null)).success;
      expected = false;
    };
    "from-protobuf-language-with-native-emits-resolve-dep" = {
      expr =
        let
          # Custom language config carrying a native package dep —
          # demonstrates the resolveDependency emission path without
          # naming any specific real-world toolchain.
          stubNative = { type = "derivation"; name = "stub-native"; outPath = "/nix/store/fake-stub-native"; pname = "stub-native"; };
          customConfigs = defaultProtobufLanguages // {
            demo = {
              args = lang: [ "--${lang}_out=$out/${lang}" ];
              native = [ stubNative ];
            };
          };
          spec = fromProtobuf {
            name = "demo";
            protos = [ "/tmp/a.proto" ];
            languages = [ "demo" ];
            languageConfigs = customConfigs;
          };
          resolveOps = lib.filter (op: op.value._con == "resolveDependency") spec.operations;
        in
        {
          hasResolve = builtins.length resolveOps >= 1;
          firstRole = (builtins.head resolveOps).value.dependency.role;
          packageIsThunk = fx.state.isThunk (builtins.head resolveOps).value.dependency.package;
        };
      expected = {
        hasResolve = true;
        firstRole = "native";
        packageIsThunk = true;
      };
    };
  };
}
