# nix/hosts/ci.nix
{pkgs, ...}: {
  networking.hostName = "ci";

  services.gitea-actions-runner.instances.forgejo = {
    enable = true;
    name = "ci";
    url = "https://git.home.arpa";
    tokenFile = "/etc/forgejo-runner/token.env";

    # host-only: no Docker daemon needed, jobs run straight in a shell.
    labels = ["self-hosted:host"];

    hostPackages = with pkgs; [
      bash coreutils curl gawk gitMinimal gnused nodejs wget
      nix terraform
    ];
  };
}
