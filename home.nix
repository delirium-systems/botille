# Home-manager configuration baked into the Botille container image.
# This module is loaded as the base configuration; callers can append
# extraHomeManagerModules via mkBotille / lib.mkApp to override anything here.
_:
{
  home = {
    username = "user";
    homeDirectory = "/home/user";
    stateVersion = "25.11";
  };

  # No systemd in container
  systemd.user.startServices = false;

  xdg = {
    enable = true;
    configFile."claude/settings.json" = {
      force = true;
      text = builtins.toJSON {
        permissions = {
          allow = [
            "Bash(curl:*)"
            "Bash(wget:*)"
            "WebFetch"
            "WebSearch"
            "Read(/work/**)"
            "Read(/home/user/**)"
            "Write(/work/**)"
            "Edit(/work/**)"
            "Bash(git:*)"
            "Bash(nix:*)"
            "Bash(gh:*)"
            "Bash(podman:*)"
            "Bash(python3:*)"
            "Bash(node:*)"
            "Bash(npm:*)"
            "Bash(npx:*)"
            "Bash(jq:*)"
            "Bash(fd:*)"
            "Bash(rg:*)"
            "Bash(tree:*)"
            "Bash(diff:*)"
            "Bash(make:*)"
          ];
        };
      };
    };
  };

  programs = {
    bash.enable = true;

    starship = {
      enable = true;
      enableBashIntegration = true;
      settings = {
        add_newline = false;
        format = "[botille](bold blue) $directory$git_branch$git_status$cmd_duration$status$character";

        character = {
          success_symbol = "[❯](bold purple)";
          error_symbol = "[❯](bold red)";
        };

        directory = {
          style = "bold cyan";
          truncate_to_repo = false;
          truncation_length = 0;
          fish_style_pwd_dir_length = 0;
        };

        git_branch = {
          format = "[$symbol$branch(:$remote_branch)]($style) ";
          symbol = "⎇ ";
          style = "bold purple";
        };

        git_status.style = "bold red";

        status.disabled = false;

        cmd_duration.min_time = 3000;
      };
    };

    direnv.enable = true;
    direnv.nix-direnv.enable = true;

    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
        line-numbers = true;
        hunk-header-decoration-style = "";
      };
    };

    git = {
      enable = true;

      lfs.enable = true;

      settings = {
        alias = {
          hist = ''log --pretty=format:"%C(dim yellow)%h %C(dim white)%ad %C(bold cyan)|%C(auto) %s %C(white)- %an%C(auto)%d%C(reset)" --graph --date=local'';
          list-changed-files = "show --pretty= --name-only";
          list-gone-branches = "! git branch -vv | grep ': gone]' | awk '{print $1}'";
          pushfwl = "push --force-with-lease";
        };
        core.commentchar = ";";
        pull.rebase = true;
        push = {
          autoSetupRemote = true;
          followTags = true;
        };
        fetch = {
          prune = true;
          pruneTags = true;
          all = true;
        };
        help.autocorrect = "prompt";
        rebase = {
          autoStash = true;
          updateRefs = true;
        };
        http.postBuffer = 1048576000;
        credential.helper = "store";
        merge = {
          conflictStyle = "zdiff3";
          tool = "nvim";
        };
        mergetool = {
          prompt = false;
          keepBackup = false;
          nvim.cmd = ''nvim -d -c "wincmd l" -c "norm gg]c" "$LOCAL" "$MERGED" "$REMOTE"'';
        };
        status.submoduleSummary = true;
        diff = {
          tool = "nvim";
          algorithm = "histogram";
          mnemonicPrefix = true;
          renames = true;
        };
        init.defaultBranch = "master";
        advice = {
          detachedHead = false;
          skippedCherryPicks = false;
        };
        rerere = {
          enabled = true;
          autoUpdate = true;
        };
        branch.sort = "-committerdate";
        tag.sort = "version:refname";
        commit.verbose = true;
      };
    };
  };
}
