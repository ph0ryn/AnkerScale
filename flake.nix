{
  description = "AnkerScale development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    moonbit-overlay = {
      url = "github:moonbit-community/moonbit-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, moonbit-overlay, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin";
        overlays = [ moonbit-overlay.overlays.default ];
      };
    in
    {
      devShells.aarch64-darwin.default = pkgs.mkShell {
        packages = [ pkgs.moonbit-bin.moonbit.latest ];
      };
    };
}
