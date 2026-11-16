// config.json as a live, editable document: the file stays the source of truth. Edits are checked,
// written atomically (mode 600: it holds secrets) and told to whoever listens; fields this station does not know are
// kept as they are. Edited by something else (the installer, `stillfail channel`, a person): read again when the file
// changed (by its size and time), and told then: as the system says the file changed where it is watched (the
// station's own: `watch`), else on the next read. A file that is not there is `{}` (the defaults).
//
// The station's own (watched) neither reads nor writes it on the main thread once it serves: what is in memory is
// current, an edit is taken and told at once and written behind it (`updateSoon`), and what the system says changed is
// read off the thread. `update` and the reads of an unwatched one stay synchronous for the command line and the
// short-lived processes beside the station.
import { type FSWatcher, mkdirSync, readFileSync, renameSync, statSync, watch, writeFileSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { writePrivateSoon } from "./files.ts";
import { setStationLang } from "./i18n.ts";
import { parseJsonText } from "./json-file.ts";

/// Checks a config before it is taken (config.rs `parse_config`'s refusals): throws what is wrong.
export type ConfigCheck = (raw: any, data: string) => void;

/// The file's size, time and inode, or "none" where it is not.
type Stamp = string;

export class ConfigFile {
  readonly path: string;
  readonly data: string;
  /// What an edit must pass (the accounts module gives parse_config's checks).
  check: ConfigCheck = () => {};
  private seen: Stamp = "";
  private value: any = {};
  private invalid: Error | null = null;
  /// Its directory watched (`watch`): what is in memory is current until the system says the file changed. Unwatched,
  /// every read looks at the file: many a second on the main thread, each waiting on the disk.
  private watcher: FSWatcher | null = null;
  private listeners = new Set<(raw: any) => void>();
  /// The text this process last wrote (or asked written): read back from the file, it is no one else's edit.
  #lastWrittenText: string | null = null;
  /// Edits taken but not yet on disk: the file is behind what is in memory until they are.
  #writing = 0;
  /// Edits are numbered as they are taken; the file holds `#written`'s once its write is done.
  #asked = 0;
  /// Edits taken here, either way (`update`, `updateSoon`): one taken while the file was read makes what was read old.
  #edits = 0;
  #written = 0;
  #latest = "";
  /// One write at a time, each of the latest text: what was asked while one was on its way is written by the next.
  #queue: Promise<void> = Promise.resolve();
  #reloading: Promise<void> | null = null;
  #reloadAgain = false;

  constructor(data: string) {
    this.data = data;
    this.path = process.env.STILLFAIL_CONFIG || join(data, "config.json");
    this.raw();
  }

  /// The config as stored now. Not to be changed in place: `update` and `updateSoon` do that.
  raw(): any {
    // (an edit on its way: the file is behind what is in memory, and would be taken for someone else's)
    if (this.watcher !== null || this.#writing > 0) return this.value;
    const now = this.stamp();
    if (now !== this.seen) this.take(now, now === "none" ? null : this.readNow());
    return this.value;
  }

  /// Reads the file again only as the system says it changed, off the main thread (the station's; a test's that edits
  /// the file reads it at every read). Where the watch fails, every read looks at the file again.
  watch(): void {
    if (this.watcher !== null) return;
    try {
      const name = basename(this.path);
      // A directory not there cannot be watched, and every read after would look at the file on the main thread.
      mkdirSync(dirname(this.path), { recursive: true }); // sync: once, before the station serves
      this.watcher = watch(dirname(this.path), { persistent: false }, (_, file) => {
        // Written beside and renamed into place (`writePrivateSoon`, an editor, `stillfail channel`): macOS's FSEvents
        // may say only the file it was written as.
        const named = file === null ? null : String(file);
        if (named !== null && named !== name && !named.startsWith(`${name}.`)) return;
        this.#reloadSoon();
      });
      this.watcher.on("error", () => this.unwatch());
    } catch {
      this.watcher = null;
    }
    // What changed between its first read and its watch, read now (as the station starts), not at the next read.
    const now = this.stamp();
    if (now !== this.seen) this.take(now, now === "none" ? null : this.readNow());
  }

  unwatch(): void {
    this.watcher?.close();
    this.watcher = null;
  }

  /// Hears each config as it changes (by an edit here or in the file); gives the function that stops it.
  listen(listener: (raw: any) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /// Applies an edit to a copy; written and told only if the result checks out (else it throws, nothing changed). On
  /// the thread that calls it: the command line's, never the station's (`updateSoon`).
  update(edit: (raw: any) => void): any {
    const next = structuredClone(this.raw());
    if (this.invalid !== null) throw this.invalid;
    edit(next);
    this.check(next, this.data);
    const text = `${JSON.stringify(next, null, 2)}\n`;
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = `${this.path.replace(/\.json$/, "")}.json.tmp-${process.pid}`;
    writeFileSync(tmp, text, { mode: 0o600 }); // sync: the command line's edit; the station's is `updateSoon`
    renameSync(tmp, this.path);
    this.value = next;
    this.#lastWrittenText = text;
    this.#edits++;
    this.seen = this.stamp();
    setStationLang(next?.language);
    this.tell();
    return next;
  }

  /// `update` off the main thread: the edit is taken, and told, at once (or refused, nothing changed), and written
  /// behind it. Resolves once the file holds it, so whatever reads the file next (the MoonBit readers, another process)
  /// reads it; rejects as its write failed, what is in memory kept until the file is read again.
  async updateSoon(edit: (raw: any) => void): Promise<any> {
    // Taken in the step it is asked in, as `update` takes it: what reads the config next reads it. (Unwatched, a test's
    // or the command line's, `raw` looks at the file first, as it does at every read.)
    const next = structuredClone(this.raw());
    if (this.invalid !== null) throw this.invalid;
    edit(next);
    this.check(next, this.data);
    const text = `${JSON.stringify(next, null, 2)}\n`;
    this.value = next;
    this.#lastWrittenText = text;
    this.#edits++;
    setStationLang(next?.language);
    this.tell();
    const asked = ++this.#asked;
    this.#latest = text;
    this.#writing++;
    const written = this.#queue.then(() => this.#write(asked));
    this.#queue = written.catch(() => undefined);
    try {
      await written;
    } finally {
      this.#writing--;
    }
    return next;
  }

  /// Once every edit taken is written (or failed).
  async written(): Promise<void> {
    while (this.#writing > 0) await this.#queue;
  }

  /// Writes the latest text unless a write since `asked` was taken already did.
  async #write(asked: number): Promise<void> {
    if (this.#written >= asked) return;
    const upTo = this.#asked;
    await writePrivateSoon(this.path, this.#latest);
    this.#written = upTo;
    // Not stamped here: what the file is stamped by now may be someone else's write after this one. Read back (as the
    // system says it changed, or at the next look), its text is known for this process's own.
  }

  /// The system said the file changed: read off the thread, once more if it says so again meanwhile.
  #reloadSoon(): void {
    if (this.#reloading !== null) {
      this.#reloadAgain = true;
      return;
    }
    this.#reloading = (async () => {
      try {
        do {
          this.#reloadAgain = false;
          await this.#settled();
        } while (this.#reloadAgain && this.watcher !== null);
      } catch {
        // Unreadable for a reason of the disk's: what is in memory stands until the system says it changed again.
      } finally {
        this.#reloading = null;
      }
    })();
  }

  /// Takes what the file holds once no write of this process's is on its way: read while one is, it would be behind
  /// what is in memory, and taken for someone else's edit.
  async #settled(): Promise<void> {
    for (;;) {
      await this.written();
      const edits = this.#edits;
      const now = await this.#stampSoon();
      if (now === this.seen) return;
      const text = now === "none" ? null : await this.#readSoon();
      if (this.watcher === null) return;
      // (an edit taken meanwhile, written or not: what was read may be from before it)
      if (this.#writing > 0 || this.#edits !== edits) continue;
      this.take(now, text);
      return;
    }
  }

  /// What the file holds (`text`, null where it is not) as stamped `now`: a text this process wrote is its own, told
  /// already; anything else is someone's edit, told. Unreadable, the last good value stays for readers, and edits are
  /// refused until the file can be read again; read first, it is thrown, never turned into the defaults.
  private take(now: Stamp, text: string | null) {
    const first = this.seen === "";
    if (text !== null && text === this.#lastWrittenText) {
      this.seen = now;
      this.invalid = null;
      return;
    }
    // Someone else's now: the same text written back later is theirs too, never taken for this process's own.
    this.#lastWrittenText = null;
    try {
      this.value = text === null ? {} : parseJsonText(this.path, text);
      this.seen = now;
      this.invalid = null;
    } catch (error) {
      this.seen = now;
      this.invalid = error instanceof Error ? error : new Error(String(error));
      if (first) throw this.invalid;
      return;
    }
    setStationLang(this.value?.language);
    if (!first) this.tell();
  }

  private readNow(): string | null {
    try {
      return readFileSync(this.path, "utf8"); // sync: an unwatched one's (the command line's), or before the station serves
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
  }

  async #readSoon(): Promise<string | null> {
    try {
      return await readFile(this.path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
  }

  private stamp(): Stamp {
    try {
      const st = statSync(this.path);
      return `${st.size}:${st.mtimeMs}:${st.ino}`;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return "none";
      throw error;
    }
  }

  async #stampSoon(): Promise<Stamp> {
    try {
      const st = await stat(this.path);
      return `${st.size}:${st.mtimeMs}:${st.ino}`;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return "none";
      throw error;
    }
  }

  private tell() {
    for (const listener of this.listeners) {
      try {
        listener(this.value);
      } catch {}
    }
  }
}
