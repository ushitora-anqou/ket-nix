{
  description = "Utilities for ket";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: {
    formatter = builtins.mapAttrs (system: pkgs: pkgs.alejandra) inputs.nixpkgs.legacyPackages;
  };
}
