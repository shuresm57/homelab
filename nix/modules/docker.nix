{ config, lib, ... }:
{
  options.homelab.docker.enable =
    lib.mkEnableOption "Docker as the OCI container backend";

  config = lib.mkIf config.homelab.docker.enable {
    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";
  };
}
