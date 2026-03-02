# Botille — AI Containment Tool

## Goal

Run AI coding agents (Claude Code, Gemini CLI, GitHub Copilot CLI, OpenCode, Pi, OpenClaw) inside a Nix-built container using rootless Podman, with the current working directory mounted at `/work`. Invoked purely through `nix run` — no separate binary to install.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Host (unprivileged user)                       │
│                                                 │
│  $ nix run 'delirium-systems/botille'                  │
│       │                                         │
│       ▼                                         │
│  rootless podman run ...                        │
│  ┌─────────────────────────────────────────┐    │
│  │  Container (Nix-built OCI image)        │    │
│  │                                         │    │
│  │  /work         ← bind mount (cwd)      │    │
│  │  /home/user    ← named volume          │    │
│  │  /nix          ← overlay (named vol)   │    │
│  │                                         │    │
│  │  nix, claude, gemini, copilot, opencode, pi, openclaw, git …   │    │
│  │                                         │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

## Core Components

### 1. Nix Flake App (default)
- A shell script wrapped as a Nix app (`writeShellApplication`)
- Container image path is baked in at Nix evaluation time (no runtime `nix build`)
- Tracks the loaded image's Nix store path in `~/.local/state/botille/loaded-image`; skips `podman load` if the same image is already present, reloads only when the store path changes
- Runs the container with mounts and drops user into an interactive shell

### 2. Container Image (Nix-built)
- Built with `pkgs.dockerTools.buildLayeredImage`
- Contains: Nix, Claude Code, Gemini CLI, Copilot CLI, OpenCode, Pi, OpenClaw, bash, git, coreutils, findutils, gnugrep, gnused, gawk, which, less, neovim, iproute2, curl, wget, direnv, nix-direnv, cachix, python3, ripgrep, fd, tree, file, jq, diffutils, unzip, gnutar, gh, openssh, nodejs, rsync, tmux, man
- Agents sourced from [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix) (auto-updated daily)
- Reproducible — fully defined in `flake.nix`

### 3. Nix Store Persistence (Overlay)
- A named Podman volume (`botille-nix-overlay`) provides upperdir/workdir for an overlay mount on `/nix`
- The image's read-only `/nix` is the lower layer; user-installed packages go to the overlay upper layer
- Entrypoint runs `nix-store --load-db` to register all image store paths and pins a GC root so they survive garbage collection
- Subsequent runs reuse the volume — `nix-env`, `nix shell`, etc. persist installed packages

### 4. Home Directory Persistence
- A named Podman volume (`botille-home`) mounted at `/home/user`
- Claude config dir at `/home/user/.config/claude` (set via `CLAUDE_CONFIG_DIR` env var)
- XDG directories (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`) all under `/home/user`
- First run: user authenticates inside the container
- Subsequent runs: credentials, shell history, and tool configs already present in the volume
- Volume lives in user's rootless Podman storage (`~/.local/share/containers/`)

### 5. Network Isolation (OCI Hooks)
- Rootless Podman uses `slirp4netns` or `pasta` for userspace networking
- An OCI hook (`createContainer` stage) applies iptables rules **before** the container process starts, using host-side Nix store binaries
- Blocked ranges:
  - `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC1918)
  - `169.254.0.0/16` (link-local)
  - `100.64.0.0/10` (CGNAT)
  - `fc00::/7`, `fe80::/10` (IPv6 ULA/link-local)
- `CAP_NET_ADMIN` and `CAP_NET_RAW` are dropped — the container process cannot modify the rules
- Public DNS forced (`--dns=1.1.1.1 --dns=1.0.0.1`) so DNS traffic bypasses private-range blocks regardless of Podman network backend (slirp4netns, pasta)
- Hook is annotation-gated (`io.botille.block-lan=true`) so it only fires for botille containers
- If the hook fails, container creation aborts (fail-safe)
- Result: container can reach the public internet (Claude API) but not the LAN; rules are immutable from inside
- Pass `--allow-lan` to the launcher to omit the annotation and skip the hook entirely, granting full LAN access for that run

