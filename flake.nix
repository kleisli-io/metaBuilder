{
  description = "Typed, effect-backed builder DSL built on nix-effects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-unit.url = "github:nix-community/nix-unit";
    nix-unit.inputs = {
      nixpkgs.follows = "nixpkgs";
      nix-github-actions.follows = "";
      treefmt-nix.follows = "";
    };

    nix-effects.url = "github:kleisli-io/nix-effects";
    nix-effects.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-unit, nix-effects, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;

      mkMb = pkgs: import ./. {
        inherit pkgs;
        fx = nix-effects.lib;
        lib = pkgs.lib;
      };
    in
    {
      # Test attrset for nix-unit: inline tests ({ expr; expected; }) and
      # integration tests (booleans wrapped as { expr; expected = true; }).
      tests =
        let pkgs = import nixpkgs { system = "x86_64-linux"; };
        in (mkMb pkgs).tests.nix-unit;

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nix-unit-pkg = nix-unit.packages.${system}.default;
        in
        {
          default = pkgs.runCommand "metaBuilder-tests"
            {
              nativeBuildInputs = [ nix-unit-pkg ];
            } ''
            export HOME="$(realpath .)"
            nix-unit --eval-store "$HOME" \
              --extra-experimental-features flakes \
              --override-input nixpkgs ${nixpkgs} \
              --override-input nix-unit ${nix-unit} \
              --override-input nix-effects ${nix-effects} \
              --flake ${self}#tests
            touch $out
          '';
        });
    };
}
