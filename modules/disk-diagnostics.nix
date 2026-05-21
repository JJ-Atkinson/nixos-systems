{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    smartmontools
    nvme-cli
  ];

  services.smartd = {
    enable = true;
    notifications.wall.enable = true;
  };
}
