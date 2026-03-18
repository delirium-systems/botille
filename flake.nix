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
            pkgs.iputils
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
            # Archives & hex
            pkgs.unixtools.xxd
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
            # Network analysis
            pkgs.nmap
            pkgs.tcpdump
            pkgs.wireshark-cli
            pkgs.netcat-gnu
            pkgs.traceroute
            pkgs.dnsutils
            pkgs.whois
            pkgs.mtr
            # Needed for mount --bind in the entrypoint
            pkgs.util-linux
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

            # Set up writable /nix by copying the image's store into a persistent
            # volume on first run (or when the image changes), then bind-mounting
            # the volume over /nix.
            #
            # cp --reflink=auto clones the tree instantly on CoW filesystems
            # (btrfs, xfs); falls back to a regular copy on ext4 etc.  This
            # replaces fuse-overlayfs, which caused CPU saturation when Nix wrote
            # large file trees (e.g. a nixpkgs source) through FUSE — and also
            # required working around SQLite locking issues on overlayfs.
            nix_vol="/var/nix-store"
            nix_data="$nix_vol/nix"
            nix_marker="$nix_vol/.botille-image"
            if ! [ -f "$nix_marker" ] || [ "$(<"$nix_marker")" != "${imageClosureInfo}" ]; then
              if [ -d "$nix_data/store" ]; then
                echo "Updating Nix store (preserving existing paths)…" >&2
                # Non-destructive merge: copy new image paths alongside old
                # ones so running containers keep their PATH entries working.
                # Only chmod the two directories we actually write into —
                # the store dir (new top-level entries) and the DB (wiped).
                # A recursive chmod of the entire store is very expensive.
                chmod u+w "$nix_data/store" 2>/dev/null || true
                for p in /nix/store/*; do
                  [ -e "$nix_data/store/''${p##*/}" ] || cp --reflink=auto -a "$p" "$nix_data/store/"
                done
                # Reset the registration DB from the new closure.
                # nix-store --load-db is not idempotent (UNIQUE constraint),
                # so we wipe the DB and reload cleanly.  Old paths keep their
                # files on disk — running containers still resolve them via
                # PATH.  nix-store --gc reclaims orphans when appropriate.
                chmod -R u+w "$nix_data/var/nix/db" 2>/dev/null || true
                rm -rf "$nix_data/var/nix/db"
              else
                echo "Initialising Nix store (first run)…" >&2
                cp --reflink=auto -a /nix "$nix_vol/"
              fi
              mount --bind "$nix_data" /nix
              mkdir -p /nix/var/nix/gcroots /nix/var/nix/db
              # The marker is written only after --load-db succeeds, so a
              # crash here causes a clean re-init on next run.
              nix-store --load-db < ${imageClosureInfo}/registration
              printf '%s' "${imageClosureInfo}" > "$nix_marker"
            else
              mount --bind "$nix_data" /nix
            fi

            # Protect image store paths from garbage collection.
            # imageClosureInfo references the entire image closure, so this
            # single GC root transitively keeps all image packages alive.
            ln -sfn ${imageClosureInfo} /nix/var/nix/gcroots/botille-image

            # Write a recovery helper to a stable location (on the volume,
            # outside the nix store).  If the shell environment becomes
            # unusable after an update, run: source /var/nix-store/botille-reload
            cat > "$nix_vol/botille-reload" << 'RELOAD'
            _p=""; for _d in /nix/store/*/bin; do [ -d "$_d" ] && _p="$_p:$_d"; done
            export PATH="''${_p#:}"; unset _p _d
            unset BASH_COMPLETION_VERSINFO
            [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
            echo "Shell environment reloaded." >&2
            RELOAD

            # --- Activate home-manager (only when configuration changed) ---
            mkdir -p "${home}/.local/state/nix/profiles"
            hm_marker="${home}/.local/state/botille/hm-generation"
            hm_generation="${hmActivation}"
            if ! [ -f "$hm_marker" ] || [ "$(<"$hm_marker")" != "$hm_generation" ]; then
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
            maxLayers = 2;

            contents = containerPackages ++ [
              pkgs.dockerTools.fakeNss
              nixConf
            ];

            fakeRootCommands = ''
              mkdir -p tmp var/tmp work .${home} usr/bin var/nix-store
              chmod 1777 tmp var/tmp
              chmod 777 work .${home} var/nix-store
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
              image="botille:latest"
              marker_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/botille"
              marker_file="$marker_dir/loaded-image"
              nix_store_path="${container}"

              # Only check podman when the marker file is missing or stale —
              # avoids a ~1-2s podman image exists call on the hot path.
              if ! [ -f "$marker_file" ] || [ "$(<"$marker_file")" != "$nix_store_path" ]; then
                echo "botille: loading image from $nix_store_path" >&2
                podman rmi "$image" 2>/dev/null || true
                podman load < "$nix_store_path"
                mkdir -p "$marker_dir"
                printf '%s' "$nix_store_path" > "$marker_file"
                echo "botille: image loaded" >&2
              else
                echo "botille: image up to date" >&2
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

              # Strip --allow-lan from args forwarded to the container
              allow_lan=false
              container_args=()
              for arg in "$@"; do
                if [ "$arg" = "--allow-lan" ]; then
                  allow_lan=true
                else
                  container_args+=("$arg")
                fi
              done
              lan_annotation="--annotation io.botille.block-lan=true"
              if [ "$allow_lan" = true ]; then
                lan_annotation=""
              fi

              cidfile=$(mktemp -u "/tmp/botille-cid.XXXXXX")
              cleanup() {
                if [ -f "$cidfile" ]; then
                  ( podman rm "$(cat "$cidfile")" >/dev/null 2>&1; rm -f "$cidfile" ) &
                  disown
                fi
              }
              trap cleanup EXIT

              echo "botille: starting container" >&2
              # shellcheck disable=SC2086
              podman --hooks-dir "${hooksDir}" run \
                --log-driver=none \
                $tty_flag \
                $lan_annotation \
                $term_env \
                --detach-keys="" \
                --cidfile "$cidfile" \
                --dns=1.1.1.1 --dns=1.0.0.1 \
                --cap-add=SYS_ADMIN \
                --cap-drop=NET_ADMIN,NET_RAW \
                --security-opt=no-new-privileges \
                --userns=keep-id \
                -v "$PWD:/work" \
                -v botille-home:${home} \
                -v botille-nix:/var/nix-store \
                "$image" "''${container_args[@]}"
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
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
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
                diskSize = 32768;
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
