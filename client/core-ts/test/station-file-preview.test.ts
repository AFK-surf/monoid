// A chat's image opened whole-window (station.file `preview`, station/calls.ts): its station's preview first (thumb=2),
// kept on the device and answered from there after; the image itself only where it is kept whole already, or where the
// station answers with it (a station from before thumb=2, or one that made no preview: its bytes are the image's
// size), and then kept as it is, never asked for again; one of PREVIEW_SMALL or less read as it was, by its parts.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { CoreError, type HostError } from "../src/error.ts";
import type { FakeHost } from "../src/testing.ts";
import { PREVIEW_SMALL, chatKeptId, previewKeptId } from "../src/drive-kept.ts";
import { BULK } from "../src/station/requests.ts";
import { StationAddr } from "../src/station/addr.ts";
import { HostWire, type StationWire, type WireReply } from "../src/station/wire.ts";
import { call } from "./helpers.ts";
import { Raw, started, stationReplies } from "./station-fixture.ts";

const ST = "ws/st";
const bytesOf = (n: number, from = 0) => Uint8Array.from({ length: n }, (_, i) => (from + i) % 251);
/// Bytes no compression makes smaller (a preview's, as a JPEG's are): a wire broken off after so many of them has
/// brought that many.
const noise = (n: number, seed: number) => {
  let x = seed >>> 0 || 1;
  return Uint8Array.from({ length: n }, () => ((x = (Math.imul(x, 1664525) + 1013904223) >>> 0) >>> 24));
};

/// The session `k1`'s images by name, each with the preview its station makes (none: the image itself, as a station
/// from before answers thumb=2); `requests` lists what was asked of it (`files?thumb=2`, `parts`, `parts?thumb=2` with
/// its offset). `old`: a station from before preview parts (it reads `parts` as the image's, saying nothing of a preview).
function station(host: FakeHost, images: Map<string, { bytes: Uint8Array; preview: Uint8Array | null }>, old = false) {
  const asked: string[] = [];
  stationReplies(host, (req) => {
    const u = new URL(req.url);
    const name = u.searchParams.get("name") ?? "";
    const image = images.get(name);
    if (image === undefined) return undefined;
    if (u.pathname.endsWith("/sessions/k1/files")) {
      const thumb = u.searchParams.get("thumb");
      asked.push(`files ${name}${thumb ? ` thumb=${thumb}` : ""}`);
      const body = thumb === "2" && image.preview !== null ? image.preview : image.bytes;
      return new Raw({ status: 200, headers: [["content-type", body === image.bytes ? "image/png" : "image/jpeg"], ["content-length", String(body.length)]], body });
    }
    if (u.pathname.endsWith("/sessions/k1/parts")) {
      const offset = Number(u.searchParams.get("offset"));
      const previewed = u.searchParams.get("thumb") === "2" && !old;
      asked.push(previewed ? `parts ${name} thumb=2 @${offset}` : `parts ${name}`);
      const of = previewed && image.preview !== null ? image.preview : image.bytes;
      const body = of.slice(offset, offset + Number(u.searchParams.get("length")));
      const said: [string, string][] = previewed ? [["stillfail-preview", image.preview !== null ? "5" : "0"]] : [];
      return new Raw({ status: 200, headers: [["content-type", of === image.bytes ? "image/png" : "image/jpeg"], ["stillfail-total", String(of.length)], ...said] , body });
    }
    return undefined;
  });
  return asked;
}

/// A wire whose answers to preview parts break off after `after` bytes while `cuts` says so (each one cut takes one).
function cutting(cuts: { left: number; after: number }) {
  return (host: FakeHost): StationWire => {
    const fallback = new HostWire(host);
    return {
      request: (st, head, body) => {
        if (!head.path.includes("/parts?") || !head.path.includes("thumb=2") || cuts.left <= 0) return fallback.request(st, head, body);
        cuts.left--;
        return Effect.map(fallback.request(st, head, body), (reply) => {
          let sent = false;
          return {
            ...reply,
            // (broken off as the mesh's wire says it: its pull fails with the core's error, mesh-wire.ts `mesh.cut`)
            body: {
              take: Effect.suspend((): Effect.Effect<Uint8Array | null, HostError | CoreError> => {
                if (sent) return Effect.fail(new CoreError("mesh", "broken off"));
                sent = true;
                return Effect.map(reply.body.take, (chunk) => (chunk === null ? null : chunk.slice(0, cuts.after)));
              }),
            } as WireReply["body"],
          };
        });
      },
    };
  };
}

