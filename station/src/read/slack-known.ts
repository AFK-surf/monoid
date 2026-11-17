// What Slack calls people and channels, as the event stream's entries name their authors (views.ts `authorNames`): the
// station's names book (<data>/slack-names.json and the other platforms', src/connects/names.ts, kept by the connects'
// connections), the connects' places (config.json, as the station holds it in memory) and those of other stations whose
// chats run here (remote-connects.json). Each file is read once as the station starts and again, off the main thread,
// when the system says it changed: every message said is named from memory, with no look at the disk (a station short
// of memory took seconds on each). A name not in the book is not known yet: the connection looks it up when it hears of
// the person or channel, and the pages are told to read again then. What the readers read of them before, a file
// looked at on each call, is the tests' (test/reference/slack-known.ts).
import { type FSWatcher, readFileSync, watch } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { NAMES_FILE, REMOTE_FILE, personKey } from "../connects/keys.ts";
import type { Json } from "./store.ts";

/// Each connect's Slack workspace (`slack.team`), as config.json has it; a Feishu, Comma or group connect's names are keyed by
/// the connect itself (src/feishu, src/comma: its people's ids are its app's own, or its Comma Group's), a Feishu one's
/// company its team. `book`: the platform whose names book has them.
export type Team = { id: string; name: string; book: keyof typeof NAMES_FILE };

/// The connects' places, by config.json's connects.
export function configTeams(raw: Json): Map<string, Team> {
  const out = new Map<string, Team>();
  for (const c of Array.isArray(raw?.connects) ? raw.connects : []) {
    if (typeof c?.id !== "string") continue;
    if (c?.kind === "feishu") {
      out.set(c.id, { id: c.id, name: typeof c?.feishu?.tenant?.name === "string" ? c.feishu.tenant.name : "", book: "feishu" });
      continue;
    }
    if (c?.kind === "comma") {
      out.set(c.id, { id: c.id, name: "", book: "comma" });
      continue;
    }
    if (c?.kind === "group") {
      out.set(c.id, { id: c.id, name: "", book: "group" });
      continue;
    }
    const team = c?.slack?.team;
    if (typeof team?.id === "string" && team.id !== "") out.set(c.id, { id: team.id, name: typeof team.name === "string" ? team.name : "", book: "slack" });
  }
  return out;
}

/// The connects of other stations whose chats run here (connects/remote.ts), as their stations described them.
export function remoteTeams(raw: Json): Map<string, Team> {
  const out = new Map<string, Team>();
  for (const [id, r] of Object.entries(raw !== null && typeof raw === "object" ? raw : {}) as [string, any][]) {
    const d = r?.described;
    if (d?.kind === "feishu") out.set(id, { id, name: typeof d?.identity?.team === "string" ? d.identity.team : "", book: "feishu" });
    else if (d?.kind === "slack" && typeof d?.team === "string" && d.team !== "") out.set(id, { id: d.team, name: typeof d?.identity?.team === "string" ? d.identity.team : "", book: "slack" });
  }
  return out;
}

/// A names book as its file has it: an object, else none.
export const bookOf = (v: Json): Record<string, Json> => (v !== null && typeof v === "object" && !Array.isArray(v) ? v : {});

/// A connect's place among `all`, by its id: a connect moved here from another station is named on what its chats said
/// before as `<connect>@<station>` (a person `slack:claude-ember@d70c…:U09…`), and goes by the connect of that name here
/// where no connect is named so whole.
export function teamIn(all: Map<string, Team>, connect: string): Team | undefined {
  const whole = all.get(connect);
  if (whole !== undefined) return whole;
  const at = connect.indexOf("@");
  return at > 0 ? all.get(connect.slice(0, at)) : undefined;
}

/// A person as a names book has them: their name, email and profile picture's address ("" when not known).
export type Person = { name: string; email: string; picture: string };
export function personIn(book: Record<string, Json>, team: Team | undefined, user: string): Person | null {
  const person = book[personKey(team?.id ?? "?", user)]?.person;
  const said = (v: Json) => (typeof v === "string" ? v : "");
  return person && typeof person.name === "string" ? { name: person.name, email: said(person.email), picture: said(person.picture) } : null;
}

