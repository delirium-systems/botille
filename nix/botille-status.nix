# Mirrors an agent harness session's lifecycle state to the host as JSON.
# Claude hooks live in claude-managed-settings.nix; other harnesses call --agent/--session.
{ pkgs }:
pkgs.writeShellApplication {
  name = "botille-status";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
  text = ''
    dir="''${BOTILLE_STATUS_DIR:-/run/botille-status}"

    # A filename-safe token: non-empty, no path separators, no leading dot.
    valid_name() {
      case "$1" in
        "" | .*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
      esac
      return 0
    }

    agent="claude"
    session_id=""
    have_session=false
    cwd=""
    have_cwd=false
    event=""
    have_event=false
    state=""
    have_state=false

    # Options precede the positional state; the first bare argument ends parsing.
    while [ $# -gt 0 ]; do
      case "$1" in
        --agent)
          [ $# -ge 2 ] || exit 0
          agent="$2"
          shift 2
          ;;
        --session)
          [ $# -ge 2 ] || exit 0
          session_id="$2"
          have_session=true
          shift 2
          ;;
        --cwd)
          [ $# -ge 2 ] || exit 0
          cwd="$2"
          have_cwd=true
          shift 2
          ;;
        --event)
          [ $# -ge 2 ] || exit 0
          event="$2"
          have_event=true
          shift 2
          ;;
        --*)
          exit 0
          ;;
        *)
          state="$1"
          have_state=true
          break
          ;;
      esac
    done
    "$have_state" || exit 0
    valid_name "$agent" || exit 0

    # Hooks must never fail or block their harness, and must stay silent on
    # stdout (some hook events feed stdout back as context). Every exit path
    # below is 0; stderr/stdout of main are discarded as a backstop.
    main() {
      [ -d "$dir" ] || exit 0

      # --session means a caller that may not provide stdin at all; reading
      # it here would block forever, so skip it entirely.
      if "$have_session"; then
        "$have_cwd" || cwd="''${PWD:-}"
        "$have_event" || event=""
      else
        input="$(cat)" || exit 0
        session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')" || exit 0
        if ! "$have_cwd"; then
          cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')" || exit 0
          [ -n "$cwd" ] || cwd="''${PWD:-}"
        fi
        event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')" || exit 0
      fi

      valid_name "$session_id" || exit 0
      file="$dir/$agent-$session_id.json"

      if [ "$state" = ended ]; then
        rm -f "$file"
        return 0
      fi

      tmp="$(mktemp "$dir/.$agent-$session_id.XXXXXX")" || exit 0
      if jq -n \
        --arg state "$state" \
        --arg agent "$agent" \
        --arg session_id "$session_id" \
        --arg cwd "$cwd" \
        --arg event "$event" \
        --arg host "''${HOSTNAME:-unknown}" \
        --argjson ts "$(date +%s)" \
        '{state: $state, agent: $agent, session_id: $session_id, cwd: $cwd, event: (if $event == "" then null else $event end), host: $host, ts: $ts}' \
        >"$tmp"
      then
        mv -f "$tmp" "$file"
      else
        rm -f "$tmp"
      fi
    }

    main >/dev/null 2>&1 || true
    exit 0
  '';
}
