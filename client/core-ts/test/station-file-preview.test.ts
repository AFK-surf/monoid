// A chat's image opened whole-window (station.file `preview`, station/calls.ts): its station's preview first (thumb=2),
// kept on the device and answered from there after; the image itself only where it is kept whole already, or where the
// station answers with it (a station from before thumb=2, or one that made no preview: its bytes are the image's
// size), and then kept as it is, never asked for again; one of PREVIEW_SMALL or less read as it was, by its parts.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import type { FakeHost } from "../src/testing.ts";
import { PREVIEW_SMALL, chatKeptId, previewKeptId } from "../src/drive-kept.ts";
import { BULK } from "../src/station/requests.ts";
import { StationAddr } from "../src/station/addr.ts";
import { HostWire, type StationWire } from "../src/station/wire.ts";
import { call } from "./helpers.ts";
import { Raw, started, stationReplies } from "./station-fixture.ts";

const ST = "ws/st";
const bytesOf = (n: number, from = 0) => Uint8Array.from({ length: n }, (_, i) => (from + i) % 251);

/// The session `k1`'s images by name, each with the preview its station makes (none: the image itself, as a station
/// from before answers thumb=2); `requests` lists what was asked of it (`files?thumb=2`, `parts`).
function station(host: FakeHost, images: Map<string, { bytes: Uint8Array; preview: Uint8Array | null }>) {
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
      asked.push(`parts ${name}`);
      const offset = Number(u.searchParams.get("offset"));
      const body = image.bytes.slice(offset, offset + Number(u.searchParams.get("length")));
      return new Raw({ status: 200, headers: [["content-type", "image/png"], ["stillfail-total", String(image.bytes.length)]], body });
    }
    return undefined;
  });
  return asked;
}

async function rig(images: Map<string, { bytes: Uint8Array; preview: Uint8Array | null }>) {
  const t = await started();
  const asked = station(t.host, images);
  const ui = t.core.connect();
  let n = 100;
  const ask = async (name: string, params: Record<string, unknown>) => {
    const id = ++n;
    call(t.core, ui, id, name, params);
    await t.host.settle();
    for (const [, m] of t.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if (msg.id === id && ("ok" in msg || "error" in msg)) return msg as { ok: { type: string; preview?: true }; bytes: Uint8Array };
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
  assert.deepEqual(r.asked, ["files shot.png thumb=2"]);
  await r.host.settle();
  assert.deepEqual((await r.kept(previewKeptId(ST, "k1", "shot.png")))?.bytes, preview);
  // Kept among the files, not as the chat's file itself.
  assert.equal(await r.kept(chatKeptId(ST, "k1", "shot.png")), null);
  // Opened again: from the device.
  const again = await r.open("shot.png", image.length);
  assert.deepEqual([again.ok, again.bytes], [{ type: "image/jpeg", preview: true }, preview]);
  assert.deepEqual(r.asked, ["files shot.png thumb=2"]);
  // Zoomed in (or saved): the image itself, a part at a time, kept with its chat.
  const whole = await r.open("shot.png", image.length, false);
  assert.deepEqual([whole.ok, whole.bytes.length], [{ type: "image/png" }, image.length]);
  assert.deepEqual(r.asked, ["files shot.png thumb=2", "parts shot.png"]);
  // Opened after: the image itself, from the device; the station asked nothing more.
  const after = await r.open("shot.png", image.length);
  assert.deepEqual([after.ok, after.bytes], [{ type: "image/png" }, image]);
  assert.deepEqual(r.asked, ["files shot.png thumb=2", "parts shot.png"]);
  r.core.close();
});

test("a station from before (or one that made no preview) answers with the image itself: kept whole, never asked again", async () => {
  const image = bytesOf(1_000_000, 3);
  const r = await rig(new Map([["old.png", { bytes: image, preview: null }]]));
  const first = await r.open("old.png", image.length);
  assert.deepEqual([first.ok, first.bytes], [{ type: "image/png" }, image]);
  await r.host.settle();
  assert.deepEqual((await r.kept(chatKeptId(ST, "k1", "old.png")))?.bytes, image);
  assert.equal(await r.kept(previewKeptId(ST, "k1", "old.png")), null);
  // Zoomed, saved or opened again: all from the device.
  assert.deepEqual((await r.open("old.png", image.length, false)).bytes, image);
  assert.deepEqual((await r.open("old.png", image.length)).bytes, image);
  assert.deepEqual(r.asked, ["files old.png thumb=2"]);
  r.core.close();
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
