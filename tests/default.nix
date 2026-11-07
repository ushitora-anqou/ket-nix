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

  forgejo =
    k.mkEnvironment {
      name = "forgejo";
      namespace = "forgejo";
    } (let
      forgejo = k.helm rec {
        name = "forgejo";
        releaseName = "ket-nix-tests";
        namespace = "forgejo";
        includeCrds = true;
        values = {
          admin.password = "foobar";
        };
      };
    in [
      (k.namespace {name = "forgejo";})
      forgejo
    ]);
in
  k.buildManifests "ket-nix-tests" [magout forgejo]
