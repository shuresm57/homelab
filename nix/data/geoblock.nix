{ 
  pkgs, ... 
}: {
  services.nginx.appendHttpConfig = ''
    geoip2 ${pkgs.dbip-country-lite}/share/dbip/dbip-country-lite.mmdb {
      $geoip2_data_country_code default=XX source=$remote_addr country iso_code;
    }

    map $geoip2_data_country_code $allowed_country {
      default no;
      DK yes; DE yes; NL yes; BE yes; FR yes; LU yes;
      AT yes; CH yes; IE yes; GB yes; SE yes; NO yes;
      FI yes; IS yes; IT yes; ES yes; PT yes;
    }
  '';
}
