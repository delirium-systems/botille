{ pkgs }:
let
  # OCI hook: block LAN/private ranges using host-side iptables
  firewallScript = pkgs.writeShellScript "botille-block-lan.sh" ''
    set -euo pipefail
    iptables="${pkgs.iptables}/sbin/iptables"
    ip6tables="${pkgs.iptables}/sbin/ip6tables"
    for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
      "$iptables" -A OUTPUT -d "$cidr" -j REJECT
    done
    for cidr in fc00::/7 fe80::/10; do
      "$ip6tables" -A OUTPUT -d "$cidr" -j REJECT
    done
  '';
in
{
  inherit firewallScript;

  # OCI hooks directory for Podman
  hooksDir = pkgs.writeTextDir "botille-block-lan.json" (
    builtins.toJSON {
      version = "1.0.0";
      hook.path = "${firewallScript}";
      when.annotations."^io\\.botille\\.block-lan$" = "true";
      stages = [ "createContainer" ];
    }
  );
}
