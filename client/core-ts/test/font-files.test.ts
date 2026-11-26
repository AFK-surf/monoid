// A face's files kept by the core for an app that keeps none (src/font-files.ts, sf/faces.mbt): fetched in parts, how
// far said each percent; kept by hash, gzipped as fetched, then as the app unzipped them; every face fetched stays;
// previews fetched once.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { Deferred, Effect, Fiber } from "effect";
import { HostError } from "../src/error.ts";
import { FontFiles } from "../src/font-files.ts";
import * as fonts from "../src/fonts.ts";
import { parseCall } from "../src/core/calls.ts";
import { SHARE_LOOKS_FILES } from "../src/share-looks.ts";
import { holdLanguage } from "../src/i18n.ts";
import type { Beside } from "../src/protocol.ts";
import type { Store } from "../src/store.ts";
import { FakeHost } from "../src/testing.ts";
import { run } from "./run.ts";

holdLanguage();

const ORIGIN = "https://stillfail.test";

function rig() {
  const host = new FakeHost();
  host.origin = ORIGIN;
  fonts.setOrigin(ORIGIN);
  let changed = 0;
  const store = { invalidate: () => void changed++ } as unknown as Store;
  const files = new FontFiles(host, store);
  const seen: unknown[] = [];
  const said = () => (files.compute() as { ok: unknown }).ok;
  // each file in parts of a tenth of the face, failing where `refuse` says
  const refuse = new Set<string>();
  // the share card's looks' files the site answers, in parts of 64 KB: none (a site that has not got them answers its page)
  const site = new Map<string, Uint8Array>();
  host.onFetchStream((req) =>
    Effect.sync(() => {
      if (req.url.startsWith(`${ORIGIN}/share-looks/`)) {
        const file = site.get(req.url.slice(`${ORIGIN}/share-looks/`.length)) ?? new TextEncoder().encode("<!doctype html><title>still.fail</title>");
        let at = 0;
        const parts = {
          take: Effect.sync(() => {
            seen.push(said());
            if (at >= file.length) return null;
            const part = file.slice(at, at + 65536);
            at += part.length;
            return part;
          }),
        };
        return { status: refuse.has(req.url) ? 503 : 200, headers: [] as [string, string][], body: parts };
      }
      const f = ["inter", "lxgw-wenkai"].flatMap((id) => fonts.faceOf(id)!.files).find((x) => x.url === req.url)!;
      if (refuse.has(req.url)) return { status: 503, headers: [] as [string, string][], body: { take: Effect.succeed(null) } };
      const whole = fonts.faceOf(f.url.includes("/inter/") ? "inter" : "lxgw-wenkai")!.bytes;
      const part = Math.ceil(whole / 10);
      let left = f.bytes;
      return {
        status: 200,
        headers: [] as [string, string][],
        body: {
          take: Effect.sync(() => {
            seen.push(said());
            if (left === 0) return null;
            const n = Math.min(part, left);
            left -= n;
            return new Uint8Array(n).fill(7);
          }),
        },
      };
    }),
  );
  return { host, files, seen, said, refuse, site, changed: () => changed };
}

