{ mb, fx, api, lib, ... }:

let
  H = fx.tc.hoas;
  K = fx.experimental.descInterp.kernel;
  T = fx.experimental.descInterp.trampoline;
  V = fx.tc.generic.value;

  validateValue = fx.types.validateValue;

  validateOr = label: ty: value:
    let errs = validateValue [ ] ty value;
    in if errs == [ ]
    then value
    else throw "metaBuilder.${label}: type check failed (${toString (builtins.length errs)} error(s))";

  # Op-side surface derived once by the kind former; this module binds it
  # to the trampoline (send/handle) and the smart-constructor namespaces.
  kind = mb.descriptions.builderKind;

  BuilderEff = kind.Eff;
  BuilderResp = kind.Resp;

  # A carrier effect is a value-level `BuilderEff` inhabitant
  # `{ _con = "Left" | "Right"; value = <bare op>; }`. `reviewEff` bridges
  # it into the kernel through the coproduct's own injection (`V.review`),
  # then carries the bare op as the single `_op` projection.
  #
  # `_op` is load-bearing, not a shortcut. `V.view` cannot reconstruct it:
  # derivations are opaque to the kernel (extract.nix: "kernel does not
  # store derivation attrs"), and handlers read the real derivation (e.g.
  # `op.tool.package`). So the bare op rides alongside the reviewed term.
  reviewEff = e:
    (V.review BuilderEff e) // { _op = e.value; };

  sendEff = e: K.send BuilderEff BuilderResp (reviewEff e);

  # Kind-derived summand tagger. Sole consumer is the direct-authoring
  # `sequence`/`emit` path; the spec path is pre-tagged and never guesses.
  reviewOp = kind.reviewOp;

  emit = operation: sendEff (reviewOp operation);

  pureUnit = K.pure BuilderEff BuilderResp H.unit H.tt;
  bindUnit = K.bind BuilderEff BuilderResp H.unit H.unit;

  sequence = ops:
    builtins.foldl'
      (comp: operation:
        bindUnit comp (_: emit operation))
      pureUnit
      ops;

  # Sequence carrier effects: each is a value-level `BuilderEff` inhabitant.
  # The summand rides in `_con`; `reviewEff` injects via `V.review`.
  sequenceEffects = effects:
    builtins.foldl'
      (comp: e: bindUnit comp (_: sendEff e))
      pureUnit
      effects;

  # Spec→effects compilation: operations as authored, then `evidence`
  # lowered to trailing `declareEvidence` ops. Interpreters only see
  # programs, so spec-level data must lower here or die.
  compileSpec = specType: spec:
    let valid = validateOr "fromSpec" specType spec;
    in valid.operations
    ++ map (e: eff.builder.declareEvidence { evidence = e; }) valid.evidence;

  fromOrnamentedSpec = specType: spec:
    sequenceEffects (compileSpec specType spec);

  fromSpec = fromOrnamentedSpec mb.descriptions.BuilderSpec.T;

  unitValue = fx.tc.eval.eval [ ] (H.elab H.tt);
  unitHandler =
    H.lam "_op" BuilderEff (_op:
      H.lam "_state" H.unit (_state:
        H.tt));

  resume = state: {
    action = "resume";
    response = unitValue;
    newState = state;
  };

  dispatchWith = kind.dispatch;

  handle = { dispatch, state, program, return ? (v: s: { value = v; state = s; }) }:
    T.handle BuilderEff BuilderResp H.unit
      {
        handler = unitHandler;
        inherit dispatch state return;
      }
      program;

  builder = lib.genAttrs mb.operations.builderOperationNames
    (name: args: emit (builtins.getAttr name mb.operations args));
  runtime = lib.genAttrs mb.operations.runtimeOperationNames
    (name: args: emit (builtins.getAttr name mb.operations args));

  # Injecting namespace: a bare op becomes a value-level `BuilderEff`
  # inhabitant tagged with its summand, from the kind's derived partitions.
  eff = kind.injectorsWith mb.operations;

  value = {
    inherit
      BuilderEff BuilderResp
      builder runtime eff
      unitValue resume dispatchWith handle
      emit sequence sequenceEffects compileSpec fromSpec fromOrnamentedSpec;
  };

  tests =
    let
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
      mkTool = n: mb.operations.tool { name = n; package = stubDrv n; };
    in {
      "builder-eff-is-closed-builder-runtime-sum" = {
        expr = fx.tc.conv.conv 0
          (fx.tc.eval.eval [ ] (H.elab BuilderEff))
          (fx.tc.eval.eval [ ] (H.elab
            (H.sum mb.descriptions.BuilderOp.T mb.descriptions.RuntimeOp.T)));
        expected = true;
      };

      "builder-resp-returns-unit-for-builder-op" = {
        expr =
          let op = reviewEff (eff.builder.materializeDerivation { name = "pkg"; });
          in (fx.tc.eval.eval [ ] (H.elab (H.app BuilderResp op))).tag;
        expected = "VUnit";
      };

      "emit-run-tool-desc-interp-program" = {
        expr =
          let
            program = emit (mb.operations.runTool {
              name = "compile";
              tool = mb.operations.tool { name = "cc"; package = stubDrv "cc"; };
            });
          in {
            tag = program._htag;
            summand = program.d._htag;
            ctorIndex = program.d.term.fst.a.fn.ctorIndex;
          };
        expected = {
          tag = "desc-con";
          summand = "boot-inr";
          ctorIndex = 0;
        };
      };

      "runtime-smart-constructor-emits-runtime-summand" = {
        expr =
          let program = runtime.materializeUnit { name = "api"; };
          in program.d.term.fst.a.fn.ctorIndex;
        expected = 1;
      };

      "eff-builder-namespace-injects-builder-summand" = {
        expr =
          let e = eff.builder.materializeDerivation { name = "pkg"; };
          in { inherit (e) _con; opCon = e.value._con; };
        expected = { _con = "Left"; opCon = "materializeDerivation"; };
      };

      "eff-runtime-namespace-injects-runtime-summand" = {
        expr =
          let e = eff.runtime.materializeUnit { name = "api"; };
          in { inherit (e) _con; opCon = e.value._con; };
        expected = { _con = "Right"; opCon = "materializeUnit"; };
      };

      "sequence-effects-equals-bare-sequence-path" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
            bareOps = [
              (mb.operations.materializeDerivation { name = "pkg"; })
              (mb.operations.declareCapability { category = lifecycleCat; })
            ];
            effects = [
              (eff.builder.materializeDerivation { name = "pkg"; })
              (eff.runtime.declareCapability { category = lifecycleCat; })
            ];
          in
          fx.tc.conv.conv 0
            (fx.tc.eval.eval [ ] (H.elab (sequence bareOps)))
            (fx.tc.eval.eval [ ] (H.elab (sequenceEffects effects)));
        expected = true;
      };

      "emit-rejects-malformed-op" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (emit { _con = "runTool"; name = "incomplete"; })
          null)).success;
        expected = false;
      };
      "fromSpec-rejects-malformed-spec" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (fromSpec { _con = "MetaBuilderSpec"; name = "missing-fields"; })
          null)).success;
        expected = false;
      };

      "compileSpec-lowers-evidence-to-trailing-declare-ops" = {
        expr =
          let
            spec = {
              _con = "MetaBuilderSpec";
              name = "with-evidence";
              parameters = [ ];
              inputs = [ ];
              dependencies = [ ];
              tools = [ ];
              operations = [ (eff.builder.materializeDerivation { name = "pkg"; }) ];
              outputs = [ ];
              evidence = [
                (mb.operations.evidence { name = "self-test"; payload = { command = "./t"; }; })
              ];
            };
            compiled = compileSpec mb.descriptions.BuilderSpec.T spec;
            last = lib.last compiled;
          in
          {
            count = builtins.length compiled;
            summand = last._con;
            opCon = last.value._con;
            evidenceName = last.value.evidence.name;
          };
        expected = {
          count = 2;
          summand = "Left";
          opCon = "declareEvidence";
          evidenceName = "self-test";
        };
      };

      "emit-accepts-runtime-op" = {
        expr =
          let
            lifecycleCat = mb.operations.capabilityCategory {
              name = "lifecycle";
              capabilities = [ (mb.operations.capability { name = "start"; }) ];
            };
          in
          (emit (mb.operations.declareCapability { category = lifecycleCat; })).d.term.fst.a.fn.ctorIndex;
        expected = 1;
      };

      "dispatchWith-routes-builder-op" = {
        expr =
          let
            dispatch = dispatchWith {
              label = "test";
              builder = op: state: state // { seen = op._con; };
              runtime = op: _state: throw "test: builder op routed to runtime summand '${op._con}'";
            };
            result = dispatch {
              op = reviewEff (eff.builder.materializeDerivation { name = "pkg"; });
              state = { };
            };
          in
          {
            inherit (result) action;
            inherit (result.newState) seen;
          };
        expected = {
          action = "resume";
          seen = "materializeDerivation";
        };
      };

      # Left-fold orientation: handled ops land in source order, not reversed.
      "handle-threads-builder-ops-in-source-order" = {
        expr =
          let
            program = sequence [
              (mb.operations.runTool { name = "first"; tool = mkTool "cc"; })
              (mb.operations.runTool { name = "second"; tool = mkTool "cc"; })
            ];
            dispatch = dispatchWith {
              label = "order";
              builder = op: state: state ++ [ op.name ];
              runtime = op: _state: throw "order: unexpected runtime summand '${op._con}'";
            };
          in (handle { inherit dispatch program; state = [ ]; }).state;
        expected = [ "first" "second" ];
      };

      # State threading over a list state agrees with the pure monoid fold.
      "state-threaded-fold-equals-monoid-fold" = {
        expr =
          let
            ops = map (n: mb.operations.runTool { name = n; tool = mkTool "cc"; })
              [ "a" "b" "c" ];
            contribution = op: op.name;
            monoidFold = builtins.foldl' (acc: op: acc ++ [ (contribution op) ]) [ ] ops;
            dispatch = dispatchWith {
              label = "parity";
              builder = op: state: state ++ [ (contribution op) ];
              runtime = op: _state: throw "parity: unexpected runtime summand '${op._con}'";
            };
            stateThreaded =
              (handle { inherit dispatch; program = sequence ops; state = [ ]; }).state;
          in monoidFold == stateThreaded;
        expected = true;
      };

      "emit-rejects-malformed-runtime-op" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (emit { _con = "declareService"; })
          null)).success;
        expected = false;
      };
    };
in
{
  scope = value;
  tests = lib.mapAttrs'
    (name: test: {
      name = "signature-${name}";
      value = test;
    })
    tests;
}
