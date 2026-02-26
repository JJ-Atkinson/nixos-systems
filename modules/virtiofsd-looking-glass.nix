{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # VirtioFS + Looking Glass Compatibility Fix
  # ============================================================================
  #
  # PROBLEM:
  # The standard virtiofsd daemon (versions using vm-memory 0.16.x) fails when
  # used alongside Looking Glass's IVSHMEM device. The error occurs during VM
  # startup with the message:
  #   "vhost_set_mem_table failed: Input/output error (5)"
  #
  # ROOT CAUSE:
  # virtiofsd uses the vhost-user protocol which requires mapping all guest
  # memory regions. The vm-memory 0.16.x library had buggy file-offset
  # validation that incorrectly rejected legitimate memory mappings, including
  # the /dev/kvmfr0 device file used by Looking Glass for IVSHMEM shared memory.
  #
  # THE FIX:
  # vm-memory 0.17.0+ (released October 2025) delegates validation to the
  # kernel's mmap() syscall instead of using homegrown validation. This allows
  # non-seekable file descriptors (like /dev/kvmfr0) to be properly mapped.
  #
  # IMPLEMENTATION:
  # Rather than wait for upstream virtiofsd to update to vm-memory 0.17.x and
  # for NixOS to package it, we use the ELginas fork which already includes
  # the necessary vm-memory updates for Looking Glass compatibility.
  #
  # REFERENCES:
  # - Bug fix PR: https://github.com/rust-vmm/vm-memory/pull/320
  # - Issue discussion: https://gitlab.com/virtio-fs/virtiofsd/-/issues/96
  # - Looking Glass announcement: https://forum.level1techs.com/t/looking-glass-with-virtio-fs/231734
  # - ELginas fork: https://github.com/ELginas/virtiofsd
  #
  # VERIFICATION:
  # After rebuild, virtiofsd --version should show "1.13.2-dev" instead of
  # "1.13.2", indicating the Looking Glass fork is active.
  # ============================================================================

  nixpkgs.overlays = [
    (final: prev: {
      virtiofsd = prev.rustPlatform.buildRustPackage rec {
        # Use ELginas fork which already includes the vm-memory fix
        pname = "virtiofsd";
        version = "1.13.2-looking-glass";

        src = final.fetchFromGitHub {
          owner = "ELginas";
          repo = "virtiofsd";
          rev = "daea013daf5cdc0adc6ae14de92e3a48ac206eae";
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
