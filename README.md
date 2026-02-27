# 🤖⛓️ Botille

**Bot** + Bas**tille** — a prison for your AI agent.

Run coding agents inside a sandboxed, LAN-isolated rootless Podman container. Everything defined in a single Nix flake — nothing to install.

## 🔒 What it does

- 📦 Builds a reproducible OCI container image with Claude Code, Gemini CLI, GitHub Copilot CLI, Nix, git, and common dev tools
- 🌐 Blocks all LAN/private network access via iptables OCI hooks — only public internet allowed
- 🔑 Persists credentials and Nix store across runs via named Podman volumes
- 🧑 Runs rootless — no daemon, no root, your UID mapped into the container

## 🚀 Usage

```sh
# Drop into a containerized shell with claude on $PATH
nix run 'github:delirium-systems/botille#run'

# Pass a command to run inside the container (replaces default /bin/bash)
nix run 'github:delirium-systems/botille#run' -- claude
```

Your current directory is mounted at `/work` inside the container. File changes persist on the host; credentials and installed packages persist in Podman volumes.

Pre-built binaries are available from the `delirium-systems` cachix cache — the flake configures this automatically when `accept-flake-config = true` is set in your Nix config.

### Shell alias

To use `botille` as a short command, add an alias to your shell config (`~/.bashrc`, `~/.zshrc`, etc.):

```sh
alias botille="nix run 'github:delirium-systems/botille#run' --"
```

Then:

```sh
botille          # drop into a shell
botille claude   # run claude directly
```

### Prerequisites

- [Nix](https://nixos.org/) (with flakes enabled)
- Rootless Podman host support — the Podman binary itself is provided by Nix, but your host must support rootless containers (user namespaces enabled, `/etc/subuid` + `/etc/subgid` configured). On NixOS, `virtualisation.podman.enable = true` handles this.
