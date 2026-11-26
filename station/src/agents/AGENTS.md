# Station agents, runtimes, tools, and sandboxes (for agents)

## Runtime drivers and MoonBit output parsing

- All runtimes sit behind one driver seam (`station/src/agents/runtime.ts`), and each driver owns its child's stdin:
  - Claude Code runs one `claude -p` process per session, or a PTY with lifecycle hooks in `station/assets/agents/claude-tui.mjs` when TUI mode is selected (chat sessions only; `station/mb/src/station_main/claude_tui.mbt` is frozen in `stillfail-reader-harness` only, while shipped `stillfail-reader` hands `claude-tui` / `claude-tui.mjs` off to Node via `station_shim`).
  - Codex runs one app-server per account with one thread per session. Pass per-session settings in `thread/start` config, never process env. Shut down idle app-servers after `WARM_MS` and reopen threads on the next turn.
  - Other runtimes live in `station/src/agents/`.
- One shared MoonBit program parses every runtime's output off the main thread on every platform (including Windows runner named pipes), with no TypeScript fallback:
  - Claude Code (`station/src/agents/mb-agents.ts`, `station/mb/src/reader/agents.mbt`, `station/mb/src/claude`, `station/mb/src/claude/outcome.mbt`): Node starts/stops processes, handles token renewals and turn outcomes, and acknowledges routed batches (`routed`, `station/src/sessions/mb-actor.ts` `#took`). The program hands events directly to actors and `#live` (`station/test/hub-e2e.test.ts` checks none pass through Node). Handover freezes reading first (`freeze`, `station/src/sessions/hub.ts` `handOver`).
  - Codex (`station/mb/src/reader/agents_codex.mbt`, `station/mb/src/codex`): Node receives only replies, app-server requests, and turn errors. Drop `turn/diff/updated`, route thread notifications in-program, track turn ids and offsets in `codex.ts` `Host.heard`, and use `replay` on crash recovery. Parity tests compare against `station/test/codex-reference.ts` (`station/test/codex-cases.ts`, `station/mb/src/codex/as_typescript_said_test.mbt`).
  - DeepSeek Harness, Cursor (and GitHub Copilot, whose `copilot-bridge.mjs` speaks Cursor's lines and keeps Cursor's transcript), and ACP runtimes (Antigravity CLI, Grok Build, Devin, Hermes Agent): `station/mb/src/reader/agents_own.mbt` (`station/mb/src/dsh`, `station/mb/src/cursor`, `station/mb/src/acp`). Node receives only request answers, runtime requests, and kept ACP transcripts/usage (`acp.ts` `took`, `KeptTranscript`). Write kept data off the main thread before marking a turn ended (`own-process.ts` `settled`). Crash recovery uses `replayOwn` (`own_replay`). Parity tests compare against `station/test/reference/live.ts` and `station/test/reference/process.ts` (`station/test/runtime-cases.ts`, `station/test/mb-dsh.test.ts`, `station/test/mb-cursor.test.ts`, `station/test/mb-acp.test.ts`).
  - Assemble chunked agent output lines once via `station/mb/src/pieces`. Concatenating per chunk blows up large lines to gigabytes.

## MCP tools and instructions

- Agent tools run on the local MCP endpoint (`station/src/tools/`, HTTP on `127.0.0.1`, per-session bearer token).
- Third-party MCP servers are hosted by the station (`station/src/tools/managed-mcp.ts`, `config.json` `mcpServers`) and exposed through the station's own `stillfail` MCP endpoint. Never write third-party MCP configs or secrets into any runtime driver's session config or environment so every runtime gets them uniformly and secrets remain inside the station process.
- Agent guidance lives in `station/src/agents/instructions.ts` and `station/assets/skills/`. When changing instructions, tool parameters, or tool rules, append one sentence with the next number to `station/src/agents/migrations.ts` so older sessions see it once. `readMemory()` hard-caps `MEMORY.md` injection at `MEMORY_INJECT_HARD_MAX` (16 KB, UTF-8 safe) while computing `overgrown` on the untruncated file, and auto-injects the current station's `skills/machines/<stationTag>.md` (capped at `STATION_MEMORY_MAX`, 4 KB, skipping symlinks and `0600` private files) as `<station-memory>`.
- Tool listings are per runtime (`station/src/sessions/agents.ts` `LISTINGS`). Claude Code defers MCP tools, so mark only `chat_post` and `chat_state` as loaded.
- Keep tool declarations compact: runtimes that load all tools pay every session, and Codex drops parameter descriptions for schemas over 5,000 bytes. State what the tool does and when, and link to its skill in `station/assets/skills/` for details. `station/test/tools-weight.test.ts` enforces ceilings. Explain any ceiling raise in the change.

## Subagents never speak in a chat

- Tools that speak (`station/src/tools/mcp.ts` `SPEAKS`, plus writing `slack_api` methods) belong to the main session agent only.
- Because the MCP endpoint sees one bearer token per session, each runtime driver blocks subagents from speaking tools. Claude Code enforces this via `station/assets/agents/subagent-hook.mjs` (gaps documented at `SILENT_SUBAGENTS` in `station/src/agents/claude.ts`); GitHub Copilot via the SDK's pre-tool hook on the runtime's `agentId` (`station/assets/agents/copilot-bridge.mjs` `refusal`). Other runtimes do not enforce it yet.
- Classify every new tool in `station/test/speaks.test.ts`. Tools that only show a card or report to the still.fail team remain open to subagents until the owner decides otherwise.

## Bug-report replies never auto-reach agents

- Replies from the still.fail team are external input and must never enter a session automatically. Cloud delivers them only to workspace members' apps (`client/core-ts/src/feedback-replies.ts`). No station reads or stores them. Agents see a reply only when a person quotes it, and call `feedback_reply` only when asked.

## Sandboxes

- Heavy work runs in sandboxes targeted by `station_task` (`station/src/agents/sandbox.ts`). Configure l4es front doors in `config.json` under `sandboxes`. `station_list` lists them beside stations, and the station runs each task as a local job through `station/assets/agents/sandbox-bridge.mjs`.
- Install nothing in a sandbox and run no agent or station inside one. Sandboxes are not devices, and no tool or UI adds them. Legacy per-session `sandbox` mode is removed.
- A sandbox of kind `colab` is a Google Colab VM with a GPU backed by native `service: "colab"` profiles in `Accounts` (`homes/<id>/colab-auth.json`, synced into bounded-ephemeral `<data>/colab/cli-homes/<id>/` via `PlaintextKeyring`), taken and handed back by `station/assets/agents/colab-sandbox.mjs`. When a station has usable Colab profiles for a workspace and no explicit `kind: "colab"` config, it exposes `colab-g4`/`colab-l4`/`colab-t4` automatically and advertises them in `describe` so other stations in the same workspace can dispatch via `sandbox:<hostId>:<name>` while credentials and per-account 3-VM locks stay on the host. Colab never stops a running VM and bills hourly, so the station stops idle ones (`reapColab`); its image has no Node, so Node is installed on the ephemeral VM before the bridge runs.