test("a face's files are fetched once, how far said as they come, kept gzipped until the app keeps them unzipped", async () => {
  const r = rig();
  const face = fonts.faceOf("lxgw-wenkai")!;
  assert.equal(face.files.length, 2);
  assert.equal(await run(r.files.fetch("lxgw-wenkai")), null);
  // how far, by what of the face came (its two files one after the other), each percent once
  const far = r.seen.map((s) => (s as { fetching: Record<string, number> }).fetching["lxgw-wenkai"]);
  assert.equal(far[0], 0);
  assert.deepEqual(far, [...far].sort((a, b) => a - b));
  assert.ok(far.some((p) => p > 0.4 && p < 0.6), JSON.stringify(far));
  assert.deepEqual(r.said(), { fetching: {}, failed: {}, kept: ["lxgw-wenkai"], share: {}, shareFailed: {} });
  // kept as fetched
  const first = (await run(r.files.file(face.files[0].sha256))) as Beside;
  assert.deepEqual(first.value, { zipped: true });
  assert.equal(first.bytes.length, face.files[0].bytes);
  // the app's unzipped one kept instead
  assert.equal(await run(r.files.keep(face.files[0].sha256, new Uint8Array([1, 2, 3]))), null);
  const now = (await run(r.files.file(face.files[0].sha256))) as Beside;
  assert.deepEqual([now.value, [...now.bytes]], [{ zipped: false }, [1, 2, 3]]);
  // fetched again: nothing asked for, what is kept is kept
  const asked = r.host.requests.length;
  await run(r.files.fetch("lxgw-wenkai"));
  assert.equal(r.host.requests.length, asked);
  assert.deepEqual((await run(r.files.file(face.files[0].sha256)) as Beside).value, { zipped: false });
  // a file not kept, a face not there
  await assert.rejects(run(r.files.file("00")));
  await assert.rejects(run(r.files.keep("00", new Uint8Array([1]))));
  await assert.rejects(run(r.files.fetch("comic-sans")));
});

test("where a file is kept, on a host that keeps values as files; its bytes still given by the call", async () => {
  const r = rig();
  const first = fonts.faceOf("lxgw-wenkai")!.files[0];
  // a host without files: nowhere
  assert.equal(r.files.at(first.sha256), null);
  r.host.storagePath = (key) => (r.host.storage.has(key) ? `/data/${key}` : null);
  assert.equal(r.files.at(first.sha256), null);
  await run(r.files.fetch("lxgw-wenkai"));
  assert.equal(r.files.at(first.sha256), `/data/fonts/file/${first.sha256}`);
  await run(r.files.keep(first.sha256, new Uint8Array([1, 2, 3])));
  const kept = (await run(r.files.file(first.sha256))) as Beside;
  assert.deepEqual([kept.value, [...kept.bytes]], [{ zipped: false }, [1, 2, 3]]);
});

test("a fetch that fails says why until the face is fetched again; a face fetched stays when another is chosen", async () => {
  const r = rig();
  const inter = fonts.faceOf("inter")!.files[0];
  r.refuse.add(inter.url);
  await assert.rejects(run(r.files.fetch("inter")));
  const failed = (r.said() as { failed: Record<string, string> }).failed;
  assert.match(failed.inter, /503/);
  r.refuse.clear();
  await run(r.files.fetch("inter"));
  assert.deepEqual(r.said(), { fetching: {}, failed: {}, kept: ["inter"], share: {}, shareFailed: {} });
  // another fetched: inter's file stays, chosen again with nothing asked of the network
  await run(r.files.fetch("lxgw-wenkai"));
  assert.deepEqual((r.said() as { kept: string[] }).kept, ["inter", "lxgw-wenkai"]);
  assert.deepEqual(((await run(r.files.file(inter.sha256))) as Beside).value, { zipped: true });
  const asked = r.host.requests.length;
  await run(r.files.fetch("inter"));
  assert.equal(r.host.requests.length, asked);
  // kept across a core started again: what the host's storage holds, said once it is read
  const again = new FontFiles(r.host, { invalidate: () => {} } as unknown as Store);
  assert.deepEqual((again.compute() as { ok: { kept: string[] } }).ok.kept, []);
  again.start();
  await run(Effect.void);
  assert.deepEqual((again.compute() as { ok: { kept: string[] } }).ok.kept, ["inter", "lxgw-wenkai"]);
  assert.equal(((await run(again.file(fonts.faceOf("lxgw-wenkai")!.files[1].sha256))) as Beside).bytes.length, fonts.faceOf("lxgw-wenkai")!.files[1].bytes);
});

test("a face's preview is fetched once and kept", async () => {
  const r = rig();
  const url = fonts.faceOf("inter")!.preview!;
  r.host.onFetch((req) => (req.url === url ? { status: 200, headers: [], body: new Uint8Array([9, 9]) } : { status: 404, headers: [], body: new Uint8Array() }));
  assert.deepEqual([...((await run(r.files.preview("inter"))) as Beside).bytes], [9, 9]);
  assert.deepEqual([...((await run(r.files.preview("inter"))) as Beside).bytes], [9, 9]);
  assert.equal(r.host.requests.filter((q) => q.url === url).length, 1);
  await assert.rejects(run(r.files.preview("comic-sans")));
});

