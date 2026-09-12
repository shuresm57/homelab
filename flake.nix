{
  description = "Nix devshells";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = { nixpkgs, ... }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [ 
      pkgs.alejandra
      pkgs.terraform
      pkgs.nixpkgs-lint
      ];
    };
  };
}


