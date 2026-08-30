{
  description = "homelab";

  inputs = {
    # 26.05 or newer is required: services.pihole-ftl / services.pihole-web
    # landed in 25.11 and do not exist in 25.05.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      mkHost = name: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/base.nix
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