/// A file of the share card's looks as still.fail's site has it (web/public/share-looks/).
const onSite = (file: string) => new Uint8Array(readFileSync(new URL(`../../../web/public/share-looks/${file}`, import.meta.url)));

test("the share card's looks' table says the site's files as they are (node scripts/share-looks.ts)", async () => {
  const { made } = await import("../../../scripts/share-looks.ts");
  assert.equal(readFileSync(new URL("../src/share-looks.ts", import.meta.url), "utf8"), made());
});

test("a file of the share card's looks is fetched from the site once, how far said as it comes, and kept; nothing else is", async () => {
  const r = rig();
  const file = "1/a1-murasame-adv.webp";
  r.site.set(file, onSite(file));
  const got = (await run(r.files.share(file))) as Beside;
  assert.deepEqual(got.bytes, onSite(file));
  const far = r.seen.map((s) => (s as { share: Record<string, { got: number; bytes: number }> }).share[file]);
  assert.deepEqual(far[0], { got: 0, bytes: SHARE_LOOKS_FILES[file]!.bytes });
  assert.ok(far.some((p) => p !== undefined && p.got > 0 && p.got < p.bytes), JSON.stringify(far));
  assert.deepEqual(r.said(), { fetching: {}, failed: {}, kept: [], share: {}, shareFailed: {} });
  // kept: asked again, nothing fetched
  const asked = r.host.requests.length;
  assert.deepEqual(((await run(r.files.share(file))) as Beside).bytes, onSite(file));
  assert.equal(r.host.requests.length, asked);
  for (const other of ["../avatars/a.gz", "1/nobody.webp", "x/face-400.gz", "https://evil.test/a.gz", "1/../1/face-400.gz"]) await assert.rejects(run(r.files.share(other)));
});

test("what a site without the file answers (its page) is not kept as it: said failed, fetched again once asked again", async () => {
  const r = rig();
  const file = "1/face-400.gz";
  // kept by a core before files were checked: the page, dropped
  r.host.storage.set(`fonts/share/${file}`, new TextEncoder().encode("<!doctype html>"));
  await assert.rejects(run(r.files.share(file)), /下载到的文件不对/);
  assert.deepEqual((r.said() as { shareFailed: Record<string, string> }).shareFailed, { [file]: "下载到的文件不对" });
  assert.equal(r.host.storage.has(`fonts/share/${file}`), false);
  assert.equal(r.host.storage.has(`share-looks/${file}`), false);
  // a site that answers but not 200
  r.site.set(file, onSite(file));
  r.refuse.add(`${ORIGIN}/share-looks/${file}`);
  await assert.rejects(run(r.files.share(file)), /503/);
  // the site has it now: fetched, kept, the failure gone
  r.refuse.clear();
  assert.deepEqual(((await run(r.files.share(file))) as Beside).bytes, onSite(file));
  assert.deepEqual(r.said(), { fetching: {}, failed: {}, kept: [], share: {}, shareFailed: {} });
  // one cut short or longer than said: not the file either
  const short = "1/face-600.gz";
  r.site.set(short, onSite(short).slice(0, 1000));
  await assert.rejects(run(r.files.share(short)), /下载到的文件不对/);
  r.site.set(short, new Uint8Array([...onSite(short), 0]));
  await assert.rejects(run(r.files.share(short)), /下载到的文件不对/);
  assert.equal(r.host.storage.has(`share-looks/${short}`), false);
});

