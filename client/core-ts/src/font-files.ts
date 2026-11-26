// A face's files on a device whose app keeps no files of its own (the mbui app; sf/faces.mbt): what the Android app
// does itself in files/fonts, done here in the host's storage. A face chosen is fetched (`fonts.fetch {id}`), each of its
// files as it is put (gzipped), how far it got said on the `fonts` topic; the app unzips each and checks it by its
// hash, and that is kept instead (`fonts.keep {sha256}` + the file); `fonts.file {sha256}` gives back either, saying
// which. For an unzipped file (`ttf`), when the host offers `storageGetVerified` it checks the SHA-256 off the UI
// thread and returns `{zipped: false, verified: true}` on match, `{zipped: false}` when unverified (e.g. an older
// shell), or clears a damaged entry + file and fails `not_found` so the app re-fetches it automatically. Where the
// host keeps each value as a file of its own (the native apps' shell), the prefs' `faces` say where
// a chosen face's files are (`path`, fonts.ts `setKeptAt`): the app's host reads them there as the app starts, none of
// them carried through here nor checked again (the app falls back on `fonts.file` where one cannot be read: one kept
// as fetched). A face's files stay once fetched, chosen or not (the `fonts` topic's `kept`: the faces whole here), so
// choosing one again asks nothing of the network. A face's preview
// (`fonts.preview {id}`: the fonts page's characters alone, tens of KB) is fetched once and kept whatever is chosen, as is
// a file of the share card's looks the app does not carry (`fonts.share {file}`: a look's picture or their face,
// web/public/share-looks/), kept only once it is the file the site's table says (share-looks.ts: a site that has not
// got it answers its page), how far each being fetched is on the topic (`share`), each one's failure until it is asked
// again (`shareFailed`).
import { Clock, Deferred, Effect } from "effect";
import { CoreError } from "./error.ts";
import * as fonts from "./fonts.ts";
import type { Host } from "./host.ts";
import { t } from "./i18n.ts";
import type { Owner } from "./core/routing.ts";
import { Beside, type Topic } from "./protocol.ts";
import { SHARE_LOOKS_FILES } from "./share-looks.ts";
import type { Store, Value } from "./store.ts";
import { hex, isObject, parseJson, sha256, toJsonBytes } from "./util.ts";

/// What is kept, by file's hash: gzipped as fetched, or unzipped as the app checked it.
const INDEX = "fonts/kept";
const fileKey = (sha256: string) => `fonts/file/${sha256}`;
const previewKey = (id: string, url: string) => `fonts/preview/${id}/${url.slice(url.lastIndexOf("/") + 1)}`;
const shareKey = (file: string) => `share-looks/${file}`;
/// Where a share file was kept before it was checked (whatever the site answered: its page, where it had not got it).
const uncheckedShareKey = (file: string) => `fonts/share/${file}`;

type Kept = Record<string, "gz" | "ttf">;

export type FontsCall = { kind: "fetch"; id: string } | { kind: "preview"; id: string } | { kind: "share"; file: string } | { kind: "file"; sha256: string } | { kind: "keep"; sha256: string; bytes: Uint8Array };

export class FontFiles implements Owner {
  readonly #host: Host;
  readonly #store: Store;
  /// A face being fetched: how far, 0 to 1.
  readonly #fetching = new Map<string, number>();
  /// In-flight face fetch completions shared across concurrent callers (registered before any yield).
  readonly #fetchingDone = new Map<string, Deferred.Deferred<null, CoreError>>();
  /// A face whose fetch failed: why.
  readonly #failed = new Map<string, string>();
  #kept: Kept | null = null;
  #indexLoading: Deferred.Deferred<Kept> | null = null;
  /// Per-SHA mutation generation and active-writer gate so concurrent reads never observe mismatched (how, bytes)
  /// and stale off-thread verifications never clear a newer write.
  readonly #gen = new Map<string, number>();
  readonly #writing = new Map<string, Deferred.Deferred<void>>();
  /// A share file being fetched: how many of its bytes are here.
  readonly #sharing = new Map<string, number>();
  /// A share file whose fetch failed: why.
  readonly #shareFailed = new Map<string, string>();

