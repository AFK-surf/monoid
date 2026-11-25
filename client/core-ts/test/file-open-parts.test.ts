// A file a message names, read whole (`file.open`, station/calls.ts `openParts`): a part at a time, each kept as it
// comes, so a read broken off goes on from what came of it, never from its start; a station from before parts by
// path answers the whole, kept as before.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import type { FakeHost } from "../src/testing.ts";
import { CoreError, type HostError } from "../src/error.ts";
import { openKeptId } from "../src/drive-kept.ts";
import { HostWire, type StationWire, type WireReply } from "../src/station/wire.ts";
import { call } from "./helpers.ts";
import { Raw, started, stationReplies } from "./station-fixture.ts";

const ST = "ws/st";
const MB = 1024 * 1024;
const bytesOf = (n: number, from = 0) => Uint8Array.from({ length: n }, (_, i) => (from + i) % 251);

/// The session `k1`'s file `out/report.pdf`, version 7; `asked` lists the offsets of what was asked of it (`whole`: the
/// whole). `old`: a station from before parts by path (it answers the whole whatever is asked).
function station(host: FakeHost, file: Uint8Array, old = false) {
  const asked: string[] = [];
  stationReplies(host, (req) => {
    const u = new URL(req.url);
    if (!u.pathname.endsWith("/sessions/k1/open") || u.searchParams.get("path") !== "out/report.pdf") return undefined;
    const offset = u.searchParams.get("offset");
    const ranged = offset !== null && !old;
    asked.push(ranged ? `@${offset}` : "whole");
    const body = ranged ? file.slice(Number(offset), Number(offset) + Number(u.searchParams.get("length"))) : file;
    const headers: [string, string][] = [["content-type", "application/pdf"], ["stillfail-name", "report.pdf"], ["stillfail-path", "out%2Freport.pdf"], ["stillfail-mtime", "7"]];
    if (ranged) headers.push(["stillfail-total", String(file.length)]);
    return new Raw({ status: 200, headers, body });
  });
  return asked;
}

/// A wire whose answers to the parts at `at` break off (each one cut takes one of `left`).
function cutting(cuts: { at: string; left: number }) {
  return (host: FakeHost): StationWire => {
    const fallback = new HostWire(host);
    return {
      request: (st, head, body) => {
        if (!head.path.includes("/open?") || !head.path.includes(`offset=${cuts.at}&`) || cuts.left <= 0) return fallback.request(st, head, body);
        cuts.left--;
        return Effect.map(fallback.request(st, head, body), (reply) => ({
          ...reply,
          // (broken off as the mesh's wire says it: mesh-wire.ts `mesh.cut`)
          body: { take: Effect.fail(new CoreError("mesh", "broken off")) as Effect.Effect<Uint8Array | null, HostError | CoreError> } as WireReply["body"],
        }));
      },
    };
  };
}

async function rig(file: Uint8Array, old = false, wire?: (host: FakeHost) => StationWire) {
  const t = await started(undefined, 0, wire);
  const asked = station(t.host, file, old);
  const ui = t.core.connect();
  let n = 100;
  const open = async () => {
    const id = ++n;
    call(t.core, ui, id, "file.open", { station: ST, key: "k1", path: "out/report.pdf" });
    await t.host.settle();
    for (const [, m] of t.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if (msg.id === id && ("ok" in msg || "error" in msg)) return msg as { ok?: { size: number; type: string }; bytes?: Uint8Array; error?: { code: string } };
    }
    throw new Error("file.open: no answer");
  };
  return { ...t, asked, open };
}

test("a file a message names read whole comes a part at a time, each kept", async () => {
  const file = bytesOf(Math.round(2.5 * MB), 3);
  const r = await rig(file);
  const got = await r.open();
  assert.deepEqual([got.ok?.size, got.ok?.type, got.bytes], [file.length, "application/pdf", file]);
  assert.deepEqual(r.asked, ["@0", `@${MB}`, `@${2 * MB}`]);
  await r.host.settle();
  assert.deepEqual((await Effect.runPromise(r.core.inner.driveKept.held(openKeptId(ST, "k1", "out/report.pdf"))))?.bytes, file);
  r.core.close();
});

test("one broken off goes on from what came of it, within its read and opened again after it failed", async () => {
  const file = bytesOf(Math.round(3.5 * MB), 5);
  // Broken off once at 2 MB: the read itself goes on from there.
  const a = await rig(file, false, cutting({ at: String(2 * MB), left: 1 }));
  assert.deepEqual((await a.open()).bytes, file);
  assert.deepEqual(a.asked, ["@0", `@${MB}`, `@${2 * MB}`, `@${2 * MB}`, `@${3 * MB}`]);
  a.core.close();
  // Broken off there each time it is tried: it fails, what came kept; opened again, only the rest is asked.
  const b = await rig(file, false, cutting({ at: String(2 * MB), left: 3 }));
  assert.equal((await b.open()).error?.code, "mesh");
  assert.deepEqual(b.asked, ["@0", `@${MB}`, `@${2 * MB}`, `@${2 * MB}`, `@${2 * MB}`]);
  await b.host.settle();
  assert.deepEqual((await b.open()).bytes, file);
  assert.deepEqual(b.asked.slice(5), [`@${2 * MB}`, `@${3 * MB}`]);
  b.core.close();
});

test("a station from before parts by path answers the whole: taken as it is, kept, asked once", async () => {
  const file = bytesOf(Math.round(2.5 * MB), 9);
  const r = await rig(file, true);
  const got = await r.open();
  assert.deepEqual([got.ok?.size, got.bytes], [file.length, file]);
  assert.deepEqual(r.asked, ["whole"]);
  await r.host.settle();
  assert.deepEqual((await Effect.runPromise(r.core.inner.driveKept.held(openKeptId(ST, "k1", "out/report.pdf"))))?.bytes, file);
  r.core.close();
});
