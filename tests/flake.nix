{
  description = "Tests for ket-nix";

  inputs = {
    ket-nix.url = "../";
  };

  outputs = inputs: {
    formatter = builtins.mapAttrs (system: pkgs: pkgs.alejandra) inputs.nixpkgs.legacyPackages;
    packages =
      builtins.mapAttrs (system: pkgs: {
        default = (import ./.) {
          inherit pkgs;
          k = inputs.ket-nix.lib."${system}".k {
            catalog-toml = ./catalog.toml;
          };
        };
      })
      inputs.ket-nix.inputs.nixpkgs.legacyPackages;
  };
}
