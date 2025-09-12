{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig = {
      url = "github:bandithedoge/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        let
          zig = inputs.zig.packages.${system}.default;
          inherit (zig) zls;
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              zig
              zls
            ];
          };
        };
    };
}