test("still.fail's own app on the test channel has the looks' files from the test channel's site, which main deploys", () => {
  fonts.setOrigin("https://app.still.fail", true);
  assert.equal(fonts.shareLooksFile("1/face-400.gz"), "https://app.youdid.wtf/share-looks/1/face-400.gz");
  fonts.setOrigin("https://app.still.fail");
  assert.equal(fonts.shareLooksFile("1/a1-murasame-adv.webp"), "https://app.still.fail/share-looks/1/a1-murasame-adv.webp");
  // a cloud of its own (a page's, a local one): its own
  fonts.setOrigin("https://app.youdid.wtf/", true);
  assert.equal(fonts.shareLooksFile("1/face-400.gz"), "https://app.youdid.wtf/share-looks/1/face-400.gz");
  fonts.setOrigin("http://localhost:8787", true);
  assert.equal(fonts.shareLooksFile("1/face-400.gz"), "http://localhost:8787/share-looks/1/face-400.gz");
  fonts.setOrigin(ORIGIN);
});

test("the calls: fonts.fetch, fonts.preview {id}; fonts.file {sha256}; fonts.keep {sha256} with the file beside", () => {
  assert.deepEqual(parseCall("fonts.fetch", { id: "inter" }), { kind: "fonts", call: { kind: "fetch", id: "inter" } });
  assert.deepEqual(parseCall("fonts.preview", { id: "inter" }), { kind: "fonts", call: { kind: "preview", id: "inter" } });
  assert.deepEqual(parseCall("fonts.share", { file: "1/face-400.gz" }), { kind: "fonts", call: { kind: "share", file: "1/face-400.gz" } });
  assert.deepEqual(parseCall("fonts.file", { sha256: "ab" }), { kind: "fonts", call: { kind: "file", sha256: "ab" } });
  assert.deepEqual(parseCall("fonts.keep", { sha256: "ab" }, new Uint8Array([1])), { kind: "fonts", call: { kind: "keep", sha256: "ab", bytes: new Uint8Array([1]) } });
  assert.throws(() => parseCall("fonts.keep", { sha256: "ab" }));
  assert.throws(() => parseCall("fonts.fetch", {}));
});

test("FontFiles.file verifies kept ttf off UI thread via storageGetVerified and self-heals damaged files", async () => {
  const r = rig();
  const face = fonts.faceOf("lxgw-wenkai")!;
  const sha = face.files[0].sha256;
  await run(r.files.fetch("lxgw-wenkai"));
  let verifiedCalls = 0;
  let mode: "verified" | "unverified" | "damaged" = "verified";
  r.host.storageGetVerified = (key, expected) => {
    verifiedCalls++;
    assert.equal(key, `fonts/file/${sha}`);
    assert.equal(expected, sha);
    const stored = r.host.storage.get(key);
    if (!stored) return Effect.succeed(null);
    if (mode === "damaged") return Effect.succeed("damaged");
    return Effect.succeed({ bytes: stored.slice(), verified: mode === "verified" });
  };

  // Gzipped file does not use storageGetVerified.
  const gz = (await run(r.files.file(sha))) as Beside;
  assert.deepEqual(gz.value, { zipped: true });
  assert.equal(verifiedCalls, 0);

  // Kept unzipped file uses storageGetVerified: verified: true.
  const ttf = new Uint8Array([10, 20, 30, 40]);
  await run(r.files.keep(sha, ttf));
  const ok = (await run(r.files.file(sha))) as Beside;
  assert.equal(verifiedCalls, 1);
  assert.deepEqual(ok.value, { zipped: false, verified: true });
  assert.deepEqual([...ok.bytes], [10, 20, 30, 40]);

  // Legacy shell fallback (verified: false) omits `verified` so UI checks it.
  mode = "unverified";
  const legacy = (await run(r.files.file(sha))) as Beside;
  assert.deepEqual(legacy.value, { zipped: false });
  assert.equal("verified" in (legacy.value as object), false);
  assert.deepEqual([...legacy.bytes], [10, 20, 30, 40]);

  // Damaged file: deletes index entry and storage file, invalidates topic, fails with not_found.
  mode = "damaged";
  const changesBefore = r.changed();
  await assert.rejects(
    run(r.files.file(sha)),
    (e: unknown) => typeof e === "object" && e !== null && (e as { code?: unknown }).code === "not_found",
  );
  assert.equal(r.host.storage.has(`fonts/file/${sha}`), false);
  assert.ok(r.changed() > changesBefore);
  assert.deepEqual((r.said() as { kept: string[] }).kept, []);
  // Index persisted without the damaged sha.
  const persisted = JSON.parse(new TextDecoder().decode(r.host.storage.get("fonts/kept")!)) as Record<string, string>;
  assert.equal(persisted[sha], undefined);
});

