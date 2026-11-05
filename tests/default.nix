{
  pkgs,
  k,
}: let
  magout =
    k.mkEnvironment {
      name = "magout";
      namespace = "magout";
    } (let
      magout = k.helm rec {
        name = "magout";
        releaseName = "ket-nix-tests";
        namespace = "magout";
        includeCrds = true;
        values = {
          serverName = "mastodon.example.com";
        };
      };
    in [
      (k.namespace {name = "magout";})
      magout
    ]);
in
  k.buildManifests "ket-nix-tests" [magout]
