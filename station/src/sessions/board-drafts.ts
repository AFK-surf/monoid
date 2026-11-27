// A person's drafts of 待派发 (the board's tasks not started yet), the same on all their devices and every station of
// the workspace, carried by their own devices as their presets and starred models are (AGENTS.md, Presets and starred
// models; the rule both sides keep is client/core-ts/src/board-drafts.ts). A device reads GET /board/drafts (its
// person's own, deleted ones too, and which of their files this station keeps), brings what the station lacks with
// PUT /board/drafts, and is told `boardDrafts` as they change here. The stations never bring them level with each other.
//
// Kept in stillfail.db (`board_drafts`), one row a person a workspace, read by its key as it is first asked and held
// after. A draft's pictures and files are kept by the station it is to run on (`<data>/board-files`, a folder a person, a
// folder a draft): a device that holds them puts each among the uploads as a chat's file goes up (POST /uploads) and
// then names it the draft's (`keep`), so that the person's other devices show it (GET /board/files) and one of them
// starting the draft sends it (`stage`: copied among the uploads, as a message takes a file). A draft started or
// deleted has its files put aside (`.gone`) for a day, so that the device starting it still sends them, then dropped.
import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, stat, utimes } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { cloneFile } from "../ops/clone.ts";
import { type DraftRecord, type KeptDraft, DraftRefusal, draftsOf, isGoneDraft, mergeDrafts } from "../../../client/core-ts/src/board-drafts.ts";
import { canonical } from "../../../client/core-ts/src/preset-records.ts";
import { moveFile } from "../ops/files.ts";
import { log } from "../ops/log.ts";
import { typeOf } from "../drive/drive.ts";

/// Where the drafts are kept (the store's `board_drafts`).
export type DraftsKept = { boardDrafts(ws: string, sub: string): string | null; putBoardDrafts(ws: string, sub: string, drafts: string): void };

export type BoardDraftsDeps = {
  store: () => DraftsKept;
  /// `<data>/board-files`, and the uploads a message takes its files from (`<data>/uploads`).
  dir: () => string;
  uploads: () => string;
  now: () => number;
};

/// A file of a draft started or deleted is kept aside so long, for the device that started it to send it (a person's
/// next carry drops it after; the station's upkeep, ops/storage.ts `goneBoardFiles`, where none comes).
/// (ops/storage.ts `BOARD_FILES_GONE_MS` is the same; not imported, so the core's tests that read this file stay apart
/// from the upkeep.)
export const GONE_FILES_MS = 24 * 3600 * 1000;
const GONE = ".gone";

const hashed = (...parts: string[]) => createHash("sha256").update(parts.join("\0")).digest("hex").slice(0, 32);
const statOf = (path: string) => stat(path).catch(() => null);

/// What a station says of a person's drafts: every record it keeps of theirs, and the ids of the files it keeps.
export type DraftsSaid = { drafts: KeptDraft[]; files: string[] };

export class BoardDrafts {
  readonly #deps: BoardDraftsDeps;
  /// Each person's as last read or written: read by its key once.
  readonly #held = new Map<string, Record<string, KeptDraft>>();

  constructor(deps: BoardDraftsDeps) {
    this.#deps = deps;
  }

