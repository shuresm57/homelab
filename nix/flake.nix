{
  description = "homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixarr.url = "github:nix-media-server/nixarr";
    nixarr.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      mkHost = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs };
        modules = [
          ./modules
          ./hosts/${name}.nix
        ];
      };
    in {
      nixosConfigurations = {
        dns = mkHost "dns";
        git = mkHost "git";
      };
    };
}
