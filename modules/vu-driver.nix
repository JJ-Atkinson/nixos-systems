{ config, pkgs, home-manager, ... }:

{
  users.users.jarrett.extraGroups = [ "dialout" ];

  # Enable lingering so user services start on boot and survive logout
  systemd.tmpfiles.rules = [
    "f /var/lib/systemd/linger/jarrett"
  ];

  # Configure user services for jarrett
  systemd.user.services = {
    # VU Server service
    vu-server = {
      description = "VU Server - Python serial communication server for VU1 dials";
      after = [ "default.target" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/home/jarrett/code/personal/VU-Server";
        ExecStart = "${pkgs.bash}/bin/bash -c 'cd /home/jarrett/code/personal/VU-Server && ${config.nix.package}/bin/nix develop -c python3 server.py'";
        Restart = "always";
        RestartSec = "10s";
        
        # Restart on failure
        StartLimitInterval = "5min";
        StartLimitBurst = 5;
      };
    };

    # VU Driver Pack service (depends on vu-server)
    vu-driver-pack = {
      description = "VU Driver Pack - Clojure dial driver application";
      after = [ "vu-server.service" ];
      requires = [ "vu-server.service" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/home/jarrett/code/personal/vu1-driver-pack";
        ExecStart = "${pkgs.jdk}/bin/java -jar /home/jarrett/code/personal/vu1-driver-pack/target/vu1-driver-pack-0.1.0-standalone.jar";
        Restart = "always";
        RestartSec = "10s";
        
        # Restart on failure
        StartLimitInterval = "5min";
        StartLimitBurst = 5;
      };
    };

    # Service triggered by the timer to restart the VU services
    vu-driver-restart = {
      description = "Restart VU driver services";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.systemd}/bin/systemctl --user restart vu-server.service vu-driver-pack.service'";
      };
    };

    # Restart services after hibernation/suspend
    vu-driver-resume = {
      description = "Restart VU driver services after resume from hibernation/suspend";
      after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target" ];
      wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" "suspend-then-hibernate.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash -c 'sleep 5 && ${pkgs.systemd}/bin/systemctl --user restart vu-server.service vu-driver-pack.service'";
      };
    };
  };

  # Timer to restart both services daily at 1am (user timer)
  systemd.user.timers = {
    vu-driver-restart = {
      description = "Daily restart timer for VU driver services at 1am";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "01:00";
        Persistent = true;
        Unit = "vu-driver-restart.service";
      };
    };
  };
}
