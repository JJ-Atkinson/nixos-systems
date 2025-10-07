{
  services.openssh = {
    enable = true;
    listenAddresses = [{
      addr = "0.0.0.0";
      port = 22;
    }];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      ChallengeResponseAuthentication = false;
      UsePAM = false;
  
  
      # Root login policy: "prohibit-password" allows root over keys only.
      # Use "no" to disable root SSH entirely and use sudo from a user.
      PermitRootLogin = "prohibit-password";
  
      # Limit auth attempts and session counts
      MaxAuthTries = 4;
      MaxStartups = "10:30:60"; # conn rate limiting
      LoginGraceTime = "20s";
  
      # Reduce information leakage
      PrintMotd = false;
      UseDns = false;
      Compression = "no";
  
      # Modern crypto (OpenSSH defaults are good; this is optional)
      # Ciphers, KexAlgorithms, MACs can be pinned if you want stricter policy.
    };
  };

  networking.firewall = {
    # let you SSH in over the public internet
    allowedTCPPorts = [ 22 ];
  };
}