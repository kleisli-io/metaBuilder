{ mb, fx, api, lib, pkgs, ... }:

let
  H = fx.types.hoas;
  G = fx.types.generic;
  ops = mb.operations;
  eff = mb.program.eff;

  OciLayerSpec = H.product "MetaBuilderOciLayer" [
    (H.field "name" H.string)
    (H.field "source" H.string)
  ];

  OciImageBuilder = H.ornament mb.descriptions.BuilderSpec {
    name = "MetaBuilderOciImage";
    constructors.MetaBuilderSpec.fields = [
      { insert = "layers"; type = H.listOf OciLayerSpec.T; }
      { insert = "entrypoint"; type = H.listOf H.string; }
      { insert = "cmd"; type = H.listOf H.string; }
      { insert = "env"; type = H.listOf H.string; }
      { insert = "exposedPorts"; type = H.listOf H.string; }
      { insert = "labels"; type = H.attrs; }
      { insert = "architecture"; type = H.string; }
      { insert = "os"; type = H.string; }
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

  # Layer blobs are uncompressed (`application/vnd.oci.image.layer.v1.tar`),
  # so diff_id == layer digest: one sha256 per layer and no compression
  # determinism surface. All digests are build-time facts (the eval/build
  # split is one-way), so config/manifest/index are rendered by build steps,
  # never by writeFile; steps pass digests to each other through files under
  # $out/.scratch, which the final step removes.
  layerMediaType = "application/vnd.oci.image.layer.v1.tar";
  configMediaType = "application/vnd.oci.image.config.v1+json";
  manifestMediaType = "application/vnd.oci.image.manifest.v1+json";

  deterministicTarFlags = lib.concatStringsSep " " [
    "--sort=name"
    "--format=posix"
    "--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime"
    "--mtime=\"@$SOURCE_DATE_EPOCH\""
    "--owner=0"
    "--group=0"
    "--numeric-owner"
  ];

  ociImage =
    { name
    , layers
    , entrypoint ? [ ]
    , cmd ? [ ]
    , env ? [ ]
    , exposedPorts ? [ ]
    , labels ? { }
    , architecture ? "amd64"
    , os ? "linux"
    , evidence ? [ ]
    }:
    let
      typedLayers = map
        (l: {
          _con = "MetaBuilderOciLayer";
          inherit (l) name;
          source = toString l.source;
        })
        layers;

      bashTool = ops.tool { name = "bash"; package = pkgs.bash; };
      tarTool = ops.tool { name = "tar"; package = pkgs.gnutar; };
      coreutilsTool = ops.tool { name = "coreutils"; package = pkgs.coreutils; };

      layoutOutput = ops.output {
        name = "oci-layout";
        path = "oci-layout";
        format = "json";
      };
      indexOutput = ops.output {
        name = "index";
        path = "$out/index.json";
        format = "json";
      };
      blobsOutput = ops.output {
        name = "blobs";
        path = "$out/blobs";
        format = "tree";
      };
      archiveOutput = ops.output {
        name = "oci-archive";
        path = "$out/image.oci.tar";
        format = "tar";
      };

      runBash = stepName: script: eff.builder.runTool {
        name = stepName;
        tool = bashTool;
        args = [ "-c" script stepName ];
      };

      # chmod u+w: store copies arrive read-only, and clean-scratch must be
      # able to unlink them; the execute bits survive (unlike
      # `--no-preserve=mode`, which would strip them from the binaries).
      assembleRootfs = l: eff.builder.runTool {
        name = "assemble-rootfs-${l.name}";
        tool = bashTool;
        args = [
          "-c"
          ''
            set -euo pipefail
            mkdir -p "$out/.scratch/rootfs-${l.name}"
            cp -a "$1"/. "$out/.scratch/rootfs-${l.name}/"
            chmod -R u+w "$out/.scratch/rootfs-${l.name}"
          ''
          "assemble-rootfs-${l.name}"
          l.source
        ];
      };

      tarLayer = l: runBash "tar-layer-${l.name}" ''
        set -euo pipefail
        mkdir -p "$out/blobs/sha256"
        LC_ALL=C tar ${deterministicTarFlags} \
          -cf "$out/.scratch/layer-${l.name}.tar" \
          -C "$out/.scratch/rootfs-${l.name}" .
        d=$(sha256sum "$out/.scratch/layer-${l.name}.tar" | cut -d " " -f 1)
        s=$(wc -c < "$out/.scratch/layer-${l.name}.tar")
        printf "%s" "$d" > "$out/.scratch/layer-${l.name}.digest"
        printf "%s" "$s" > "$out/.scratch/layer-${l.name}.size"
        mv "$out/.scratch/layer-${l.name}.tar" "$out/blobs/sha256/$d"
      '';

      layerNamesShell = lib.concatMapStringsSep " " (l: l.name) typedLayers;

      configSection = builtins.toJSON ({ }
        // lib.optionalAttrs (entrypoint != [ ]) { Entrypoint = entrypoint; }
        // lib.optionalAttrs (cmd != [ ]) { Cmd = cmd; }
        // lib.optionalAttrs (env != [ ]) { Env = env; }
        // lib.optionalAttrs (exposedPorts != [ ])
        { ExposedPorts = lib.genAttrs exposedPorts (_: { }); }
        // lib.optionalAttrs (labels != { }) { Labels = labels; });

      configPrefix = "{\"architecture\":${builtins.toJSON architecture}"
        + ",\"os\":${builtins.toJSON os}"
        + ",\"config\":${configSection}"
        + ",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[";

      writeConfig = runBash "write-config" ''
        set -euo pipefail
        mkdir -p "$out/blobs/sha256"
        ids=""
        sep=""
        for n in ${layerNamesShell}; do
          d=$(cat "$out/.scratch/layer-$n.digest")
          ids="$ids$sep\"sha256:$d\""
          sep=,
        done
        printf "%s%s%s" ${lib.escapeShellArg configPrefix} "$ids" "]}}" \
          > "$out/.scratch/config.json"
        d=$(sha256sum "$out/.scratch/config.json" | cut -d " " -f 1)
        s=$(wc -c < "$out/.scratch/config.json")
        printf "%s" "$d" > "$out/.scratch/config.digest"
        printf "%s" "$s" > "$out/.scratch/config.size"
        cp "$out/.scratch/config.json" "$out/blobs/sha256/$d"
      '';

      writeManifest = runBash "write-manifest" ''
        set -euo pipefail
        mkdir -p "$out/blobs/sha256"
        cfgd=$(cat "$out/.scratch/config.digest")
        cfgs=$(cat "$out/.scratch/config.size")
        lj=""
        sep=""
        for n in ${layerNamesShell}; do
          d=$(cat "$out/.scratch/layer-$n.digest")
          s=$(cat "$out/.scratch/layer-$n.size")
          lj="$lj$sep{\"mediaType\":\"${layerMediaType}\",\"digest\":\"sha256:$d\",\"size\":$s}"
          sep=,
        done
        m="{\"schemaVersion\":2,\"mediaType\":\"${manifestMediaType}\",\"config\":{\"mediaType\":\"${configMediaType}\",\"digest\":\"sha256:$cfgd\",\"size\":$cfgs},\"layers\":[$lj]}"
        printf "%s" "$m" > "$out/.scratch/manifest.json"
        d=$(sha256sum "$out/.scratch/manifest.json" | cut -d " " -f 1)
        s=$(wc -c < "$out/.scratch/manifest.json")
        printf "%s" "$d" > "$out/.scratch/manifest.digest"
        printf "%s" "$s" > "$out/.scratch/manifest.size"
        cp "$out/.scratch/manifest.json" "$out/blobs/sha256/$d"
      '';

      writeIndex = runBash "write-index" ''
        set -euo pipefail
        ref=${lib.escapeShellArg (builtins.toJSON name)}
        md=$(cat "$out/.scratch/manifest.digest")
        ms=$(cat "$out/.scratch/manifest.size")
        i="{\"schemaVersion\":2,\"manifests\":[{\"mediaType\":\"${manifestMediaType}\",\"digest\":\"sha256:$md\",\"size\":$ms,\"annotations\":{\"org.opencontainers.image.ref.name\":$ref}}]}"
        printf "%s" "$i" > "$out/index.json"
      '';

      # Loud digest-chain self-check: every blob re-hashes to its filename
      # and every recorded size matches the blob on disk. Runs before
      # clean-scratch so the recorded chain is still available.
      verifyBlobs = runBash "verify-blobs" ''
        set -euo pipefail
        st=0
        for b in "$out"/blobs/sha256/*; do
          d=$(sha256sum "$b" | cut -d " " -f 1)
          if [ "$d" != "$(basename "$b")" ]; then
            echo "oci-image: blob digest mismatch: $b" >&2
            st=1
          fi
        done
        for f in "$out"/.scratch/*.size; do
          n=$(basename "$f" .size)
          d=$(cat "$out/.scratch/$n.digest")
          s=$(cat "$f")
          if [ "$s" != "$(wc -c < "$out/blobs/sha256/$d")" ]; then
            echo "oci-image: blob size mismatch: $n" >&2
            st=1
          fi
        done
        exit $st
      '';

      cleanScratch = runBash "clean-scratch" ''
        set -euo pipefail
        rm -rf "$out/.scratch"
      '';

      # Built under $TMPDIR so the archive never contains itself.
      archiveLayout = runBash "archive-layout" ''
        set -euo pipefail
        LC_ALL=C tar ${deterministicTarFlags} \
          -cf "$TMPDIR/image.oci.tar" \
          -C "$out" .
        mv "$TMPDIR/image.oci.tar" "$out/image.oci.tar"
      '';

      layoutOp = eff.builder.writeFile {
        output = layoutOutput;
        text = builtins.toJSON { imageLayoutVersion = "1.0.0"; };
      };

      descriptorOp = eff.builder.emitDescriptor {
        descriptor = ops.descriptor {
          name = "${name}-oci-image";
          payload = {
            kind = "oci-image";
            inherit entrypoint exposedPorts labels architecture os;
          };
        };
      };

      materializeOp = eff.builder.materializeDerivation {
        name = "${name}-oci-image";
        builder = "runCommand";
      };

      operations =
        map (t: eff.builder.declareTool { tool = t; })
          [ bashTool tarTool coreutilsTool ]
        ++ [ layoutOp ]
        ++ lib.concatMap (l: [ (assembleRootfs l) (tarLayer l) ]) typedLayers
        ++ [ writeConfig writeManifest writeIndex verifyBlobs cleanScratch archiveLayout ]
        ++ [ descriptorOp ]
        ++ map (output: eff.builder.transformOutput { inherit output; })
          [ layoutOutput indexOutput blobsOutput archiveOutput ]
        ++ [ materializeOp ];
    in
    {
      _con = "MetaBuilderSpec";
      inherit name entrypoint cmd env exposedPorts labels architecture os
        operations evidence;
      layers = typedLayers;
      parameters = [ ];
      inputs = [ ];
      dependencies = [ ];
      tools = [ bashTool tarTool coreutilsTool ];
      outputs = [ layoutOutput indexOutput blobsOutput archiveOutput ];
    };

  materialize = spec:
    mb.program.materialize.run
      (mb.program.fromOrnamentedSpec OciImageBuilder.T spec);

  value = {
    inherit OciImageBuilder OciLayerSpec ociImage materialize;
    descriptor = G.derive.deriveDescriptor OciImageBuilder;
    schema = G.derive.deriveSchema OciImageBuilder;
  };

in
api.mk {
  description = "OciImageBuilder ornament over BuilderSpec, with an `ociImage` smart constructor that compiles image fields into a named-step OCI layout assembly program.";
  doc = ''
    # OCI Image Builder

    `OciImageBuilder` refines `BuilderSpec` with image metadata (layers,
    entrypoint, cmd, env, exposedPorts, labels, architecture, os) so OCI
    images carry their runtime contract in the type.

    The `ociImage` smart constructor compiles a single config record into
    a typed spec whose operations assemble a spec-conformant OCI image
    layout (`oci-layout`, `index.json`, `blobs/sha256/*`) entirely at
    build time: per-layer rootfs assembly and deterministic tar, then
    config/manifest/index rendering in digest-chain order, a blob
    self-check, scratch cleanup, and an `image.oci.tar` archive of the
    layout — each as a named step so every fold renders the assembly
    legibly.
  '';
  inherit value;
  tests =
    let
      demoSpec = value.ociImage {
        name = "demo";
        layers = [{ name = "app"; source = "/nix/store/fake-rootfs"; }];
        entrypoint = [ "/bin/sh" ];
      };
    in
    {
      "descriptor-constructor" = {
        expr = (builtins.head value.descriptor.constructors).name;
        expected = "MetaBuilderSpec";
      };

      "oci-image-builds-typed-spec" = {
        expr = {
          inherit (demoSpec) architecture os entrypoint cmd;
          layerCount = builtins.length demoSpec.layers;
          layerSource = (builtins.head demoSpec.layers).source;
          opCount = builtins.length demoSpec.operations;
          outputCount = builtins.length demoSpec.outputs;
          toolNames = map (t: t.name) demoSpec.tools;
        };
        expected = {
          architecture = "amd64";
          os = "linux";
          entrypoint = [ "/bin/sh" ];
          cmd = [ ];
          layerCount = 1;
          layerSource = "/nix/store/fake-rootfs";
          # 3 declares + 1 layout write + 2 per-layer + 6 assembly
          # + 1 descriptor + 4 transforms + 1 materialize
          opCount = 18;
          outputCount = 4;
          toolNames = [ "bash" "tar" "coreutils" ];
        };
      };

      "spec-validates-against-ornament-type" = {
        expr = fx.types.validateValue [ ] OciImageBuilder.T demoSpec;
        expected = [ ];
      };

      # Ops are summand-injected: ctor name is value._con.
      "compiled-program-constructor-set" = {
        expr =
          let
            cons = map (o: o.value._con)
              (mb.program.compileSpec OciImageBuilder.T demoSpec);
          in
          {
            opCount = builtins.length cons;
            byCon = lib.genAttrs (lib.unique cons)
              (c: builtins.length (lib.filter (x: x == c) cons));
          };
        expected = {
          opCount = 18;
          byCon = {
            declareTool = 3;
            writeFile = 1;
            runTool = 8;
            emitDescriptor = 1;
            transformOutput = 4;
            materializeDerivation = 1;
          };
        };
      };

      "materialize-renders-named-assembly-steps" = {
        expr =
          let
            result = materialize demoSpec;
          in
          {
            planName = result.plan.name;
            stepNames = map (s: s.name) result.plan.steps;
            hasDerivation = result ? derivation;
          };
        expected = {
          planName = "demo-oci-image";
          stepNames = [
            "write:oci-layout"
            "assemble-rootfs-app"
            "tar-layer-app"
            "write-config"
            "write-manifest"
            "write-index"
            "verify-blobs"
            "clean-scratch"
            "archive-layout"
          ];
          hasDerivation = true;
        };
      };

      "materialize-rejects-malformed-spec" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (materialize { _con = "MetaBuilderSpec"; name = "missing-fields"; })
          null)).success;
        expected = false;
      };
    };
}
