{
  description = "Botille — AI containment tool running agents in a rootless Podman container";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://delirium-systems.cachix.org"
      "https://cache.numtide.com"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "delirium-systems.cachix.org-1:66ovNl3TR96B++WAvUK0U6nmrejRLR3DYoFzQbKnPHs="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      home-manager,
      llm-agents,
    }:
    let
      # Core builder — wraps all per-system derivations so that both
      # apps.default and lib.mkApp share the same logic.
      mkBotille =
        {
          system,
          extraHomeManagerModules ? [ ],
        }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          home = "/home/user";

          # Core tools available inside the container
          containerPackages = [
            pkgs.bash
            pkgs.coreutils
            pkgs.git
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gawk
            pkgs.findutils
            pkgs.which
            pkgs.less
            pkgs.neovim
            pkgs.iproute2
            pkgs.curl
            pkgs.wget
            pkgs.direnv
            pkgs.nix-direnv
            pkgs.cachix
            pkgs.nix
            pkgs.cacert
            llm-agents.packages.${system}.claude-code
            llm-agents.packages.${system}.gemini-cli
            llm-agents.packages.${system}.copilot-cli
            llm-agents.packages.${system}.opencode
            llm-agents.packages.${system}.pi
            llm-agents.packages.${system}.openclaw
            pkgs.python3
            # Search & navigation
            pkgs.ripgrep
            pkgs.fd
            pkgs.tree
            pkgs.file
            # JSON & diffs
            pkgs.jq
            pkgs.diffutils
            pkgs.delta
            # Archives
            pkgs.unzip
            pkgs.gnutar
            # Git & GitHub
            pkgs.gh
            pkgs.openssh
            # General
            pkgs.nodejs
            pkgs.rsync
            pkgs.tmux
            pkgs.man
            pkgs.ncurses
            # Mounting (overlay for writable /nix)
            pkgs.util-linux
            pkgs.fuse-overlayfs
            pkgs.starship
            # Home environment
            home-manager.packages.${system}.home-manager
          ];

          # Nix configuration for single-user mode inside the container
          nixConf = pkgs.writeTextDir "etc/nix/nix.conf" ''
            build-users-group =
            max-jobs = auto
            auto-optimise-store = true
            use-xdg-base-directories = true
            experimental-features = nix-command flakes
            extra-substituters = https://nix-community.cachix.org
            extra-trusted-public-keys = nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
            extra-substituters = https://delirium-systems.cachix.org
            extra-trusted-public-keys = delirium-systems.cachix.org-1:66ovNl3TR96B++WAvUK0U6nmrejRLR3DYoFzQbKnPHs=
          '';

          # Home-manager activation package (built at Nix time, activated at container start).
          # extraHomeManagerModules are appended last so they can override base settings.
          hmActivation =
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                ./home.nix
              ]
              ++ extraHomeManagerModules;
            }).activationPackage;

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

          # OCI hooks directory for Podman
          hooksDir = pkgs.writeTextDir "botille-block-lan.json" (
            builtins.toJSON {
              version = "1.0.0";
              hook.path = "${firewallScript}";
              when.annotations."^io\\.botille\\.block-lan$" = "true";
              stages = [ "createContainer" ];
            }
          );

          # Registration info for all image store paths (nix-store --load-db format)
          imageClosureInfo = pkgs.closureInfo {
            rootPaths = containerPackages ++ [
              pkgs.dockerTools.fakeNss
              nixConf
              hmActivation
            ];
          };

          # Entrypoint script
          entrypoint = pkgs.writeShellScript "entrypoint.sh" ''
            set -euo pipefail

            # Set up writable /nix via overlay.
            # Bind-mount captures the image's read-only /nix before the overlay
            # hides it. The volume at /var/nix-overlay persists writes across runs.
            # Uses fuse-overlayfs because native kernel overlayfs cannot do
            # overlay-on-overlay in user namespaces (Podman's root fs is already
            # an overlay from the storage driver).
            mount --bind /nix /nix-lower
            fuse-overlayfs \
              -o squash_to_uid="$(id -u)",squash_to_gid="$(id -g)",lowerdir=/nix-lower,upperdir=/var/nix-overlay/upper,workdir=/var/nix-overlay/work \
              /nix

            # Bootstrap /nix/var structure (missing on first run since the
            # image only ships /nix/store, not /nix/var).
            mkdir -p /nix/var/nix/gcroots /nix/var/nix/db

            # Move the Nix SQLite database off fuse-overlayfs onto the real
            # volume filesystem. SQLite needs POSIX locking/fsync semantics
            # that overlayfs cannot provide, causing "database disk image is
            # malformed" errors during writes (e.g. nix store gc).
            mkdir -p /var/nix-overlay/db
            mount --bind /var/nix-overlay/db /nix/var/nix/db

            # Register image store paths in the nix db (only when image changed).
            # nix-store --load-db is not idempotent — re-inserting existing refs
            # hits a UNIQUE constraint in the SQLite Refs table. Guard with a
            # marker so we only load once per image closure.
            nix_db_marker="/nix/var/nix/db/.botille-closure"
            if ! [ -f "$nix_db_marker" ] || [ "$(cat "$nix_db_marker")" != "${imageClosureInfo}" ]; then
              nix-store --load-db < ${imageClosureInfo}/registration
              printf '%s' "${imageClosureInfo}" > "$nix_db_marker"
            fi

            # Protect image store paths from garbage collection.
            # imageClosureInfo references the entire image closure, so this
            # single GC root transitively keeps all image packages alive.
            ln -sfn ${imageClosureInfo} /nix/var/nix/gcroots/botille-image

            # --- Activate home-manager (only when configuration changed) ---
            mkdir -p "${home}/.local/state/nix/profiles"
            hm_marker="${home}/.local/state/botille/hm-generation"
            hm_generation="${hmActivation}"
            if ! [ -f "$hm_marker" ] || [ "$(cat "$hm_marker")" != "$hm_generation" ]; then
              "$hm_generation/activate"
              mkdir -p "$(dirname "$hm_marker")"
              printf '%s' "$hm_generation" > "$hm_marker"
            fi

            # --- Ensure directories exist (tool-specific, not managed by home-manager) ---
            mkdir -p /work \
              "${home}/.local/state/bash" \
              "${home}/.local/state/python" \
              "${home}/.local/state/node" \
              "${home}/.cache/python" \
              "${home}/.config/ripgrep" \
              "${home}/.config/npm" \
              "${home}/.cache/npm" \
              "${home}/.config/wget" \
              "${home}/.local/state/gemini" \
              "${home}/.local/state/botille"

            exec "$@"
          '';

          # Container image
          container = pkgs.dockerTools.buildLayeredImage {
            name = "botille";
            tag = "latest";

            contents = containerPackages ++ [
              pkgs.dockerTools.fakeNss
              nixConf
            ];

            fakeRootCommands = ''
              mkdir -p tmp work .${home} usr/bin var/nix-overlay/upper var/nix-overlay/work nix-lower
              chmod 1777 tmp
              chmod 777 work .${home} var/nix-overlay var/nix-overlay/upper var/nix-overlay/work nix-lower
              mkdir -p nix/store nix/var
              ln -s ${pkgs.coreutils}/bin/env usr/bin/env
            '';

            config = {
              Entrypoint = [ "${entrypoint}" ];
              Cmd = [ "/bin/bash" ];
              WorkingDir = "/work";
              Env = [
                "PATH=${pkgs.lib.makeBinPath containerPackages}"
                "USER=user"
                "HOME=${home}"
                "XDG_CONFIG_HOME=${home}/.config"
                "XDG_DATA_HOME=${home}/.local/share"
                "XDG_STATE_HOME=${home}/.local/state"
                "XDG_CACHE_HOME=${home}/.cache"
                "NIX_CONF_DIR=/etc/nix"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "CLAUDE_CONFIG_DIR=${home}/.config/claude"
                # XDG overrides for tools that don't respect it natively
                "HISTFILE=${home}/.local/state/bash/history"
                "PYTHON_HISTORY=${home}/.local/state/python/history"
                "PYTHONPYCACHEPREFIX=${home}/.cache/python"
                "RIPGREP_CONFIG_PATH=${home}/.config/ripgrep/config"
                "NODE_REPL_HISTORY=${home}/.local/state/node/history"
                "NPM_CONFIG_USERCONFIG=${home}/.config/npm/npmrc"
                "NPM_CONFIG_CACHE=${home}/.cache/npm"
                "WGETRC=${home}/.config/wget/wgetrc"
                "GEMINI_CLI_HOME=${home}/.local/state/gemini"
                "TERM=xterm-256color"
                "COLORTERM=truecolor"
              ];
            };
          };

          # Launcher script
          launcher = pkgs.writeShellApplication {
            name = "botille-run";
            runtimeInputs = [ pkgs.podman ];
            text = ''
              marker_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/botille"
              marker_file="$marker_dir/loaded-image"
              nix_store_path="${container}"
              if ! [ -f "$marker_file" ] || [ "$(cat "$marker_file")" != "$nix_store_path" ]; then
                podman rmi botille:latest 2>/dev/null || true
                podman load < "$nix_store_path"
                mkdir -p "$marker_dir"
                printf '%s' "$nix_store_path" > "$marker_file"
              fi
              tty_flag=""
              if [ -t 0 ]; then
                tty_flag="-it"
              fi
              # Forward host terminal identity so CLI tools (claude, delta, etc.)
              # can detect the real emulator and enable full colour/highlighting.
              term_env=""
              if [ -n "''${TERM_PROGRAM:-}" ]; then
                term_env="$term_env -e TERM_PROGRAM=$TERM_PROGRAM"
              fi
              if [ -n "''${TERM_PROGRAM_VERSION:-}" ]; then
                term_env="$term_env -e TERM_PROGRAM_VERSION=$TERM_PROGRAM_VERSION"
              fi

              # shellcheck disable=SC2086
              podman --hooks-dir "${hooksDir}" run $tty_flag --rm \
                --annotation io.botille.block-lan=true \
                --dns=1.1.1.1 --dns=1.0.0.1 \
                --cap-add=SYS_ADMIN --cap-drop=NET_ADMIN,NET_RAW \
                --security-opt=no-new-privileges \
                --device /dev/fuse \
                --userns=keep-id \
                $term_env \
                -v "$PWD:/work" \
                -v botille-home:${home} \
                -v botille-nix-overlay:/var/nix-overlay \
                botille:latest "$@"
            '';
          };

        in
        {
          inherit
            pkgs
            container
            launcher
            ;
          app = {
            type = "app";
            program = pkgs.lib.getExe launcher;
          };
        };

    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        built = mkBotille { inherit system; };
        inherit (built) pkgs container launcher;
      in
      {
        packages = {
          inherit container;
          default = container;
        };

        apps.default = built.app;

        checks = {
          statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
            statix check ${self}
            touch $out
          '';

          deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
            deadnix --fail ${self}
            touch $out
          '';
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          ai-tools = pkgs.testers.runNixOSTest {
            name = "botille-ai-tools";
            nodes.machine = {
              virtualisation = {
                podman.enable = true;
                diskSize = 8192;
                memorySize = 2048;
              };
            };
            testScript = ''
              machine.wait_for_unit("default.target")

              with subtest("claude-code"):
                  output = machine.succeed("${pkgs.lib.getExe launcher} claude --version")
                  print(f"claude-code: {output.strip()}")

              with subtest("gemini-cli"):
                  output = machine.succeed("${pkgs.lib.getExe launcher} gemini --version")
                  print(f"gemini-cli: {output.strip()}")

              with subtest("copilot-cli"):
                  output = machine.succeed("${pkgs.lib.getExe launcher} copilot --version")
                  print(f"copilot-cli: {output.strip()}")

              with subtest("opencode"):
                  output = machine.succeed("${pkgs.lib.getExe launcher} opencode --version")
                  print(f"opencode: {output.strip()}")

              with subtest("pi-coding-agent"):
                  output = machine.succeed("${pkgs.lib.getExe launcher} pi --version")
                  print(f"pi-coding-agent: {output.strip()}")

              with subtest("openclaw"):
                  output = machine.succeed("${pkgs.lib.getExe launcher} openclaw --version")
                  print(f"openclaw: {output.strip()}")
            '';
          };
        };

        formatter = pkgs.nixfmt;

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.podman
            pkgs.nix
          ];
        };
      }
    )
    // {
      # Flake library — customise the home-manager configuration baked into
      # the container image without forking this repository.
      #
      # Usage: create a wrapper flake.nix in your project:
      #
      #   {
      #     inputs.botille.url = "github:delirium-systems/botille";
      #     outputs = { self, botille }: {
      #       apps.x86_64-linux.default = botille.lib.mkApp {
      #         system = "x86_64-linux";
      #         extraHomeManagerModules = [
      #           { programs.git.userEmail = "you@example.com"; }
      #           ./extra-hm.nix
      #         ];
      #       };
      #     };
      #   }
      #
      # Note: customised images are not in the delirium-systems cachix cache
      # and will be built locally on first use.
      lib = {
        mkApp =
          {
            system,
            extraHomeManagerModules ? [ ],
          }:
          (mkBotille { inherit system extraHomeManagerModules; }).app;
      };
    };
}