async function rig(images: Map<string, { bytes: Uint8Array; preview: Uint8Array | null }>, old = false, wire?: (host: FakeHost) => StationWire) {
  const t = await started(undefined, 0, wire);
  const asked = station(t.host, images, old);
  const ui = t.core.connect();
  let n = 100;
  const ask = async (name: string, params: Record<string, unknown>) => {
    const id = ++n;
    call(t.core, ui, id, name, params);
    await t.host.settle();
    for (const [, m] of t.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if (msg.id === id && ("ok" in msg || "error" in msg)) return msg as { ok: { type: string; preview?: true }; bytes: Uint8Array; error?: { code: string } };
    }
    throw new Error(`${name}: no answer`);
  };
  const open = (name: string, size: number, preview = true) => ask("station.file", { station: ST, key: "k1", name, keep: true, size, ...(preview ? { preview: true } : {}) });
  const kept = (id: string) => Effect.runPromise(t.core.inner.driveKept.held(id));
  return { ...t, asked, open, kept };
}

test("a big image opens as its station's preview, kept; zoomed, the image itself, which is what opens it after", async () => {
  const image = bytesOf(3_000_000, 1);
  const preview = bytesOf(400_000, 7);
  const r = await rig(new Map([["shot.png", { bytes: image, preview }]]));
  const first = await r.open("shot.png", image.length);
  assert.deepEqual(first.ok, { type: "image/jpeg", preview: true });
  assert.deepEqual(first.bytes, preview);
  assert.deepEqual(r.asked, ["parts shot.png thumb=2 @0"]);
  await r.host.settle();
  assert.deepEqual((await r.kept(previewKeptId(ST, "k1", "shot.png")))?.bytes, preview);
  // Kept among the files, not as the chat's file itself.
  assert.equal(await r.kept(chatKeptId(ST, "k1", "shot.png")), null);
  // Opened again: from the device.
  const again = await r.open("shot.png", image.length);
  assert.deepEqual([again.ok, again.bytes], [{ type: "image/jpeg", preview: true }, preview]);
  assert.deepEqual(r.asked, ["parts shot.png thumb=2 @0"]);
  // Zoomed in (or saved): the image itself, a part at a time, kept with its chat.
  const whole = await r.open("shot.png", image.length, false);
  assert.deepEqual([whole.ok, whole.bytes.length], [{ type: "image/png" }, image.length]);
  assert.deepEqual(r.asked, ["parts shot.png thumb=2 @0", "parts shot.png"]);
  // Opened after: the image itself, from the device; the station asked nothing more.
  const after = await r.open("shot.png", image.length);
  assert.deepEqual([after.ok, after.bytes], [{ type: "image/png" }, image]);
  assert.deepEqual(r.asked, ["parts shot.png thumb=2 @0", "parts shot.png"]);
  r.core.close();
});

for (const old of [false, true]) {
  test(`${old ? "a station from before preview parts" : "a station that made no preview"} answers with the image itself: kept whole, never asked again`, async () => {
    const image = bytesOf(1_000_000, 3);
    const r = await rig(new Map([["old.png", { bytes: image, preview: null }]]), old);
    const first = await r.open("old.png", image.length);
    assert.deepEqual([first.ok, first.bytes], [{ type: "image/png" }, image]);
    await r.host.settle();
    assert.deepEqual((await r.kept(chatKeptId(ST, "k1", "old.png")))?.bytes, image);
    assert.equal(await r.kept(previewKeptId(ST, "k1", "old.png")), null);
    // Zoomed, saved or opened again: all from the device.
    assert.deepEqual((await r.open("old.png", image.length, false)).bytes, image);
    assert.deepEqual((await r.open("old.png", image.length)).bytes, image);
    assert.deepEqual(r.asked, [old ? "parts old.png" : "parts old.png thumb=2 @0"]);
    r.core.close();
  });
}

test("a station from before preview parts: its previews read whole from then on, as before", async () => {
  const image = bytesOf(9_000_000, 1);
  const preview = bytesOf(400_000, 7);
  const other = bytesOf(5_000_000, 2);
  const r = await rig(new Map([["shot.png", { bytes: image, preview }], ["two.png", { bytes: other, preview }]]), true);
  const first = await r.open("shot.png", image.length);
  assert.deepEqual([first.ok, first.bytes], [{ type: "image/jpeg", preview: true }, preview]);
  // (the image's first part it answered kept with its chat: not asked again as it is zoomed into)
  assert.deepEqual(r.asked, ["parts shot.png", "files shot.png thumb=2"]);
  const two = await r.open("two.png", other.length);
  assert.deepEqual([two.ok, two.bytes], [{ type: "image/jpeg", preview: true }, preview]);
  assert.deepEqual(r.asked, ["parts shot.png", "files shot.png thumb=2", "files two.png thumb=2"]);
  r.core.close();
});