test("FontFiles.file stale damaged result does not delete a concurrent keep/fetch and preserves index on save failure", async () => {
  const r = rig();
  const face = fonts.faceOf("lxgw-wenkai")!;
  const sha = face.files[0].sha256;
  const key = `fonts/file/${sha}`;
  await run(r.files.fetch("lxgw-wenkai"));
  await run(r.files.keep(sha, new Uint8Array([1, 2, 3])));

  // 1. Stale "damaged" verification held while a concurrent keep() writes good bytes:
  // releasing the stale result must NOT delete the newly kept file or index, and instead re-reads the fresh bytes.
  const gate1 = Effect.runSync(Deferred.make<"damaged">());
  let calls = 0;
  r.host.storageGetVerified = (k) => {
    calls++;
    if (calls === 1) return Deferred.await(gate1);
    const cur = r.host.storage.get(k);
    return Effect.succeed(cur ? { bytes: cur.slice(), verified: true } : null);
  };
  const staleRead = run(r.files.file(sha));
  const goodBytes = new Uint8Array([7, 8, 9, 10]);
  await run(r.files.keep(sha, goodBytes));
  await run(Deferred.succeed(gate1, "damaged"));
  const got = (await staleRead) as Beside;
  assert.deepEqual(got.value, { zipped: false, verified: true });
  assert.deepEqual([...got.bytes], [7, 8, 9, 10]);
  assert.deepEqual([...(r.host.storage.get(key) ?? [])], [7, 8, 9, 10]);
  const persisted1 = JSON.parse(new TextDecoder().decode(r.host.storage.get("fonts/kept")!)) as Record<string, string>;
  assert.equal(persisted1[sha], "ttf");

  // 2. Two concurrent "damaged" reads: both enter storageGetVerified while kept[sha]==="ttf";
  // the first clears and triggers fetch() (writing fresh "gz"); releasing the second stale "damaged" result must
  // NOT delete the newly fetched "gz" file, and instead re-reads the fresh "gz" bytes.
  const gate2a = Effect.runSync(Deferred.make<"damaged">());
  const gate2b = Effect.runSync(Deferred.make<"damaged">());
  let secondCalls = 0;
  r.host.storageGetVerified = () => {
    secondCalls++;
    return secondCalls === 1 ? Deferred.await(gate2a) : Deferred.await(gate2b);
  };
  const readA = run(r.files.file(sha));
  const readB = run(r.files.file(sha));
  await run(Deferred.succeed(gate2a, "damaged"));
  await assert.rejects(readA, (e: unknown) => typeof e === "object" && e !== null && (e as { code?: unknown }).code === "not_found");
  await run(r.files.fetch("lxgw-wenkai"));
  const freshGz = r.host.storage.get(key)!.slice();
  await run(Deferred.succeed(gate2b, "damaged"));
  const gotB = (await readB) as Beside;
  assert.deepEqual(gotB.value, { zipped: true });
  assert.deepEqual([...gotB.bytes], [...freshGz]);
  assert.deepEqual([...(r.host.storage.get(key) ?? [])], [...freshGz]);

  // 3. Index save failure during damage cleanup must restore in-memory index and NOT delete the storage file.
  await run(r.files.keep(sha, new Uint8Array([4, 5, 6])));
  r.host.storageGetVerified = () => Effect.succeed("damaged");
  const origSet = r.host.storageSet.bind(r.host);
  let failIndexSave = true;
  r.host.storageSet = (k, v) => {
    if (k === "fonts/kept" && failIndexSave) return Effect.fail(new HostError("disk full"));
    return origSet(k, v);
  };
  await assert.rejects(
    run(r.files.file(sha)),
    (e: unknown) => typeof e === "object" && e !== null && (e as { code?: unknown }).code === "fonts",
  );
  assert.equal(r.host.storage.has(key), true);
  assert.equal((r.said() as { kept: string[] }).kept.includes("lxgw-wenkai"), true);
  failIndexSave = false;

  // 4. Genuine missing file on disk (storageGetVerified -> null) clears stale index so fetch() re-downloads it.
  r.host.storage.delete(key);
  r.host.storageGetVerified = (k) => {
    const cur = r.host.storage.get(k);
    return Effect.succeed(cur ? { bytes: cur.slice(), verified: true } : null);
  };
  await assert.rejects(
    run(r.files.file(sha)),
    (e: unknown) => typeof e === "object" && e !== null && (e as { code?: unknown }).code === "not_found",
  );
  const persistedAfterNull = JSON.parse(new TextDecoder().decode(r.host.storage.get("fonts/kept")!)) as Record<string, string>;
  assert.equal(persistedAfterNull[sha], undefined);
  await run(r.files.fetch("lxgw-wenkai"));
  assert.equal(r.host.storage.has(key), true);
});

