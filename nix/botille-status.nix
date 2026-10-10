# Mirrors an agent harness session's lifecycle state to the host as JSON.
# Claude/Codex hooks and the pi extension all call this shared reporter.
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
        details='{}'
      else
        input="$(cat)" || exit 0
        session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')" || exit 0
        if ! "$have_cwd"; then
          cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')" || exit 0
          [ -n "$cwd" ] || cwd="''${PWD:-}"
        fi
        event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')" || exit 0
        details="$(printf '%s' "$input" | jq -c --arg agent "$agent" --arg effort "''${CLAUDE_EFFORT:-}" '
          # Subagents share the session_id but may differ in effort and permission mode.
          if (.agent_id // "") != "" then {} else {
            model: (.model // .to_model),
            effort: (.effort.level // (if $agent != "claude" or $effort == "" then null else $effort end)),
            permission_mode,
            session_title,
            transcript_path
          } end')" || exit 0
      fi

      # Codex's hook config calls the reporter directly with STATE=auto.
      # Explicit states and metadata-only updates retain their existing behavior.
      if [ "$state" = auto ]; then
        [ "$agent" = codex ] && ! "$have_session" || return 0
        # Child hooks share the parent's session ID; they must not mark it idle.
        [ "$(printf '%s' "$input" | jq -r '.agent_id // empty')" = "" ] || return 0
        case "$event" in
          SessionStart)
            state=idle
            [ "$(printf '%s' "$input" | jq -r '.source // empty')" != compact ] || state=working
            ;;
          UserPromptSubmit|PostToolUse|PreCompact|PostCompact) state=working ;;
          PreToolUse)
            tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
            case "$tool" in
              request_user_input|request_user_input_async|*__request_user_input|*__request_user_input_async) state=needs-input ;;
              *) state=working ;;
            esac
            ;;
          PermissionRequest) state=needs-input ;;
          Stop|Interrupt) state=idle ;;
          SessionEnd) state=ended ;;
          *) return 0 ;;
        esac
      fi

      valid_name "$session_id" || exit 0
      file="$dir/$agent-$session_id.json"

      if [ "$state" = ended ]; then
        rm -f "$file"
        return 0
      fi

      # Codex hooks omit effort and title. Read just this session's local
      # metadata, with a hard time limit; failures must not suppress status.
      if [ "$agent" = codex ] && ! "$have_session" &&
        [ "$(printf '%s' "$input" | jq -r '.agent_id // empty')" = "" ]; then
        fallback="$(timeout 0.5s ${pkgs.python3}/bin/python3 ${../scripts/codex-status-details.py} "$session_id")" || fallback='{}'
        details="$(printf '%s' "$details" | jq -c --argjson fallback "$fallback" '
          $fallback + with_entries(select(.value != null and .value != ""))')" || return 0
      fi

      # A corrupt or missing old file counts as empty.
      old="$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null)" || old='{}'

      # Without a state (PostModelSwitch) only refresh details of a known session.
      if ! "$have_state"; then
        state="$(printf '%s' "$old" | jq -r '.state // empty')" || exit 0
        [ -n "$state" ] || exit 0
      fi

      tmp="$(mktemp "$dir/.$agent-$session_id.XXXXXX")" || exit 0
      if jq -n \
        --arg state "$state" \
        --arg agent "$agent" \
        --arg session_id "$session_id" \
        --arg cwd "$cwd" \
        --arg event "$event" \
        --arg host "''${HOSTNAME:-unknown}" \
        --argjson old "$old" \
        --argjson new "$details" \
        --argjson ts "$(date +%s)" \
        '$old + {state: $state, agent: $agent, session_id: $session_id, cwd: $cwd, event: (if $event == "" then null else $event end), host: $host, ts: $ts}
          + (reduce ("model", "effort", "permission_mode", "session_title", "transcript_path") as $k ({};
              .[$k] = (if ($new[$k] // "") == "" then $old[$k] else $new[$k] end)))' \
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
