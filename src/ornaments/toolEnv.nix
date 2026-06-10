{ mb, fx, api, lib, ... }:

let
  inherit (mb.operations) toolEnv tool;
  inherit (fx.state) forceThunk;

  # Smart constructors. `define` is the canonical typed form; `create`
  # accepts a raw `{ name = package; }` attrset for ergonomic
  # consumer-site construction (delegates to `define` via the typed
  # `tool` smart-ctor).
  define = toolEnv;

  create = packageAttrs:
    let
      # A null package means "tool unavailable for this configuration".
      pairs = lib.filter ({ value, ... }: value != null)
        (lib.mapAttrsToList (name: value: { inherit name value; }) packageAttrs);
      tools = map (p: tool { name = p.name; package = p.value; }) pairs;
    in
    define { inherit tools; };

  empty = define { tools = [ ]; };

  # `merge a b`: combine two typed environments. Tool name collisions
  # resolve B-wins.
  merge = a: b:
    let
      bNames = map (t: t.name) b.tools;
      aFiltered = lib.filter (t: !(lib.elem t.name bNames)) a.tools;
    in
    define { tools = aFiltered ++ b.tools; };

  # Eliminators (pure functions of the typed spec).

  # toolInputs : ToolEnvSpec -> [Derivation]
  # Extracts package derivations for `nativeBuildInputs`. The typed
  # `tools` carry Thunk-wrapped packages; the eliminator forces the
  # thunks back to plain derivations at the consumer boundary.
  # Deduplicates by Nix-level equality.
  toolInputs = env: lib.unique (map (t: forceThunk t.package) env.tools);

  # toolBinPath : ToolEnvSpec -> String
  # `lib.makeBinPath` over the deduplicated input list. Suitable for
  # `export PATH="${toolBinPath}:$PATH"` in build scripts.
  toolBinPath = env: lib.makeBinPath (toolInputs env);

  # isEmpty : ToolEnvSpec -> Bool
  isEmpty = env: env.tools == [ ];

  # toolPackages : ToolEnvSpec -> { name = Derivation; }
  # Attrset view derived from the typed list. Forces the Thunk carriers
  # so consumers see plain derivations. Suitable for round-tripping
  # through `passthru.toolPackages`.
  toolPackages = env: lib.listToAttrs
    (map (t: { inherit (t) name; value = forceThunk t.package; }) env.tools);

  # toExportSnippet : ToolEnvSpec -> String
  # Shell snippet (heredoc style) that prepends the tool bin path.
  # Empty environments emit "" so the snippet can be unconditionally
  # spliced into build scripts.
  toExportSnippet = env:
    if isEmpty env then ""
    else "export PATH=\"${toolBinPath env}:$PATH\"\n";

  # toInlineSnippet : ToolEnvSpec -> String
  # Indented variant for inline shell-script use.
  toInlineSnippet = env:
    if isEmpty env then ""
    else "          export PATH=\"${toolBinPath env}:$PATH\"\n";

  # toWrapPrefix : ToolEnvSpec -> String
  # Shell fragment suitable for `wrapProgram --prefix PATH : "$path" \`.
  # Empty environments emit "" so the fragment can be unconditionally
  # spliced into a wrapper invocation.
  toWrapPrefix = env:
    if isEmpty env then ""
    else "          --prefix PATH : \"${toolBinPath env}\" \\\n";

  value = {
    inherit define create empty merge;
    inherit toolInputs toolBinPath isEmpty toolPackages
      toExportSnippet toInlineSnippet toWrapPrefix;
  };

