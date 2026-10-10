# /etc/codex/hooks.json: system hooks are trusted and merge with user/project hooks.
{ pkgs, botilleStatus }:
let
  events = [
    "SessionStart"
    "UserPromptSubmit"
    "PreToolUse"
    "PostToolUse"
    "PermissionRequest"
    "PreCompact"
    "PostCompact"
    "Stop"
    "Interrupt"
    "SessionEnd"
  ];
in
pkgs.writeTextDir "etc/codex/hooks.json" (
  builtins.toJSON {
    hooks = builtins.listToAttrs (
      map (name: {
        inherit name;
        value = [
          {
            hooks = [
              {
                type = "command";
                command = "${botilleStatus}/bin/botille-status --agent codex auto";
                timeout = 3;
              }
            ];
          }
        ];
      }) events
    );
  }
)
