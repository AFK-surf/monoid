// Cross-station Colab sandbox discovery & mesh dispatch integration test:
// Station B has a native Google Colab profile (`homes/colab-1/colab-auth.json`), Station A has none.
// Verifies: station_list discovery (`sandbox:<B>:colab-g4`/`l4`/`t4`), dispatching station_task by short name and
// full id, `back` artifact retrieval + `task.changed` push, withholding/disabling refusal, `revoke` stopping a
// running remote Colab task, `closeSession` cleaning B's isolated sandbox room, and refusal of remote l4es calls.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { COLAB_AUTH_FILE } from "../src/accounts/colab.ts";
import { type SandboxPlace, colabAccountsFor, effectiveSandboxes } from "../src/agents/sandbox.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { Refused, Remote, answerPeer, type PeerCall } from "../src/jobs/remote.ts";
import { bytesOf, withBytes } from "../src/mesh/bus.ts";
import type { Profile } from "../src/sessions/config.ts";
import { type JobRow, type Json, Store } from "../src/store/store.ts";
import { remoteTools } from "../src/tools/remote.ts";
import { killGroups } from "./kill-groups.ts";

const ID_A = "a".repeat(64);
const ID_B = "b".repeat(64);
const WS_HOME = "ws-home";
const WS_JOINED = "ws-joined";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];

