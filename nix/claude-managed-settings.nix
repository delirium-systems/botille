# /etc/claude-code/managed-settings.json: these hooks run in addition
# to (not instead of) user/project hooks and can't be overridden.
{ pkgs, botilleStatus }:
pkgs.writeTextDir "etc/claude-code/managed-settings.json" (
  builtins.toJSON {
    hooks = {
      SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude idle";
            }
          ];
        }
      ];
      UserPromptSubmit = [
        {
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude working";
            }
          ];
        }
      ];
      PreToolUse = [
        {
          matcher = "*";
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude working";
            }
          ];
        }
      ];
      # No state argument: only refreshes the model, never the state.
      PostModelSwitch = [
        {
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude";
            }
          ];
        }
      ];
      Notification = [
        {
          matcher = "permission_prompt";
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude needs-input";
            }
          ];
        }
      ];
      Stop = [
        {
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude idle";
            }
          ];
        }
      ];
      SessionEnd = [
        {
          hooks = [
            {
              type = "command";
              command = "${botilleStatus}/bin/botille-status --agent claude ended";
            }
          ];
        }
      ];
    };
  }
)
