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
- Reproducible — fully defined in the Nix flake (`flake.nix` + `nix/` modules)

### 3. Nix Store Persistence (Copy + Bind Mount)
- A named Podman volume (`botille-nix`) is mounted at `/var/nix-store`
- On first run, the entrypoint copies the image's `/nix` to the volume (`cp --reflink=auto` for instant clones on CoW filesystems), then bind-mounts the volume copy over `/nix`
- On image update, new store paths are merged alongside existing ones (non-destructive); the Nix DB is reset and reloaded from the new image closure
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
- Two OCI hooks enforce the firewall in stages:
  1. **`createContainer`** — REJECT rules block all private ranges **before** the container process starts, using host-side Nix store binaries
  2. **`poststart`** — an ACCEPT rule is inserted for the container's own IP (e.g. `10.0.2.100`). Pasta forwards exposed ports by connecting to the container's IP from within the network namespace; without this exception those SYNs hit the REJECT rules. Self-addressed traffic never leaves the container (equivalent to localhost), so this has no security impact.
- Blocked ranges:
  - `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC1918)
  - `169.254.0.0/16` (link-local)
  - `100.64.0.0/10` (CGNAT)
  - `fc00::/7`, `fe80::/10` (IPv6 ULA/link-local)
- `CAP_NET_ADMIN` and `CAP_NET_RAW` are dropped — the container process cannot modify the rules
- Public DNS forced (`--dns=1.1.1.1 --dns=1.0.0.1`) so DNS traffic bypasses private-range blocks regardless of Podman network backend (slirp4netns, pasta)
- Hooks are annotation-gated (`io.botille.block-lan=true`) so they only fire for botille containers
- If the `createContainer` hook fails, container creation aborts (fail-safe)
- Result: container can reach the public internet (Claude API) but not the LAN; rules are immutable from inside
- Pass `--allow-lan` to the launcher to omit the annotation and skip both hooks entirely, granting full LAN access for that run
- Pass `--port`/`-p` to expose container ports to the host (e.g. `--port 4096:4096` for web UIs)

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

# Expose ports to the host (e.g. for web UIs)
nix run 'delirium-systems/botille' -- --port 4096:4096 opencode web --hostname 0.0.0.0
nix run 'delirium-systems/botille' -- -p 8080:3000 -p 9090:9090
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
flake.nix                 → thin orchestrator wiring modules together
├── nix/
│   ├── caches.nix        → binary cache URLs/keys (single source of truth)
│   ├── packages.nix      → container package list
│   ├── entrypoint.sh     → container entrypoint (standalone shell script)
│   ├── entrypoint.nix    → builds entrypoint via replaceVarsWith
│   ├── firewall.nix      → OCI hook: iptables LAN-blocking script
│   ├── container.nix     → OCI image (dockerTools.buildLayeredImage)
│   ├── launcher.nix      → launcher script (podman load + podman run)
│   └── tests.nix         → NixOS VM tests for AI tool smoke checks
├── home.nix              → home-manager configuration
│
├── packages.container    → OCI image
├── apps.default          → launcher shell script
├── checks                → statix, deadnix, ai-tools (NixOS VM test)
└── formatter             → nixfmt
```

## Execution Flow

1. User runs `nix run 'delirium-systems/botille'`
2. Nix builds the launcher script (which depends on the container image, so both are built/cached)
3. Script checks if the current image (by Nix store path) is already loaded; if not, removes the old image and loads the new one
4. Script runs container with:
   - `$PWD` → `/work` bind mount
   - `botille-home` volume → `/home/user`
   - `botille-nix` volume → `/var/nix-store` (bind-mounted over `/nix` by entrypoint)
   - `--userns=keep-id` to map host UID into container
   - Interactive TTY attached (`-it`)
5. OCI `createContainer` hook fires, applying iptables REJECT rules for all private ranges using host-side binaries
6. Podman drops `CAP_NET_ADMIN`/`NET_RAW` and starts the container process
6b. OCI `poststart` hook fires, inserting an ACCEPT rule for the container's own IP (enables pasta port forwarding)
7. Entrypoint registers image store paths in the Nix DB and pins a GC root
8. User lands in a shell with `claude`, `gemini`, `copilot`, `opencode`, `pi`, `openclaw`, `nix`, `git` on `$PATH`, working dir `/work`
8. On exit, file changes persist in host `cwd`; home directory and nix store persist in volumes

## Volume Layout

| Mount             | Source                          | Purpose                              |
|-------------------|---------------------------------|--------------------------------------|
| `/work`           | bind: host `$PWD`              | Project files                        |
| `/home/user`      | volume: `botille-home`         | Credentials, configs, XDG dirs       |
| `/nix`            | bind mount from `botille-nix` volume | Nix store (copied from image, persists installs) |
