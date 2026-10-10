// Pi extension: forwards lifecycle events to the shared botille-status reporter.
// Loaded from PI_CODING_AGENT_DIR/extensions by pi 1.x.
import { spawnSync } from "node:child_process";

export default function (pi) {
  function report(event, ctx, state) {
    try {
      spawnSync("@botilleStatus@/bin/botille-status", ["--agent", "pi", ...(state ? [state] : [])], {
        input: JSON.stringify({
          session_id: ctx.sessionManager.getSessionId(),
          cwd: ctx.cwd,
          hook_event_name: event.type,
          model: ctx.model?.id,
          effort: { level: pi.getThinkingLevel() },
          session_title: pi.getSessionName(),
          transcript_path: ctx.sessionManager.getSessionFile(),
        }),
        stdio: ["pipe", "ignore", "ignore"],
        timeout: 1000,
      });
    } catch {
      // Status reporting must never interrupt the agent.
    }
  }

  pi.on("session_start", (event, ctx) => report(event, ctx, "idle"));
  pi.on("agent_start", (event, ctx) => report(event, ctx, "working"));
  // agent_end can be followed by retries, compaction, or queued work.
  pi.on("agent_settled", (event, ctx) => report(event, ctx, "idle"));
  pi.on("ui_prompt_start", (event, ctx) => report(event, ctx, "needs-input"));
  pi.on("ui_prompt_end", (event, ctx) => report(event, ctx, ctx.isIdle() ? "idle" : "working"));
  pi.on("session_shutdown", (event, ctx) => report(event, ctx, "ended"));
  for (const event of ["model_select", "thinking_level_select", "session_info_changed"]) {
    pi.on(event, (event, ctx) => report(event, ctx));
  }
}
