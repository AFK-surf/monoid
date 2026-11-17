// What the station's main thread waits on as it looks at its disk (ops/disk.ts `diskFree`: the relief of a full disk,
// sessions/agents.ts `relieving`, and the remote tasks' `node.diskLow`, jobs/remote.ts), the machine's mounts and the
// folders macOS protects (platform `mountsSoon`, drive/fs.ts `protectedPlaceSoon`), the processes' directories
// (platform `cwds`), the runner it starts agents under (platform/processes.ts `runnerBinary`) and the control plane's
// frames once nothing in them changed (cloud/presence.ts `applyState`, cloud/state.ts `update`): nothing of node:fs's or
// node:child_process's synchronous calls (station/AGENTS.md, the main thread waits on nothing). The mounts are read cold
// here, nothing having read them before in this process: `/sbin/mount` was once run on the thread at the first ask.
import assert from "node:assert/strict";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { applyState } from "../src/cloud/presence.ts";
import { Cloud, writeState } from "../src/cloud/state.ts";
import { protectedPlaceSoon } from "../src/drive/fs.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { Remote } from "../src/jobs/remote.ts";
import { diskFree } from "../src/ops/disk.ts";
import { WINDOWS, platform } from "../src/platform/index.ts";
import { runnerBinary } from "../src/platform/processes.ts";
import { Store } from "../src/store/store.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const temp = (name: string) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), name)));
  dirs.push(dir);
  return dir;
};

test("the machine's mounts read cold and a protected place looked at wait on no file or process", { skip: WINDOWS }, async () => {
  const h = homedir();
  const calls = await syncCalls(async () => {
    const mounts = await platform.mountsSoon();
    assert.ok(Array.isArray(mounts));
    if (process.platform !== "darwin") assert.deepEqual(mounts, []);
    assert.deepEqual(await protectedPlaceSoon(join(h, "Desktop", "x"), h), { top: join(h, "Desktop"), helper: true });
    // Asked again at once: as read, nothing read again.
    assert.deepEqual(await platform.mountsSoon(), mounts);
    assert.deepEqual(platform.mounts(), mounts);
  });
  assert.deepEqual(calls, []);
});

test("the disk's free space, as the relief and the remote tasks ask it, waits on no file", async () => {
  const dir = temp("disk-main-thread-");
  const store = Store.open(":memory:");
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const remote = new Remote({ data: dir, store, jobs, notify: () => {} });
  const asked = (f: string, args: unknown[]) => (remote as unknown as { asked(f: string, args: unknown[]): Promise<unknown> }).asked(f, args);
  try {
    const calls = await syncCalls(async () => {
      assert.ok((await diskFree(dir)) > 0);
      assert.equal(typeof (await asked("node.diskLow", [dir])), "boolean");
      // One that cannot be looked at is not low.
      assert.equal(await asked("node.diskLow", [join(dir, "gone", "deeper")]), false);
      await assert.rejects(diskFree(join(dir, "gone")));
      const job = { id: "j1", sessionKey: "s", name: "n", command: "true", cwd: dir, port: null, state: "running", pgid: null, exitCode: null, startedAt: 1, endedAt: null, restarts: 0, log: "l", watch: false };
      assert.equal(((await asked("node.jobJson", [job])) as { id: string }).id, "j1");
    });
    assert.deepEqual(calls, []);
  } finally {
    await remote.close();
    await jobs.shutdown();
    store.close();
  }
});

test("the processes' directories and the runner, once found, wait on no file", { skip: WINDOWS }, async () => {
  const runner = runnerBinary();
  const calls = await syncCalls(async () => {
    assert.equal((await platform.cwds([process.pid])).get(process.pid), process.cwd());
    assert.equal(runnerBinary(), runner);
  });
  assert.deepEqual(calls, []);
});

test("the control plane's frame that changes nothing writes nothing", async () => {
  const data = temp("presence-main-thread-");
  const ws = "01WORKSPACE";
  const station = "bb".repeat(32);
  writeState(data, { origin: "https://app.still.fail", station, workspace: ws, workspace_name: "Home", name: "nas", peers: [], relay_urls: [], revocations: [] } as any);
  const s = new Cloud(data, false);
  try {
    const frame = JSON.stringify({ type: "state", workspace: ws, workspace_name: "Home", name: "nas", peers: [{ id: "cc".repeat(32), name: "willow" }], lock: null });
    applyState(s, frame);
    const calls = await syncCalls(async () => {
      applyState(s, frame);
      applyState(s, frame);
    });
    assert.deepEqual(calls, []);
    assert.deepEqual(s.state?.peers.map((p: any) => p.id), ["cc".repeat(32)]);
  } finally {
    s.close();
  }
});
