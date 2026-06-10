{ fx, api, lib, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;

  validateValue = fx.types.validateValue;
  datatypeInfo = G.datatype.datatypeInfo;

  unitValue = fx.tc.eval.eval [ ] (H.elab H.tt);

  resume = state: {
    action = "resume";
    response = unitValue;
    newState = state;
  };

  # Derives a kind's op side (Eff, Resp, reviewOp, opNames, injectors,
  # dispatch) and state side (State, forget) in one let, so they cannot
  # drift. `forget` is operations-preserving by construction — it walks
  # only ornament spec arms. Handlers, initial state, and in-flight
  # representation stay with the interpreter (`forgetWith finalize`
  # normalizes in-flight state before the forget).
  mkBuilderKind =
    { name
    , base
    , builderOps
    , runtimeOps
    , stateSpec
    }:
    let
      builderInfo = datatypeInfo builderOps.T;
      runtimeInfo = datatypeInfo runtimeOps.T;
      constructorNames = info: map (c: c.name) info.constructors;

      Eff = H.sum builderOps.T runtimeOps.T;

      RespTy = H.forall "_op" Eff (_: H.u 0);
      Resp = H.ann
        (H.lam "op" Eff (op:
          H.sumElim 1
            builderOps.T
            runtimeOps.T
            (H.lam "_op" Eff (_: H.u 0))
            (H.lam "_builderOp" builderOps.T (_: H.unit))
            (H.lam "_runtimeOp" runtimeOps.T (_: H.unit))
            op))
        RespTy;

      State = G.ornaments.ornament base stateSpec;

      forgetWith = finalize: state:
        G.ornaments.forget State (finalize state);

      opNames = {
        builder = constructorNames builderInfo;
        runtime = constructorNames runtimeInfo;
      };

      validAs = ty: v: validateValue [ ] ty v == [ ];

      # Tag a bare op with its summand by validating against each op
      # datatype in order.
      reviewOp = operation:
        if validAs builderOps.T operation
        then { _con = "Left"; value = operation; }
        else if validAs runtimeOps.T operation
        then { _con = "Right"; value = operation; }
        else throw "${name}: operation is neither ${builderInfo.name} nor ${runtimeInfo.name}";

      # Pre-tagged injector namespaces over a name → constructor table,
      # generated from the same partitions as `opNames`.
      injectorsWith = ctors: {
        builder = lib.genAttrs opNames.builder
          (n: args: { _con = "Left"; value = (builtins.getAttr n ctors) args; });
        runtime = lib.genAttrs opNames.runtime
          (n: args: { _con = "Right"; value = (builtins.getAttr n ctors) args; });
      };

      # Copair out of the binary sum: neither handler is optional. The
      # summand is recovered from the coproduct injection (`ctorIndex`
      # 0 = inl, 1 = inr) — no tag string.
      dispatch =
        { label
        , builder
        , runtime
        }:
        ctx:
        let
          op = ctx.op._op or
            (throw "${name}.${label}: operation missing carried op projection");
          summand = ctx.op.fn.ctorIndex or
            (throw "${name}.${label}: operation is not a ${builderInfo.name} + ${runtimeInfo.name} coproduct injection");
          nextState =
            if summand == 0 then builder op ctx.state
            else if summand == 1 then runtime op ctx.state
            else throw "${name}.${label}: operation outside the builder/runtime coproduct";
        in
        resume nextState;
    in
    {
      inherit Eff Resp State opNames reviewOp injectorsWith dispatch forgetWith;
      forget = forgetWith (s: s);
    };

  value = { inherit mkBuilderKind; };

  tests =
    let
      V = G.value;
      AOp = H.datatype "FormerTestAOp" [
        (H.con "alpha" [ (H.field "x" H.string) ])
        (H.con "beta" [ ])
      ];
      BOp = H.datatype "FormerTestBOp" [
        (H.con "gamma" [ (H.field "y" H.string) ])
      ];
      Base = H.product "FormerTestBase" [
        (H.field "label" H.string)
        (H.field "items" (H.listOf H.string))
      ];
      stateSpec = {
        name = "FormerTestState";
        constructors.FormerTestBase.fields = [
          { keep = "label"; }
          { keep = "items"; }
          { insert = "seen"; type = H.attrs; }
        ];
      };
      kind = mkBuilderKind {
        name = "former-test";
        base = Base;
        builderOps = AOp;
        runtimeOps = BOp;
        inherit stateSpec;
      };
      state = {
        _con = "FormerTestBase";
        label = "demo";
        items = [ "a" "b" ];
        seen = { a = true; };
      };
    in
    {
      "eff-is-sum-of-op-datatypes" = {
        expr = fx.tc.conv.conv 0
          (fx.tc.eval.eval [ ] (H.elab kind.Eff))
          (fx.tc.eval.eval [ ] (H.elab (H.sum AOp.T BOp.T)));
        expected = true;
      };

      "resp-returns-unit-for-both-summands" = {
        expr =
          let
            respTagOf = e:
              (fx.tc.eval.eval [ ]
                (H.elab (H.app kind.Resp (V.review kind.Eff e)))).tag;
          in
          {
            builder = respTagOf { _con = "Left"; value = { _con = "beta"; }; };
            runtime = respTagOf { _con = "Right"; value = { _con = "gamma"; y = "g"; }; };
          };
        expected = { builder = "VUnit"; runtime = "VUnit"; };
      };

      "state-is-ornament-over-base" = {
        expr = kind.State ? T && kind.State ? _ornMeta;
        expected = true;
      };

      "forget-drops-inserts-and-inhabits-base" = {
        expr =
          let plan = kind.forget state; in
          {
            hasInsert = plan ? seen;
            inherit (plan) _con label items;
            errs = validateValue [ ] Base.T plan;
          };
        expected = {
          hasInsert = false;
          _con = "FormerTestBase";
          label = "demo";
          items = [ "a" "b" ];
          errs = [ ];
        };
      };

      # The op-blind witness: two kinds sharing base + stateSpec but with
      # different (here: swapped) op datatypes produce identical forgets.
      "forget-is-op-blind" = {
        expr =
          let
            swapped = mkBuilderKind {
              name = "former-test-swapped";
              base = Base;
              builderOps = BOp;
              runtimeOps = AOp;
              inherit stateSpec;
            };
          in
          kind.forget state == swapped.forget state;
        expected = true;
      };

      "forget-with-applies-finalize-before-forget" = {
        expr =
          let
            consState = state // { items = { head = "b"; tail = { head = "a"; tail = null; }; }; };
            toList = c: if c == null then [ ] else [ c.head ] ++ toList c.tail;
            finalize = s: s // { items = lib.reverseList (toList s.items); };
          in
          (kind.forgetWith finalize consState).items;
        expected = [ "a" "b" ];
      };

      "op-names-partition-by-datatype" = {
        expr = kind.opNames;
        expected = { builder = [ "alpha" "beta" ]; runtime = [ "gamma" ]; };
      };

      "review-op-tags-builder-left" = {
        expr = kind.reviewOp { _con = "alpha"; x = "hi"; };
        expected = { _con = "Left"; value = { _con = "alpha"; x = "hi"; }; };
      };

      "review-op-tags-runtime-right" = {
        expr = kind.reviewOp { _con = "gamma"; y = "lo"; };
        expected = { _con = "Right"; value = { _con = "gamma"; y = "lo"; }; };
      };

      "review-op-rejects-foreign-value" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (kind.reviewOp { _con = "delta"; })
          null)).success;
        expected = false;
      };

      "injectors-tag-summands-from-ctor-table" = {
        expr =
          let
            ctors = {
              alpha = args: { _con = "alpha"; } // args;
              beta = args: { _con = "beta"; } // args;
              gamma = args: { _con = "gamma"; } // args;
            };
            inj = kind.injectorsWith ctors;
          in
          {
            builder = inj.builder.alpha { x = "hi"; };
            runtime = inj.runtime.gamma { y = "lo"; };
          };
        expected = {
          builder = { _con = "Left"; value = { _con = "alpha"; x = "hi"; }; };
          runtime = { _con = "Right"; value = { _con = "gamma"; y = "lo"; }; };
        };
      };

      "dispatch-routes-by-ctor-index" = {
        expr =
          let
            d = kind.dispatch {
              label = "test";
              builder = op: s: s // { builderSaw = op._con; };
              runtime = op: s: s // { runtimeSaw = op._con; };
            };
            route = e:
              (d {
                op = (V.review kind.Eff e) // { _op = e.value; };
                state = { };
              }).newState;
          in
          {
            builder = route { _con = "Left"; value = { _con = "beta"; }; };
            runtime = route { _con = "Right"; value = { _con = "gamma"; y = "g"; }; };
          };
        expected = {
          builder = { builderSaw = "beta"; };
          runtime = { runtimeSaw = "gamma"; };
        };
      };
    };
in
{
  scope = {
    former = api.mk {
      description = "former: derives a builder kind's op-coproduct side and state-ornament side from one argument tuple.";
      doc = ''
        # Former

        `mkBuilderKind { name, base, builderOps, runtimeOps, stateSpec }`
        derives the operation coproduct surface (`Eff`, `Resp`, `reviewOp`,
        `opNames`, `injectorsWith`, `dispatch`) and the state ornament
        (`State`, `forget`, `forgetWith`) from one argument tuple, so the
        op side and the state side cannot drift. The derived `forget` is
        op-blind: it never depends on the operation datatypes, so it is
        operations-preserving by construction.
      '';
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "former-${name}";
      value = test;
    })
    tests;
}
