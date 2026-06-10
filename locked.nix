# Fetches and imports a flake-locked input by name from flake.lock.
#
# Usage:
#   pkgs = (import ./locked.nix "nixpkgs") { };
#   fx   = (import ./locked.nix "nix-effects") { inherit pkgs; lib = pkgs.lib; };
#
# Reads the input's locked entry from flake.lock and reproduces the
# same source the flake would, so shell-, test-, and default-paths see
# the exact tree that `nix flake check` sees. Supports `github` inputs
# (constructed from owner/repo/rev) and `tarball` inputs (use locked
# `url` directly).
name:

let
  json = builtins.fromJSON (builtins.readFile ./flake.lock);
  locked = json.nodes.${name}.locked or
    (throw "locked.nix: no locked entry for input '${name}' in flake.lock");
  type = locked.type or "";

  src =
    if type == "github"
    then
      builtins.fetchTarball
        {
          url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
          sha256 = locked.narHash;
        }
    else if type == "tarball"
    then
      builtins.fetchTarball
        {
          url = locked.url;
          sha256 = locked.narHash;
        }
    else throw "locked.nix: unsupported locked input type '${type}' for '${name}'";
in
import src
