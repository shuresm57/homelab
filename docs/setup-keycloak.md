# Protecting Forgejo on a homelab

I recently started a Forgejo instance on my homelab, and exposed it to the public.

Being the paranoid human that I am, especially when it comes to cyber crimes, I am reluctant to expose all of my code there, especially the private repos that are:

a) not ready to be shown to the public
b) actually private stuff that will never be shown to the public.

But “private” is only a temporary state when hackers are involved. Eventually, they’ll make it public.

I started off by just geoblocking everything but the countries that i somewhat trust - then I installed fail2ban, pretty standard practice for reverse proxies and servers with ssh enabled, but the list ended up looking like this:

1. Single sign-on with Keycloak, so Forgejo has no password form of its own and there is one hardened login for everything.
2. Anubis, keeping AI scrapers from crawling every page of every repository.

## The setup

- One NixOS VM runs Forgejo, Keycloak, PostgreSQL and nginx.
- Forgejo listens on `127.0.0.1:3000` and Keycloak on `127.0.0.1:8080`. Only nginx (80, 443) and Forgejo's built-in SSH server (2222) are exposed.
- nginx serves `git.example.com` (Forgejo) and `auth.example.com` (Keycloak), both with Let's Encrypt certificates.
- The Keycloak admin console is only reachable from the LAN.

Running both on one host keeps things simple: the router already forwards 80 and 443 to this machine, so the new domain only needs a DNS record.

## Layer 1: Geoblocking

nginx can look up the client's country with the `geoip2` module and a free database from db-ip.com, which is packaged in nixpkgs:

```nix
services.nginx.package = pkgs.nginx.override {
  modules = [ pkgs.nginxModules.geoip2 ];
};

services.nginx.appendHttpConfig = ''
  geoip2 ${pkgs.dbip-country-lite}/share/dbip/dbip-country-lite.mmdb {
    $geoip2_data_country_code default=XX source=$remote_addr country iso_code;
  }

  map $geoip2_data_country_code $allowed_country {
    default no;
    DK yes;
    DE yes;
    SE yes;
    # ... or whichever countries you would like to allow.
  }
'';
```

Each public location then starts with:

```nix
extraConfig = ''
  if ($allowed_country = no) { return 403; }
'';
```

This is not a security boundary, since a VPN can get around it. It cuts out most of the automated traffic, and that makes the other layers and the logs a lot quieter.

## Layer 2: fail2ban

fail2ban watches logs and bans IPs that fail too often. On NixOS, enabling it gives you an `sshd` jail out of the box. I turn it on for every host in a shared base module:

```nix
services.fail2ban = {
  enable = true;
  maxretry = 3;
  ignoreIP = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
  bantime = "24h";
  bantime-increment = {
    enable = true;
    formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
    maxtime = "168h";
    overalljails = true;
  };
};
```

A few choices worth explaining:

- `maxretry = 3` with a 24 hour ban. Bots do not give up after a short ban, so short bans just postpone the next round.
- `bantime-increment` makes the ban grow every time the same IP comes back, up to a week. `overalljails` counts offences across all jails, not per jail.
- `ignoreIP` for the private ranges. It is far too easy to lock yourself out from your own LAN while testing.

And of course, it works best together with SSH that only accepts keys:

```nix
services.openssh.settings = {
  PasswordAuthentication = false;
  PermitRootLogin = "prohibit-password";
};
```

Forgejo's built-in SSH server on port 2222 only accepts keys and logs to Forgejo's own log, not sshd's, so the `sshd` jail does not cover it. The web login is covered by the next layer instead: once Forgejo has no password form, there is nothing there to brute force. The login moves to Keycloak, which has brute force detection built in.

## Layer 3: Single sign-on with Keycloak

### Step 1: Keycloak

The NixOS module does most of the work. It creates the database for you when `createLocally` is set.

```nix
services.keycloak = {
  enable = true;
  database = {
    type = "postgresql";
    createLocally = true;
    passwordFile = "/etc/keycloak/db-password";
  };
  initialAdminPassword = "change-me"; 
  settings = {
    hostname = "https://auth.example.com";
    http-enabled = true;
    http-host = "127.0.0.1";
    http-port = 8080;
    proxy-headers = "xforwarded";
  };
};
```

