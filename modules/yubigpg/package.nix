{ lib, pkgs, probeTimeout ? 3, agentConfigFile ? null }:
let
  testAgentConfig = if agentConfigFile != null then agentConfigFile else
    (pkgs.formats.keyValue {
      mkKeyValue = lib.generators.mkKeyValueDefault {} " ";
    }).generate "yubigpg-test-agent.conf" { disable-check-own-socket = ""; };
  sshConfig = ''
    Match host * exec "${pkgs.runtimeShell} -c '${pkgs.gnupg}/bin/gpg-connect-agent --quiet --no-autostart --raw-socket \"''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/gnupg/S.gpg-agent.local\" updatestartuptty /bye >/dev/null 2>&1'"
    Match all
  '';
  testSSHConfig = pkgs.writeText "yubigpg-test-ssh-config" sshConfig;
  configuration = pkgs.writeText "yubigpg-config.json" (builtins.toJSON {
    inherit probeTimeout;
    gpgconf = "${pkgs.gnupg}/bin/gpgconf";
  });
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "yubigpg";
  version = "0.2.1";
  src = ./.;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  nativeCheckInputs = [ pkgs.python3 pkgs.gnupg pkgs.openssh pkgs.git ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export PYTHONDONTWRITEBYTECODE=1
    export YUBIGPG_TEST_SSH_CONFIG=${testSSHConfig}
    export YUBIGPG_TEST_AGENT_CONFIG=${testAgentConfig}
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
  passthru = { inherit sshConfig; };
}
