{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      version = "0.1.2"; # x-release-please-version
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.buildGoModule {
            pname = "fob";
            inherit version;
            src = ./.;
            vendorHash = "sha256-z8IndcHcZ6nLqhLtAYul3ppddpOA4AHGQWIlfYY/pfI=";
            ldflags = [
              "-X main.version=v${version}"
            ];
            nativeCheckInputs = [ pkgs.git ];
          };
        }
      );
    };
}
