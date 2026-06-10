{ mb, fx, api, lib, ... }:

let
  G = fx.types.generic;

  ToolEnvSpec = mb.descriptions.ToolEnvSpec;

  # `tools` is a list of { name, package } records; each is wrapped into
  # a typed ToolSpec (so `package` is carried as a `Thunk Derivation`) by
  # the canonical `mb.operations.tool` smart-ctor.
  create = { tools ? [ ] }:
    let typedTools = map mb.operations.tool tools;
    in mb.operations.toolEnv { tools = typedTools; };

  empty = create { tools = [ ]; };

  # Merge two ToolEnvSpecs. Tools from `b` override tools from `a` whose
  # `name` matches; remaining `a` tools are preserved in their original
  # order. Composition is associative for distinct-name inputs but not
  # commutative — later wins, matching the old recursiveUpdate semantics.
  merge = a: b:
    let
      bNames = map (t: t.name) b.tools;
      aKept = lib.filter (t: !(lib.elem t.name bNames)) a.tools;
    in
    mb.operations.toolEnv { tools = aKept ++ b.tools; };

  value = {
    inherit ToolEnvSpec create merge empty;
    types.toolEnv = ToolEnvSpec;
    schemas.toolEnv = G.derive.deriveSchema ToolEnvSpec;
  };

in
api.mk {
  description = "metaBuilder tool-env lib: typed bundle of `ToolSpec` records describing a tool environment. The typed list is the API — shell-script glue (binPath strings, PATH snippets) is a separate concern handled by materialization downstream.";
  doc = ''
    # ToolEnv

    `create { tools = [...] }` builds a typed `ToolEnvSpec` from a list
    of raw `{ name; package }` records; each is wrapped via
    `mb.operations.tool` so `package` is carried as a typed
    `Thunk Derivation`.

    `merge a b` composes two envs — `b` overrides any `a` tool whose
    `name` matches. `empty` is the identity.
  '';
  inherit value;
  tests =
    let stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; }; in {
      "create-validates-tool-list" = {
        expr =
          let
            env = create {
              tools = [
                { name = "cc"; package = stubDrv "cc"; }
                { name = "ld"; package = stubDrv "ld"; }
              ];
            };
          in
          map (t: t.name) env.tools;
        expected = [ "cc" "ld" ];
      };

      "empty-has-no-tools" = {
        expr = empty.tools;
        expected = [ ];
      };

      "merge-later-wins-on-name-collision" = {
        expr =
          let
            a = create {
              tools = [
                { name = "cc"; package = stubDrv "gcc"; }
                { name = "ld"; package = stubDrv "ld"; }
              ];
            };
            b = create {
              tools = [
                { name = "cc"; package = stubDrv "clang"; }
              ];
            };
            merged = merge a b;
          in
          map (t: t.name) merged.tools;
        expected = [ "ld" "cc" ];
      };

      "schema-non-empty" = {
        expr = (value.schemas.toolEnv.oneOf or [ ]) != [ ];
        expected = true;
      };
    };
}
