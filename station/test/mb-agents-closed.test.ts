// A process started for a driver whose program host was let go meanwhile (mb-agents.ts `HostedProcess.start`): its
// drivers shut down while a session was being opened, as a Codex turn's nudge was as hub-e2e.test.ts's station shut
// down (2026-11-16, CI of #6583: the program started for it held the test file's process open past CI's limit, its
// runner and app-server left running). Nothing is left of it: no program, no runner.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentsHost, HostedProcess, type HostedOptions } from "../src/agents/mb-agents.ts";
import { sessionsBinaryAvailable } from "../src/agents/mb-program.ts";
import { liveRunners } from "../src/agents/runner.ts";

const skip = (process.platform === "win32" && "runner-windows.test.ts starts Windows' runners") || (!sessionsBinaryAvailable() && "no stillfail-reader/stillfail-pion built");
const options: HostedOptions = { label: "test", kind: "dsh", heard: () => {}, exit: () => {} };
/// A process that runs until it is ended.
const forever = [process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"]] as const;

for (const when of ["before it is started", "as it is started"] as const) {
  test(`its host let go ${when}: the process is not left running, nor a program for it`, { skip }, async () => {
    // Short: a runner's socket is under it (104 bytes at most on macOS).
    const data = mkdtempSync(process.platform === "darwin" ? "/tmp/mbc-" : join(tmpdir(), "mbc-"));
    try {
      const host = AgentsHost.where(data);
      const driver = {};
      host.use(driver);
      if (when === "before it is started") await host.close(driver);
      const started = HostedProcess.start(host, data, "dsh-x", forever[0], [...forever[1]], { ...process.env } as Record<string, string>, data, options, null);
      // (let go in the same turn: its start is on its way, its runner starting or about to)
      if (when === "as it is started") await host.close(driver);
      await assert.rejects(started, /not started: the station's agents were let go/);
      assert.equal(host.program(), null, "no program started for it");
      assert.deepEqual((await liveRunners(data)).map((r) => r.id), [], "its runner ended");
    } finally {
      rmSync(data, { recursive: true, force: true });
    }
  });
}
