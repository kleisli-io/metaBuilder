# Standalone dev shell for metaBuilder.
#
# At .envrc:
#   use nix
#
# Provides the test runner (nix-unit) and the task launcher (just) so
# contributors can iterate with `just test` without a flake.
{ pkgs ? (import ./locked.nix "nixpkgs") { }
,
}:
pkgs.mkShell {
  buildInputs = [
    pkgs.nix-unit
    pkgs.just
  ];
}