type Kept = { remote: Map<string, Team>; books: Record<keyof typeof NAMES_FILE, Record<string, Json>> };
const FILES: Record<string, (kept: Kept, v: Json | undefined) => void> = {
  [REMOTE_FILE]: (kept, v) => void (kept.remote = v === undefined ? new Map() : remoteTeams(v)),
  ...Object.fromEntries((Object.entries(NAMES_FILE) as [keyof typeof NAMES_FILE, string][]).map(([platform, file]) =>
    [file, (kept: Kept, v: Json | undefined) => void (kept.books[platform] = v === undefined ? {} : bookOf(v))])),
};

/// The names books and other stations' connects of a data directory, in memory: read once as it is made, again as the
/// system says a file changed (`fs.watch` of the directory itself, not of what is under it), each file's reads one at a
/// time with one more after where it changed meanwhile. A file gone is empty.
export class KnownNames {
  readonly #data: string;
  readonly #config: () => Json;
  readonly #kept: Kept = { remote: new Map(), books: { slack: {}, feishu: {}, comma: {}, group: {} } };
  #watcher: FSWatcher | null = null;
  readonly #reading = new Map<string, Promise<void>>();
  readonly #again = new Set<string>();
  readonly #listeners = new Set<(file: string) => void>();
  #closed = false;
  #teams: { of: Json; remote: Map<string, Team>; all: Map<string, Team> } | null = null;

  /// `config`: config.json as the station holds it (ops/config.ts `raw`), the same object until it changed.
  constructor(data: string, config: () => Json) {
    this.#data = data;
    this.#config = config;
    // (watched first: what changes as it is read is read again after)
    try {
      // Each of its files by its name, or by its temporary's (`<file>.<pid>.tmp`, ops/files.ts writePrivateSoon): macOS's
      // FSEvents coalesces a file written and renamed into an event named after either. None named (the system's
      // queue overflowed): every one.
      this.#watcher = watch(data, { persistent: false }, (_, file) => {
        for (const k of Object.keys(FILES)) if (file === null || file === k || file.startsWith(`${k}.`)) void this.#reread(k);
      });
      this.#watcher.on("error", () => this.close());
    } catch {
      this.#watcher = null;
    }
    for (const file of Object.keys(FILES)) {
      let v: Json | undefined;
      try {
        v = JSON.parse(readFileSync(join(data, file), "utf8")); // sync: read once, before the station serves
      } catch {}
      FILES[file]!(this.#kept, v);
    }
  }

  /// Reads `file` again (as its watch says it changed): once read, what it has is kept; told again meanwhile, read again after.
  #reread(file: string): Promise<void> {
    const reading = this.#reading.get(file);
    if (reading !== undefined) {
      this.#again.add(file);
      return reading;
    }
    const read = (async () => {
      do {
        if (this.#closed) return;
        this.#again.delete(file);
        try {
          FILES[file]!(this.#kept, JSON.parse(await readFile(join(this.#data, file), "utf8")));
        } catch (error) {
          // Gone: none known. Caught as it is written (not by a rename): what was known, until it is read whole.
          if ((error as NodeJS.ErrnoException).code === "ENOENT") FILES[file]!(this.#kept, undefined);
        }
      } while (this.#again.has(file));
      if (!this.#closed) for (const listener of this.#listeners) listener(file);
    })().finally(() => this.#reading.delete(file));
    this.#reading.set(file, read);
    return read;
  }

  /// Hears each file's name as what it has is taken in; gives the function that stops it.
  listen(listener: (file: string) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  close(): void {
    this.#closed = true;
    this.#watcher?.close();
    this.#watcher = null;
  }

  /// Every connect's place: this station's own, then other stations' whose chats run here.
  teams(): Map<string, Team> {
    const of = this.#config(), remote = this.#kept.remote;
    if (this.#teams === null || this.#teams.of !== of || this.#teams.remote !== remote) {
      const own = configTeams(of);
      this.#teams = { of, remote, all: remote.size === 0 ? own : new Map([...remote, ...own]) };
    }
    return this.#teams.all;
  }

  /// The names book a connect's are in: Slack's (<data>/slack-names.json), Feishu's (feishu-names.json), Comma's or a group's.
  book(platform: keyof typeof NAMES_FILE = "slack"): Record<string, Json> {
    return this.#kept.books[platform];
  }

  /// A person of a connect, as far as known.
  person(connect: string, user: string): Person | null {
    const team = teamIn(this.teams(), connect);
    return personIn(this.book(team?.book), team, user);
  }
}
