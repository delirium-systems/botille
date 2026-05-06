{ lib }:
let
  inherit (lib)
    concatLists
    escapeShellArg
    filterAttrs
    mapAttrsToList
    optional
    ;
  capAdds = filterAttrs (_: v: v != null && v);
  capDrops = filterAttrs (_: v: v != null && !v);
in
cfg:
concatLists [
  [
    "--log-driver=${escapeShellArg cfg.logDriver}"
    "--network"
    (escapeShellArg cfg.network)
  ]
  (concatLists (
    map (v: [
      "-v"
      (escapeShellArg v)
    ]) cfg.volumes
  ))
  (concatLists (
    map (p: [
      "-p"
      (escapeShellArg p)
    ]) cfg.ports
  ))
  (concatLists (
    mapAttrsToList (k: v: [
      "-e"
      (escapeShellArg "${k}=${v}")
    ]) cfg.environment
  ))
  (concatLists (
    map (d: [
      "--dns"
      (escapeShellArg d)
    ]) cfg.dns
  ))
  (map (k: "--cap-add=${escapeShellArg k}") (builtins.attrNames (capAdds cfg.capabilities)))
  (map (k: "--cap-drop=${escapeShellArg k}") (builtins.attrNames (capDrops cfg.capabilities)))
  (concatLists (
    map (s: [
      "--security-opt"
      (escapeShellArg s)
    ]) cfg.securityOpt
  ))
  (optional (cfg.userns != null) "--userns=${escapeShellArg cfg.userns}")
  (concatLists (
    mapAttrsToList (k: v: [
      "--annotation"
      (escapeShellArg "${k}=${v}")
    ]) cfg.annotations
  ))
  cfg.extraOptions
]