  #read(ws: string, sub: string): Record<string, KeptDraft> {
    const at = `${ws}\0${sub}`;
    let drafts = this.#held.get(at);
    if (drafts === undefined) {
      const text = this.#deps.store().boardDrafts(ws, sub);
      drafts = {};
      try {
        for (const r of draftsOf(text === null ? [] : Object.values(JSON.parse(text) as object))) if (r.owner === sub) drafts[r.id] = r;
      } catch (e) {
        log.warn("board", "a person's drafts kept here do not read; taken as none", { error: (e as Error).message });
      }
      this.#held.set(at, drafts);
    }
    return drafts;
  }

  #person(ws: string, sub: string) {
    return join(this.#deps.dir(), hashed(ws, sub));
  }

  #fileAt(ws: string, sub: string, draft: string, file: string, gone = false) {
    return gone ? join(this.#person(ws, sub), GONE, hashed(draft), hashed(file)) : join(this.#person(ws, sub), hashed(draft), hashed(file));
  }

  /// The ids of the files of `sub`'s live drafts kept here.
  async #files(ws: string, sub: string, drafts: Record<string, KeptDraft>): Promise<string[]> {
    const out: string[] = [];
    for (const d of Object.values(drafts)) {
      if (isGoneDraft(d)) continue;
      for (const f of d.files) if ((await statOf(this.#fileAt(ws, sub, d.id, f.id)))?.isFile()) out.push(f.id);
    }
    return out.sort();
  }

  /// `sub`'s drafts in `ws` as kept here, and the files kept of them.
  async said(ws: string, sub: string): Promise<DraftsSaid> {
    const drafts = this.#read(ws, sub);
    return { drafts: Object.values(drafts), files: await this.#files(ws, sub, drafts) };
  }

  /// What `sub`'s device brought (`given`: records, each checked, of theirs alone) merged into what is kept: the newer of
  /// each kept, written and told (`changed`) only where something did; a draft gone puts its files aside, a file a
  /// draft no longer names is dropped. Throws a DraftRefusal where a record does not check.
  async carry(ws: string, sub: string, given: unknown): Promise<DraftsSaid & { changed: boolean }> {
    if (!Array.isArray(given)) throw new DraftRefusal("drafts: a list of drafts");
    const records = draftsOf(given);
    if (records.length !== given.length) throw new DraftRefusal("a draft does not read");
    if (records.some((r) => r.owner !== sub)) throw new DraftRefusal("a draft is its person's own");
    const was = this.#read(ws, sub);
    const now = mergeDrafts(was, records);
    const changed = now !== was && canonical(now) !== canonical(was);
    if (changed) {
      this.#deps.store().putBoardDrafts(ws, sub, JSON.stringify(now));
      this.#held.set(`${ws}\0${sub}`, now);
      for (const [id, before] of Object.entries(was)) {
        if (isGoneDraft(before)) continue;
        const after = now[id];
        if (after === undefined || isGoneDraft(after)) await this.#putAside(ws, sub, before);
        else for (const f of before.files) if (!after.files.some((x) => x.id === f.id)) await rm(this.#fileAt(ws, sub, id, f.id), { force: true });
      }
    }
    await this.#sweep(ws, sub);
    return { drafts: Object.values(now), files: await this.#files(ws, sub, now), changed };
  }

  /// A draft gone: its files put aside, kept for GONE_FILES_MS from now.
  async #putAside(ws: string, sub: string, d: DraftRecord): Promise<void> {
    for (const f of d.files) {
      const from = this.#fileAt(ws, sub, d.id, f.id);
      if (!(await statOf(from))?.isFile()) continue;
      const to = this.#fileAt(ws, sub, d.id, f.id, true);
      await mkdir(dirname(to), { recursive: true });
      await rename(from, to);
      const at = new Date(this.#deps.now());
      await utimes(to, at, at).catch(() => {});
    }
    await rm(join(this.#person(ws, sub), hashed(d.id)), { recursive: true, force: true });
  }

  /// What was put aside longer ago than GONE_FILES_MS, dropped.
  async #sweep(ws: string, sub: string): Promise<void> {
    const aside = join(this.#person(ws, sub), GONE);
    let drafts: string[];
    try {
      drafts = await readdir(aside);
    } catch {
      return;
    }
    for (const d of drafts) {
      let files: string[];
      try {
        files = await readdir(join(aside, d));
      } catch {
        continue;
      }
      for (const f of files) {
        const st = await statOf(join(aside, d, f));
        if (st !== null && this.#deps.now() - st.mtimeMs > GONE_FILES_MS) await rm(join(aside, d, f), { force: true });
      }
      if ((await readdir(join(aside, d)).catch(() => [])).length === 0) await rm(join(aside, d), { recursive: true, force: true });
    }
  }

  /// The upload at `path` (one of the uploads, a file a message has not taken) kept as file `file` of `sub`'s live draft
  /// `draft`, moved out of the uploads: the files kept of their drafts now. Refused where the draft is not theirs or not
  /// live, it names no such file, or `path` is no upload.
  async keep(ws: string, sub: string, draft: string, file: string, path: string): Promise<{ files: string[] }> {
    const drafts = this.#read(ws, sub);
    const d = drafts[draft];
    if (d === undefined || isGoneDraft(d) || !d.files.some((f) => f.id === file)) throw new DraftRefusal("no such draft or file");
    const uploads = resolve(this.#deps.uploads());
    const from = resolve(path);
    if (dirname(from) !== uploads || from.slice(uploads.length + 1).startsWith(".")) throw new DraftRefusal("not an upload");
    if (!(await statOf(from))?.isFile()) throw new DraftRefusal("not an upload");
    const to = this.#fileAt(ws, sub, draft, file);
    await mkdir(dirname(to), { recursive: true });
    // (the uploads and the board's files on two disks, one a link: copied across, as a message takes an upload)
    await moveFile(from, to);
    return { files: await this.#files(ws, sub, drafts) };
  }

  /// Where file `file` of `sub`'s draft `draft` is kept here (aside, of one gone), with its name and size; null where
  /// it is not.
  async #found(ws: string, sub: string, draft: string, file: string): Promise<{ path: string; name: string; size: number } | null> {
    const d = this.#read(ws, sub)[draft];
    const named = d !== undefined && !isGoneDraft(d) ? d.files.find((f) => f.id === file)?.name : undefined;
    for (const gone of [false, true]) {
      const path = this.#fileAt(ws, sub, draft, file, gone);
      const st = await statOf(path);
      if (st?.isFile()) return { path, name: named ?? file, size: st.size };
    }
    return null;
  }

  /// The bytes of file `file` of `sub`'s draft `draft`, and their type by its name: null where none are kept here.
  async bytes(ws: string, sub: string, draft: string, file: string): Promise<{ type: string; bytes: Buffer } | null> {
    const at = await this.#found(ws, sub, draft, file);
    if (at === null) return null;
    return { type: typeOf(at.name), bytes: await readFile(at.path) };
  }

  /// File `file` of `sub`'s draft `draft` copied among the uploads for a message to take (as POST /uploads answers):
  /// its name there, its path and size; null where none is kept here.
  async stage(ws: string, sub: string, draft: string, file: string, name: string): Promise<{ name: string; path: string; size: number } | null> {
    const at = await this.#found(ws, sub, draft, file);
    if (at === null) return null;
    const base = name.replace(/\\/g, "/").split("/").at(-1) ?? "";
    const safe = [...[...base].map((c) => (c.codePointAt(0)! < 0x20 ? "_" : c)).join("").replace(/^\.+/, "")].slice(0, 120).join("") || "file";
    const dir = this.#deps.uploads();
    await mkdir(dir, { recursive: true });
    const stamp = new Date(this.#deps.now()).toISOString().slice(0, 19).replace(/[:.]/g, "-");
    const path = join(dir, `${stamp}-${randomBytes(3).toString("hex")}-${safe}`);
    await cloneFile(at.path, path);
    return { name: safe, path, size: at.size };
  }
}
