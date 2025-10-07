{
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/" ]; # top level mount - this will make sure to only scrub every subvolume mounted inside `/` once. 
  };
}