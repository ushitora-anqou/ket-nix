{
  system,
  pkgs,
}: {
  k = import ./k.nix {
    inherit pkgs;
  };
}