test("FontFiles.file waits for concurrent keep() format switch and concurrent fetch() shares one network request", async () => {
  // 1a. Concurrent file() started AFTER keep() began writing TTF (while kept[sha] is still "gz") waits for keep()
  // and returns { zipped: false, verified: true } + TTF bytes, never { zipped: true } + TTF bytes.
  {
    const r = rig();
    const face = fonts.faceOf("inter")!;
    const sha = face.files[0].sha256;
    const key = `fonts/file/${sha}`;
    await run(r.files.fetch("inter"));
    const ttfBytes = new Uint8Array([0x00, 0x01, 0x00, 0x00, 99, 88, 77]);
    const writeStarted = Effect.runSync(Deferred.make<void>());
    const releaseWrite = Effect.runSync(Deferred.make<void>());
    const origSet = r.host.storageSet.bind(r.host);
    r.host.storageSet = (k, v) => {
      if (k === key) {
        return Effect.gen(function* () {
          // Write the new TTF bytes first, then suspend before keep() updates kept[sha] = "ttf".
          yield* origSet(k, v);
          yield* Deferred.succeed(writeStarted, undefined);
          yield* Deferred.await(releaseWrite);
        });
      }
      return origSet(k, v);
    };
    r.host.storageGetVerified = (k) => {
      const cur = r.host.storage.get(k);
      return Effect.succeed(cur ? { bytes: cur.slice(), verified: true } : null);
    };

    const keepPromise = run(r.files.keep(sha, ttfBytes));
    await run(Deferred.await(writeStarted));
    // Now disk already has ttfBytes while kept[sha] is still "gz": start file() before keep() completes.
    const filePromise = run(r.files.file(sha));
    await run(Deferred.succeed(releaseWrite, undefined));
    await keepPromise;
    const got = (await filePromise) as Beside;
    assert.deepEqual(got.value, { zipped: false, verified: true });
    assert.deepEqual([...got.bytes], [...ttfBytes]);
  }

  // 1b. Concurrent file() started BEFORE keep() (captured how="gz") whose storageGet resolves after keep() wrote TTF
  // must detect the version bump and retry, never returning { zipped: true } + TTF bytes.
  {
    const r = rig();
    const face = fonts.faceOf("inter")!;
    const sha = face.files[0].sha256;
    const key = `fonts/file/${sha}`;
    await run(r.files.fetch("inter"));
    const ttfBytes = new Uint8Array([0x00, 0x01, 0x00, 0x00, 11, 22, 33]);
    const readHeld = Effect.runSync(Deferred.make<void>());
    const releaseRead = Effect.runSync(Deferred.make<void>());
    const origGet = r.host.storageGet.bind(r.host);
    let firstFileGet = true;
    r.host.storageGet = (k) => {
      if (k === key && firstFileGet) {
        firstFileGet = false;
        return Effect.gen(function* () {
          yield* Deferred.succeed(readHeld, undefined);
          yield* Deferred.await(releaseRead);
          // Returns the newly overwritten TTF bytes from disk!
          return yield* origGet(k);
        });
      }
      return origGet(k);
    };
    r.host.storageGetVerified = (k) => {
      const cur = r.host.storage.get(k);
      return Effect.succeed(cur ? { bytes: cur.slice(), verified: true } : null);
    };

    const filePromise = run(r.files.file(sha));
    await run(Deferred.await(readHeld));
    await run(r.files.keep(sha, ttfBytes));
    await run(Deferred.succeed(releaseRead, undefined));
    const got = (await filePromise) as Beside;
    assert.deepEqual(got.value, { zipped: false, verified: true });
    assert.deepEqual([...got.bytes], [...ttfBytes]);
  }

  // 2. Two concurrent callers recovering the same face share one in-flight fetch() and both read the file afterward.
  {
    const r = rig();
    const face = fonts.faceOf("inter")!;
    const sha = face.files[0].sha256;
    const fetchStarted = Effect.runSync(Deferred.make<void>());
    const releaseFetch = Effect.runSync(Deferred.make<void>());
    let networkCalls = 0;
    const payload = new Uint8Array([0x1f, 0x8b, 8, 0, 1, 2, 3, 4]);
    r.host.onFetchStream(() =>
      Effect.gen(function* () {
        networkCalls++;
        yield* Deferred.succeed(fetchStarted, undefined);
        yield* Deferred.await(releaseFetch);
        let sent = false;
        return {
          status: 200,
          headers: [],
          body: {
            take: Effect.sync(() => {
              if (sent) return null;
              sent = true;
              return payload;
            }),
          },
        };
      }),
    );

    const f1 = run(r.files.fetch("inter"));
    await run(Deferred.await(fetchStarted));
    let secondSettled = false;
    const f2 = run(r.files.fetch("inter")).then((v) => {
      secondSettled = true;
      return v;
    });
    // Flush microtasks: second caller must still be awaiting the in-flight download, not returning early.
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(secondSettled, false);
    assert.equal(networkCalls, 1);

    await run(Deferred.succeed(releaseFetch, undefined));
    await Promise.all([f1, f2]);
    assert.equal(secondSettled, true);
    assert.equal(networkCalls, 1);
    const [b1, b2] = (await Promise.all([run(r.files.file(sha)), run(r.files.file(sha))])) as [Beside, Beside];
    assert.deepEqual(b1.value, { zipped: true });
    assert.deepEqual([...b1.bytes], [...payload]);
    assert.deepEqual(b2.value, { zipped: true });
    assert.deepEqual([...b2.bytes], [...payload]);
  }
});

