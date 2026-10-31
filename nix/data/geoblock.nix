{
  pkgs, ...
}: {
  services.nginx.appendHttpConfig = ''
    geoip2 ${pkgs.dbip-country-lite}/share/dbip/dbip-country-lite.mmdb {
      $geoip2_data_country_code default=XX source=$remote_addr country iso_code;
    }

    # Private addresses have no country, so the LAN is let through separately.
    geo $is_lan {
      default 0;
      127.0.0.0/8 1;
      10.0.0.0/8 1;
      172.16.0.0/12 1;
      192.168.0.0/16 1;
      ::1 1;
      fc00::/7 1;
      fe80::/10 1;
    }

    map $geoip2_data_country_code $country_allowed {
      default no;
      DK yes;
      DE yes;
      NL yes;
      BE yes;
      FR yes;
      LU yes;
      AT yes;
      CH yes;
      IE yes;
      GB yes;
      SE yes;
      NO yes;
      FI yes;
      IS yes;
      IT yes;
      ES yes;
      PT yes;
    }

    map "$is_lan:$country_allowed" $allowed_country {
      default no;
      "~^1:" yes;
      "0:yes" yes;
    }
  '';
}
