{
  pkgs,
  container,
  hooksDir,
  home,
}:
pkgs.writeShellApplication {
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
}
