{
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [
      "/"  # Main system btrfs (all subvolumes)
      "/vm-storage/images"  # VM storage btrfs (checks integrity of qcow2 files)
    ];
  };
}