in
api.mk {
  description = "toolEnv ornament: typed tool-environment vocabulary for builder consumers. The spec carries only a typed `tools : [ToolSpec]` list; eliminators derive `toolInputs`/`toolBinPath`/snippets. No bash-string fragments live in the spec — they emerge from eliminators only.";
  doc = ''
    # Tool Environment

    Typed tool-environment vocabulary. The underlying `ToolEnvSpec`
    lives in `mb.descriptions` and carries only a `tools : [ToolSpec]`
    list — no bash-string fragments leak into the spec.

    - **Smart constructors**:
      - `toolEnv.define { tools }` proxies to `mb.operations.toolEnv`
        (eager structural validation).
      - `toolEnv.create { name = package; ... }` builds the spec from
        a `{ name = package | null; }` attrset (legacy ergonomic shape;
        `null` entries are dropped).
      - `toolEnv.empty` is the zero element.
      - `toolEnv.merge a b` combines two environments; tool name
        collisions resolve B-wins.

    - **Eliminators** (pure functions of the typed spec):
      - `toolInputs : ToolEnvSpec → [Derivation]` — deduplicated
        package list for `nativeBuildInputs`.
      - `toolBinPath : ToolEnvSpec → String` — `lib.makeBinPath` view.
      - `toExportSnippet : ToolEnvSpec → String` — heredoc-style
        `export PATH=...` snippet (empty for empty envs).
      - `toInlineSnippet : ToolEnvSpec → String` — indented variant.
      - `toWrapPrefix : ToolEnvSpec → String` — `wrapProgram --prefix`
        fragment.
      - `toolPackages : ToolEnvSpec → { name = Derivation; }` —
        legacy-shaped attrset view, useful for `passthru` round-trip.
      - `isEmpty : ToolEnvSpec → Bool`.

    The spec is the single source of truth; every derived view comes
    from an eliminator. Shell snippets live in eliminator outputs, not
    in spec fields.
  '';
  inherit value;
  tests =
    let
      stubDrv = name: { type = "derivation"; inherit name; outPath = "/nix/store/fake-${name}"; };
      stubAlpha = stubDrv "tool-alpha";
      stubBeta = stubDrv "tool-beta";
      stubGamma = stubDrv "tool-gamma";

      envAlphaBeta = create { alpha = stubAlpha; beta = stubBeta; };
      envBetaGamma = create { beta = stubBeta; gamma = stubGamma; };
      envWithNull = create { alpha = stubAlpha; beta = null; };
    in
    {
      "define-typed-shape" = {
        expr = (define { tools = [ ]; })._con;
        expected = "MetaBuilderToolEnv";
      };

      "empty-has-no-tools" = {
        expr = { inherit (empty) tools; emptyFlag = isEmpty empty; };
        expected = { tools = [ ]; emptyFlag = true; };
      };

      "create-builds-typed-tools-from-attrset" = {
        expr = {
          toolCount = builtins.length envAlphaBeta.tools;
          names = builtins.sort builtins.lessThan (map (t: t.name) envAlphaBeta.tools);
          firstConTag = (builtins.head envAlphaBeta.tools)._con;
        };
        expected = {
          toolCount = 2;
          names = [ "alpha" "beta" ];
          firstConTag = "MetaBuilderTool";
        };
      };

      "create-drops-null-packages" = {
        expr = {
          toolCount = builtins.length envWithNull.tools;
          names = map (t: t.name) envWithNull.tools;
        };
        expected = {
          toolCount = 1;
          names = [ "alpha" ];
        };
      };

      "merge-B-wins-on-name-collision" = {
        expr =
          let merged = merge envAlphaBeta envBetaGamma; in {
            names = builtins.sort builtins.lessThan (map (t: t.name) merged.tools);
            toolCount = builtins.length merged.tools;
          };
        expected = {
          names = [ "alpha" "beta" "gamma" ];
          toolCount = 3;
        };
      };

      "merge-empty-is-identity" = {
        expr = (merge envAlphaBeta empty).tools == envAlphaBeta.tools;
        expected = true;
      };

      "toolInputs-returns-package-list" = {
        expr = builtins.length (toolInputs envAlphaBeta);
        expected = 2;
      };

      "toolPackages-roundtrips-to-attrset" = {
        expr = builtins.attrNames (toolPackages envAlphaBeta);
        expected = [ "alpha" "beta" ];
      };

      "toExportSnippet-empty-env-is-empty-string" = {
        expr = toExportSnippet empty;
        expected = "";
      };

      "toExportSnippet-non-empty-emits-PATH-line" = {
        expr =
          let s = toExportSnippet envAlphaBeta; in {
            isNonEmpty = s != "";
            startsWithExport = lib.hasPrefix "export PATH=\"" s;
            containsPathSuffix = lib.hasInfix ":$PATH\"" s;
          };
        expected = {
          isNonEmpty = true;
          startsWithExport = true;
          containsPathSuffix = true;
        };
      };

      "toWrapPrefix-empty-env-is-empty-string" = {
        expr = toWrapPrefix empty;
        expected = "";
      };

      "toWrapPrefix-non-empty-emits-prefix-fragment" = {
        expr =
          let s = toWrapPrefix envAlphaBeta; in {
            containsPrefixFlag = lib.hasInfix "--prefix PATH : \"" s;
            endsWithBackslash = lib.hasSuffix " \\\n" s;
          };
        expected = {
          containsPrefixFlag = true;
          endsWithBackslash = true;
        };
      };

      "define-rejects-malformed-tool" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (define { tools = [{ _con = "MetaBuilderTool"; name = 42; package = stubAlpha; }]; })
          null)).success;
        expected = false;
      };
    };
}
