{ mb, fx, api, lib, ... }:

let
  G = fx.types.generic;

  projectValue = mb.descriptions.runtime.projectValue;

  recordFields = ty:
    (builtins.head (G.datatype.datatypeInfo ty).constructors).fields;

  stateFieldTypes = builtins.listToAttrs (map
    (f: { inherit (f) name; value = f.type; })
    (recordFields mb.descriptions.PlanState.T));

  # Keep-set: BuildPlan's own field names. State inserts (`declaredTools`,
  # `serviceIndex`) have no image in the forget codomain and drop out here.
  keepNames = map (f: f.name) (recordFields mb.descriptions.BuildPlan.T);

  # Project each kept field at its PlanState-declared type: thunk record
  # fields are omitted, bare thunk positions become null (arity preserved).
  export = program:
    let state = mb.program.materialize.runState program; in
    builtins.listToAttrs (map
      (name: {
        inherit name;
        value = projectValue stateFieldTypes.${name} state.${name};
      })
      keepNames);

  json = program: builtins.toJSON (export program);

  tests =
    let
      # Real nixpkgs derivation cycle: out/all/self all point back at the drv.
      cyclicDrv = {
        type = "derivation";
        name = "cyclic";
        outPath = "/nix/store/cyclic-x";
      } // { self = cyclicDrv; out = cyclicDrv; all = [ cyclicDrv ]; };

      lifecycleCat = mb.operations.capabilityCategory {
        name = "lifecycle";
        capabilities = [ (mb.operations.capability { name = "start"; }) ];
      };
      lifecycleSet = mb.operations.capabilitySet { categories = [ lifecycleCat ]; };

      # Exercises all four thunk-boxed positions with the cyclic stub.
      program = mb.program.sequence [
        (mb.operations.declareTool {
          tool = mb.operations.tool { name = "cyc-tool"; package = cyclicDrv; };
        })
        (mb.operations.runTool {
          name = "gen";
          tool = mb.operations.tool { name = "cyc-tool"; package = cyclicDrv; };
          args = [ "--version" ];
        })
        (mb.operations.resolveDependency {
          dependency = mb.operations.dependency {
            name = "cyc-dep";
            role = "native";
            package = cyclicDrv;
          };
        })
        (mb.operations.declareService {
          service = mb.operations.service {
            name = "cyc-svc";
            package = cyclicDrv;
            capabilities = lifecycleSet;
          };
        })
        (mb.operations.materializeUnit { name = "cyc-svc"; })
      ];

      # Fuel-bounded structural walker: attrs/lists recurse, everything else
      # (functions included) is a leaf, no outPath special-casing; throws on
      # exhaustion, so divergence is tryEval-catchable. Returns leftover fuel.
      walk = fuel: v:
        if fuel <= 0 then throw "plan-export: walker fuel exhausted"
        else if builtins.isAttrs v then
          builtins.foldl' walk (fuel - 1) (builtins.attrValues v)
        else if builtins.isList v then
          builtins.foldl' walk (fuel - 1) v
        else fuel - 1;
      fuel = 1000;
    in
    {
      "json-round-trips-minus-boxed-derivations" = {
        expr =
          let decoded = builtins.fromJSON (json program); in
          {
            toolNames = map (t: t.name) decoded.tools;
            toolHasPackage = builtins.any (t: t ? package) decoded.tools;
            stepCons = map (s: s._con) decoded.steps;
            stepToolPackage = (builtins.head decoded.steps).tool.package;
            nativePaths = decoded.nativePaths;
            serviceNames = map (s: s.name) decoded.declaredServices;
            serviceHasPackage = builtins.any (s: s ? package) decoded.declaredServices;
            artifactHasStorePath = builtins.any (a: a ? storePath) decoded.runtimeArtifacts;
            hasInserts = decoded ? declaredTools || decoded ? serviceIndex;
          };
        expected = {
          toolNames = [ "cyc-tool" ];
          toolHasPackage = false;
          stepCons = [ "runStep" ];
          stepToolPackage = "/nix/store/cyclic-x";
          nativePaths = [ null ];
          serviceNames = [ "cyc-svc" ];
          serviceHasPackage = false;
          artifactHasStorePath = false;
          hasInserts = false;
        };
      };

      # Boxes guard the cyclic stubs as function leaves: both the export
      # output and the boxed state walk to completion.
      "walker-completes-on-export-and-boxed-state" = {
        expr = {
          exportSpare = walk fuel (export program) > 0;
          boxedStateSpare = walk fuel (mb.program.materialize.runState program) > 0;
        };
        expected = { exportSpare = true; boxedStateSpare = true; };
      };

      # Necessity proof: splice the raw cyclic stubs back into the boxed
      # positions and the same walker exhausts any fuel on the self-cycle.
      "unboxed-state-exhausts-walker" = {
        expr =
          let
            state = mb.program.materialize.runState program;
            unboxed = state // {
              tools = map
                (t: t // { package = fx.state.forceThunk t.package; })
                state.tools;
              nativePaths = map fx.state.forceThunk state.nativePaths;
              declaredServices = map
                (s: s // { package = fx.state.forceThunk s.package; })
                state.declaredServices;
            };
          in
          (builtins.tryEval (walk fuel unboxed)).success;
        expected = false;
      };
    };

  value = { inherit export json; };
in
{
  scope = {
    "plan-export" = api.mk {
      description = "plan-export: serializes the pre-finalize PlanState to JSON with thunk-boxed derivation fields as the omission boundary.";
      doc = ''
        Serializes a builder program's pre-finalize plan state: `export`
        yields a JSON-safe attrset with the `BuildPlan` fields, `json` the
        corresponding string. Live derivations never appear in the output —
        boxed derivation fields are omitted, and bare boxed positions show
        as `null`.
      '';
      inherit value;
    };
  };
  tests = lib.mapAttrs'
    (name: test: {
      name = "plan-export-${name}";
      value = test;
    })
    tests;
}