test("FontFiles cold-start concurrent keep/file shares one index and interrupted keep commits before releasing gate", async () => {
  // 1. Cold-start concurrent keep() and file() over a persisted "gz" index must share one in-memory Kept object,
  // persist "ttf" in fonts/kept, and never return { zipped: true } with TTF bytes.
  {
    const r = rig();
    const face = fonts.faceOf("inter")!;
    const sha = face.files[0].sha256;
    const key = `fonts/file/${sha}`;
    const gzBytes = new Uint8Array([0x1f, 0x8b, 8, 0, 1, 2]);
    const ttfBytes = new Uint8Array([0x00, 0x01, 0x00, 0x00, 42, 43, 44]);
    r.host.storage.set("fonts/kept", new TextEncoder().encode(JSON.stringify({ [sha]: "gz" })));
    r.host.storage.set(key, gzBytes);
    const indexReadStarted = Effect.runSync(Deferred.make<void>());
    const releaseIndexRead = Effect.runSync(Deferred.make<void>());
    let indexReads = 0;
    const origGet = r.host.storageGet.bind(r.host);
    r.host.storageGet = (k) => {
      if (k === "fonts/kept") {
        indexReads++;
        return Effect.gen(function* () {
          yield* Deferred.succeed(indexReadStarted, undefined);
          yield* Deferred.await(releaseIndexRead);
          return yield* origGet(k);
        });
      }
      return origGet(k);
    };
    r.host.storageGetVerified = (k) => {
      const cur = r.host.storage.get(k);
      return Effect.succeed(cur ? { bytes: cur.slice(), verified: true } : null);
    };

    const keepPromise = run(r.files.keep(sha, ttfBytes));
    await run(Deferred.await(indexReadStarted));
    const filePromise = run(r.files.file(sha));
    await run(Deferred.succeed(releaseIndexRead, undefined));
    const [, got] = await Promise.all([keepPromise, filePromise]);
    assert.equal(indexReads, 1);
    const persisted = JSON.parse(new TextDecoder().decode(r.host.storage.get("fonts/kept")!)) as Record<string, string>;
    assert.equal(persisted[sha], "ttf");
    const beside = got as Beside;
    // Whichever order ran first, bytes and zipped flag must match (never zipped: true with ttfBytes).
    if ((beside.value as { zipped: boolean }).zipped) {
      assert.deepEqual([...beside.bytes], [...gzBytes]);
    } else {
      assert.deepEqual(beside.value, { zipped: false, verified: true });
      assert.deepEqual([...beside.bytes], [...ttfBytes]);
    }
    const after = (await run(r.files.file(sha))) as Beside;
    assert.deepEqual(after.value, { zipped: false, verified: true });
    assert.deepEqual([...after.bytes], [...ttfBytes]);
  }

  // 2. Interrupting keep() after storageSet starts must still finish the atomic commit (file + kept[sha]="ttf" + save)
  // before releasing the write gate, so subsequent file() and a fresh FontFiles instance both see { zipped: false }.
  {
    const r = rig();
    const face = fonts.faceOf("inter")!;
    const sha = face.files[0].sha256;
    const key = `fonts/file/${sha}`;
    await run(r.files.fetch("inter"));
    const ttfBytes = new Uint8Array([0x00, 0x01, 0x00, 0x00, 55, 66, 77]);
    const writeSubmitted = Effect.runSync(Deferred.make<void>());
    const finishWrite = Effect.runSync(Deferred.make<void>());
    const origSet = r.host.storageSet.bind(r.host);
    r.host.storageSet = (k, v) => {
      if (k === key) {
        return Effect.gen(function* () {
          yield* Deferred.succeed(writeSubmitted, undefined);
          yield* Deferred.await(finishWrite);
          return yield* origSet(k, v);
        });
      }
      return origSet(k, v);
    };
    r.host.storageGetVerified = (k) => {
      const cur = r.host.storage.get(k);
      return Effect.succeed(cur ? { bytes: cur.slice(), verified: true } : null);
    };

    const keepFiber = Effect.runFork(r.files.keep(sha, ttfBytes));
    await run(Deferred.await(writeSubmitted));
    const interruptPromise = run(Fiber.interrupt(keepFiber));
    // File read started while interrupted keep() is still committing must wait for the commit to complete.
    const filePromise = run(r.files.file(sha));
    await run(Deferred.succeed(finishWrite, undefined));
    await interruptPromise;
    const got = (await filePromise) as Beside;
    assert.deepEqual(got.value, { zipped: false, verified: true });
    assert.deepEqual([...got.bytes], [...ttfBytes]);
    const persisted = JSON.parse(new TextDecoder().decode(r.host.storage.get("fonts/kept")!)) as Record<string, string>;
    assert.equal(persisted[sha], "ttf");

    // Rebuilding a fresh FontFiles instance from the persisted host storage also sees "ttf" + TTF bytes.
    const store2 = { invalidate: () => {} } as unknown as Store;
    const rebuilt = new FontFiles(r.host, store2);
    const fromFresh = (await run(rebuilt.file(sha))) as Beside;
    assert.deepEqual(fromFresh.value, { zipped: false, verified: true });
    assert.deepEqual([...fromFresh.bytes], [...ttfBytes]);
  }
});