  constructor(host: Host, store: Store) {
    this.#host = host;
    this.#store = store;
  }

  owns(topic: Topic): boolean {
    return topic.topic === "fonts";
  }

  /// What is kept is read from the host's storage the first time the topic is wanted, said once it is read.
  start(): void {
    if (this.#kept === null) Effect.runFork(Effect.map(this.#index(), () => this.#changed()));
  }

  compute(): Value {
    const kept = this.#kept;
    const whole = kept === null ? [] : fonts.ids().filter((id) => fonts.faceOf(id)!.files.every((f) => kept[f.sha256] !== undefined));
    const share = Object.fromEntries([...this.#sharing].map(([file, got]) => [file, { got, bytes: SHARE_LOOKS_FILES[file]!.bytes }]));
    return {
      ok: {
        fetching: Object.fromEntries(this.#fetching),
        failed: Object.fromEntries(this.#failed),
        kept: whole,
        share,
        shareFailed: Object.fromEntries(this.#shareFailed),
      },
    };
  }

  #changed(): void {
    this.#store.invalidate({ topic: "fonts" });
  }

  run(call: FontsCall): Effect.Effect<unknown, CoreError> {
    switch (call.kind) {
      case "fetch":
        return this.fetch(call.id);
      case "preview":
        return this.preview(call.id);
      case "share":
        return this.share(call.file);
      case "file":
        return this.file(call.sha256);
      case "keep":
        return this.keep(call.sha256, call.bytes);
    }
  }

  #index(): Effect.Effect<Kept> {
    return Effect.gen({ self: this }, function* () {
      if (this.#kept !== null) return this.#kept;
      if (this.#indexLoading !== null) return yield* Deferred.await(this.#indexLoading);
      const gate = Deferred.makeUnsafe<Kept>();
      this.#indexLoading = gate;
      Effect.runFork(
        Effect.gen({ self: this }, function* () {
          const raw = parseJson(yield* Effect.orElseSucceed(this.#host.storageGet(INDEX), () => null));
          const kept: Kept = {};
          if (isObject(raw)) for (const [sha, how] of Object.entries(raw)) if (how === "gz" || how === "ttf") kept[sha] = how;
          if (this.#kept === null) this.#kept = kept;
          return this.#kept;
        }).pipe(
          Effect.exit,
          Effect.flatMap((exit) =>
            Effect.sync(() => {
              if (this.#indexLoading === gate) this.#indexLoading = null;
              Deferred.doneUnsafe(gate, exit);
            }),
          ),
        ),
      );
      return yield* Deferred.await(gate);
    });
  }

  #save(): Effect.Effect<void, CoreError> {
    return Effect.mapError(this.#host.storageSet(INDEX, toJsonBytes(this.#kept ?? {})), (e) => CoreError.plainly("fonts", e));
  }

  #version(sha256: string): number {
    return this.#gen.get(sha256) ?? 0;
  }

  #bump(sha256: string): number {
    const next = this.#version(sha256) + 1;
    this.#gen.set(sha256, next);
    return next;
  }

  #withShaWrite<A, E>(sha256: string, body: Effect.Effect<A, E>): Effect.Effect<A, E> {
    // Waiting for an earlier writer stays interruptible; registering the gate, committing storage + index, and
    // releasing the gate run uninterruptibly so an interruption can neither leak the gate nor expose a torn write.
    return Effect.uninterruptibleMask((restore) =>
      Effect.gen({ self: this }, function* () {
        while (true) {
          const prev = this.#writing.get(sha256);
          if (prev === undefined) break;
          yield* restore(Deferred.await(prev));
        }
        const gate = Deferred.makeUnsafe<void>();
        this.#writing.set(sha256, gate);
        return yield* Effect.ensuring(
          body,
          Effect.sync(() => {
            if (this.#writing.get(sha256) === gate) this.#writing.delete(sha256);
            Deferred.doneUnsafe(gate, Effect.void);
          }),
        );
      }),
    );
  }

  /// Clears a stale or damaged index entry (and optionally its file) only if no newer write raced with `expectedGen`.
  /// Saves the index before deleting the file so a save failure never leaves a stale index pointing at a deleted file.
  #clearEntry(kept: Kept, sha256: string, how: "gz" | "ttf", expectedGen: number, deleteFile: boolean): Effect.Effect<"cleared" | "raced", CoreError> {
    return this.#withShaWrite(
      sha256,
      Effect.gen({ self: this }, function* () {
        if (this.#version(sha256) !== expectedGen || kept[sha256] !== how) return "raced" as const;
        const cleanGen = this.#bump(sha256);
        delete kept[sha256];
        const saved = yield* Effect.result(this.#save());
        if (saved._tag === "Failure") {
          if (this.#version(sha256) === cleanGen) kept[sha256] = how;
          return yield* Effect.fail(saved.failure);
        }
        if (deleteFile && this.#version(sha256) === cleanGen) {
          yield* Effect.ignore(this.#host.storageDelete(fileKey(sha256)));
        }
        this.#changed();
        return "cleared" as const;
      }),
    );
  }

  /// Face `id`'s files fetched, those not kept yet, each whole; null once all are here (gzipped, or as the app kept
  /// them). Concurrent callers for the same face share the in-flight completion. Failed: said on the topic too, until
  /// it is fetched again.
  fetch(id: string): Effect.Effect<null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const face = fonts.faceOf(id);
      if (face === null) return yield* Effect.fail(CoreError.invalid(t("core-misc.params.invalid", { error: `id ${id}` })));
      const existing = this.#fetchingDone.get(id);
      if (existing !== undefined) return yield* Deferred.await(existing);
      const doneGate = Deferred.makeUnsafe<null, CoreError>();
      this.#fetchingDone.set(id, doneGate);
      const clock = yield* Clock.Clock;
      Effect.runFork(
        this.#runFetch(id, face).pipe(
          Effect.exit,
          Effect.flatMap((exit) =>
            Effect.sync(() => {
              if (this.#fetchingDone.get(id) === doneGate) this.#fetchingDone.delete(id);
              Deferred.doneUnsafe(doneGate, exit);
            }),
          ),
          Effect.provideService(Clock.Clock, clock),
        ),
      );
      return yield* Deferred.await(doneGate);
    });
  }

  #runFetch(id: string, face: NonNullable<ReturnType<typeof fonts.faceOf>>): Effect.Effect<null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const kept = yield* this.#index();
      this.#fetching.set(id, 0);
      this.#failed.delete(id);
      this.#changed();
      let done = 0;
      const got = yield* Effect.result(
        Effect.gen({ self: this }, function* () {
          for (const f of face.files) {
            if (kept[f.sha256] !== undefined) {
              done += f.bytes;
              continue;
            }
            const parts: Uint8Array[] = [];
            let size = 0;
            yield* Effect.scoped(
              Effect.gen({ self: this }, function* () {
                const r = yield* Effect.mapError(this.#host.fetchStream({ method: "GET", url: f.url, headers: [], body: null }), (e) => CoreError.plainly("fonts", e));
                if (r.status !== 200) return yield* Effect.fail(new CoreError("fonts", t("android-misc.updates.httpStatus", { status: r.status })));
                while (true) {
                  const part = yield* Effect.mapError(r.body.take, (e) => CoreError.plainly("fonts", e));
                  if (part === null) break;
                  parts.push(part);
                  size += part.length;
                  // said each percent, not each part
                  const p = Math.min(100, Math.floor(((done + size) * 100) / Math.max(1, face.bytes))) / 100;
                  if (p !== this.#fetching.get(id)) {
                    this.#fetching.set(id, p);
                    this.#changed();
                  }
                }
              }),
            );
            const whole = new Uint8Array(size);
            let at = 0;
            for (const part of parts) {
              whole.set(part, at);
              at += part.length;
            }
            yield* this.#withShaWrite(
              f.sha256,
              Effect.gen({ self: this }, function* () {
                this.#bump(f.sha256);
                yield* Effect.mapError(this.#host.storageSet(fileKey(f.sha256), whole), (e) => CoreError.plainly("fonts", e));
                kept[f.sha256] = "gz";
                this.#bump(f.sha256);
                yield* this.#save();
              }),
            );
            done += f.bytes;
          }
        }),
      );
      this.#fetching.delete(id);
      if (got._tag === "Failure") this.#failed.set(id, got.failure.message);
      this.#changed();
      if (got._tag === "Failure") return yield* Effect.fail(got.failure);
      return null;
    });
  }

  /// Where the host keeps a file, by its hash, as a file of its own: null while none is kept (or not as a file).
  at(sha256: string): string | null {
    return this.#host.storagePath?.(fileKey(sha256)) ?? null;
  }

  /// A file kept, by its hash: its bytes, and whether they are as fetched (gzipped) or as the app kept them
  /// (and whether the host already verified their SHA-256 off the UI thread).
  file(sha256: string): Effect.Effect<Beside, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const kept = yield* this.#index();
      for (let attempt = 0; attempt < 4; attempt++) {
        while (true) {
          const writing = this.#writing.get(sha256);
          if (writing === undefined) break;
          yield* Deferred.await(writing);
        }
        const how = kept[sha256];
        if (how === undefined) return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
        const gen = this.#version(sha256);
        if (how === "ttf" && this.#host.storageGetVerified !== undefined) {
          const res = yield* Effect.result(this.#host.storageGetVerified(fileKey(sha256), sha256));
          if (res._tag === "Failure") {
            return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
          }
          const got = res.success;
          if (got === "damaged") {
            const state = yield* this.#clearEntry(kept, sha256, how, gen, true);
            if (state === "raced") continue;
            return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
          }
          if (got === null) {
            const state = yield* this.#clearEntry(kept, sha256, how, gen, false);
            if (state === "raced") continue;
            return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
          }
          if (this.#version(sha256) !== gen || this.#writing.has(sha256)) continue;
          return new Beside(got.verified ? { zipped: false, verified: true } : { zipped: false }, got.bytes);
        }
        const res = yield* Effect.result(this.#host.storageGet(fileKey(sha256)));
        if (res._tag === "Failure") {
          return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
        }
        const bytes = res.success;
        if (bytes === null) {
          const state = yield* this.#clearEntry(kept, sha256, how, gen, false);
          if (state === "raced") continue;
          return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
        }
        if (this.#version(sha256) !== gen || this.#writing.has(sha256)) continue;
        return new Beside({ zipped: how === "gz" }, bytes);
      }
      return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
    });
  }

  /// A file as the app unzipped and checked it, kept instead of what was fetched.
  keep(sha256: string, bytes: Uint8Array): Effect.Effect<null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const kept = yield* this.#index();
      return yield* this.#withShaWrite(
        sha256,
        Effect.gen({ self: this }, function* () {
          if (kept[sha256] === undefined) return yield* Effect.fail(new CoreError("not_found", t("core-misc.params.invalid", { error: `sha256 ${sha256}` })));
          this.#bump(sha256);
          yield* Effect.mapError(this.#host.storageSet(fileKey(sha256), bytes), (e) => CoreError.plainly("fonts", e));
          kept[sha256] = "ttf";
          this.#bump(sha256);
          yield* this.#save();
          return null;
        }),
      );
    });
  }

  /// Face `id`'s preview: kept, else fetched and kept.
  preview(id: string): Effect.Effect<Beside, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const face = fonts.faceOf(id);
      if (face === null || face.preview === undefined) return yield* Effect.fail(CoreError.invalid(t("core-misc.params.invalid", { error: `id ${id}` })));
      return yield* this.#keptOrFetched(previewKey(id, face.preview), face.preview);
    });
  }

