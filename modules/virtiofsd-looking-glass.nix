{ config, lib, pkgs, ... }:

{
  # Use ELginas fork of virtiofsd with Looking Glass compatibility fix
  # This fixes the vhost_set_mem_table error when using virtiofs with IVSHMEM
  # See: https://github.com/ELginas/virtiofsd (Looking Glass compatibility fork)
  # Root cause: https://github.com/rust-vmm/vm-memory/pull/320

  nixpkgs.overlays = [
    (final: prev: {
      virtiofsd = prev.rustPlatform.buildRustPackage rec {
        # Use ELginas fork which already includes the vm-memory fix
        pname = "virtiofsd";
        version = "1.13.2-looking-glass";

        src = final.fetchFromGitHub {
          owner = "ELginas";
          repo = "virtiofsd";
          rev = "main";
          hash = "sha256-3p9WoUInWh+fmUkiMCjl2Tygx2/reUyKX+3xvMsW26w=";
        };

        # Copy settings from original package
        separateDebugInfo = true;
        cargoHash = "sha256-rKlm8TpCKc+Nzb9+H0FPs5GSNNjWs5/xNpSd0ZZuQt0=";

        LIBCAPNG_LIB_PATH = "${final.lib.getLib final.libcap_ng}/lib";
        LIBCAPNG_LINK_TYPE = if final.stdenv.hostPlatform.isStatic then "static" else "dylib";

        buildInputs = [
          final.libcap_ng
          final.libseccomp
        ];

        postConfigure = ''
          sed -i "s|/usr/libexec|$out/bin|g" 50-virtiofsd.json
        '';

        postInstall = ''
          install -Dm644 50-virtiofsd.json "$out/share/qemu/vhost-user/50-virtiofsd.json"
        '';

        meta = {
          homepage = "https://github.com/ELginas/virtiofsd";
          description = "vhost-user virtio-fs device backend written in Rust (Looking Glass compatible fork)";
          maintainers = [];
          mainProgram = "virtiofsd";
          platforms = final.lib.platforms.linux;
          license = with final.lib.licenses; [ asl20 bsd3 ];
        };
      };
    })
  ];
}