`proxy-headers = "xforwarded"` tells Keycloak to trust the `X-Forwarded-*` headers from nginx, so it generates `https://` URLs even though it only speaks plain HTTP itself.

### Step 2: nginx in front of Keycloak

```nix
services.nginx.virtualHosts."auth.example.com" = {
  forceSSL = true;
  enableACME = true;
  locations."/".proxyPass = "http://127.0.0.1:8080";
  locations."/admin" = {
    proxyPass = "http://127.0.0.1:8080";
    extraConfig = "allow 192.168.0.0/24; deny all;";
  };
  locations."/realms/master" = {
    proxyPass = "http://127.0.0.1:8080";
    extraConfig = "allow 192.168.0.0/24; deny all;";
  };
};

networking.hosts."127.0.0.1" = [ "auth.example.com" ];
```

The admin console logs in through the `master` realm, so I lock down both paths. Your users log in through their own realm, which stays public.

The `networking.hosts` line matters. Forgejo has to call Keycloak from the server to fetch the discovery document and exchange tokens. Without it, the request goes out to your public IP and back in, and many home routers do not support that (hairpin NAT). With it, Forgejo talks to the local nginx and still gets a valid certificate.

### Step 3: Configure the realm

Rebuild and log in to `https://auth.example.com/admin` from your LAN. Then:

1. Create a realm, for example `homelab`.
2. Create a client `forgejo` with client authentication turned on (confidential). Set the redirect URI to `https://git.example.com/user/oauth2/keycloak/callback`. Copy the client secret.
3. Under the client's dedicated scope, add a "Group Membership" mapper with token claim name `groups` and "Full group path" turned off.
4. Create a group `forgejo-admins` and add yourself to it.
5. Create your users.
6. Under Realm settings, Security defenses, turn on **Brute force detection**. This is what replaces fail2ban for the web login: Keycloak locks the account for a while after repeated failures.

### Step 4: Forgejo

Forgejo needs two things: settings in `app.ini`, and an auth source. The settings are easy:

```nix
services.forgejo.settings = {
  service = {
    DISABLE_REGISTRATION = false;            # must be false, or OIDC cannot create users
    ALLOW_ONLY_EXTERNAL_REGISTRATION = true; # but only through the provider
    ENABLE_INTERNAL_SIGNIN = false;          # hide the password form
    ENABLE_BASIC_AUTHENTICATION = false;     # HTTPS git uses access tokens instead
  };
  oauth2_client = {
    ENABLE_AUTO_REGISTRATION = true;
    ACCOUNT_LINKING = "auto";
    USERNAME = "nickname";                   # Keycloak's preferred_username
    OPENID_CONNECT_SCOPES = "openid email profile";
  };
};
```

The auth source is the tricky part. Forgejo stores it in its database, not in `app.ini`, so you cannot declare it directly. I create it in `preStart` with the Forgejo CLI. It adds the source the first time and updates it on every later start, so the Nix config stays the source of truth:

```nix
systemd.services.forgejo = {
  after = [ "keycloak.service" ];
  wants = [ "keycloak.service" ];
  serviceConfig.EnvironmentFile = "/etc/forgejo/oidc.env"; # OIDC_SECRET=...
  preStart = lib.mkAfter ''
    flags="--name keycloak --provider openidConnect --key forgejo \
      --auto-discover-url https://auth.example.com/realms/homelab/.well-known/openid-configuration \
      --scopes 'openid email profile' \
      --group-claim-name groups --admin-group forgejo-admins --skip-local-2fa"
    id=$(forgejo admin auth list | awk '$2 == "keycloak" { print $1 }')
    if [ -z "$id" ]; then
      eval forgejo admin auth add-oauth $flags --secret "$OIDC_SECRET"
    else
      eval forgejo admin auth update-oauth --id "$id" $flags --secret "$OIDC_SECRET"
    fi
  '';
};
```

