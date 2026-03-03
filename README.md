# 🤖⛓️ Botille

**Bot** + Bas**tille** — a prison for your AI agent.

Run coding agents inside a sandboxed, LAN-isolated rootless Podman container. Everything defined in a single Nix flake — nothing to install.

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
```

Your current directory is mounted at `/work` inside the container. File changes persist on the host; credentials and installed packages persist in Podman volumes.

Pre-built binaries are available from the `delirium-systems` cachix cache — the flake configures this automatically when `accept-flake-config = true` is set in your Nix config.

### Shell alias

To use `botille` as a short command, add an alias to your shell config (`~/.bashrc`, `~/.zshrc`, etc.):

```sh
alias botille="nix run 'github:delirium-systems/botille' --"
```

Then:

```sh
botille               # drop into a shell
botille claude        # run claude directly
botille --allow-lan   # drop into a shell with LAN access enabled
```

### Customising home-manager

To add your own home-manager configuration (git identity, extra packages, shell aliases, etc.) without forking this repository, create a wrapper `flake.nix` in a directory of your choice:

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

Then run your customised container with:

```sh
nix run .
```

`extraHomeManagerModules` are appended after the base configuration, so they can override any base setting using the standard home-manager module system (e.g. `lib.mkForce`).

> **Note:** customised images are not in the `delirium-systems` cachix cache and will be built locally on first use.

## Security

The primary security boundary is the **rootless Podman container**: the agent runs as an unprivileged user with no host network access to LAN/private ranges, and only the working directory is bind-mounted.

Claude Code's permission rules (`~/.config/claude/settings.json`) provide a secondary, **advisory** layer. `Read` denies for credential paths (`.ssh`, `.aws`, `.gnupg`, etc.) are reliably enforced by the Read tool. `Bash` deny rules match on literal argument strings only — they do not survive shell expansion, variable indirection, or `~` aliasing, so they prevent accidental access but are not a hard security boundary. Allowed Bash commands such as `curl`, `cp`, and `openssl` can still reach sensitive paths if given explicit instructions to do so.

**Do not rely on the permission rules to protect secrets.** Keep sensitive files out of the bind-mounted working directory, and treat anything inside the container as potentially visible to the agent.

### Prerequisites

- [Nix](https://nixos.org/) (with flakes enabled)
- Rootless Podman host support — the Podman binary itself is provided by Nix, but your host must support rootless containers (user namespaces enabled, `/etc/subuid` + `/etc/subgid` configured). On NixOS, `virtualisation.podman.enable = true` handles this.
