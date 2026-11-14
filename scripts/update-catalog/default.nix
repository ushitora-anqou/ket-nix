{
  lib,
  stdenv,
  python3,
}:
# cf. https://notes.myuu.dev/posts/cd2179454a67658c/
stdenv.mkDerivation {
  name = "update-catalog";
  src = ./.;
  nativeBuildInputs = [];
  buildInputs = [
    (python3.withPackages (p:
      with p; [
        pyyaml
        requests
        semver
        tomlkit
      ]))
  ];
  installPhase = ''
    mkdir -p $out/bin
    cp main.py $out/bin/update-catalog
    chmod +x $out/bin/update-catalog
    patchShebangs --host $out/bin/update-catalog
  '';
  meta = with lib; {
    mainProgram = "update-catalog";
  };
}
