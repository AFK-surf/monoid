// A station letting go of a process the MoonBit program reads (mb-agents.ts `detach`): where a runner's socket has no
// one-way close (a Windows pipe, `platform.runnerSaysLeave`) the program asks it to close (`leave`) after what it wrote
// before, and the next takes it up from there. The runner here is a fake that never closes on a one-way close, as a
// pipe's cannot see one: let go without `leave`, it would keep the connection.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { AgentsHost, HostedProcess, type HostedOptions } from "../src/agents/mb-agents.ts";
import { sessionsBinaryAvailable } from "../src/agents/mb-program.ts";
import { allLeft, type RunnerInfo } from "../src/agents/runner.ts";
import { platform } from "../src/platform/index.ts";

/// Looks every 20 ms until `f` holds (a real process answers when the machine lets it: no deadline, as runner.test.ts).
const until = async (f: () => boolean) => {
  while (!f()) await new Promise((r) => setTimeout(r, 20));
};
const skip = (process.platform === "win32" && "runner-windows.test.ts takes it up with the real runner's pipe") || (!sessionsBinaryAvailable() && "no stillfail-reader/stillfail-pion built");

test("let go where its runner cannot see a one-way close, it is asked to leave and taken up again", { skip }, async () => {
  // Short: a Unix socket's path is 104 bytes at most on macOS.
  const data = mkdtempSync(process.platform === "darwin" ? "/tmp/mbl-" : join(tmpdir(), "mbl-"));
  const socket = join(data, "r.sock");
  /// What the fake runner was sent, by connection, each message's op.
  const ops: string[][] = [];
  const conns: Socket[] = [];
  const lines = ["one", "two"];
  let sent = 0;
  const server = createServer({ allowHalfOpen: true }, (conn) => {
    const mine: string[] = [];
    ops.push(mine);
    conns.push(conn);
    let carry = "";
    conn.on("data", (chunk) => {
      carry += chunk.toString("utf8");
      for (let i = carry.indexOf("\n"); i >= 0; i = carry.indexOf("\n")) {
        const message = JSON.parse(carry.slice(0, i));
        carry = carry.slice(i + 1);
        mine.push(message.op);
        if (message.op === "attach") {
          const line = lines[ops.length - 1]!;
          conn.write(JSON.stringify({ op: "out", stream: "out", at: sent, data: Buffer.from(line + "\n").toString("base64") }) + "\n");
          sent += line.length + 1;
        }
        // (as the runner: what came before handled, the connection ended)
        if (message.op === "leave") conn.end();
      }
    });
    conn.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(socket, resolve));
  const was = platform.runnerSaysLeave;
  platform.runnerSaysLeave = true;
  const host = AgentsHost.where(data)!;
  const owner = {};
  host.use(owner);
  after(async () => {
    platform.runnerSaysLeave = was;
    await host.close(owner);
    for (const c of conns) c.destroy();
    server.close();
  });
  const info: RunnerInfo = { id: "f1", runner: process.pid, pid: process.pid, pgid: process.pid, startedAt: 0, program: "fake", args: [], socket };
  const heard: string[] = [];
  const options: HostedOptions = { label: "test", kind: "codex", heard: (h) => void heard.push(...(h.lines ?? []).map((l) => l.text)), exit: () => {} };

  const a = HostedProcess.adopt(host, info, options, null, null);
  await until(() => heard.length === 1 && ops[0]!.includes("ack"));
  a.detach();
  // (let go: the runner closed on `leave`, never on the one-way close)
  await allLeft();
  assert.deepEqual(ops[0], ["attach", "ack", "leave"], "`leave` after what was written before");
  assert.equal(host.program(), null);

  HostedProcess.adopt(host, info, options, null, null);
  // (its ack goes to the runner after Node took the line, on the program's next turn: waited for, as the first's)
  await until(() => heard.length === 2 && ops[1]!.includes("ack"));
  assert.deepEqual(heard, ["one", "two"]);
  assert.deepEqual(ops[1]!.slice(0, 2), ["attach", "ack"]);
});

test("let go while its session still writes what it took, that is acknowledged before it leaves", { skip }, async () => {
  const data = mkdtempSync(process.platform === "darwin" ? "/tmp/mbw-" : join(tmpdir(), "mbw-"));
  const socket = join(data, "r.sock");
  const ops: string[] = [];
  const conns: Socket[] = [];
  const server = createServer({ allowHalfOpen: true }, (conn) => {
    conns.push(conn);
    let carry = "";
    conn.on("data", (chunk) => {
      carry += chunk.toString("utf8");
      for (let i = carry.indexOf("\n"); i >= 0; i = carry.indexOf("\n")) {
        const message = JSON.parse(carry.slice(0, i));
        carry = carry.slice(i + 1);
        ops.push(message.op);
        if (message.op === "attach") conn.write(JSON.stringify({ op: "out", stream: "out", at: 0, data: Buffer.from("one\n").toString("base64") }) + "\n");
        if (message.op === "leave") conn.end();
      }
    });
    conn.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(socket, resolve));
  const was = platform.runnerSaysLeave;
  platform.runnerSaysLeave = true;
  const host = AgentsHost.where(data)!;
  const owner = {};
  host.use(owner);
  after(async () => {
    platform.runnerSaysLeave = was;
    await host.close(owner);
    for (const c of conns) c.destroy();
    server.close();
  });
  const info: RunnerInfo = { id: "f2", runner: process.pid, pid: process.pid, pgid: process.pid, startedAt: 0, program: "fake", args: [], socket };
  // (its session writes what it took on the disk: done when the test says, as a transcript's append, own-process.ts `settled`)
  let written!: () => void;
  const writing = new Promise<void>((resolve) => (written = resolve));
  const heard: string[] = [];
  const options: HostedOptions = {
    label: "test",
    kind: "codex",
    heard: (h) => {
      heard.push(...(h.lines ?? []).map((l) => l.text));
      return writing;
    },
    exit: () => {},
  };

  const a = HostedProcess.adopt(host, info, options, null, null);
  await until(() => heard.length === 1);
  // (let go as the next driver takes over, devin.test.ts: before the line is on the disk)
  a.detach();
  assert.deepEqual(ops, ["attach"], "nothing acknowledged or let go before its session wrote it");
  written();
  await allLeft();
  assert.deepEqual(ops, ["attach", "ack", "leave"], "acknowledged once written, then let go");
});
