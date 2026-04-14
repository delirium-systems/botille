# 🤖⛓️ Botille

**Bot** + Bas**tille** — a prison for your AI agent.

Run coding agents inside a sandboxed, LAN-isolated rootless Podman container. Everything defined in a single Nix flake — nothing to install. See [DESIGN.md](DESIGN.md) for architecture details.

## 📋 Prerequisites

- [Nix](https://nixos.org/) (with flakes enabled)
- Rootless Podman host support — the Podman binary itself is provided by Nix, but your host must support rootless containers (user namespaces enabled, `/etc/subuid` + `/etc/subgid` configured). On NixOS, `virtualisation.podman.enable = true` handles this.
- Supported platforms: `x86_64-linux`, `aarch64-linux`

## 🔒 What it does

- 📦 Builds a reproducible OCI container image with Claude Code, Gemini CLI, GitHub Copilot CLI, OpenCode, Pi, OpenClaw, Nix, git, and common dev tools
- 🌐 Blocks all LAN/private network access via iptables OCI hooks — only public internet allowed
- 🔑 Persists credentials and Nix store across runs via named Podman volumes
- 🧑 Runs rootless — no daemon, no root, your UID mapped into the container

## 🚀 Usage

```sh
# Drop into a containerized shell with claude on $PATH
nix run 'github:delirium-systems/botille'

# Pass a command to run inside the container (replaces default /bin/bash)
nix run 'github:delirium-systems/botille' -- claude

# Disable LAN restrictions (allow access to private/LAN IP ranges)
nix run 'github:delirium-systems/botille' -- --allow-lan
nix run 'github:delirium-systems/botille' -- --allow-lan claude

# Enter the project's direnv dev shell before running the command
nix run 'github:delirium-systems/botille' -- --devshell claude
nix run 'github:delirium-systems/botille' -- --devshell

# Expose ports to access web UIs from the host (e.g. opencode, openclaw)
nix run 'github:delirium-systems/botille' -- --port 3000 opencode
nix run 'github:delirium-systems/botille' -- -p 8080:3000 -p 9090:9090
```

Your current directory is mounted at `/work` inside the container. File changes persist on the host; credentials and installed packages persist in Podman volumes.

Pre-built binaries are available from the `delirium-systems` cachix cache — the flake configures this automatically when `accept-flake-config = true` is set in your Nix config.

### Shell alias

```sh
alias botille="nix run 'github:delirium-systems/botille' --"
```

Then: `botille`, `botille claude`, `botille --allow-lan`, `botille --devshell claude`, `botille --port 3000 opencode`.

Inside the container, `claude-yolo` is a shell alias for `claude --dangerously-skip-permissions` — it runs Claude Code with no permission prompts.

### API keys

Authenticate interactively inside the container on first run — credentials persist in the `botille-home` volume. Alternatively, pass keys via environment variables by editing the launcher or using `podman run -e` directly.

### Customising home-manager

Create a wrapper `flake.nix` to add your own home-manager configuration (git identity, extra packages, shell aliases, etc.) without forking:

```nix
{
  inputs.botille.url = "github:delirium-systems/botille";

  outputs = { self, botille }: {
    apps.x86_64-linux.default = botille.lib.mkApp {
      system = "x86_64-linux";
      extraHomeManagerModules = [
        {
          programs.git = {
            userEmail = "you@example.com";
            userName  = "Your Name";
          };
        }
        # or point to a separate file:
        # ./extra-hm.nix
      ];
    };
  };
}
```

Then `nix run .` to use your customised container. Modules are appended after the base config and can override any setting via `lib.mkForce`.

> **Note:** customised images are not in the cachix cache and will be built locally on first use.

## ⚙️ How it works

1. **Launcher** checks if the current container image is already loaded in Podman; reloads only when the Nix store path changes
2. **OCI hooks** apply iptables rules in two stages: REJECT rules blocking RFC1918, CGNAT, and link-local ranges at `createContainer` (before the process starts), then an ACCEPT rule for the container's own IP at `poststart` (so pasta can forward exposed ports). `CAP_NET_ADMIN`/`CAP_NET_RAW` are dropped so rules are immutable from inside
3. **Entrypoint** copies the image's Nix store to a persistent volume (first run only), registers store paths in the Nix DB, pins a GC root, and runs home-manager activation
4. **Container starts** with your `$PWD` at `/work`, tools on `$PATH`, DNS forced to 1.1.1.1/1.0.0.1

### Volumes

| Mount | Podman volume | Purpose |
|---|---|---|
| `/work` | bind: host `$PWD` | Project files (read-write) |
| `/home/user` | `botille-home` | Credentials, configs, shell history |
| `/var/nix-store` | `botille-nix` | Nix store (persists `nix shell`/`nix-env` installs) |

Reset all state: `podman volume rm botille-home botille-nix`

## 🛡️ Security

The primary security boundary is the **rootless Podman container**: the agent runs as an unprivileged user with no host network access to LAN/private ranges, and only the working directory is bind-mounted. `--allow-lan` disables the network firewall for that run — use only when needed (e.g. accessing local APIs).

Claude Code's permission rules (`~/.config/claude/settings.json`) provide a secondary, **advisory** layer. `Read` denies for credential paths (`.ssh`, `.aws`, `.gnupg`, etc.) are enforced by the Read tool. `Bash` deny rules match on literal argument strings only — they do not survive shell expansion or variable indirection, so they prevent accidental access but are not a hard boundary.

**Do not rely on the permission rules to protect secrets.** Keep sensitive files out of the bind-mounted working directory, and treat anything inside the container as potentially visible to the agent.

See [DESIGN.md](DESIGN.md) for the full threat model.

## 🔧 Troubleshooting

- **First run is slow** — Nix store is copied to the persistent volume. Subsequent runs reuse it.
- **`podman load` fails with `copy_file_range: is a directory`** — the image already exists. Run `podman rmi botille:latest` then retry. The launcher handles this automatically.
- **Reset everything** — `podman volume rm botille-home botille-nix` removes all persistent state.
