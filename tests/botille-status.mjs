// Regression checks for the shared botille-status reporter and its integrations.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [hooksFile, extensionFile] = process.argv.slice(2);
const dir = mkdtempSync(join(tmpdir(), "botille-status-test-"));
process.env.BOTILLE_STATUS_DIR = dir;
process.env.CODEX_HOME = join(dir, "codex-home");
mkdirSync(process.env.CODEX_HOME);
const file = (agent, id) => join(dir, `${agent}-${id}.json`);
const read = (agent, id) => JSON.parse(readFileSync(file(agent, id), "utf8"));
try {
  const { hooks } = JSON.parse(readFileSync(hooksFile, "utf8"));
  function codex(event, extra = {}) {
    // Generated hook commands contain a store path and literal CLI arguments.
    const [command, ...args] = hooks[event][0].hooks[0].command.split(" ");
    const result = spawnSync(command, args, {
      input: JSON.stringify({ session_id: "codex-test", cwd: "/work", hook_event_name: event, ...extra }),
      encoding: "utf8",
      timeout: 5000,
    });
    assert.equal(result.status, 0);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr, "");
  }
  codex("SessionStart", { source: "startup", model: "test-model" });
  assert.equal(read("codex", "codex-test").state, "idle");
  assert.equal(read("codex", "codex-test").session_title, null);
  assert.equal(read("codex", "codex-test").effort, null);
  codex("UserPromptSubmit");
  assert.equal(read("codex", "codex-test").state, "working");
  codex("Stop", { agent_id: "child", model: "child-model" });
  assert.equal(read("codex", "codex-test").state, "working");
  assert.equal(read("codex", "codex-test").model, "test-model");
  codex("PermissionRequest");
  assert.equal(read("codex", "codex-test").state, "needs-input");
  codex("PostToolUse");
  assert.equal(read("codex", "codex-test").state, "working");
  for (const tool_name of ["request_user_input", "request_user_input_async", "mcp__test__request_user_input"]) {
    codex("PreToolUse", { tool_name });
    assert.equal(read("codex", "codex-test").state, "needs-input");
  }
  codex("PreToolUse", { tool_name: "Bash" });
  assert.equal(read("codex", "codex-test").state, "working");
  codex("SessionStart", { source: "compact" });
  assert.equal(read("codex", "codex-test").state, "working");
  for (const event of ["Stop", "Interrupt"]) {
    codex(event);
    assert.equal(read("codex", "codex-test").state, "idle");
  }
  codex("SessionEnd");
  assert.equal(existsSync(file("codex", "codex-test")), false);

  // Codex does not include effort/title in hook payloads. Its displayed name
  // differs from the first-prompt title, and metadata can change mid-session.
  const database = new DatabaseSync(join(process.env.CODEX_HOME, "state_5.sqlite"));
  try {
    database.exec("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, reasoning_effort TEXT)");
    database.prepare("INSERT INTO threads VALUES (?, ?, ?, ?)").run("codex-test", "hi", "Status hooks", "xhigh");
    database.prepare("INSERT INTO threads VALUES (?, ?, ?, ?)").run("unrelated", "Other session", "Other name", "low");
    codex("SessionStart");
    assert.equal(read("codex", "codex-test").session_title, "Status hooks");
    assert.equal(read("codex", "codex-test").effort, "xhigh");
    database.exec("UPDATE threads SET name = 'Renamed session', reasoning_effort = 'high' WHERE id = 'codex-test'");
    codex("PreToolUse", { agent_id: "child", session_title: "Child", effort: { level: "low" } });
    assert.equal(read("codex", "codex-test").session_title, "Status hooks");
    assert.equal(read("codex", "codex-test").effort, "xhigh");
    codex("PreToolUse", { tool_name: "Bash" });
    assert.equal(read("codex", "codex-test").session_title, "Renamed session");
    assert.equal(read("codex", "codex-test").effort, "high");
    codex("PostToolUse", { session_title: "From hook", effort: { level: "medium" } });
    assert.equal(read("codex", "codex-test").session_title, "From hook");
    assert.equal(read("codex", "codex-test").effort, "medium");
    database.exec("BEGIN EXCLUSIVE");
    codex("PermissionRequest");
    assert.equal(read("codex", "codex-test").state, "needs-input");
    assert.equal(read("codex", "codex-test").session_title, "From hook");
    assert.equal(read("codex", "codex-test").effort, "medium");
    database.exec("ROLLBACK");
    codex("SessionEnd");
    assert.equal(existsSync(file("codex", "codex-test")), false);
    database.exec("UPDATE threads SET name = NULL WHERE id = 'codex-test'");
    codex("SessionStart");
    assert.equal(read("codex", "codex-test").session_title, "hi");
    codex("SessionEnd");
    // A corrupt newer database must not select stale metadata from version 5.
    writeFileSync(join(process.env.CODEX_HOME, "state_6.sqlite"), "not sqlite");
    codex("SessionStart");
    assert.equal(read("codex", "codex-test").state, "idle");
    assert.equal(read("codex", "codex-test").session_title, null);
    assert.equal(read("codex", "codex-test").effort, null);
    codex("SessionEnd");
  } finally {
    database.close();
  }

  // Shared reporter still supports explicit states and metadata-only updates.
  const reporter = hooks.SessionStart[0].hooks[0].command.split(" ")[0];
  function claude(state, extra = {}) {
    const result = spawnSync(reporter, state ? [state] : [], {
      input: JSON.stringify({ session_id: "claude-test", cwd: "/work", ...extra }),
      encoding: "utf8", timeout: 5000,
    });
    assert.equal(result.status, 0);
    assert.equal(result.stdout, "");
    assert.equal(result.stderr, "");
  }
  claude("working", { model: "claude-first" });
  claude(undefined, { hook_event_name: "PostModelSwitch", to_model: "claude-second" });
  assert.equal(read("claude", "claude-test").state, "working");
  assert.equal(read("claude", "claude-test").model, "claude-second");
  claude("ended");
  assert.equal(existsSync(file("claude", "claude-test")), false);

  const handlers = new Map();
  let idle = true;
  let session = "pi-first";
  const ctx = {
    cwd: "/work", model: { id: "pi-model" }, isIdle: () => idle,
    sessionManager: { getSessionId: () => session, getSessionFile: () => "/tmp/session.jsonl" },
  };
  const { default: install } = await import(pathToFileURL(extensionFile));
  install({ on: (event, handler) => handlers.set(event, handler), getThinkingLevel: () => "high", getSessionName: () => "Test session" });
  const emit = (type) => handlers.get(type)({ type }, ctx);
  emit("session_start");
  assert.equal(read("pi", session).state, "idle");
  assert.equal(read("pi", session).effort, "high");
  assert.equal(read("pi", session).session_title, "Test session");
  idle = false;
  emit("agent_start");
  assert.equal(read("pi", session).state, "working");
  emit("ui_prompt_start");
  assert.equal(read("pi", session).state, "needs-input");
  ctx.model.id = "new-model";
  emit("model_select");
  assert.equal(read("pi", session).model, "new-model");
  assert.equal(read("pi", session).state, "needs-input");
  emit("ui_prompt_end");
  assert.equal(read("pi", session).state, "working");
  assert.equal(handlers.has("agent_end"), false, "must wait for retries/continuations to settle");
  idle = true;
  emit("agent_settled");
  assert.equal(read("pi", session).state, "idle");
  emit("ui_prompt_start");
  emit("ui_prompt_end");
  assert.equal(read("pi", session).state, "idle");
  emit("session_shutdown");
  assert.equal(existsSync(file("pi", session)), false);
  session = "pi-second";
  emit("session_start");
  assert.equal(read("pi", session).state, "idle");
  emit("session_shutdown");
  process.env.BOTILLE_STATUS_DIR = join(dir, "missing");
  emit("session_start");
  codex("SessionStart");
  console.log("Claude, Codex, and pi lifecycle/status regression checks passed");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
