{ lib, pkgs, probeTimeout ? 3 }:
let
  configuration = pkgs.writeText "yubigpg-config.json" (builtins.toJSON {
    inherit probeTimeout;
    gpgconf = "${pkgs.gnupg}/bin/gpgconf";
  });
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "yubigpg";
  version = "0.2.0";
  src = ./.;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  nativeCheckInputs = [ pkgs.python3 pkgs.gnupg pkgs.openssh pkgs.git ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export PYTHONDONTWRITEBYTECODE=1
    ${pkgs.python3}/bin/python -m unittest discover -s tests -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 tool.py "$out/lib/yubigpg.py"
    makeWrapper ${pkgs.python3}/bin/python "$out/bin/yubigpg" \
      --add-flags "$out/lib/yubigpg.py" \
      --set YUBIGPG_CONFIG ${configuration}
    runHook postInstall
  '';
  meta = {
    description = "Receiver-side socket selection for ordinary GnuPG and standard SSH forwarding";
    platforms = lib.platforms.linux;
    mainProgram = "yubigpg";
  };
}
