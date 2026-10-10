# 🤖⛓️ Botille

**Bot** + Bas**tille** — a prison for your AI agent.

Run coding agents inside a sandboxed, LAN-isolated rootless Podman container. Everything defined in a single Nix flake — nothing to install. See [DESIGN.md](DESIGN.md) for architecture details.

## 📋 Prerequisites

- [Nix](https://nixos.org/) (with flakes enabled)
- Rootless Podman host support — the Podman binary itself is provided by Nix, but your host must support rootless containers (user namespaces enabled, `/etc/subuid` + `/etc/subgid` configured). On NixOS, `virtualisation.podman.enable = true` handles this.
- Supported platforms: `x86_64-linux`, `aarch64-linux`

## 🔒 What it does

- 📦 Builds a reproducible OCI container image with Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, OpenCode, Pi, Nix, git, and common dev tools
- 🌐 Blocks all LAN/private network access via iptables OCI hooks — only public internet allowed
- 🔑 Persists credentials and Nix store across runs via named Podman volumes
- 🧑 Runs rootless — no daemon, no root, your UID mapped into the container
- 📊 Reports each session's status (idle, working, needs-input) to the host as JSON, for monitoring from outside the container

## 🚀 Usage

```sh
# Drop into a containerized shell with claude on $PATH
nix run 'github:delirium-systems/botille'

# Pass a command to run inside the container (replaces default /bin/bash)
nix run 'github:delirium-systems/botille' -- claude

# Allow access to a service on the host (e.g. llama.cpp, ollama)
# The host service must bind to 127.0.0.1, not 0.0.0.0
# Inside the container, find the host IP with: ip route show default | awk '{print $3}'
nix run 'github:delirium-systems/botille' -- --host-port 8080
nix run 'github:delirium-systems/botille' -- --host-port 8080 --host-port 11434 claude

# Disable LAN restrictions (allow access to private/LAN IP ranges)
nix run 'github:delirium-systems/botille' -- --allow-lan
nix run 'github:delirium-systems/botille' -- --allow-lan claude

# Enter the project's direnv dev shell before running the command
nix run 'github:delirium-systems/botille' -- --devshell claude
nix run 'github:delirium-systems/botille' -- --devshell

# Expose ports to access web UIs from the host (e.g. opencode)
nix run 'github:delirium-systems/botille' -- --port 3000 opencode
nix run 'github:delirium-systems/botille' -- -p 8080:3000 -p 9090:9090
```

Your current directory is mounted at `/work` inside the container. File changes persist on the host; credentials and installed packages persist in Podman volumes.

Pre-built binaries are available from the `delirium-systems` cachix cache — the flake configures this automatically when `accept-flake-config = true` is set in your Nix config.

### Shell alias

```sh
alias botille="nix run 'github:delirium-systems/botille' --"
```

Then: `botille`, `botille claude`, `botille --host-port 8080`, `botille --allow-lan`, `botille --devshell claude`, `botille --port 3000 opencode`.

Inside the container, `claude-yolo` is a shell alias for `claude --dangerously-skip-permissions` — it runs Claude Code with no permission prompts.

### API keys

Authenticate interactively inside the container on first run — credentials persist in the `botille-home` volume. Alternatively, pass keys via environment variables by editing the launcher or using `podman run -e` directly.

### Customisation

Create a wrapper `flake.nix` to customise the container without forking. `lib.mkApp` accepts two module lists:

- **`extraHomeManagerModules`** — home-manager config (git identity, extra packages, shell aliases, etc.; `home.packages` binaries are on PATH, after the image packages)
- **`extraContainerModules`** — podman run flags (volumes, ports, environment, DNS, capabilities, etc.; see `nix/container-options.nix` for all options)

The wrapper flake needs its own `nixConfig`, because Nix reads `nixConfig` only from the top-level flake, not from inputs.

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
      ];
      extraContainerModules = [
        {
          volumes = [ "/tmp/claude-dir:/home/user/.config/claude/:Z" ];
          environment.MY_VAR = "hello";
          dns = lib.mkForce [ "8.8.8.8" ];
        }
      ];
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
}
```

Then `nix run .` to use your customised container. Modules merge with standard NixOS semantics (lists concatenate, attrsets merge by key). Use `lib.mkForce` to replace defaults instead of merging. Runtime CLI flags (`-v`, `-p`) still work and append after declarative ones.

> **Note:** customised images are not in the cachix cache and will be built locally on first use.

## ⚙️ How it works

1. **Launcher** checks if the current container image is already loaded in Podman; reloads only when the Nix store path changes
2. **OCI hooks** apply iptables rules in two stages: REJECT rules blocking RFC1918, CGNAT, and link-local ranges at `createContainer` (before the process starts), then an ACCEPT rule for the container's own IP at `poststart` (so pasta can forward exposed ports). `CAP_NET_ADMIN`/`CAP_NET_RAW` are dropped so rules are immutable from inside
3. **Entrypoint** copies the image's Nix store to a persistent volume (first run only), registers store paths in the Nix DB, pins a GC root, and runs home-manager activation
4. **Container starts** with your `$PWD` at `/work`, tools on `$PATH`, DNS forwarded to the host's resolver via pasta (`--dns-forward 198.18.0.53`)

### Volumes

| Mount | Podman volume | Purpose |
|---|---|---|
| `/work` | bind: host `$PWD` | Project files (read-write) |
| `/home/user` | `botille-home` | Credentials, configs, shell history |
| `/var/nix-store` | `botille-nix` | Nix store (persists `nix shell`/`nix-env` installs) |

Reset all state: `podman volume rm botille-home botille-nix`

## 📊 Agent status

Each Claude Code, Codex, and pi session inside the container writes its state to a JSON file on the host.
This lets you monitor what an agent is doing from outside the container.

Files appear in `${XDG_STATE_HOME:-~/.local/state}/botille/status/` on the host.
The launcher creates this directory and bind-mounts it at `/run/botille-status` inside the container.

File name: `<agent>-<session_id>.json`.

| Field | Meaning |
|---|---|
| `agent` | Harness name: `claude`, `codex`, or `pi` |
| `state` | `idle`, `working`, or `needs-input` |
| `session_id` | Session identifier |
| `cwd` | Working directory inside the container, e.g. `/work` |
| `event` | Hook or report event name |
| `host` | Container ID |
| `ts` | Unix timestamp, in seconds |
| `model` | Model ID, e.g. `claude-opus-5-5` |
| `effort` | Harness effort/thinking level, e.g. `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max` |
| `permission_mode` | Permission mode, e.g. `default` or `bypassPermissions` |
| `session_title` | Session title |
| `transcript_path` | Path of the session transcript inside the container |

For Claude, `model` comes from the `SessionStart` and `PostModelSwitch` hooks.
Claude's `effort` is null until the first tool call of the session, and refreshes on tool calls.
There is no hook for `/effort`, so a change shows up at the next tool call.
A detail field keeps its last known value until a hook reports a new one.
Hooks fired by subagents (the payload has `agent_id`) do not change the detail fields.
These fields are null for agents that do not report them, such as those using `--session`.

Codex hooks omit effort and session title, so Botille reads them from Codex's local database.
Values refresh on each hook, retaining previous values or null when unavailable.

States:

- `idle`: the session started, or the agent finished its turn and is waiting for a prompt
- `working`: a prompt was submitted, or a tool is about to run
- `needs-input`: a permission prompt or a supported blocking question/dialog is showing

The file is deleted when the session ends.

Claude Code reports through hooks shipped in the image at `/etc/claude-code/managed-settings.json`.
These hooks run in addition to any hooks you add yourself.

Codex reports through trusted [system hooks](https://learn.chatgpt.com/docs/hooks) at `/etc/codex/hooks.json`, alongside user/project hooks.
Disabling `features.hooks` disables reporting.

Pi reports through an extension at `$PI_CODING_AGENT_DIR/extensions/botille-status.js` (normally `~/.config/pi/extensions/botille-status.js`).
Disabling extensions disables reporting.

Other harnesses can report through the same script:

```sh
botille-status [--agent NAME] [--session ID] [--cwd DIR] [--event NAME] [STATE]
```

Without `STATE`, the script keeps the state of the existing file and does nothing if there is none.
Codex hooks call `botille-status --agent codex auto`, which derives the state from the hook event JSON.
Pi's extension calls `botille-status --agent pi STATE` directly.

With `--session`, the script does not read stdin, so a plugin can call it directly.
Without `--session`, it reads Claude-style hook JSON from stdin: `session_id`, `cwd` and `hook_event_name`, plus the detail fields above (`model` or `to_model`, `effort.level`, `permission_mode`, `session_title` and `transcript_path`).
It always exits 0 and prints nothing.
Claude Code, Codex, and pi are wired up by default after rebuilding/restarting Botille.

Files are replaced atomically: a temp file is written, then renamed with `mv` in the same directory.
Watch the directory, not a single file.

Event-driven example with `inotifywait` (no polling):

```sh
inotifywait -m -q -e moved_to,delete --format '%e %f' \
  ~/.local/state/botille/status |
