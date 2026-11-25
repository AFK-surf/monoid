// How a process the MoonBit program reads (mb-agents.ts, mb agents.mbt) is told ended: its last words on stderr kept
// where it wrote no newline after them (a runtime that would not start says why on one line and exits), what was held
// of a step's words told before a runner gone with no end said (killed, the machine short of memory), and a handover's
// hold that the program's end does not leave waiting. The runner here is a fake on a Unix socket, as
// mb-agents-leave.test.ts's.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentsHost, HostedProcess, type Heard, type HostedOptions } from "../src/agents/mb-agents.ts";
import { sessionsBinaryAvailable } from "../src/agents/mb-program.ts";
import type { RunnerInfo } from "../src/agents/runner.ts";

/// Looks every 20 ms until `f` holds (a real process answers when the machine lets it: no deadline, as runner.test.ts).
const until = async (f: () => boolean) => {
  while (!f()) await new Promise((r) => setTimeout(r, 20));
};
const skip = (process.platform === "win32" && "runner-windows.test.ts takes it up with the real runner's pipe") || (!sessionsBinaryAvailable() && "no stillfail-reader/stillfail-pion built");

/// What a runner says: `stream`'s bytes from `at`.
const out = (stream: "out" | "err", at: number, text: string) => JSON.stringify({ op: "out", stream, at, data: Buffer.from(text).toString("base64") }) + "\n";
/// A frame of Claude Code's stream-json, a line of its stdout.
const frame = (event: object) => JSON.stringify({ type: "stream_event", event, parent_tool_use_id: null, session_id: "s1", uuid: `u${Math.random()}` }) + "\n";

/// A fake runner: `onAttach` given each connection as the program attaches; and a host reading it.
async function world(name: string, onAttach: (conn: Socket) => void, onMessage?: (conn: Socket, message: { op: string }) => void) {
  // Short: a Unix socket's path is 104 bytes at most on macOS.
  const data = mkdtempSync(process.platform === "darwin" ? `/tmp/${name}-` : join(tmpdir(), `${name}-`));
  const socket = join(data, "r.sock");
  const conns: Socket[] = [];
  const server: Server = createServer({ allowHalfOpen: true }, (conn) => {
    conns.push(conn);
    let carry = "";
    conn.on("data", (chunk) => {
      carry += chunk.toString("utf8");
      for (let i = carry.indexOf("\n"); i >= 0; i = carry.indexOf("\n")) {
        const message = JSON.parse(carry.slice(0, i));
        carry = carry.slice(i + 1);
        if (message.op === "attach") onAttach(conn);
        onMessage?.(conn, message);
      }
    });
    conn.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(socket, resolve));
  const host = AgentsHost.where(data);
  const owner = {};
  host.use(owner);
  // (its runner gone: a pid no process has any more)
  const gone = spawnSync(process.execPath, ["-e", ""]).pid!;
  const info: RunnerInfo = { id: "f1", runner: gone, pid: gone, pgid: gone, startedAt: 0, program: "fake", args: [], socket };
  const end = async () => {
    await host.close(owner);
    for (const c of conns) c.destroy();
    server.close();
    rmSync(data, { recursive: true, force: true });
  };
  return { host, info, conns, end };
}

test("a process that ends on a line of stderr with no newline after it is told ended with that line", { skip }, async () => {
  const w = await world("mbe", (conn) => {
    conn.write(out("err", 0, "starting\nError: model claude-x not found"));
    conn.write(JSON.stringify({ op: "exit", code: 1, signal: null }) + "\n");
  });
  try {
    let ended: [string, string] | null = null;
    const options: HostedOptions = { label: "test", heard: () => {}, exit: (said, stderr) => void (ended = [said, stderr]) };
    HostedProcess.adopt(w.host, w.info, options, null, null);
    await until(() => ended !== null);
    assert.deepEqual(ended, ["1", "starting\nError: model claude-x not found"]);
  } finally {
    await w.end();
  }
});

test("a runner gone with no end said: what was held of a step's words is told first, and its last words with its end", { skip }, async () => {
  const lines = [
    frame({ type: "message_start", message: { id: "m1", role: "assistant", content: [] } }),
    frame({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
    frame({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "the last words" } }),
  ];
  const w = await world("mbk", (conn) => {
    let at = 0;
    for (const line of lines) {
      conn.write(out("out", at, line));
      at += Buffer.byteLength(line);
    }
    conn.write(out("err", 0, "Killed: 9"));
    // (killed: its socket gone, no exit said; end() sends the frames written before it closes, where destroy()
    // could drop them unsent and the reader would see only the end)
    conn.end();
  });
  try {
    const order: string[] = [];
    const words: string[] = [];
    let stderr: string | null = null;
    const options: HostedOptions = {
      label: "test",
      heard: (h: Heard) => {
        order.push("heard");
        for (const e of h.events) if (e.type === "live" && e.event?.kind === "delta") words.push(JSON.stringify(e.event));
      },
      exit: (said, err) => {
        order.push(`exit ${said}`);
        stderr = err;
      },
    };
    HostedProcess.adopt(w.host, w.info, options, null, null);
    await until(() => stderr !== null);
    assert.ok(words.some((w) => w.includes("the last words")), `the step's words held were told: ${words.join(" ")}`);
    assert.equal(order.at(-1), "exit runner gone", order.join(", "));
    assert.equal(stderr, "Killed: 9");
  } finally {
    await w.end();
  }
});

test("the program ending while a handover holds its reading leaves the handover waiting on nothing", { skip }, async () => {
  const w = await world("mbf", (conn) => conn.write(out("out", 0, "{}\n")));
  try {
    const options: HostedOptions = { label: "test", heard: () => {}, exit: () => {} };
    const p = HostedProcess.adopt(w.host, w.info, options, null, null);
    await until(() => w.conns.length === 1);
    const program = w.host.program()!;
    // (ended before it could answer the hold: killed, as the machine short of memory would)
    program.kill();
    let held = false;
    void w.host.freeze([p]).then(() => (held = true));
    await until(() => program.ended || w.host.program() !== program);
    // (what its end settles runs in the same turn: the hold's own steps after it before the next)
    await new Promise((r) => setImmediate(r));
    assert.ok(held, "the hold went on once the program was gone");
  } finally {
    await w.end();
  }
});

test("a process being killed whose socket closes before its runner has exited is told ended, not taken over", { skip }, async () => {
  // (its runner: a process still there as the socket closes, ended a moment after)
  const runner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  await new Promise<void>((resolve) => runner.once("spawn", () => resolve()));
  // (it takes no signal and says no exit: told done, it closes its socket first and its process ends after)
  const w = await world("mbx", () => {}, (conn, message) => {
    if (message.op !== "done") return;
    conn.end();
    setTimeout(() => runner.kill("SIGKILL"), 150);
  });
  try {
    let handed = false;
    let ended: string | null = null;
    const options: HostedOptions = { label: "test", heard: () => {}, handed: () => void (handed = true), exit: (said) => void (ended = said) };
    const p = HostedProcess.adopt(w.host, { ...w.info, runner: runner.pid! }, options, null, null);
    await until(() => w.conns.length === 1);
    await p.kill(50);
    assert.equal(await p.exited, "runner gone");
    assert.equal(ended, "runner gone");
    assert.equal(handed, false, "its own kill is no other station's takeover");
  } finally {
    runner.kill("SIGKILL");
    await w.end();
  }
});
