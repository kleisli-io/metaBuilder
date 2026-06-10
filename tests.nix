#!/usr/bin/env nix-unit
{ pkgs ? (import ./locked.nix "nixpkgs") { }
, ...
}:
let
  fx = (import ./locked.nix "nix-effects") { inherit pkgs; lib = pkgs.lib; };
  metaBuilder = import ./. {
    inherit pkgs fx;
    lib = pkgs.lib;
  };
in
metaBuilder.tests.nix-unit