while read -r ev f; do
  case $f in *.json) ;; *) continue ;; esac
  if [ "$ev" = DELETE ]; then
    echo "$f ended"
  else
    jq -c '{agent, state, cwd}' ~/.local/state/botille/status/"$f"
  fi
done
```

If `inotifywait` is missing, get it with `nix shell nixpkgs#inotify-tools`.

One-shot snapshot instead of watching:

```sh
jq -c '{agent, state, cwd}' ~/.local/state/botille/status/*.json
```

## 🛡️ Security

The primary security boundary is the **rootless Podman container**: the agent runs as an unprivileged user with no host network access to LAN/private ranges, and only the working directory is bind-mounted.
`--host-port PORT` opens a surgical exception for a single TCP port on the host — the host service **must** bind to `127.0.0.1` to prevent LAN exposure.
`--allow-lan` disables the network firewall entirely for that run — use only when needed.

Claude Code's permission rules (`~/.config/claude/settings.json`) provide a secondary, **advisory** layer. `Read` denies for credential paths (`.ssh`, `.aws`, `.gnupg`, etc.) are enforced by the Read tool. `Bash` deny rules match on literal argument strings only — they do not survive shell expansion or variable indirection, so they prevent accidental access but are not a hard boundary.

**Do not rely on the permission rules to protect secrets.** Keep sensitive files out of the bind-mounted working directory, and treat anything inside the container as potentially visible to the agent.

See [DESIGN.md](DESIGN.md) for the full threat model.

## 🔧 Troubleshooting

- **First run is slow** — Nix store is copied to the persistent volume. Subsequent runs reuse it.
- **`podman load` fails with `copy_file_range: is a directory`** — the image already exists. Run `podman rmi botille:latest` then retry. The launcher handles this automatically.
- **Reset everything** — `podman volume rm botille-home botille-nix` removes all persistent state.