In a real module, use the full path to the binary (`lib.getExe config.services.forgejo.package`) and build the flags with `lib.escapeShellArgs` instead of `eval`.

The secret lives in a file on the host, outside the Nix store. Anything in a Nix expression ends up world-readable in `/nix/store`.

Finally, skip the login page entirely:

```nix
services.nginx.virtualHosts."git.example.com".locations."= /user/login".return =
  "302 /user/oauth2/keycloak";
```

### Step 5: Keep your existing accounts

With `ACCOUNT_LINKING = "auto"`, Forgejo links a Keycloak login to an existing local account with the same username and email. Before you switch over, make sure the emails on your existing Forgejo users match the ones in Keycloak. Then your first SSO login lands you in your old account, with all your repositories.

## Things to know

- Do it in two deploys.** First deploy Keycloak alone, set up the realm and client, write the secret file, and only then enable OIDC in Forgejo. Otherwise Forgejo starts with an auth source that points at nothing.
- Pushing over HTTPS 

needs a personal access token once basic auth is off. SSH keeps working as before.

- You cannot lock yourself out.

If Keycloak breaks, SSH into the host and use `forgejo admin user` and `forgejo admin auth` to fix things.

- Memory

Keycloak uses around 1 GB of RAM, so give the VM some headroom.

- Never ban your own LAN. 

Keep `ignoreIP` in fail2ban and the LAN-only rules in nginx in sync with your actual subnet.

## Layer 4: Keeping scrapers out with Anubis

The layers above protect the login. Public repositories are a different problem: AI scrapers crawl every commit, blame and diff page, and a small Forgejo instance can buckle under that. Geoblocking helps a little, but these crawlers come from cloud providers everywhere.

[Anubis](https://github.com/TecharoHQ/anubis) is a self-hosted reverse proxy that makes each new visitor's browser solve a small proof-of-work challenge before it lets the request through. People see a short loading screen once and get a cookie, while bots that fetch thousands of pages pay for every one. nixpkgs has a `services.anubis` module, and it slots in between nginx and Forgejo:

```nix
services.anubis.instances.forgejo.settings.TARGET = "http://127.0.0.1:3000";

# Anubis listens on a unix socket owned by the anubis group.
users.users.nginx.extraGroups = [ config.users.groups.anubis.name ];

services.nginx.virtualHosts."git.example.com".locations = {
  "/".proxyPass = "http://unix:${config.services.anubis.instances.forgejo.settings.BIND}";

  # Git clients and API tokens cannot run JavaScript, so they go straight to Forgejo.
  "~ (/info/refs|/git-upload-pack|/git-receive-pack)$".proxyPass = "http://127.0.0.1:3000";
  "/api/".proxyPass = "http://127.0.0.1:3000";
};
```

The bypass locations are the important part. Without them, `git clone` over HTTPS gets an HTML challenge page back and fails with a confusing error. nginx picks regex locations over the plain `/` prefix, so only the git and API paths skip the challenge. In my real config they still carry the geoblock rule.

I only put Anubis on the public domain. On the LAN, the internal hostname goes straight to Forgejo, since nothing there needs filtering.

The default policy is a good start. It lets well-behaved search engines through, blocks known AI crawlers by user agent, and challenges anything that claims to be a browser. If you need to tune it, `services.anubis.instances.<name>.policy.extraBots` takes extra rules.

## Summary

| Threat | Layer |
|---|---|
| Random scanners from far away | Geoblocking in nginx |
| SSH password guessing | Key-only SSH and fail2ban |
| Web login brute force | No Forgejo password form; Keycloak brute force detection |
| Exposed admin panel | Keycloak admin and master realm restricted to the LAN |
| Secrets leaking | Client secret and DB password in files outside the Nix store |
| Scrapers hammering the repos | Anubis, with git and API paths bypassed |

None of these layers is enough on its own, but together they turn a public Forgejo instance from an easy target into a boring one. As a bonus, every new service I add can use the same Keycloak realm, so I only have one password to keep track of.
