// The hook a Claude Code session runs after each tool (src/agents/repo-rules-hook.mjs): a repository's rules for agents
// (AGENTS.md, else CLAUDE.md, from its root down to the directory touched) told the first time a tool touches it, by
// the shell too, once per session and per subagent, again when a file changed (not to the tool that changed it) and
// after a compaction; nothing outside a repository.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

// (the file repo-rules.ts names as REPO_RULES_HOOK: test/claude.test.ts and codex.test.ts hold that it is the one started)
const REPO_RULES_HOOK = fileURLToPath(new URL("../assets/agents/repo-rules-hook.mjs", import.meta.url));

const root = mkdtempSync(join(tmpdir(), "repo-rules-"));
after(() => rmSync(root, { recursive: true, force: true }));
const workspace = join(root, "workspace");
const repo = join(workspace, "wt");
mkdirSync(join(repo, ".git"), { recursive: true });
mkdirSync(join(repo, "apps", "x", "src"), { recursive: true });
mkdirSync(join(repo, "other"), { recursive: true });
writeFileSync(join(repo, "AGENTS.md"), "root rule HERON");
writeFileSync(join(repo, "CLAUDE.md"), "@AGENTS.md");
writeFileSync(join(repo, "apps", "x", "CLAUDE.md"), "x rule OSPREY");
writeFileSync(join(repo, "apps", "x", "src", "a.txt"), "a");
mkdirSync(join(workspace, "notes"), { recursive: true });
writeFileSync(join(workspace, "AGENTS.md"), "not a repository's");

/// The context the hook adds after `tool` with `input`, "" when none.
function told(input: object, session = "s1", agent?: string, event = "PostToolUse"): string {
  const out = execFileSync(process.execPath, [REPO_RULES_HOOK], {
    input: JSON.stringify({ session_id: session, ...(agent === undefined ? {} : { agent_id: agent }), cwd: workspace, hook_event_name: event, ...input }),
    env: { ...process.env, TMPDIR: root, TEMP: root, TMP: root },
  }).toString();
  return out === "" ? "" : JSON.parse(out).hookSpecificOutput.additionalContext;
}

test("a shell command into a repository tells its rules from the root down, once", () => {
  const first = told({ tool_name: "Bash", tool_input: { command: "cat wt/apps/x/src/a.txt | head -3" } });
  assert.match(first, /root rule HERON[\s\S]*x rule OSPREY/);
  assert.doesNotMatch(first, /not a repository's/);
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "grep -rn foo wt/apps/x" } }), "");
  // A directory of the repository not touched before: only what is new.
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "ls wt/other" } }), "");
});

test("a file tool's path, a subagent and a changed rule are told again; outside a repository nothing", () => {
  assert.match(told({ tool_name: "Read", tool_input: { file_path: join(repo, "apps", "x", "src", "a.txt") } }, "s2"), /OSPREY/);
  assert.match(told({ tool_name: "Grep", tool_input: { pattern: "x", path: join(repo, "apps", "x") } }, "s2", "agent-1"), /HERON[\s\S]*OSPREY/);
  const later = new Date(Date.now() + 10_000);
  writeFileSync(join(repo, "apps", "x", "CLAUDE.md"), "x rule KESTREL");
  utimesSync(join(repo, "apps", "x", "CLAUDE.md"), later, later);
  const again = told({ tool_name: "Bash", tool_input: { command: `cat ${join(repo, "apps", "x", "src", "a.txt")}` } }, "s2");
  assert.match(again, /KESTREL/);
  assert.doesNotMatch(again, /HERON/);
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "ls notes/ && echo done" } }, "s3"), "");
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "curl -s https://example.com/a/b" } }, "s3"), "");
});

test("a rules file the tool itself wrote is not told again; after a compaction every one is", () => {
  const rules = join(repo, "apps", "x", "CLAUDE.md");
  assert.match(told({ tool_name: "Read", tool_input: { file_path: join(repo, "apps", "x", "src", "a.txt") } }, "s4"), /HERON[\s\S]*rule/);
  const later = new Date(Date.now() + 20_000);
  writeFileSync(rules, "x rule MERLIN");
  utimesSync(rules, later, later);
  assert.equal(told({ tool_name: "Edit", tool_input: { file_path: rules } }, "s4"), "");
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "ls wt/apps/x/src" } }, "s4"), "");
  // A file never told is told even to the tool that wrote it.
  assert.match(told({ tool_name: "Write", tool_input: { file_path: rules } }, "s5"), /HERON[\s\S]*MERLIN/);
  // Compacted: told again, a subagent's own record left as it was.
  assert.match(told({ tool_name: "Bash", tool_input: { command: "ls wt/apps/x" } }, "s4", "agent-2"), /MERLIN/);
  assert.equal(told({ source: "compact" }, "s4", undefined, "SessionStart"), "");
  assert.match(told({ tool_name: "Bash", tool_input: { command: "ls wt/apps/x" } }, "s4"), /HERON[\s\S]*MERLIN/);
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "ls wt/apps/x" } }, "s4", "agent-2"), "");
  // Codex's: its compaction is a PostCompact of its own.
  assert.equal(told({ trigger: "manual" }, "s4", undefined, "PostCompact"), "");
  assert.match(told({ tool_name: "Bash", tool_input: { command: "ls wt/apps/x" } }, "s4"), /HERON[\s\S]*MERLIN/);
});

