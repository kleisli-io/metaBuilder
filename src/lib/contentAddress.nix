{ api, ... }:

let
  # drv -> drv: opt a derivation into floating content-addressing. Output path
  # is keyed by realised content, not inputs. Only wrap byte-reproducible drvs
  # (must pass `nix build --rebuild`).
  contentAddress = drv:
    drv.overrideAttrs (_: {
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    });

  value = contentAddress;
in
api.mk {
  description = "Opt a reproducible derivation into floating content-addressing (drv -> drv). Output path keyed by realised content; enables early-cutoff and cross-machine realisation sharing.";
  doc = ''
    # contentAddress

    `contentAddress drv` returns `drv` with floating content-addressing: its
    output store path is the realised NAR content hash, not the input hash.

    ```nix
    final = contentAddress wrappedPackage;
    ```

    Wins over input-addressed caching: early cutoff (unchanged output stops a
    rebuild cascade) and cross-machine sharing (a realisation built on one
    machine substitutes on another, given nix >= 2.35 + harmonia >= 3.1.0).

    Only wrap byte-reproducible derivations (`nix build --rebuild`). A
    non-reproducible CA drv flaps its output hash and mismatches across
    machines. Per-derivation opt-in; never `contentAddressedByDefault`.
  '';
  inherit value;
  tests =
    let
      # Stand-in for nixpkgs `overrideAttrs`: result merged over prior attrs.
      mkFake = attrs: {
        inherit attrs;
        overrideAttrs = f: mkFake (attrs // (f attrs));
      };
    in
    {
      "injects-ca-attrs-and-preserves-prior" = {
        expr = (contentAddress (mkFake { name = "p"; foo = 1; })).attrs;
        expected = {
          name = "p";
          foo = 1;
          __contentAddressed = true;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        };
      };

      "is-a-function" = {
        expr = builtins.typeOf contentAddress;
        expected = "lambda";
      };
    };
}
