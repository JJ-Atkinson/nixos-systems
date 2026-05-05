{ config, pkgs, home-manager, ... }:

let
  yubikey2030 = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDj7HtYyKNytlpE6bv1Au4r/W4sO1OS3GwphVPSlBvs8mqxILyD6e8Rtm9gBAagppdDvM8QWI4sG2Du9ovSS8d7t64bOZRzWcRuNwGKR2duOspFqQKV+jMCkw7zYefIebp34QHcIwsidr2D/NmzdAAR38wDemnmG3GivrVRnPi+DBDQhqp4G6ETS7MU50slfwjC6Hce2VWnpNZPo7odm2JlbOsU7SajZF+OuauYFWj9ZpI1AWFc21dcdtoT4auwnspEsMxxbgEoQEPLTnmI2N+lV4vZpDjlTRSxzy52grJSnJv29n+6XVKGqZzA7L8pWV5oUMg+m0MFGj5tlBkaiyTbOlc+wHgUqxq1qeaV5s3ABqTmoPmeFlyzjBTibykaA21SAi2BEZiJh58k+r9/nVeIxxlF50GpIuBdMzF8sX9+Rrjlxgz23g1RvM1Vi0mCQ77HMKIvjiOXliCBHIqgEaybJSk+l4UEsJdKgYEJIYWhP2PVE3WeRGoSFYKnbTYnPut2ourvRAr0emzsVM21uOyKAJxoBth9xcumZ0V5rS0BLMeS++LWIgbU08vZ82UBBfBhQSctSGUL4UsD4sa2Q2g5IDX/lgpEQyM8cYTFXcEuHt5L+bgucYOgR+wSledeFwvDYkkDQ8eo2i+f9QEtafZLNSUrqqGkTnc9p0/iZBwKlQ== cardno:19_026_550";
in

{
  environment.systemPackages = with pkgs; [ git vim ];

  time.timeZone = "America/Chicago";

  users = {
    mutableUsers = false;

    users.root.hashedPassword = "$6$qwHU7LepEU4KZGb1$f6t0ag76oz5N1UcEhnnUndv4ZyoJrnuF.P7pbBTaDXjHd3gEZUvxsdXdkL8j/hAs0sibQf7CT3wEBgNfSnCgQ0";


    users.jarrett = {
      isNormalUser = true;
      hashedPassword = "$6$qwHU7LepEU4KZGb1$f6t0ag76oz5N1UcEhnnUndv4ZyoJrnuF.P7pbBTaDXjHd3gEZUvxsdXdkL8j/hAs0sibQf7CT3wEBgNfSnCgQ0";
      extraGroups = [ "networkmanager" "wheel" "docker" "plugdev" "kvm" ];
      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDCkSttFbonLeJPrX48W1szmk9UC/rODU1RXlLi3LAuYym02QRTziUE0upjYcmEkZkUlk+pQ3C9UWIrqINdZ0uBpchSFxITsWxGfFiwYVbz0ohy/oP/ikUbet7jFxxNB/I1v4NoDQ77YQmWa9nm4LwzszrOIg+T8kg9nd/ArCM36S5kDPBMB0keJBkLaiJ8v6j0NoqDZa6ayXTOsxecr9c14qWKidDi3zLj7fMRBbylBoEvji1z4wFOv9BZSCPK7BfrqgfW296sz32vN0yk/H95sO6wbM+1dOUW8NrojKBdcazG8fAkq7DquACCIc4/Doiw4nUXHgBLRY6eU1+bL78G+0jlaBs7H4LhDeWqCCDzEb7/25jlzViGKeEwHJeL6aMA54eMoDQcqmlZzJGSvvx7N7mIdo/zg6+8EQkztMcLDKCHbK+zF8a+i+4Shq2h6ei22Og5/i9gJlLSNB8AHriVT0dp9DoGrBqew1c1KvzbaqZweYnod8NnpKqfhi15y4lQC3pt80HuRDbnyz7L3QzeHY1DB0fftAGFSmNAR9hYS6bbjscE7EDW3Xx2ku37ZxSLHM7LaE5LPJ/LDA8xazWvdpyl+dJ5G+HpQREtmLKfFAFT3FPTcFC5F4rfz0FIc4wX3NM+MvOI6FQWOpkk1qz7I0gCinREivnATNl5zNonMw== cardno:19 026 974"
        yubikey2030
      ];

      packages = with pkgs; [
      ];
    };

    users.root.openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDCkSttFbonLeJPrX48W1szmk9UC/rODU1RXlLi3LAuYym02QRTziUE0upjYcmEkZkUlk+pQ3C9UWIrqINdZ0uBpchSFxITsWxGfFiwYVbz0ohy/oP/ikUbet7jFxxNB/I1v4NoDQ77YQmWa9nm4LwzszrOIg+T8kg9nd/ArCM36S5kDPBMB0keJBkLaiJ8v6j0NoqDZa6ayXTOsxecr9c14qWKidDi3zLj7fMRBbylBoEvji1z4wFOv9BZSCPK7BfrqgfW296sz32vN0yk/H95sO6wbM+1dOUW8NrojKBdcazG8fAkq7DquACCIc4/Doiw4nUXHgBLRY6eU1+bL78G+0jlaBs7H4LhDeWqCCDzEb7/25jlzViGKeEwHJeL6aMA54eMoDQcqmlZzJGSvvx7N7mIdo/zg6+8EQkztMcLDKCHbK+zF8a+i+4Shq2h6ei22Og5/i9gJlLSNB8AHriVT0dp9DoGrBqew1c1KvzbaqZweYnod8NnpKqfhi15y4lQC3pt80HuRDbnyz7L3QzeHY1DB0fftAGFSmNAR9hYS6bbjscE7EDW3Xx2ku37ZxSLHM7LaE5LPJ/LDA8xazWvdpyl+dJ5G+HpQREtmLKfFAFT3FPTcFC5F4rfz0FIc4wX3NM+MvOI6FQWOpkk1qz7I0gCinREivnATNl5zNonMw== cardno:19 026 974"
      yubikey2030
    ];
  };

  # Enable passwordless sudo.
#   security.sudo.extraRules = [{
#     users = [ "jarrett" ];
#     commands = [{
#       command = "ALL";
#       options = [ "NOPASSWD" ];
#     }];
#   }];
}