/// Where each preview part asked began, as `asked` says it.
const offsets = (asked: string[]) => asked.map((a) => Number(/@(\d+)$/.exec(a)?.[1] ?? NaN));

test("a preview broken off as it comes goes on from where it stopped: within its read, and opened again after it failed", async () => {
  const image = bytesOf(9_000_000, 1);
  const preview = noise(1_000_000, 7);
  const pid = previewKeptId(ST, "k1", "shot.png");
  // Broken off after 300 KB of its answer once (what of it came through the wire's compression: 256 KB, a whole
  // block): the read itself goes on from there, nothing asked twice.
  const once = { left: 1, after: 300_000 };
  const a = await rig(new Map([["shot.png", { bytes: image, preview }]]), false, cutting(once));
  const got = await a.open("shot.png", image.length);
  assert.deepEqual([got.ok, got.bytes], [{ type: "image/jpeg", preview: true }, preview]);
  const [start, on] = offsets(a.asked);
  assert.equal(a.asked.length, 2);
  assert.equal(start, 0);
  assert.ok(on! > 0 && on! <= 300_000, `went on from ${on}`);
  a.core.close();
  // Broken off each time it is tried (the read and its two tries more): the open fails, what came kept; opened
  // again, only the rest is asked.
  const always = { left: 3, after: 300_000 };
  const b = await rig(new Map([["shot.png", { bytes: image, preview }]]), false, cutting(always));
  const failed = await b.open("shot.png", image.length);
  assert.equal(failed.error?.code, "mesh");
  const tried = offsets(b.asked);
  assert.equal(tried.length, 3);
  assert.ok(tried[0] === 0 && tried[1]! > 0 && tried[2]! > tried[1]!, `tried from ${tried}`);
  await b.host.settle();
  const kept = await Effect.runPromise(b.core.inner.driveKept.from(pid, 5, preview.length, 0, preview.length));
  assert.ok(kept !== null && kept.bytes.length > tried[2]!, "what came of each try kept");
  assert.deepEqual(kept.bytes, preview.slice(0, kept.bytes.length));
  const again = await b.open("shot.png", image.length);
  assert.deepEqual([again.ok, again.bytes], [{ type: "image/jpeg", preview: true }, preview]);
  assert.deepEqual(offsets(b.asked.slice(3)), [kept.bytes.length]);
  // Kept whole now: opened again, from the device.
  assert.deepEqual((await b.open("shot.png", image.length)).bytes, preview);
  assert.equal(b.asked.length, 4);
  b.core.close();
});

test("an image of PREVIEW_SMALL or less is read as it was: by its parts, no preview asked", async () => {
  const image = bytesOf(PREVIEW_SMALL, 5);
  const r = await rig(new Map([["small.png", { bytes: image, preview: bytesOf(10) }]]));
  const got = await r.open("small.png", image.length);
  assert.deepEqual([got.ok, got.bytes], [{ type: "image/png" }, image]);
  assert.deepEqual(r.asked, ["parts small.png"]);
  r.core.close();
});

test("requests.file marks preview (thumb=2) and full file with BULK header, but not small thumbnail (thumb=1)", async () => {
  const image = bytesOf(3_000_000, 1);
  const preview = bytesOf(400_000, 7);
  const seen: { path: string; bulk: string | undefined }[] = [];
  const t = await started(undefined, 0, (host): StationWire => {
    const fallback = new HostWire(host);
    return {
      request: (st, head, body) => {
        if (head.path.includes("/sessions/k1/files")) {
          seen.push({ path: head.path, bulk: head.headers.find(([k]) => k.toLowerCase() === BULK)?.[1] });
        }
        return fallback.request(st, head, body);
      },
    };
  });
  station(t.host, new Map([["shot.png", { bytes: image, preview }]]));
  const addr = StationAddr.parse(ST);
  await Effect.runPromise(t.core.inner.stations.requests.file(addr, "k1", "shot.png", "preview", () => {}, null));
  await Effect.runPromise(t.core.inner.stations.requests.file(addr, "k1", "shot.png", false, () => {}, null));
  await Effect.runPromise(t.core.inner.stations.requests.file(addr, "k1", "shot.png", true, () => {}, null));
  assert.deepEqual(seen, [
    { path: "/admin/api/sessions/k1/files?name=shot.png&thumb=2", bulk: "1" },
    { path: "/admin/api/sessions/k1/files?name=shot.png", bulk: "1" },
    { path: "/admin/api/sessions/k1/files?name=shot.png&thumb=1", bulk: undefined },
  ]);
  t.core.close();
});
