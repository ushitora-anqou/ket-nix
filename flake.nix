{
  description = "Utilities for ket";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: {
    formatter = builtins.mapAttrs (system: pkgs: pkgs.alejandra) inputs.nixpkgs.legacyPackages;

    lib = builtins.mapAttrs (system: pkgs:
      import ./lib.nix {
        inherit system pkgs;
      })
    inputs.nixpkgs.legacyPackages;

    apps =
      builtins.mapAttrs (system: pkgs: {
        update-catalog = {
          type = "app";
          program = with pkgs; lib.getExe (callPackage ./scripts/update-catalog {});
        };
      })
      inputs.nixpkgs.legacyPackages;

    devShells =
      builtins.mapAttrs (system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (python3.withPackages (p: with p; [pyyaml requests tomlkit]))
            ruff
          ];
        };
      })
      inputs.nixpkgs.legacyPackages;
  };
}
