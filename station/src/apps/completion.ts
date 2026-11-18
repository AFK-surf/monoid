// The completion a station app's widget asks of the chat it is shown in (POST /apps/<id>/llm): that chat's profile, as
// one of three. A DeepSeek Harness profile with a key whose provider speaks chat completions is asked over HTTP with
// its own endpoint and key (title-completion.ts `titleCompletion`: text in, text out, no tools). A Claude Code or Codex
// profile (a subscription's login or a key) answers one text-only turn of its own runtime (sessions/text-runtime.ts:
// the drivers' `textOnly`, on the profile's own login, its env and home as the driver gives them), in an empty
// directory of the station's made for it and removed after, never the chat's workspace. The widget never sees a key or
// a login. Any other profile is refused saying which can answer.
import { randomUUID } from "node:crypto";
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { AgentDriver } from "../agents/runtime.ts";
import type { RunOn } from "../sessions/accounts.ts";
import type { SessionRow } from "../store/rows.ts";
import { titleCompletion } from "../sessions/title-completion.ts";
import { runtimeText } from "../sessions/text-runtime.ts";
import type { AppAsk, AppCompletion } from "../api/routes/apps.ts";

export type CompletionSide = {
  getSession(key: string): SessionRow | null;
  profile(id: string): RunOn | null;
  allows(key: string, profile: RunOn): boolean;
  /// The station's home workspace, for a session of it (its row's `ws` null).
  home(): string;
  /// The station's driver of a runtime, if it has one.
  driver(runtime: "claude" | "codex"): AgentDriver | undefined;
  /// Where a runtime's turn gets an empty working directory of its own (`<data>/run/app-llm`).
  scratch: string;
  /// Told once a runtime's turn is over: its session ended (Claude Code's process gone, Codex's thread let go) and its
  /// directory removed (what a test waits on).
  turnOver?: () => void;
};

/// What the model is told before the widget's own system text.
const TEXT_ONLY = "Answer the message with text alone. You have no tools and no files; never try to use any.";

export function appCompletion(side: CompletionSide, key: string): AppCompletion | null {
  const row = side.getSession(key);
  if (row === null) return null;
  const ws = row.ws ?? side.home();
  const profile = side.profile(row.profile);
  if (!profile || !side.allows(row.key, profile)) {
    return { ws, refusal: "this chat has no profile it may use for the app's model: give the chat a profile (its settings), then ask again" };
  }
  const config = titleCompletion(profile, row.model, row.key);
  if (config !== null) return { ws, config };
  // The chat's own runtime when it is one of these, else the one the profile runs.
  const runtime = (row.runtime === "claude" || row.runtime === "codex") && profile.runtimes.includes(row.runtime) ? row.runtime
    : profile.runtimes.includes("claude") ? "claude" : profile.runtimes.includes("codex") ? "codex" : null;
  if (runtime === null) {
    return { ws, refusal: `the chat's profile "${row.profile}" cannot answer an app (a Claude Code or Codex profile can, or a DeepSeek Harness profile with a key whose provider speaks chat completions): show the app in a chat on such a profile, or add one to this station` };
  }
  const driver = side.driver(runtime);
  const name = runtime === "claude" ? "Claude Code" : "Codex";
  if (!driver) {
    return { ws, refusal: `this station does not run ${name}, which the chat's profile "${row.profile}" needs: install ${name} on this station, or show the app in a chat on another profile` };
  }
  const model = row.model ? (profile.spelling?.(row.model) ?? row.model) : undefined;
  return {
    ws,
    runtime,
    complete: async (ask: AppAsk, signal: AbortSignal) => {
      const id = randomUUID();
      const cwd = join(side.scratch, id);
      await mkdir(cwd, { recursive: true });
      const instructions = ask.system ? `${TEXT_ONLY}\n\n${ask.system}` : TEXT_ONLY;
      // Claude Code's process is the turn's own (its runner named by the key); Codex's thread is on the profile's
      // app-server, which it shares.
      return runtimeText(driver, {
        key: runtime === "codex" ? row.key : `${row.key}-app-${id}`,
        profile, cwd, model, instructions, mcpToken: "", mcpUrl: "", route: row.key,
      }, ask.prompt, signal, () => rm(cwd, { recursive: true, force: true }).finally(() => side.turnOver?.()));
    },
  };
}
