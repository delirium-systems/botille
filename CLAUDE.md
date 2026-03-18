# Project Instructions

<!-- Keep this file lean. Only add things that are NOT inferrable from reading
     the source code: surprising gotchas, easy-to-make mistakes, external facts,
     local workstation details, and behavioral rules for Claude. Everything else
     (host configs, services, modules, flake inputs, etc.) lives in the code. -->

## Gotchas

- **podman load fails on re-load** — `podman load` of an image that already exists errors with `copy_file_range: is a directory`. The launcher handles this automatically (skips load when the same Nix store path is already loaded, `podman rmi` before reload otherwise). If debugging manually, always `podman rmi` first.
- **`CACHIX_AUTH_TOKEN` secret** — CI pushes to the `delirium-systems` cachix cache. The secret must be configured in GitHub repo settings (Settings > Secrets > Actions) for pushes to work. Without it, CI still runs but skips pushing.
- **Launcher args go to the container command**, not to `podman run` flags. `nix run .# -- foo` runs `foo` inside the container (overriding default CMD `/bin/bash`).
- **Run from project directories only** — `$PWD` is bind-mounted read-write at `/work`. Running from `$HOME` or `/` exposes your entire home directory or root filesystem to the AI agent. Always `cd` into a project directory first.
- **Nix store updates are non-destructive** — On image update, new store paths are merged alongside old ones (not wiped). Old paths stay on disk so running containers keep working. The nix DB is reset and reloaded from the new image closure. Run `nix-store --gc` inside the container to reclaim orphaned old paths when no other containers need them.
- **Shell recovery** — If the shell environment breaks after an update, `source /var/nix-store/botille-reload` reconstructs PATH from the current store and re-sources `.bashrc`.
