// The station's terminals as a part of it (parts.ts, terminals.ts): their views on members' links (`terminal`
// requests), GET /terminals and ending one (POST /terminals/<id>/end), `terminals` on the event stream as they change.
// Each is a runner's (`term-<id>`), its meta beside it in <data>/run/terminals/<id>.json, so the station after this one
// (an update, a crash) takes them up as they are; a station that stops leaves them to it.
import { randomBytes } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { Effect, Layer } from "effect";
import { TERMINAL_RUNNER, isTerminalRunner, liveRunners, listeningSoon, startRunner } from "../agents/runner.ts";
import { readOnly } from "../mesh/credential.ts";
import { error, json } from "../api/request.ts";
import type { Request } from "../api/request.ts";
import { STATION_INTERNAL } from "../ops/agent-env.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { stationFeature } from "../features.ts";
import { Events, Parts, Paths, StationConfig, Store } from "../services.ts";
import { TerminalLink, runnerWire } from "./link.ts";
import { type TerminalMeta, Terminals } from "./terminals.ts";

/// The shell a terminal opens: the person's login shell, as a terminal app starts it.
function shell(): { program: string; args: string[] } {
  if (platform.os === "windows") return { program: "powershell.exe", args: ["-NoLogo"] };
  return { program: process.env.SHELL || "/bin/sh", args: ["-l"] };
}

/// Environment hooks so interactive login shells emit `OSC 7` after each command (`cd`) without touching user dotfiles:
/// macOS `/etc/zshrc` sources `/etc/zshrc_Apple_Terminal` when `TERM_PROGRAM=Apple_Terminal` (with session files off),
/// and bash executes `PROMPT_COMMAND` when unset.
function shellEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const name of STATION_INTERNAL) delete env[name];
  if (platform.os === "macos") {
    env.TERM_PROGRAM ??= "Apple_Terminal";
    env.SHELL_SESSIONS_DISABLE ??= "1";
  }
  if (!env.PROMPT_COMMAND) {
    env.PROMPT_COMMAND = `printf '\\033]7;file://%s%s\\007' "\${HOSTNAME:-}" "$PWD"`;
  }
  return env;
}

const metaOf = (v: any): TerminalMeta | null =>
  v !== null && typeof v === "object" && typeof v.by === "string" && typeof v.at === "number" && typeof v.cwd === "string" && typeof v.workspace === "string"
    ? { by: v.by, ...(typeof v.byEmail === "string" ? { byEmail: v.byEmail } : {}), at: v.at, cwd: v.cwd, workspace: v.workspace, ...(typeof v.chat === "string" ? { chat: v.chat } : {}) }
    : null;

export const TerminalsLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const parts = yield* Parts;
    const events = yield* Events;
    const store = yield* Store;
    const { app, data } = yield* Paths;
    const config = yield* StationConfig;
    const metaDir = join(data, "run", "terminals");
    const metaFile = (id: string) => join(metaDir, `${id}.json`);
    let terminals: Terminals | null = null;
    const tell = (workspace: string) => {
      if (terminals === null) return;
      events.tell("terminals", { terminals: terminals.list(workspace) }, `terminals\0${workspace}`, { workspace });
    };
    terminals = new Terminals({
      home: homedir(),
      chatDir: (chat) => { const row = store.getSession(chat); return row ? (row.cwd ?? row.workspace) : undefined; },
      newId: () => `${TERMINAL_RUNNER}${randomBytes(8).toString("hex")}`,
      offered: () => stationFeature("terminal", config.raw(), app),
      changed: tell,
      meta: (id, meta) => void writeFile(metaFile(id), JSON.stringify(meta), { mode: 0o600 }).catch(() => undefined),
      gone: (id) => void rm(metaFile(id), { force: true }).catch(() => undefined),
      async start(id, o, meta) {
        await mkdir(metaDir, { recursive: true, mode: 0o700 });
        await writeFile(metaFile(id), JSON.stringify(meta), { mode: 0o600 });
        const { program, args } = shell();
        const info = await startRunner(data, id, program, args, shellEnv(), o.cwd, { cols: o.cols, rows: o.rows });
        return new TerminalLink(runnerWire(info));
      },
    });
    const kept = terminals;
    // Those a station before this one opened: their runners, with what was kept of them.
    yield* Effect.promise(async () => {
      for (const info of await liveRunners(data)) {
        if (!isTerminalRunner(info.id) || info.pty !== true || !(await listeningSoon(info))) continue;
        const meta = metaOf(await readFile(metaFile(info.id), "utf8").then(JSON.parse).catch(() => null));
        if (meta === null) continue;
        kept.keep(info.id, new TerminalLink(runnerWire(info)), meta, { cols: info.cols, rows: info.rows });
        log.info("terminal", "taken up", { id: info.id });
      }
    });
    yield* Effect.addFinalizer(() => Effect.sync(() => kept.detach()));

    parts.streams("terminal", async ({ viewer, head, stream, reader }) => kept.answer(stream, reader.carry, head, viewer));
    parts.routes([
      { method: "GET", pattern: /^\/terminals$/, handle: async (r: Request) => json(200, JSON.stringify({ terminals: kept.list(r.viewer.workspace) })) },
      {
        method: "POST",
        pattern: /^\/terminals\/([^/]+)\/end$/,
        handle: async (r: Request, [raw]: string[]) => {
          if (readOnly(r.viewer)) return error(403, "a read-only member does not end a terminal");
          let id: string;
          try {
            id = decodeURIComponent(raw!);
          } catch {
            return error(404, "no such terminal");
          }
          return kept.end(id, r.viewer.name || r.viewer.email, r.viewer.workspace) ? json(200, "{}") : error(404, "no such terminal");
        },
      },
    ]);
  }),
);
