{ home }:
{ lib, config, ... }:
let
  inherit (lib) mkIf mkOption types;
in
{
  options = {
    devshell = mkOption {
      type = types.bool;
      default = false;
      description = "Enable direnv integration inside the container (sets BOTILLE_DEVSHELL=1).";
    };

    volumes = mkOption {
      type = types.listOf types.str;
      default = [
        "botille-home:${home}"
        "botille-nix:/var/nix-store"
      ];
      description = "Volume mounts passed to podman run as -v flags.";
      example = [ "/host/path:/container/path:Z" ];
    };

    ports = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Port mappings passed to podman run as -p flags.";
      example = [ "8080:8080" ];
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Environment variables passed to podman run as -e flags.";
    };

    dns = mkOption {
      type = types.listOf types.str;
      default = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      description = "DNS servers for the container.";
    };

    network = mkOption {
      type = types.str;
      default = "pasta:--map-gw,-a,10.171.0.100,-n,24,-g,10.171.0.1";
      description = "Network mode for the container.";
    };

    capabilities = mkOption {
      type = types.lazyAttrsOf (types.nullOr types.bool);
      default = {
        SYS_ADMIN = true;
        NET_ADMIN = false;
        NET_RAW = false;
      };
      description = ''
        Capabilities to configure. true = --cap-add, false = --cap-drop, null = default.
      '';
    };

    securityOpt = mkOption {
      type = types.listOf types.str;
      default = [ "no-new-privileges" ];
      description = "Security options passed to podman run.";
    };

    userns = mkOption {
      type = types.nullOr types.str;
      default = "keep-id";
      description = "User namespace mode.";
    };

    logDriver = mkOption {
      type = types.str;
      default = "none";
      description = "Logging driver for the container.";
    };

    annotations = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "OCI annotations passed to podman run.";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra flags passed verbatim to podman run.";
    };
  };

  config = mkIf config.devshell {
    environment.BOTILLE_DEVSHELL = "1";
  };
}
