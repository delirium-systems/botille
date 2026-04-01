{ pkgs }:
let
  # Stage 1 (createContainer): block all private ranges.
  # Network isn't configured yet so we can't determine the container's
  # own IP, but we can lock down the OUTPUT chain before anything starts.
  blockScript = pkgs.writeShellScript "botille-block-lan.sh" ''
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

  # Stage 2 (poststart): allow traffic to the container's own IPs.
  # Pasta forwards ports by connecting to the container's own IP from
  # within the network namespace. Without this, those TCP SYNs hit the
  # REJECT rules and port forwarding breaks. Allowing self-addressed
  # traffic is safe — it never leaves the container, same as localhost.
  allowSelfScript = pkgs.writeShellScript "botille-allow-self.sh" ''
    set -euo pipefail
    nsenter="${pkgs.util-linux}/bin/nsenter"
    ip="${pkgs.iproute2}/bin/ip"
    iptables="${pkgs.iptables}/sbin/iptables"
    ip6tables="${pkgs.iptables}/sbin/ip6tables"
    awk="${pkgs.gawk}/bin/awk"

    pid=$(${pkgs.jq}/bin/jq -r '.pid')

    for addr in $("$nsenter" -t "$pid" -n -- "$ip" -4 addr show | "$awk" '/inet / && !/127\.0\.0\.1/ {split($2,a,"/"); print a[1]}'); do
      "$nsenter" -t "$pid" -n -- "$iptables" -I OUTPUT 1 -d "$addr" -j ACCEPT
    done
    for addr in $("$nsenter" -t "$pid" -n -- "$ip" -6 addr show | "$awk" '/inet6 / && !/::1/ {split($2,a,"/"); print a[1]}'); do
      "$nsenter" -t "$pid" -n -- "$ip6tables" -I OUTPUT 1 -d "$addr" -j ACCEPT
    done
  '';
in
{
  # OCI hooks directory — two hooks, two stages
  hooksDir = pkgs.symlinkJoin {
    name = "botille-hooks";
    paths = [
      (pkgs.writeTextDir "botille-block-lan.json" (
        builtins.toJSON {
          version = "1.0.0";
          hook.path = "${blockScript}";
          when.annotations."^io\\.botille\\.block-lan$" = "true";
          stages = [ "createContainer" ];
        }
      ))
      (pkgs.writeTextDir "botille-allow-self.json" (
        builtins.toJSON {
          version = "1.0.0";
          hook.path = "${allowSelfScript}";
          when.annotations."^io\\.botille\\.block-lan$" = "true";
          stages = [ "poststart" ];
        }
      ))
    ];
  };
}
