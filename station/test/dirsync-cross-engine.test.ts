// Cross-engine directory sync tests (`mb` source -> `pion` target and `pion` source -> `mb` target).
// Kept separate from `mb-dirsync.test.ts` so forced-Pion CI gates (`STILLFAIL_REQUIRE_PION_SESSIONS=1`)
// do not reject the explicit MB end, while dual-engine gates (`STILLFAIL_REQUIRE_DUAL_READER=1`) run
// this file strictly 0-skip and verify both spawned engines and distinct PIDs.
import assert from "node:assert/strict";
import { chmodSync, existsSync, lstatSync, mkdirSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, test } from "node:test";
import { type SessionsSpawnEvent, setSessionsSpawnObserverForTest } from "../src/agents/mb-program.ts";
import { mbReaderBinary, pionBinary } from "../src/read/mb-reader.ts";
import { pair, tempdir } from "./dirsync-pair.ts";

function dataArgOf(argv: readonly string[]): string | null {
  const idx = argv.indexOf("--data");
  return idx >= 0 && idx + 1 < argv.length ? resolve(argv[idx + 1]!) : null;
}

describe("cross-engine dirsync (MoonBit <-> Pion)", () => {
  for (const [sourceEngine, targetEngine] of [["mb", "pion"], ["pion", "mb"]] as const) {
    test(`${sourceEngine} source -> ${targetEngine} target: engine/PID verification, regular/symlink same-hash switch, zero-upload regular->exec reuse, and remove`, async (t) => {
      const mbBin = mbReaderBinary();
      const pionBin = pionBinary();
      if (mbBin === null || pionBin === null) {
        if (process.env.STILLFAIL_REQUIRE_DUAL_READER === "1") {
          assert.fail("both stillfail-reader and stillfail-pion are required");
        }
        t.skip("both stillfail-reader and stillfail-pion are required for cross-engine dirsync");
        return;
      }
      assert.notEqual(realpathSync(mbBin), realpathSync(pionBin), "MB and Pion binaries must be distinct");

      const spawns: SessionsSpawnEvent[] = [];
      setSessionsSpawnObserverForTest((ev) => {
        spawns.push(ev);
      });
      try {
        const p = await pair({ sourceEngine, targetEngine });
        const dir = join(tempdir(), `cross-${sourceEngine}-${targetEngine}`);
        mkdirSync(dir);
        writeFileSync(join(dir, "target.txt"), "hello\n");
        writeFileSync(join(dir, "same"), "target.txt");
        const r1 = await p.run("c1", dir, "true");
        const m = p.mirror(`cross-${sourceEngine}-${targetEngine}`);
        assert.equal(r1.sync.written, 2);
        assert.ok(!lstatSync(join(m, "same")).isSymbolicLink());

        // Verify both sides actually spawned the requested engine with distinct live PIDs.
        const aDir = resolve(p.a.dir);
        const bDir = resolve(p.b.dir);
        const aReady = spawns.find((e) => e.ready && dataArgOf(e.argv) === aDir);
        const bReady = spawns.find((e) => e.ready && dataArgOf(e.argv) === bDir);
        assert.ok(aReady, `expected ready spawn for source (${aDir}), saw ${JSON.stringify(spawns)}`);
        assert.ok(bReady, `expected ready spawn for target (${bDir}), saw ${JSON.stringify(spawns)}`);
        assert.equal(aReady.engine, sourceEngine, "source engine mismatch");
        assert.equal(bReady.engine, targetEngine, "target engine mismatch");
        assert.equal(aReady.fallback, false, "source must not fall back");
        assert.equal(bReady.fallback, false, "target must not fall back");
        assert.equal(realpathSync(aReady.binary), realpathSync(sourceEngine === "mb" ? mbBin : pionBin));
        assert.equal(realpathSync(bReady.binary), realpathSync(targetEngine === "mb" ? mbBin : pionBin));
        assert.ok(typeof aReady.pid === "number" && aReady.pid > 0, `invalid source pid: ${aReady.pid}`);
        assert.ok(typeof bReady.pid === "number" && bReady.pid > 0, `invalid target pid: ${bReady.pid}`);
        assert.notEqual(aReady.pid, bReady.pid, "source and target must run in distinct processes");

        // Standalone zero-upload regular -> exec reuse batch (no symlink in batch)
        writeFileSync(join(dir, "exec-only"), "target.txt");
        chmodSync(join(dir, "exec-only"), 0o755);
        const rExec = await p.run("c1-exec", dir, "true");
        assert.equal(rExec.sync.sent.files, 0, "exec file with same hash as existing regular file uploads 0 blobs");
        assert.ok(!lstatSync(join(m, "exec-only")).isSymbolicLink());
        assert.ok((lstatSync(join(m, "exec-only")).mode & 0o100) !== 0);

        // Add symlink with identical hash (must NOT cross-reuse regular file -> 1 blob uploaded)
        symlinkSync("target.txt", join(dir, "link-same"));
        const r2 = await p.run("c2", dir, "true");
        assert.equal(r2.sync.sent.files, 1);
        assert.ok(lstatSync(join(m, "link-same")).isSymbolicLink());
        assert.equal(readlinkSync(join(m, "link-same")), "target.txt");

        // Flip link <-> file & remove
        rmSync(join(dir, "same"));
        symlinkSync("target.txt", join(dir, "same"));
        rmSync(join(dir, "exec-only"));
        const r3 = await p.run("c3", dir, "true");
        assert.equal(r3.sync.removed, 1);
        assert.ok(lstatSync(join(m, "same")).isSymbolicLink());
        assert.equal(readlinkSync(join(m, "same")), "target.txt");
        assert.ok(!existsSync(join(m, "exec-only")));
      } finally {
        setSessionsSpawnObserverForTest(null);
      }
    });
  }
});