after(async () => {
  for (const c of cleanup.reverse()) await c();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempdir(): string {
  const d = mkdtempSync(join(tmpdir(), "colab-mesh-"));
  dirs.push(d);
  return d;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until(check: () => boolean) {
  while (!check()) await sleep(10);
}

const overWire = (request: Json) => {
  const taken = JSON.parse(JSON.stringify(request));
  const bytes = bytesOf(request);
  return bytes === null ? taken : withBytes(taken, bytes);
};

function makeStation(id: string, name: string, workspace: string) {
  const dir = tempdir();
  const store = Store.open(":memory:");
  const told: [string, string][] = [];
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const remote = new Remote({
    data: dir,
    store,
    jobs,
    version: "0.1.99999",
    notify: (session, text) => void told.push([session, text]),
  });
  remote.place = () => ({ station: id, name, workspace, joined: [{ workspace: WS_JOINED }] });
  cleanup.push(async () => {
    await remote.close();
    await jobs.shutdown();
    await killGroups(store.listJobs(null).map((j) => j.pgid));
    store.close();
  });
  return { id, name, dir, store, jobs, remote, told };
}

function wireMesh(a: ReturnType<typeof makeStation>, b: ReturnType<typeof makeStation>) {
  const roster = {
    stations: [
      { id: a.id, name: a.name, version: "0.1.99999" },
      { id: b.id, name: b.name, version: "0.1.99999" },
    ],
  };
  const callFrom = (from: ReturnType<typeof makeStation>, to: ReturnType<typeof makeStation>): PeerCall => async (station, workspace, request) => {
    if (station === "" && request.method === "peers") return roster;
    if (station === to.id) {
      const answer = await answerPeer(to.remote, workspace ?? WS_HOME, from.id, overWire(request));
      if ("error" in answer) throw new Refused(answer.error);
      return answer.result;
    }
    throw new Refused(`unknown station ${station}`);
  };
  a.remote.attach(callFrom(a, b));
  b.remote.attach(callFrom(b, a));
}

function makeColabProfile(dir: string, id: string, opts: { enabled?: boolean; withheld?: string[] } = {}): Profile {
  const home = join(dir, "homes", id);
  mkdirSync(home, { recursive: true });
  writeFileSync(join(home, COLAB_AUTH_FILE), JSON.stringify({ token: "tok", refresh_token: "ref" }));
  return {
    id,
    name: id,
    home,
    runtimes: [],
    models: [],
    named: [],
    backgroundOnMessage: true,
    enabled: opts.enabled ?? true,
    withheld: opts.withheld,
    service: "colab",
    access: { kind: "service", service: "colab" },
  };
}

function callTool(remote: Remote, name: string, session: string, args: Json): Promise<Json> {
  const tool = remoteTools(remote).find((t) => t.name === name)!;
  return tool.run(session, args).then((out) => JSON.parse(out));
}

describe("cross-station Colab sandbox mesh dispatch", () => {
  test("discovers remote Colab sandboxes, dispatches tasks with back + push, enforces withheld/revoke/closeSession, and blocks remote l4es", async () => {
    const a = makeStation(ID_A, "station-a", WS_HOME);
    const b = makeStation(ID_B, "station-b", WS_HOME);
    wireMesh(a, b);

    // Station B has 1 Colab profile + 1 local l4es sandbox; Station A has none.
    let bProfiles: Profile[] = [makeColabProfile(b.dir, "colab-1")];
    const bRawConfig = { sandboxes: [{ name: "l4es-only", target: "{name}.ws@l4es.local" }] };
    const bColabFor = (ws?: string) => colabAccountsFor(bProfiles, ws ?? null, WS_HOME);
    const bSandboxesFor = (ws?: string) => effectiveSandboxes(bRawConfig, bColabFor(ws).length);
    b.remote.setColabAccounts(bColabFor);
    b.remote.setSandboxes(bSandboxesFor);
    b.jobs.setColabAccounts(bColabFor);
    b.jobs.setSandboxes((name, ws) => bSandboxesFor(ws).find((s) => s.name === name) ?? null);

    // Intercept B's job spawn so the test runs commands locally without contacting real Google Colab,
    // while recording the exact SandboxPlace passed to B.jobs.
    const spawnedSandboxes: SandboxPlace[] = [];
    const origSpawn = (b.jobs as any).spawn.bind(b.jobs);
    (b.jobs as any).spawn = async (job: JobRow, restarted: boolean, extra: Record<string, string>) => {
      if (job.sandbox !== undefined) {
        spawnedSandboxes.push(job.sandbox);
        return await origSpawn({ ...job, sandbox: undefined }, restarted, extra);
      }
      return await origSpawn(job, restarted, extra);
    };

    // Create a session on Station A in WS_JOINED (so we can test withheld on WS_JOINED too).
    const sessionWs = join(a.dir, "sessions", "s1");
    mkdirSync(sessionWs, { recursive: true });
    a.store.insertSession({ key: "s1", connect: "ds", runtime: "claude", profile: "cc", workspace: sessionWs, ws: WS_JOINED, token: "t1", createdBy: "ann", createdAt: Date.now(), lastActiveAt: Date.now() });

    // 1. Station A lists stations and discovers B's Colab sandboxes (and NOT B's l4es sandbox).
    const listed = await callTool(a.remote, "station_list", "s1", {});
    const colabEntries = (listed.stations as Json[]).filter((s) => s.sandboxKind === "colab");
    assert.deepEqual(colabEntries.map((s) => s.id).sort(), [
      `sandbox:${ID_B}:colab-g4`,
      `sandbox:${ID_B}:colab-l4`,
      `sandbox:${ID_B}:colab-t4`,
    ]);
    const g4 = colabEntries.find((s) => s.name === "colab-g4")!;
    assert.equal(g4.host, "station-b");
    assert.equal(g4.hostId, ID_B);
    assert.equal(g4.gpu, "G4");
    assert.equal(g4.accounts, 1);
    assert.equal((listed.stations as Json[]).some((s) => s.name === "l4es-only"), false);

    // Single-target station_list on remote sandbox id (including mixed case)
    const detail = await callTool(a.remote, "station_list", "s1", { station: `sandbox:${ID_B}:COLAB-G4` });
    assert.equal(detail.sandboxKind, "colab");
    assert.equal(detail.name, "colab-g4");
    assert.equal(detail.gpu, "G4");
    assert.equal(detail.accounts, 1);

    // 2. Station A dispatches a task by short name ("colab-g4") with `back`, verifies B's SandboxPlace,
    //    `task.changed` push delivery, and `station-back/<key>` download.
    const prep = await callTool(a.remote, "station_task", "s1", {
      station: "colab-g4",
      action: "prepare",
      key: "gpu-job-1",
      name: "gpu render",
      command: "printf 'gpu-result' > out.txt",
      back: ["out.txt"],
    });
    assert.equal(prep.prepared, true);

    const started = await callTool(a.remote, "station_task", "s1", {
      station: "colab-g4",
      action: "start",
      key: "gpu-job-1",
    });
    assert.equal(started.push, true);

    await until(() => a.told.some(([, text]) => text.includes("gpu-job-1") && text.includes("exited")));
    assert.equal(spawnedSandboxes.length, 1);
    assert.deepEqual(spawnedSandboxes[0], {
      sandbox: "colab-g4",
      session: `${ID_A}:s1`,
      back: ["out.txt"],
      workspace: WS_JOINED,
    });
    const backFile = join(sessionWs, "station-back", "gpu-job-1", "out.txt");
    assert.equal(existsSync(backFile), true);
    assert.equal(readFileSync(backFile, "utf8"), "gpu-result");

    // 2b. Explicit mixed-case remote sandbox id (`sandbox:<B>:COLAB-G4`) is canonicalized on the host to `colab-g4`.
    const prepUpper = await callTool(a.remote, "station_task", "s1", {
      station: `sandbox:${ID_B}:COLAB-G4`,
      action: "prepare",
      key: "gpu-job-upper",
      name: "gpu upper",
      command: "printf 'upper-ok'",
    });
    assert.equal(prepUpper.prepared, true);
    await callTool(a.remote, "station_task", "s1", {
      station: `sandbox:${ID_B}:COLAB-G4`,
      action: "start",
      key: "gpu-job-upper",
    });
    await until(() => a.told.some(([, text]) => text.includes("gpu-job-upper") && text.includes("exited")));
    assert.equal(spawnedSandboxes.length, 2);
    assert.equal(spawnedSandboxes[1]!.sandbox, "colab-g4");

    // 3. Attempting to call B's local l4es sandbox remotely is Refused.
    await assert.rejects(
      () => b.remote.handle(WS_JOINED, ID_A, { method: "task.prepare", workspace: WS_JOINED, session: "s1", key: "bad-l4es", sandbox: "l4es-only", spec: { command: "echo hi" } }),
      /cannot be called from another station/,
    );

    // 4. Withholding WS_JOINED on B removes Colab sandboxes from B's describe and refuses new prepare/start.
    bProfiles = [makeColabProfile(b.dir, "colab-1", { withheld: [WS_JOINED] })];
    const listedAfterWithhold = await callTool(a.remote, "station_list", "s1", {});
    assert.equal((listedAfterWithhold.stations as Json[]).some((s) => s.sandboxKind === "colab"), false);
    await assert.rejects(
      () => b.remote.handle(WS_JOINED, ID_A, { method: "task.prepare", workspace: WS_JOINED, session: "s1", key: "blocked-1", sandbox: "colab-g4", spec: { command: "echo hi" } }),
      /not available for this workspace/,
    );

    // Re-enable for WS_JOINED to test revoke and closeSession.
    bProfiles = [makeColabProfile(b.dir, "colab-1")];
    await callTool(a.remote, "station_task", "s1", {
      station: `sandbox:${ID_B}:colab-g4`,
      action: "prepare",
      key: "long-gpu-job",
      name: "long gpu",
      command: "tail -f /dev/null",
    });
    await callTool(a.remote, "station_task", "s1", {
      station: `sandbox:${ID_B}:colab-g4`,
      action: "start",
      key: "long-gpu-job",
    });
    await until(() => b.store.jobsUp().length === 1);

    // 5. Revoking Station A from WS_JOINED on B stops A's running Colab task on B.
    await b.remote.revoke([{ workspace: WS_HOME, peers: [ID_A] }, { workspace: WS_JOINED, peers: [] }], true);
    await until(() => b.store.jobsUp().length === 0);

    // 6. closeSession on A sends session.close to `sandbox:<B>:colab-g4` and removes B's sandbox session room.
    const sessionsDir = join(b.dir, "remote", "sessions");
    assert.ok(readdirSync(sessionsDir).length > 0);
    await a.remote.closeSession("s1");
    await until(() => readdirSync(sessionsDir).length === 0);
    assert.equal(readdirSync(sessionsDir).length, 0);
  });
});