test("what one call tells stays under what Claude Code takes whole; the rest follows on the next tools, in order, all of it", () => {
  // As this repository's are: a root file near a call's room, one below it longer than a call, one below that short.
  const big = join(workspace, "big");
  mkdirSync(join(big, ".git"), { recursive: true });
  mkdirSync(join(big, "app", "lib"), { recursive: true });
  const paragraphs = (name: string, n: number) => Array.from({ length: n }, (_, i) => `- ${name} rule ${i}: ${"words of it ".repeat(20)}`).join("\n") + "\n";
  const rootRules = `# Root\n\n${paragraphs("ROOT", 32)}`;
  const appRules = `# App\n\n${paragraphs("APP", 52)}`;
  const libRules = "# Lib\n\n- LIB rule, the only one.\n";
  assert.ok(rootRules.length > 8_000 && rootRules.length < 8_700 && appRules.length > 13_000);
  writeFileSync(join(big, "AGENTS.md"), rootRules);
  writeFileSync(join(big, "app", "AGENTS.md"), appRules);
  writeFileSync(join(big, "app", "lib", "AGENTS.md"), libRules);

  const calls: string[] = [told({ tool_name: "Bash", tool_input: { command: "ls big/app/lib" } }, "s6")];
  // The tools after it touch nothing of the repository: what waits is told all the same.
  for (let i = 0; i < 8; i++) calls.push(told({ tool_name: "Bash", tool_input: { command: "ls notes/" } }, "s6"));
  const spoke = calls.filter((c) => c !== "");
  assert.equal(spoke.length, 3);
  assert.deepEqual(calls.slice(3), ["", "", "", "", "", ""]);
  for (const call of spoke) assert.ok(call.length <= 10_000, `a call told ${call.length} characters`);
  assert.match(spoke[0]!, /^Contents of \S+big\/AGENTS\.md \([^)]*\):\n\n# Root/);
  assert.doesNotMatch(spoke[0]!, /APP rule/);
  assert.match(spoke[1]!, /app\/AGENTS\.md \([^)]*\), lines 1 to \d+ of 54:\n\n# App[\s\S]*\[more of this file follows after your next tool call\]$/);
  assert.match(spoke[2]!, /app\/AGENTS\.md \([^)]*\), lines \d+ to 54, the last of it:\n\n- APP rule[\s\S]*---[\s\S]*lib\/AGENTS\.md \([^)]*\):\n\n# Lib/);
  // Every rule of every file reached the session once, whole, in the files' order.
  const body = spoke.join("\n").split("\n").filter((l) => /^- (ROOT|APP|LIB) rule/.test(l));
  assert.deepEqual(body, [rootRules, appRules, libRules].flatMap((t) => t.split("\n").filter((l) => l.startsWith("- "))));

  // A file changed while part of it waits is told from its start; one the tool itself rewrote waits no more.
  assert.match(told({ tool_name: "Bash", tool_input: { command: "ls big/app" } }, "s7"), /# Root/);
  assert.match(told({ tool_name: "Bash", tool_input: { command: "ls notes/" } }, "s7"), /lines 1 to \d+ of 54/);
  const later = new Date(Date.now() + 30_000);
  writeFileSync(join(big, "app", "AGENTS.md"), `# App again\n\n${paragraphs("APP", 52)}`);
  utimesSync(join(big, "app", "AGENTS.md"), later, later);
  assert.match(told({ tool_name: "Bash", tool_input: { command: "ls notes/" } }, "s7"), /lines 1 to \d+ of 54:\n\n# App again/);
  const edited = new Date(Date.now() + 60_000);
  writeFileSync(join(big, "app", "AGENTS.md"), `# App rewritten\n\n${paragraphs("APP", 52)}`);
  utimesSync(join(big, "app", "AGENTS.md"), edited, edited);
  assert.equal(told({ tool_name: "Edit", tool_input: { file_path: join(big, "app", "AGENTS.md") } }, "s7"), "");
  assert.equal(told({ tool_name: "Bash", tool_input: { command: "ls notes/" } }, "s7"), "");
});

test("Antigravity CLI's protojson PostToolUse queues AGENTS.md and CLAUDE.md rules and PostInvocation injects them", () => {
  const ccRepo = join(workspace, "cc-only");
  mkdirSync(join(ccRepo, ".git"), { recursive: true });
  mkdirSync(join(ccRepo, ".claude"), { recursive: true });
  mkdirSync(join(ccRepo, "web", "src"), { recursive: true });
  writeFileSync(join(ccRepo, ".claude", "CLAUDE.md"), "root rule DOTCLAUDE_FALCON");
  writeFileSync(join(ccRepo, "web", "CLAUDE.md"), "web rule SWIFT");
  writeFileSync(join(ccRepo, "web", "src", "page.tsx"), "export {};\n");

  const conversationId = "2be6c385-f255-498e-91dd-1f88064d021f";
  const common = {
    conversationId,
    workspacePaths: [workspace],
    transcriptPath: join(root, ".gemini", "antigravity-cli", "brain", conversationId, ".system_generated", "logs", "transcript.jsonl"),
    artifactDirectoryPath: join(root, ".gemini", "antigravity-cli", "brain", conversationId),
    modelName: "claude-opus-5-5-medium",
    lastUserInput: "fix web/src/page.tsx",
    cwd: workspace,
  };
  const agyCall = (payload: object, extraEnv: Record<string, string> = {}) => {
    const out = execFileSync(process.execPath, [REPO_RULES_HOOK], {
      input: JSON.stringify({ ...common, ...payload }),
      env: { ...process.env, TMPDIR: root, TEMP: root, TMP: root, ...extraEnv },
    }).toString();
    return out === "" ? null : JSON.parse(out);
  };

  // A session with STILLFAIL_REPO_RULES=0 (continued without the station's instructions) answers `{}` without queuing or injecting rules.
  assert.deepEqual(
    agyCall(
      {
        conversationId: "00000000-0000-4000-8000-000000000001",
        hookEventName: "PostToolUse",
        stepIdx: 1,
        toolCall: { id: "t-off", name: "run_command", args: { CommandLine: "cat wt/apps/x/src/a.txt cc-only/web/src/page.tsx" } },
      },
      { STILLFAIL_REPO_RULES: "0" },
    ),
    {},
  );
  assert.deepEqual(
    agyCall({ conversationId: "00000000-0000-4000-8000-000000000001", hookEventName: "PostInvocation", invocationNum: 0, initialNumSteps: 2 }, { STILLFAIL_REPO_RULES: "0" }),
    {},
  );

  // PostToolUse (as agy 1.5.9 sends it) returns `{}` and queues rules from both `wt` (AGENTS.md) and `cc-only` (.claude/CLAUDE.md + CLAUDE.md).
  assert.deepEqual(
    agyCall({
      hookEventName: "PostToolUse",
      stepIdx: 5,
      toolCall: {
        id: "2d9dd882-e769-441f-be84-aa0982d7a995",
        name: "run_command",
        args: { CommandLine: "cat wt/apps/x/src/a.txt cc-only/web/src/page.tsx", WaitMsBeforeAsync: 5000, toolSummary: "Read files" },
      },
    }),
    {},
  );
  const first = agyCall({ hookEventName: "PostInvocation", invocationNum: 0, initialNumSteps: 4 });
  const injected: string = first?.injectSteps?.[0]?.systemMessage?.systemMessage ?? "";
  assert.match(injected, /wt\/AGENTS\.md[\s\S]*root rule HERON[\s\S]*x rule/);
  assert.match(injected, /cc-only\/\.claude\/CLAUDE\.md \(the repository's rules for agents working in .*cc-only\/; follow them\):\n\nroot rule DOTCLAUDE_FALCON[\s\S]*web rule SWIFT/);

  // Nothing queued on the next invocation, or when touching the same directory via read_file.
  assert.deepEqual(agyCall({ hookEventName: "PostInvocation", invocationNum: 1, initialNumSteps: 7 }), {});
  assert.deepEqual(
    agyCall({
      hookEventName: "PostToolUse",
      stepIdx: 8,
      toolCall: { id: "c83d6f75-1036-4b66-a955-971098364e70", name: "read_file", args: { Path: join(ccRepo, "web", "src", "page.tsx") } },
    }),
    {},
  );
  assert.deepEqual(agyCall({ hookEventName: "PostInvocation", invocationNum: 2, initialNumSteps: 9 }), {});

  // Editing the rules file itself via edit_file does not echo it back to the session that edited it.
  const later = new Date(Date.now() + 90_000);
  writeFileSync(join(ccRepo, "web", "CLAUDE.md"), "web rule PEREGRINE");
  utimesSync(join(ccRepo, "web", "CLAUDE.md"), later, later);
  assert.deepEqual(
    agyCall({
      hookEventName: "PostToolUse",
      stepIdx: 10,
      toolCall: {
        id: "f91a2201-4411-4091-b20a-881122334455",
        name: "edit_file",
        args: { Path: join(ccRepo, "web", "CLAUDE.md"), Target: "web rule SWIFT", Replacement: "web rule PEREGRINE" },
      },
    }),
    {},
  );
  assert.deepEqual(agyCall({ hookEventName: "PostInvocation", invocationNum: 3, initialNumSteps: 11 }), {});
});
