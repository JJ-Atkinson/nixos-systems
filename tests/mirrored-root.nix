# Run with: nix build --impure --file tests/mirrored-root.nix
# Disposable virtual disks ONLY. Tests the real host recovery module with
# both members, disk_a absent, and disk_b absent. No physical disks are used.
let
  flake = builtins.getFlake "/etc/nixos";
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
in
pkgs.testers.runNixOSTest {
  name = "desktop-mirrored-root";
  nodes = pkgs.lib.genAttrs [ "both" "only_a" "only_b" ] (_: { lib, pkgs, ... }: {
    virtualisation = {
      # disk_b is deliberately larger, like the real Solidigm.
      emptyDiskImages = [ 2048 2304 ];
      useBootLoader = true;
      mountHostNixStore = true;
      useEFIBoot = true;
      memorySize = 1536;
    };
    boot.loader.systemd-boot.enable = true;
    boot.kernelPackages = pkgs.linuxPackages_7_3;
    boot.initrd.systemd = { enable = true; emergencyAccess = true; };
    boot.swraid.enable = true;
    environment.etc."mdadm.conf".text = "MAILADDR test@example.invalid";
    boot.swraid.mdadmConf = lib.mkDefault ''
      ARRAY /dev/md/swap UUID=25eb788e:0c293850:a21dc655:0086fa90
    '';
    environment.systemPackages = with pkgs; [ btrfs-progs cryptsetup mdadm gptfdisk dosfstools efibootmgr ];
    specialisation.mirrored.configuration = {
      imports = [ ../systems/nixos/initrd-luks-tolerant.nix ];
      # Otherwise qemu-vm.nix replaces luks.devices and swapDevices with {} / [].
      virtualisation.useDefaultFilesystems = false;
      virtualisation.rootDevice = "/dev/disk/by-uuid/6137e9a6-e9b2-49e6-9ac4-03e044ee845a";
      virtualisation.fileSystems = {
        "/" = {
          device = "/dev/disk/by-uuid/6137e9a6-e9b2-49e6-9ac4-03e044ee845a";
          fsType = lib.mkForce "btrfs";
          autoFormat = false;
          options = [ "degraded" "subvol=@" "x-systemd.requires=mirrored-root-ready.service" ];
        };
        # /nix is the test driver's host store, not a fixture subvolume.
        "/boot" = {
          device = lib.mkForce "/dev/disk/by-partlabel/disk-disk_a-ESP";
          fsType = "vfat";
          options = [ "nofail" "x-systemd.device-timeout=10s" ];
        };
        "/boot-fallback" = {
          device = "/dev/disk/by-partlabel/disk-disk_b-ESP";
          fsType = "vfat";
          options = [ "nofail" "x-systemd.device-timeout=10s" ];
        };
      };
      fileSystems = lib.genAttrs
        [ "/" "/home" "/nix" "/var/log" "/vm-storage/images" "/vm-storage/shared" ]
        (_: { fsType = "btrfs"; options = [ "degraded" "subvol=@" ]; });
      boot.initrd.secrets."/fixture-key" = pkgs.writeText "fixture-key" "test-only";
      boot.initrd.luks.devices = {
        cryptbtrfs_a = {
          device = "/dev/disk/by-partlabel/disk-disk_a-crypt";
          keyFile = "/fixture-key";
        };
        cryptbtrfs_b = {
          device = "/dev/disk/by-partlabel/disk-disk_b-crypt";
          keyFile = "/fixture-key";
        };
        cryptswap = {
          device = "/dev/md/swap";
          keyFile = "/fixture-key";
        };
      };
      boot.resumeDevice = "/dev/mapper/cryptswap";
      swapDevices = [{ device = "/dev/mapper/cryptswap"; options = [ "x-systemd.device-timeout=45s" ]; }];
    };
  });
  testScript = ''
    start_all()
    for machine, missing in [(both, None), (only_a, "b"), (only_b, "a")]:
        machine.wait_for_unit("multi-user.target")
        machine.succeed("printf test-only > /tmp/key")
        for role, disk in [("a", "/dev/vdb"), ("b", "/dev/vdc")]:
            machine.succeed(f"sgdisk -n 1:0:+128M -t 1:ef00 -c 1:disk-disk_{role}-ESP -n 2:0:+128M -t 2:fd00 -c 2:disk-disk_{role}-swap_raid -n 3:0:0 -t 3:8309 -c 3:disk-disk_{role}-crypt {disk}")
            machine.succeed("udevadm settle")
            machine.succeed(f"mkfs.vfat {disk}1")
            machine.succeed(f"cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --iter-time 1 --key-file /tmp/key {disk}3")
            machine.succeed(f"cryptsetup open --key-file /tmp/key {disk}3 cryptbtrfs_{role}")
        machine.succeed("mkfs.btrfs -U 6137e9a6-e9b2-49e6-9ac4-03e044ee845a -d raid1 -m raid1 /dev/mapper/cryptbtrfs_b /dev/mapper/cryptbtrfs_a")
        machine.succeed("mkdir -p /mnt; mount /dev/mapper/cryptbtrfs_a /mnt; btrfs subvolume create /mnt/@; echo survives > /mnt/@/fixture")
        # Prove that pre-shrinking the old larger member permits replacement
        # after removal with an encrypted partition the size of disk_a's.
        machine.succeed('size=$(blockdev --getsize64 /dev/mapper/cryptbtrfs_a); btrfs filesystem resize "1:$((size - 16777216))" /mnt; umount /mnt')
        machine.succeed("mdadm --create /dev/md/swap --run --name=swap --homehost=any --level=1 --raid-devices=2 --metadata=1.2 --uuid=25eb788e:0c293850:a21dc655:0086fa90 /dev/vdb2 /dev/vdc2")
        machine.wait_until_succeeds("udevadm settle; test -b /dev/md/swap")
        machine.succeed("cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --iter-time 1 --key-file /tmp/key /dev/md/swap")
        machine.succeed("cryptsetup open --key-file /tmp/key /dev/md/swap cryptswap; mkswap /dev/mapper/cryptswap; cryptsetup close cryptswap")
        machine.wait_until_succeeds("! grep -qE 'resync|recovery' /proc/mdstat")
        machine.succeed("mdadm --stop /dev/md/swap; cryptsetup close cryptbtrfs_a; cryptsetup close cryptbtrfs_b")
        for disk in ["/dev/vdb", "/dev/vdc"]:
            machine.succeed(f"mount {disk}1 /mnt; cp -a /boot/. /mnt/; umount /mnt")
        if missing:
            disk = "/dev/vdb" if missing == "a" else "/dev/vdc"
            # Remove the partition table/signatures before boot: this disk no
            # longer supplies any root, swap, or ESP member to the guest.
            machine.succeed(f"wipefs -a {disk}1 {disk}2 {disk}3; sgdisk --zap-all {disk}; udevadm settle")
        boot_disk = "/dev/vdc" if missing == "a" else "/dev/vdb"
        boot_partuuid = machine.succeed(f"blkid -s PARTUUID -o value {boot_disk}1").strip()
        # Boot the actual survivor's ESP, not the fixture's original vda ESP.
        machine.succeed(f"efibootmgr -c -d {boot_disk} -p 1 -L survivor -l '\\EFI\\BOOT\\BOOTX64.EFI'")
        machine.succeed("bootctl set-default nixos-generation-1-specialisation-mirrored.conf; sync")
        machine.crash()
        machine.start()
        machine.wait_for_unit("multi-user.target", timeout=180)
        machine.succeed("uname -r | grep -Fx ${pkgs.linuxPackages_7_3.kernel.modDirVersion}")
        assert machine.succeed("cat /fixture").strip() == "survives"
        machine.succeed("findmnt -n -o FSTYPE / | grep -x btrfs")
        machine.succeed("mountpoint /boot")
        boot_status = machine.succeed("bootctl status --no-pager")
        assert boot_partuuid in boot_status.split("Current Boot Loader:")[1].split("Random Seed:")[0]
        print(machine.succeed("journalctl -b -u mirrored-swap-assemble.service --no-pager; cat /proc/mdstat; swapon --show"))
        # swapon may print /dev/dm-N rather than its /dev/mapper alias.
        machine.succeed('swapon --show=NAME --noheadings | xargs -r readlink -f | grep -Fx "$(readlink -f /dev/mapper/cryptswap)"')
        if missing:
            machine.succeed("grep -F '[U_]' /proc/mdstat || grep -F '[_U]' /proc/mdstat")
            machine.succeed(f"test ! -b /dev/mapper/cryptbtrfs_{missing}")
        else:
            machine.succeed("grep -F '[UU]' /proc/mdstat")
        if missing == "b":
            # Simulate the blank replacement, limiting its root partition to
            # the smaller disk's size. No add/remove or RAID-profile conversion.
            machine.succeed("sgdisk -n 1:0:+128M -t 1:ef00 -c 1:disk-disk_b-ESP -n 2:0:+128M -t 2:fd00 -c 2:disk-disk_b-swap_raid -n 3:0:+1790M -t 3:8309 -c 3:disk-disk_b-crypt /dev/vdc; udevadm settle")
            machine.succeed("printf test-only > /tmp/key; cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --iter-time 1 --key-file /tmp/key /dev/vdc3; cryptsetup open --key-file /tmp/key /dev/vdc3 cryptbtrfs_b")
            machine.succeed("btrfs replace start -B 1 /dev/mapper/cryptbtrfs_b /")
            machine.succeed("test $(cat /sys/fs/btrfs/6137e9a6-e9b2-49e6-9ac4-03e044ee845a/devinfo/1/missing) = 0")
            assert machine.succeed("cat /fixture").strip() == "survives"
            machine.succeed("mdadm --manage /dev/md/swap --add /dev/vdc2")
            machine.wait_until_succeeds("grep -F '[UU]' /proc/mdstat")
            machine.succeed("btrfs scrub start -B /")
  '';
}
