{ mb, fx, api, lib, pkgs, ... }:

let
  inherit (fx.state) forceThunk mkThunk;

  isLocalPath = arg:
    builtins.isPath arg
    || (builtins.isString arg
    && lib.hasPrefix "/" arg
    && !lib.hasPrefix "/nix/store/" arg
    && !lib.hasPrefix "$" arg);

  pathMapKey = p: "pathMap_${builtins.hashString "sha256" (toString p)}";

  registerLocal = state: p:
    if p != null && isLocalPath p
    then state // { pathMap = state.pathMap // { ${pathMapKey p} = toString p; }; }
    else state;

  registerLocalArgs = state: args:
    builtins.foldl' registerLocal state args;

  # The eight PlanState list fields accumulate newest-first as cons-cells
  # (`{ head; tail; }`, empty = `null`) during the handler fold, so each
  # append is O(1) and the whole fold is O(N). Nix lists are immutable
  # vectors and `xs ++ [x]` copies both operands, so a `++`-append fold is
  # O(N²); the trampoline uses the same cons-cell trick for its worklist
  # stack for exactly this reason. `flattenListFields` converts them back to
  # declaration-order Nix vectors ONCE, in `finalizePlan`, before the
  # ornament forget (which expects ordinary lists).
  consListFields = [
    "tools"
    "outputs"
    "steps"
    "nativePaths"
    "declaredCapabilities"
    "declaredProtocols"
    "declaredServices"
    "runtimeArtifacts"
  ];
  prepend = x: xs: { head = x; tail = xs; };
  # Walk a newest-first cons-cell list iteratively (`genericClosure`, so a
  # deep list does not recurse on the host stack) collecting heads in
  # newest→oldest order, then reverse into a declaration-order Nix vector.
  consToList = c:
    let
      nodes = builtins.genericClosure {
        startSet = if c == null then [ ] else [{ key = 0; cell = c; }];
        operator = s:
          if s.cell.tail == null then [ ]
          else [{ key = s.key + 1; cell = s.cell.tail; }];
      };
      heads = map (s: s.cell.head) nodes;
      n = builtins.length heads;
    in
    builtins.genList (i: builtins.elemAt heads (n - 1 - i)) n;
  flattenListFields = state:
    state // builtins.listToAttrs
      (map (f: { name = f; value = consToList state.${f}; }) consListFields);

  # PlanState mirrors BuildPlan field-for-field, with two moves: (i) live
  # derivations stay `Thunk`-boxed in-flight (keeps the cyclic drv attrset
  # out of deep walks); the kind's forget projects each box to its store
  # path, so the finalized plan is substrate-neutral — derivation edges
  # survive only as string context. (ii) pure inserts the forget drops:
  # `declaredTools` and `serviceIndex` (O(1) lookups).
  # The eight list fields start cons-empty (`null`); `flattenListFields`
  # vectorizes them at finalize.
  emptyPlan = {
    _con = "MetaBuilderPlan";
    name = "metabuilder-output";
    builder = "runCommand";
    tools = null;
    outputs = null;
    pathMap = { };
    steps = null;
    declaredTools = { };
    nativePaths = null;
    declaredCapabilities = null;
    declaredProtocols = null;
    declaredServices = null;
    serviceIndex = { };
    runtimeArtifacts = null;
  };

  # Kind-derived forget PlanState → BuildPlan: `keep` copies, `keep + sub`
  # projects boxed derivations to store paths, `insert` drops.
  finalizePlan = mb.descriptions.builderKind.forgetWith flattenListFields;

  handleBuilder = op: state:
    if op._con == "readSource" then
      registerLocal state (op.source.path or null)
    else if op._con == "resolveDependency" then
      state // {
        nativePaths = prepend op.dependency.package state.nativePaths;
      }
    else if op._con == "declareTool" then
      let
        tool = mb.descriptions.toToolState op.tool;
      in
      state // {
        tools = prepend tool state.tools;
        declaredTools = state.declaredTools // {
          ${op.tool.name} = tool;
        };
      }
    else if op._con == "runTool" then
      if !(builtins.hasAttr op.tool.name state.declaredTools)
      then
        throw ''
          metaBuilder.materialize: runTool '${op.name}' references undeclared tool '${op.tool.name}'.
          Declared so far: [${lib.concatStringsSep ", " (builtins.attrNames state.declaredTools)}].
          Add a declareTool operation for this tool before runTool.''
      else
        let
          state1 = registerLocalArgs state op.args;
        in
        state1 // {
          steps = prepend {
            _con = "runStep";
            inherit (op) name args env;
            tool = mb.descriptions.finalizeTool op.tool;
          } state1.steps;
        }
    else if op._con == "writeFile" then
      state // {
        steps = prepend {
          _con = "writeStep";
          name = "write:${op.output.path}";
          path = op.output.path;
          inherit (op) text;
        } state.steps;
      }
    else if op._con == "copyPath" then
      let state1 = registerLocal state (op.source.path or null);
      in state1 // {
        steps = prepend {
          _con = "copyStep";
          name = "copy:${op.output.path}";
          source = op.source;
          path = op.output.path;
        } state1.steps;
      }
    else if op._con == "transformOutput" then
      state // { outputs = prepend op.output state.outputs; }
    else if op._con == "validateValue" then
      state
    else if op._con == "emitDescriptor" then
      state
    else if op._con == "materializeDerivation" then
      state // { inherit (op) name builder; }
    else if op._con == "declareEvidence" then
      state
    else
      throw "metaBuilder.materialize: unknown builder operation '${op._con}'";

  handleRuntime = op: state:
    if op._con == "declareCapability" then
      state // {
        declaredCapabilities = prepend op.category state.declaredCapabilities;
      }
    else if op._con == "declareProtocol" then
      state // {
        declaredProtocols = prepend op.protocol state.declaredProtocols;
      }
    else if op._con == "declareService" then
      let
        svc = mb.descriptions.toServiceState op.service;
      in
      state // {
        declaredServices = prepend svc state.declaredServices;
        serviceIndex = state.serviceIndex // { ${op.service.name} = svc; };
      }
    else if op._con == "materializeUnit" then
      if !(builtins.hasAttr op.name state.serviceIndex) then
        throw ''
          metaBuilder.materialize: materializeUnit '${op.name}' references undeclared service.
          Declared so far: [${lib.concatStringsSep ", " (builtins.attrNames state.serviceIndex)}].
          Add a declareService operation for this service before materializeUnit.''
      else
        let
          svc = state.serviceIndex.${op.name};
          serviceDescriptor = mb.descriptions.runtime.descriptor svc;
          drv = pkgs.writeText
            "service-${op.name}.json"
            (builtins.toJSON serviceDescriptor);
        in
        state // {
          runtimeArtifacts = prepend {
            _con = "MetaBuilderRuntimeArtifact";
            kind = "service";
            inherit (op) name;
            descriptor = serviceDescriptor;
            storePath = mkThunk drv;
          } state.runtimeArtifacts;
        }
    else
      throw "metaBuilder.materialize: unknown runtime operation '${op._con}'";

  dispatch = mb.program.dispatchWith {
    label = "materialize";
    builder = handleBuilder;
    runtime = handleRuntime;
  };

  splitAroundOut = s:
    let
      parts = lib.splitString "$out" s;
      interleave = i: part:
        let escaped = lib.escapeShellArg part;
        in if i == 0 then escaped else "\"$out\"" + escaped;
    in
    lib.concatStrings (lib.imap0 interleave parts);

  interpolateArg = arg:
    if isLocalPath arg
    then "\"$" + pathMapKey arg + "\""
    else if builtins.isString arg && lib.hasInfix "$out" arg
    then splitAroundOut arg
    else lib.escapeShellArg (toString arg);

  interpolateEnvValue = v:
    let s = toString v;
    in if lib.hasInfix "$out" s
    then splitAroundOut s
    else lib.escapeShellArg s;

  renderStep = step:
    let con = step._con or ""; in
    if con == "runStep" then
      let
        argsStr = lib.concatMapStringsSep " " interpolateArg step.args;
        envPrefix = lib.concatStringsSep " "
          (lib.mapAttrsToList (k: v: "${k}=${interpolateEnvValue v}") step.env);
        binary = step.tool.name;
      in
      if envPrefix == ""
      then "${binary} ${argsStr}"
      else "${envPrefix} ${binary} ${argsStr}"
    else if con == "writeStep" then
      let
        marker = "METABUILDER_HEREDOC_${builtins.hashString "sha256" step.text}";
      in
      lib.concatStringsSep "\n" [
        ''mkdir -p "$(dirname "$out/${step.path}")"''
        "cat > \"$out/${step.path}\" <<'${marker}'"
        step.text
        marker
      ]
    else if con == "copyStep" then
      let src = toString (step.source.path or ""); in
      lib.concatStringsSep "\n" [
        ''mkdir -p "$(dirname "$out/${step.path}")"''
        "cp -r ${lib.escapeShellArg src} \"$out/${step.path}\""
      ]
    else if con == "mkdirStep" then
      ''mkdir -p "$out/${step.path}"''
    else throw "metaBuilder.materialize.renderStep: unknown step constructor '${con}'";

  toDerivation = plan:
    let
      localPathStorePath = path:
        builtins.path {
          inherit path;
          name = baseNameOf (toString path);
        };
      pathMapLines = lib.mapAttrsToList
        (k: v: "${k}=${lib.escapeShellArg (localPathStorePath v)}")
        plan.pathMap;
      pathMapSetup = lib.concatStringsSep "\n" pathMapLines;
      stepCmds = lib.concatMapStringsSep "\n" renderStep plan.steps;
      packages = map (t: t.package) plan.tools;
      ldPathExport =
        if plan.nativePaths == [ ] then ""
        else "export LD_LIBRARY_PATH=${lib.makeLibraryPath plan.nativePaths}:\${LD_LIBRARY_PATH:-}";
    in
    pkgs.runCommand plan.name { nativeBuildInputs = packages; } ''
      set -euo pipefail
      mkdir -p $out
      ${pathMapSetup}
      ${ldPathExport}
      ${stepCmds}
      if [ -z "$(ls -A $out 2>/dev/null)" ]; then
        touch $out/.empty
      fi
    '';

  # Pre-finalize seam: the typed, flattened, still thunk-boxed PlanState.
  # `forgetWith finalize` factors as forget ∘ finalize, so
  # `builderKind.forget (runState p) == (run p).plan`.
  runState = program:
    flattenListFields
      (mb.program.handle { inherit dispatch program; state = emptyPlan; }).state;

  run = program:
    let
      result = mb.program.handle { inherit dispatch program; state = emptyPlan; };
      plan = finalizePlan result.state;
    in
    {
      _con = "MetaBuilderMaterializeResult";
      inherit plan;
      inherit (result) value;
      derivation = toDerivation plan;
    };

  validatePlan = plan:
    fx.types.validateValue [ ] mb.descriptions.BuildPlan.T plan;

  formatDiagnostic = e: "[${e.reason}] ${e.message}";

  runChecked = program:
    let
      mat = run program;
      errs = validatePlan mat.plan;
    in
    if errs == [ ] then mat
    else
      throw ("metaBuilder.materialize: BuildPlan validation failed "
        + "(${toString (builtins.length errs)} errors):\n"
        + builtins.concatStringsSep "\n"
        (map (e: "  - ${formatDiagnostic e}") errs));

  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "plan-records-typed-run-step" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
              })
              (mb.operations.runTool {
                name = "generate";
                tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
                args = [ "--version" ];
              })
            ])).plan;
            step = builtins.elemAt plan.steps 0;
          in
          {
            stepCount = builtins.length plan.steps;
            con = step._con;
            toolName = step.tool.name;
            inherit (step) args;
          };
        expected = {
          stepCount = 1;
          con = "runStep";
          toolName = "protoc";
          args = [ "--version" ];
        };
      };

      "run-tool-without-declare-throws" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (run (mb.program.sequence [
            (mb.operations.runTool {
              name = "unregistered";
              tool = mb.operations.tool { name = "missing"; package = stubDrv "missing"; };
            })
          ]))
          null)).success;
        expected = false;
      };

      "render-run-step-escapes-args" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
              })
              (mb.operations.runTool {
                name = "say";
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
                args = [ "hello world" "with;semicolon" ];
              })
            ])).plan;
            rendered = renderStep (builtins.head plan.steps);
          in
          {
            escapedFirst = lib.hasInfix "'hello world'" rendered;
            escapedSecond = lib.hasInfix "'with;semicolon'" rendered;
            startsWithBinary = lib.hasPrefix "echo " rendered;
          };
        expected = { escapedFirst = true; escapedSecond = true; startsWithBinary = true; };
      };

      "render-run-step-preserves-out-prefix" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
              })
              (mb.operations.runTool {
                name = "gen";
                tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
                args = [ "--cpp_out=$out/cpp" "$out" ];
              })
            ])).plan;
            rendered = renderStep (builtins.head plan.steps);
          in
          {
            # $out must appear inside double-quotes so the shell expands it.
            hasExpandableOut = lib.hasInfix "\"$out\"" rendered;
            # $out must never be inside single-quotes (which would pass it literally).
            noLiteralDollarOut = !(lib.hasInfix "'$out'" rendered);
            # The flag prefix is escaped as its own shell token.
            hasFlag = lib.hasInfix "'--cpp_out='" rendered;
            # The /cpp suffix appears after the expanded $out (escapeShellArg
            # is minimal so /cpp itself stays unquoted).
            hasSuffix = lib.hasInfix "\"$out\"/cpp" rendered;
          };
        expected = {
          hasExpandableOut = true;
          noLiteralDollarOut = true;
          hasFlag = true;
          hasSuffix = true;
        };
      };

      "write-file-renders-heredoc" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.writeFile {
                output = mb.operations.output { name = "manifest"; path = "manifest.txt"; };
                text = "hello";
              })
            ])).plan;
            step = builtins.head plan.steps;
            rendered = renderStep step;
          in
          {
            con = step._con;
            inherit (step) path text;
            hasHeredoc = lib.hasInfix "<<'METABUILDER_HEREDOC_" rendered;
          };
        expected = {
          con = "writeStep";
          path = "manifest.txt";
          text = "hello";
          hasHeredoc = true;
        };
      };

      "local-path-arg-registers-pathmap" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "tool"; package = stubDrv "tool"; };
              })
              (mb.operations.runTool {
                name = "use-local";
                tool = mb.operations.tool { name = "tool"; package = stubDrv "tool"; };
                args = [ "/local/path/input.txt" ];
              })
            ])).plan;
          in
          builtins.length (builtins.attrNames plan.pathMap);
        expected = 1;
      };

      "declare-tool-recorded" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
              })
            ])).plan;
          in
          (builtins.head plan.tools).name;
        expected = "protoc";
      };

      "materialize-derivation-finalizes-name" = {
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.materializeDerivation { name = "demo-out"; builder = "runCommand"; })
            ])).plan;
          in
          plan.name;
        expected = "demo-out";
      };

      "resolve-dependency-with-package-adds-native-path" = {
        expr =
          let
            pkg = stubDrv "grpcio-tools";
            plan = (run (mb.program.sequence [
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "grpcio-tools";
                  role = "native";
                  package = pkg;
                };
              })
            ])).plan;
          in
          {
            count = builtins.length plan.nativePaths;
            firstNative = builtins.head plan.nativePaths;
          };
        expected = {
          count = 1;
          firstNative = "/nix/store/fake-grpcio-tools";
        };
      };

      # The state boxes the cyclic drv; the forget projects it to its
      # store path, so the finalized plan carries no cyclic structure:
      # the WHOLE plan deepSeqs and toJSONs — the neutrality witness.
      "cyclic-drv-stays-out-of-the-plan" = {
        expr =
          let
            cyclicDrv = {
              type = "derivation";
              name = "cyclic";
              outPath = "/nix/store/cyclic-x";
            } // { self = cyclicDrv; };

            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "cyc-tool"; package = cyclicDrv; };
              })
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "cyc-dep";
                  role = "native";
                  package = cyclicDrv;
                };
              })
            ])).plan;
          in
          {
            wholePlanForces = (builtins.tryEval (builtins.deepSeq plan null)).success;
            planIsJson = builtins.isString (builtins.toJSON plan);
            toolPackage = (builtins.head plan.tools).package;
            nativePath = builtins.head plan.nativePaths;
          };
        expected = {
          wholePlanForces = true;
          planIsJson = true;
          toolPackage = "/nix/store/cyclic-x";
          nativePath = "/nix/store/cyclic-x";
        };
      };

      # Real nixpkgs backref shape (d.out = d, d.all ∋ d): forget projects to
      # the store path, so the plan stays acyclic and deepSeqs/toJSONs.
      "cyclic-drv-real-output-backref-stays-out-of-the-plan" = {
        expr =
          let
            cyclicDrv = {
              type = "derivation";
              name = "cyclic";
              outPath = "/nix/store/cyclic-x";
            } // { out = cyclicDrv; all = [ cyclicDrv ]; };

            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "cyc-tool"; package = cyclicDrv; };
              })
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "cyc-dep";
                  role = "native";
                  package = cyclicDrv;
                };
              })
            ])).plan;
          in
          {
            wholePlanForces = (builtins.tryEval (builtins.deepSeq plan null)).success;
            planIsJson = builtins.isString (builtins.toJSON plan);
            toolPackage = (builtins.head plan.tools).package;
            nativePath = builtins.head plan.nativePaths;
          };
        expected = {
          wholePlanForces = true;
          planIsJson = true;
          toolPackage = "/nix/store/cyclic-x";
          nativePath = "/nix/store/cyclic-x";
        };
      };

      # Service twin of `cyclic-drv-stays-out-of-the-plan`.
      "cyclic-drv-service-stays-out-of-the-plan" = {
        expr =
          let
            cyclicDrv = {
              type = "derivation";
              name = "cyclic";
              outPath = "/nix/store/cyclic-svc";
            } // { self = cyclicDrv; };

            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };

            plan = (run (mb.program.sequence [
              (mb.operations.declareService {
                service = mb.operations.service {
                  name = "cyc-svc";
                  package = cyclicDrv;
                  capabilities = lifecycleSet;
                };
              })
            ])).plan;

            svc = builtins.head plan.declaredServices;
          in
          {
            wholePlanForces = (builtins.tryEval (builtins.deepSeq plan null)).success;
            name = svc.name;
            con = svc._con;
            package = svc.package;
          };
        expected = {
          wholePlanForces = true;
          name = "cyc-svc";
          con = "MetaBuilderFinalizedService";
          package = "/nix/store/cyclic-svc";
        };
      };

      "runtime-materialize-unit-emits-service-json-derivation" = {
        expr =
          let
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
            result = run (mb.program.sequence [
              (mb.operations.declareCapability { category = lifecycleCat; })
              (mb.operations.declareProtocol { protocol = grpc; })
              (mb.operations.declareService { service = svc; })
              (mb.operations.materializeUnit { name = "api"; })
            ]);
            artifact = builtins.head result.plan.runtimeArtifacts;
          in
          {
            artifactCount = builtins.length result.plan.runtimeArtifacts;
            inherit (artifact) kind name;
            isStorePath = lib.hasPrefix builtins.storeDir artifact.storePath;
            isServiceJson = lib.hasSuffix "-service-api.json" artifact.storePath;
            descriptorName = artifact.descriptor.name;
            protoCount = builtins.length artifact.descriptor.protocols;
          };
        expected = {
          artifactCount = 1;
          kind = "service";
          name = "api";
          isStorePath = true;
          isServiceJson = true;
          descriptorName = "api";
          protoCount = 1;
        };
      };

      "runtime-materialize-unit-without-declare-service-throws" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (run (mb.program.sequence [
            (mb.operations.materializeUnit { name = "ghost"; })
          ]))
          null)).success;
        expected = false;
      };

      "runtime-declare-service-collects-spec" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            svc = mb.operations.service {
              name = "internal";
              package = stubDrv "internal";
              capabilities = lifecycleSet;
            };
            result = run (mb.program.sequence [
              (mb.operations.declareService { service = svc; })
            ]);
            first = builtins.head result.plan.declaredServices;
          in
          {
            serviceCount = builtins.length result.plan.declaredServices;
            serviceName = first.name;
            serviceCon = first._con;
            packageIsStorePath = builtins.isString first.package;
          };
        expected = {
          serviceCount = 1;
          serviceName = "internal";
          serviceCon = "MetaBuilderFinalizedService";
          packageIsStorePath = true;
        };
      };

      # PlanState accumulates `declaredServices` as a cons-cell list that
      # flattens to declaration order (matching BuildPlan's field shape), and
      # a `serviceIndex` sideband insert mapping name → finalized thunk for
      # O(1) lookup. The forget map drops `serviceIndex`; the list passes
      # through in declaration order, and `runtime.materialize-unit` resolves
      # any declared service by name, independent of its list position.
      "declare-multiple-services-preserves-order" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            mkSvc = name: mb.operations.service {
              inherit name;
              package = stubDrv name;
              capabilities = lifecycleSet;
            };
            result = run (mb.program.sequence [
              (mb.operations.declareService { service = mkSvc "alpha"; })
              (mb.operations.declareService { service = mkSvc "beta"; })
              (mb.operations.declareService { service = mkSvc "gamma"; })
              (mb.operations.materializeUnit { name = "beta"; })
            ]);
            art = builtins.head result.plan.runtimeArtifacts;
          in
          {
            serviceNames = map (s: s.name) result.plan.declaredServices;
            materializedName = art.name;
            materializedDescriptorName = art.descriptor.name;
          };
        expected = {
          serviceNames = [ "alpha" "beta" "gamma" ];
          materializedName = "beta";
          materializedDescriptorName = "beta";
        };
      };

      "validate-plan-empty-program-is-clean" = {
        expr = validatePlan (run (mb.program.sequence [ ])).plan;
        expected = [ ];
      };

      "validate-plan-with-tool-is-clean" = {
        expr = validatePlan (run (mb.program.sequence [
          (mb.operations.declareTool {
            tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
          })
        ])).plan;
        expected = [ ];
      };

      "validate-plan-with-run-step-is-clean" = {
        expr = validatePlan (run (mb.program.sequence [
          (mb.operations.declareTool {
            tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
          })
          (mb.operations.runTool {
            name = "compile";
            tool = mb.operations.tool { name = "protoc"; package = stubDrv "protoc"; };
            args = [ "schema.proto" ];
          })
        ])).plan;
        expected = [ ];
      };

      "validate-plan-with-runtime-artifact-is-clean" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            svc = mb.operations.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
            };
          in
          validatePlan (run (mb.program.sequence [
            (mb.operations.declareService { service = svc; })
            (mb.operations.materializeUnit { name = "api"; })
          ])).plan;
        expected = [ ];
      };

      "validate-plan-rejects-missing-required-field" = {
        expr =
          let
            plan = (run (mb.program.sequence [ ])).plan;
            broken = builtins.removeAttrs plan [ "runtimeArtifacts" ];
          in
          builtins.length (validatePlan broken) > 0;
        expected = true;
      };

      "validate-plan-rejects-thunked-tool-package" = {
        # FinalizedToolSpec.package is H.string; a thunk carrier must
        # produce a structural diagnostic.
        expr =
          let
            plan = (run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "t"; package = stubDrv "t"; };
              })
            ])).plan;
            broken = plan // {
              tools = map
                (t: t // {
                  package = fx.state.mkThunk t.package;
                })
                plan.tools;
            };
          in
          builtins.length (validatePlan broken) > 0;
        expected = true;
      };

      "run-checked-passes-through-valid-program" = {
        expr =
          let
            mat = runChecked (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
              })
            ]);
          in
          {
            hasPlan = mat ? plan;
            hasDerivation = mat ? derivation;
            toolName = (builtins.head mat.plan.tools).name;
          };
        expected = { hasPlan = true; hasDerivation = true; toolName = "echo"; };
      };

      "materialize-result-validates-against-description" = {
        expr =
          let
            mat = run (mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
              })
            ]);
          in
          fx.types.validateValue [ ] mb.descriptions.MaterializeResult.T mat;
        expected = [ ];
      };

      # The ornament-driven `finalizePlan` must produce the same plan
      # record as the hand-coded forget map captured here.
      "plan-state-forget-equals-hand-finalize" = {
        expr =
          let
            handFinalize = state:
              let
                project = t: toString (forceThunk t);
                flat = flattenListFields state;
              in
              {
                _con = "MetaBuilderPlan";
                inherit (flat) name builder outputs pathMap steps
                  declaredCapabilities declaredProtocols;
                tools = map (t: t // { package = project t.package; }) flat.tools;
                nativePaths = map (t: toString (lib.getLib (forceThunk t))) flat.nativePaths;
                declaredServices = map (s: s // { package = project s.package; }) flat.declaredServices;
                runtimeArtifacts = map (a: a // { storePath = project a.storePath; }) flat.runtimeArtifacts;
              };
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            svc = mb.operations.service {
              name = "api";
              package = stubDrv "api";
              capabilities = lifecycleSet;
            };
            state = (mb.program.handle {
              inherit dispatch;
              program = mb.program.sequence [
                (mb.operations.declareTool {
                  tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
                })
                (mb.operations.resolveDependency {
                  dependency = mb.operations.dependency {
                    name = "lib";
                    role = "native";
                    package = stubDrv "lib";
                  };
                })
                (mb.operations.declareService { service = svc; })
                (mb.operations.materializeUnit { name = "api"; })
              ];
              state = emptyPlan;
            }).state;
            fromOrnament = finalizePlan state;
            fromHand = handFinalize state;
          in
          fromOrnament == fromHand;
        expected = true;
      };

      # The seam coherence witness: the kind's bare forget over the
      # flattened pre-finalize state is the finalized plan.
      "run-state-forget-coheres-with-run" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            program = mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
              })
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "lib";
                  role = "native";
                  package = stubDrv "lib";
                };
              })
              (mb.operations.declareService {
                service = mb.operations.service {
                  name = "api";
                  package = stubDrv "api";
                  capabilities = lifecycleSet;
                };
              })
              (mb.operations.materializeUnit { name = "api"; })
            ];
          in
          mb.descriptions.builderKind.forget (runState program) == (run program).plan;
        expected = true;
      };

      "run-state-inhabits-plan-state" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };
            program = mb.program.sequence [
              (mb.operations.declareTool {
                tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
              })
              (mb.operations.resolveDependency {
                dependency = mb.operations.dependency {
                  name = "lib";
                  role = "native";
                  package = stubDrv "lib";
                };
              })
              (mb.operations.declareService {
                service = mb.operations.service {
                  name = "api";
                  package = stubDrv "api";
                  capabilities = lifecycleSet;
                };
              })
              (mb.operations.materializeUnit { name = "api"; })
            ];
          in
          fx.types.validateValue [ ] mb.descriptions.PlanState.T (runState program);
        expected = [ ];
      };

      "ornament-validates-plan" = {
        expr = validatePlan (run (mb.program.sequence [
          (mb.operations.declareTool {
            tool = mb.operations.tool { name = "echo"; package = stubDrv "echo"; };
          })
          (mb.operations.resolveDependency {
            dependency = mb.operations.dependency {
              name = "lib";
              role = "native";
              package = stubDrv "lib";
            };
          })
        ])).plan;
        expected = [ ];
      };

    };
  value = {
    inherit dispatch run runState runChecked validatePlan toDerivation
      renderStep interpolateArg interpolateEnvValue finalizePlan;
  };
in
{
  scope = {
    materialize = api.mk {
      description = "materialize: lowers builder programs into typed BuildPlan records and runCommand derivations.";
      doc = ''
        Builds typed `BuildPlan` step records, validates tool and service
        declarations, renders shell commands, and produces a `runCommand`
        derivation for the finalized plan. `runState` exposes the typed
        pre-finalize plan state that `plan-export` serializes.
      '';
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "materialize-${name}";
      value = test;
    })
    tests;
}