### 6. Guardrails
- Rootless Podman — no daemon, no root privileges, runs entirely as the calling user
- `/work` is read-write by default
- No access to host filesystem outside `/work`
- LAN blocked, internet allowed

## Interface

```sh
# Drop into a containerized shell with claude available
nix run 'delirium-systems/botille'

# All args after -- are passed as the container command (replacing default /bin/bash)
nix run 'delirium-systems/botille' -- claude

# Disable LAN restrictions for this run (--allow-lan is consumed by the launcher, not forwarded to the container)
nix run 'delirium-systems/botille' -- --allow-lan
nix run 'delirium-systems/botille' -- --allow-lan claude
```

### 7. Binary Caching (Cachix)
- Flake `nixConfig` declares `delirium-systems`, `nix-community`, and `numtide` cachix caches as `extra-substituters` — users with `accept-flake-config = true` get pre-built binaries automatically
- CI (GitHub Actions) pushes all newly-built store paths to the `delirium-systems` cache via `cachix/cachix-action`
- The in-container `nix.conf` also includes both caches, so `nix build`/`nix shell` inside the container benefit from the same binary cache

## Tech Choices

- **Everything is Nix** — flake app, container image, no separate build tool
- **Container runtime:** Rootless Podman (no Docker daemon, no root required)
- **Agents:** Claude Code, Gemini CLI, GitHub Copilot CLI, OpenCode, Pi, OpenClaw — all from [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)
- **Nix inside container:** allows user/agent to install additional tools on the fly

## Nix Flake Structure

```
flake.nix
├── packages.container    → OCI image (dockerTools.buildLayeredImage)
│   └── contents:
│       ├── nix, cachix, direnv, nix-direnv
│       ├── claude-code, gemini-cli, copilot-cli, opencode, pi, openclaw
│       ├── bash, git, coreutils, findutils, gnugrep, gnused, gawk
│       ├── which, less, neovim, python3, nodejs, ripgrep, fd, jq, …
│       └── fakeNss, /etc/nix/nix.conf, /tmp, /usr/bin/env
├── apps.default          → shell script: podman load + podman run
├── checks                → statix, deadnix, ai-tools (NixOS VM test)
├── formatter             → nixfmt
└── devShells.default     → dev environment (podman, nix)
```

## Execution Flow

1. User runs `nix run 'delirium-systems/botille'`
2. Nix builds the launcher script (which depends on the container image, so both are built/cached)
3. Script checks if the current image (by Nix store path) is already loaded; if not, removes the old image and loads the new one
4. Script runs container with:
   - `$PWD` → `/work` bind mount
   - `botille-home` volume → `/home/user`
   - `botille-nix-overlay` volume + overlay mount → `/nix`
   - `--userns=keep-id` to map host UID into container
   - Interactive TTY attached (`-it`)
5. OCI hook fires at `createContainer` stage, applying iptables LAN-blocking rules using host-side binaries
6. Podman drops `CAP_NET_ADMIN`/`NET_RAW` and starts the container process
7. Entrypoint registers image store paths in the Nix DB and pins a GC root
8. User lands in a shell with `claude`, `gemini`, `copilot`, `opencode`, `pi`, `openclaw`, `nix`, `git` on `$PATH`, working dir `/work`
8. On exit, file changes persist in host `cwd`; home directory and nix store persist in volumes

## Volume Layout

| Mount             | Source                          | Purpose                              |
|-------------------|---------------------------------|--------------------------------------|
| `/work`           | bind: host `$PWD`              | Project files                        |
| `/home/user`      | volume: `botille-home`         | Credentials, configs, XDG dirs       |
| `/nix`            | overlay on `botille-nix-overlay` | Nix store (image lower + user upper) |
