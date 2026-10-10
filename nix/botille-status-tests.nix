{ pkgs }:
let
  botilleStatus = import ./botille-status.nix { inherit pkgs; };
  codexHooks = import ./codex-managed-hooks.nix { inherit pkgs botilleStatus; };
  piExtension = pkgs.writeText "pi-botille-status.mjs" (
    builtins.replaceStrings [ "@botilleStatus@" ] [ "${botilleStatus}" ] (
      builtins.readFile ./pi-status-extension.js
    )
  );
in
pkgs.runCommand "botille-status-tests" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
  node ${../tests/botille-status.mjs} ${codexHooks}/etc/codex/hooks.json ${piExtension}
  touch $out
''
