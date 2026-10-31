# nix/overlays/abyss-spotlight.nix
#
# Abyss' Spotlight carousel (https://github.com/AumGupta/abyss-jellyfin) is not
# a Jellyfin plugin: it is three files dropped into jellyfin-web/ui plus one
# script tag before </body> in jellyfin-web/index.html. Upstream's installer
# writes them into /usr/share/jellyfin/web, which here is a read-only store
# path, so bake them into the package instead. The vendored files under
# ./abyss-spotlight/ are spotlight v1.2.3, taken verbatim from the repository's
# scripts/spotlight/; refresh them from there to update.
#
# The theme *itself* is CSS and is not installed here -- it goes in
# Dashboard > General > Custom CSS as a single line:
#
#   @import url('https://cdn.jsdelivr.net/gh/AumGupta/abyss-jellyfin@main/abyss.css');
#
# ...with Settings > Display > Theme set to Dark. Spotlight looks unstyled
# without it.
#
# Note the copy of the prebuilt output rather than an overrideAttrs: touching
# jellyfin-web's own build would rebuild the entire web client from npm, while
# this only unpacks what the binary cache already has. jellyfin does get
# rebuilt either way -- it bakes --webdir=${jellyfin-web} into its wrapper, so
# a new web path means a new server derivation (a .NET build, a few minutes,
# once per jellyfin bump).
final: prev: {
  jellyfin-web = prev.runCommand "jellyfin-web-${prev.jellyfin-web.version}-abyss"
    {
      inherit (prev.jellyfin-web) version meta;
      passthru.unthemed = prev.jellyfin-web;
    }
    ''
      cp -r --no-preserve=mode,ownership ${prev.jellyfin-web} $out

      web=$out/share/jellyfin-web
      install -Dm444 ${./abyss-spotlight/spotlight.html}      $web/ui/spotlight.html
      install -Dm444 ${./abyss-spotlight/spotlight.css}       $web/ui/spotlight.css
      install -Dm444 ${./abyss-spotlight/spotlight-loader.js} $web/ui/spotlight-loader.js

      # --replace-fail, not --replace: if a future jellyfin-web ships an
      # index.html without a closing body tag, fail the build instead of
      # quietly serving a web root with no loader in it.
      substituteInPlace $web/index.html \
        --replace-fail '</body>' \
          '<script src="ui/spotlight-loader.js" data-abyss-spotlight></script></body>'
    '';
}