  /// A file of the share card's looks (`<drawing>/<name>`, fonts.shareLooksFile, one of share-looks.ts'): kept, else
  /// fetched in parts (how far said on the topic), checked against its size and hash and kept (a drawing's files never
  /// change: one drawn anew goes under the next number). Failed: said on the topic too, until it is asked again.
  share(file: string): Effect.Effect<Beside, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const want = SHARE_LOOKS_FILES[file];
      const url = fonts.shareLooksFile(file);
      if (want === undefined || url === null) return yield* Effect.fail(CoreError.invalid(t("core-misc.params.invalid", { error: `file ${file}` })));
      const kept = yield* Effect.orElseSucceed(this.#host.storageGet(shareKey(file)), () => null);
      if (kept !== null) return new Beside({}, kept);
      // (one kept before files were checked: perhaps the site's page)
      yield* Effect.ignore(this.#host.storageDelete(uncheckedShareKey(file)));
      this.#sharing.set(file, 0);
      this.#shareFailed.delete(file);
      this.#changed();
      const got = yield* Effect.result(
        Effect.scoped(
          Effect.gen({ self: this }, function* () {
            const r = yield* Effect.mapError(this.#host.fetchStream({ method: "GET", url, headers: [], body: null }), (e) => CoreError.plainly("fonts", e));
            if (r.status !== 200) return yield* Effect.fail(new CoreError("fonts", t("android-misc.updates.httpStatus", { status: r.status })));
            const whole = new Uint8Array(want.bytes);
            let size = 0;
            while (true) {
              const part = yield* Effect.mapError(r.body.take, (e) => CoreError.plainly("fonts", e));
              if (part === null) break;
              if (size + part.length > want.bytes) return yield* Effect.fail(new CoreError("fonts", t("core-misc.shareLooks.notTheFile")));
              whole.set(part, size);
              size += part.length;
              // said each percent, not each part
              const before = Math.floor(((this.#sharing.get(file) ?? 0) * 100) / want.bytes);
              this.#sharing.set(file, size);
              if (Math.floor((size * 100) / want.bytes) !== before) this.#changed();
            }
            if (size !== want.bytes || hex(sha256(whole)) !== want.sha256) return yield* Effect.fail(new CoreError("fonts", t("core-misc.shareLooks.notTheFile")));
            yield* Effect.ignore(this.#host.storageSet(shareKey(file), whole), { log: "Unhandled", message: "share file kept" });
            return whole;
          }),
        ),
      );
      this.#sharing.delete(file);
      if (got._tag === "Failure") this.#shareFailed.set(file, got.failure.message);
      this.#changed();
      if (got._tag === "Failure") return yield* Effect.fail(got.failure);
      return new Beside({}, got.success);
    });
  }

  #keptOrFetched(key: string, url: string): Effect.Effect<Beside, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const kept = yield* Effect.orElseSucceed(this.#host.storageGet(key), () => null);
      if (kept !== null) return new Beside({}, kept);
      const r = yield* Effect.mapError(this.#host.fetch({ method: "GET", url, headers: [], body: null }), (e) => CoreError.plainly("fonts", e));
      if (r.status !== 200) return yield* Effect.fail(new CoreError("fonts", t("android-misc.updates.httpStatus", { status: r.status })));
      yield* Effect.ignore(this.#host.storageSet(key, r.body), { log: "Unhandled", message: "font kept" });
      return new Beside({}, r.body);
    });
  }
}
