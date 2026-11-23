// What the station's Node process hands the launcher at a handover (src/ops/launcher.ts):
// what it holds only in memory goes on the control channel only to a launcher that carries it over (one from before
// would write the line to its log), and what the launcher carries over from the process before is taken as it comes.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { type Socket, createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { launcher } from "../src/ops/launcher.ts";

/// A launcher's end of the control channel (a pipe, as Windows' launcher gives it): the lines it hears.
async function channel(dir: string) {
  const path = join(dir, "control.sock");
  const lines: unknown[] = [];
  let socket: Socket | null = null;
  const connected = new Promise<Socket>((resolve) => {
    const server = createServer((s) => {
      socket = s;
      let carry = "";
      s.on("data", (chunk) => {
        carry += chunk;
        for (let at; (at = carry.indexOf("\n")) >= 0; carry = carry.slice(at + 1)) lines.push(JSON.parse(carry.slice(0, at)));
      });
      resolve(s);
    });
    server.listen(path);
    stops.push(() => {
      socket?.destroy();
      server.close();
    });
  });
  return { path, lines, connected };
}
const stops: (() => void)[] = [];
const until = async (f: () => boolean) => {
  while (!f()) await new Promise((r) => setImmediate(r));
};

test("what is carried over goes only to a launcher that carries it, and what the launcher carries over is taken as it comes", async () => {
  const dir = mkdtempSync(join(tmpdir(), "launcher-carry-"));
  try {
    // A launcher from before: nothing is given.
    const old = await channel(dir);
    const before = launcher(["run", "--launcher-pipe", old.path, "--launcher-ports", "1,2"]);
    await old.connected;
    assert.equal(before.carries, false);
    before.carry({ vault: { held: [] } });
    before.ready("0.1.0");
    await until(() => old.lines.length === 1);
    assert.deepEqual(old.lines, [{ ready: true, version: "0.1.0" }]);
    stops.splice(0).forEach((stop) => stop());

    const now = await channel(dir);
    const control = launcher(["run", "--launcher-pipe", now.path, "--launcher-ports", "1,2", "--launcher-carries"]);
    const socket = await now.connected;
    assert.equal(control.carries, true);
    control.carry({ vault: { held: [1] } });
    await until(() => now.lines.length === 1);
    assert.deepEqual(now.lines, [{ carry: { vault: { held: [1] } } }]);
    // Carried over before anyone takes it: kept for the one that does.
    // (The lines are heard in order: once the hup after it is, so is it.)
    const heard = new Promise<void>((resolve) => control.on("hup", resolve));
    socket.write(JSON.stringify({ op: "carried", carried: { vault: { held: [2] } } }) + "\n" + JSON.stringify({ op: "hup" }) + "\n");
    await heard;
    const took: unknown[] = [];
    control.carried((what) => took.push(what));
    assert.deepEqual(took, [{ vault: { held: [2] } }]);
  } finally {
    stops.splice(0).forEach((stop) => stop());
    rmSync(dir, { recursive: true, force: true });
  }
});

test("that its main thread runs is said only to a launcher that asks for it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "launcher-heartbeat-"));
  try {
    // A launcher from before `--launcher-heartbeat`: it would log each line as one it does not know.
    const old = await channel(dir);
    const before = launcher(["run", "--launcher-pipe", old.path, "--launcher-ports", "1,2", "--launcher-carries"]);
    await old.connected;
    before.heartbeat();
    before.ready("0.1.0");
    await until(() => old.lines.length === 1);
    assert.deepEqual(old.lines, [{ ready: true, version: "0.1.0" }]);
    stops.splice(0).forEach((stop) => stop());

    const now = await channel(dir);
    const control = launcher(["run", "--launcher-pipe", now.path, "--launcher-ports", "1,2", "--launcher-carries", "--launcher-heartbeat"]);
    await now.connected;
    control.heartbeat();
    await until(() => now.lines.length === 1);
    assert.deepEqual(now.lines, [{ heartbeat: true }]);
    // On its own (no launcher): nothing to say it to.
    launcher(["run"]).heartbeat();
  } finally {
    stops.splice(0).forEach((stop) => stop());
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a launcher that closes its end first stops the process once, and what is said after is dropped, not thrown", async () => {
  const dir = mkdtempSync(join(tmpdir(), "launcher-closed-"));
  const thrown: unknown[] = [];
  const heard = (error: unknown) => void thrown.push(error);
  process.on("uncaughtException", heard);
  try {
    const end = await channel(dir);
    const control = launcher(["run", "--launcher-pipe", end.path, "--launcher-ports", "1,2", "--launcher-carries", "--launcher-heartbeat"]);
    let stopped = 0;
    control.on("stop", () => void stopped++);
    const socket = await end.connected;
    socket.destroy();
    // Said before the close is heard (the write that fails with EPIPE), and after it.
    control.heartbeat();
    control.drained("idle");
    await Promise.resolve();
    control.ready("0.1.0");
    await until(() => stopped > 0);
    control.heartbeat();
    control.drained("idle");
    control.carry({ vault: { held: [] } });
    // A turn of the loop for an error the writes would give to be told.
    await new Promise((r) => setImmediate(r));
    assert.equal(stopped, 1);
    assert.deepEqual(thrown, []);
  } finally {
    process.off("uncaughtException", heard);
    stops.splice(0).forEach((stop) => stop());
    rmSync(dir, { recursive: true, force: true });
  }
});
