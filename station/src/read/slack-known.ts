// What Slack calls people and channels, as the readers know it: the station's names book (<data>/slack-names.json,
// src/connects/names.ts, kept by the connects' connections) and the connects' Slack workspaces (config.json), each read
// again when its file changed. A name not in the book is not known yet: the connection looks it up when it hears of
// the person or channel, and the pages are told to read again then.
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { NAMES_FILE, REMOTE_FILE, personKey } from "../connects/keys.ts";
import type { Json, Store } from "./store.ts";

type Cached<T> = { stamp: string; value: T };
const cache = new Map<string, Cached<unknown>>();

/// A JSON file of the data directory, read again when it changed; `empty` when it is not there or does not read.
function readJson<T>(path: string, empty: T, shape: (v: Json) => T): T {
  let stamp = "none";
  try {
    const st = statSync(path);
    stamp = `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch {}
  const had = cache.get(path) as Cached<T> | undefined;
  if (had && had.stamp === stamp) return had.value;
  let value = empty;
  if (stamp !== "none") {
    try {
      value = shape(JSON.parse(readFileSync(path, "utf8")));
    } catch {}
  }
  cache.set(path, { stamp, value });
  return value;
}

/// Each connect's Slack workspace (`slack.team`), as config.json has it; a Feishu, Comma or group connect's names are keyed by
/// the connect itself (src/feishu, src/comma: its people's ids are its app's own, or its Comma Group's), a Feishu one's
/// company its team. `book`: the platform whose names book has them.
export type Team = { id: string; name: string; book: keyof typeof NAMES_FILE };
export function teams(s: Store): Map<string, Team> {
  const own = readJson(join(s.dataDir, "config.json"), new Map<string, Team>(), (raw) => {
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
  });
  // And the connects of other stations whose chats run here (connects/remote.ts), as their stations described them.
  const others = readJson(join(s.dataDir, REMOTE_FILE), new Map<string, Team>(), (raw) => {
    const out = new Map<string, Team>();
    for (const [id, r] of Object.entries(raw !== null && typeof raw === "object" ? raw : {}) as [string, any][]) {
      const d = r?.described;
      if (d?.kind === "feishu") out.set(id, { id, name: typeof d?.identity?.team === "string" ? d.identity.team : "", book: "feishu" });
      else if (d?.kind === "slack" && typeof d?.team === "string" && d.team !== "") out.set(id, { id: d.team, name: typeof d?.identity?.team === "string" ? d.identity.team : "", book: "slack" });
    }
    return out;
  });
  return others.size === 0 ? own : new Map([...others, ...own]);
}

/// The names book a connect's are in: Slack's (<data>/slack-names.json), Feishu's (feishu-names.json), Comma's or a group's.
export function book(s: Store, platform: keyof typeof NAMES_FILE = "slack"): Record<string, Json> {
  return readJson(join(s.dataDir, NAMES_FILE[platform]), {}, (v) => (v !== null && typeof v === "object" && !Array.isArray(v) ? v : {}));
}

/// A connect's place on its platform, by its id: a connect moved here from another station is named on what its chats
/// said before as `<connect>@<station>` (a person `slack:claude-ember@d70c…:U09…`), and goes by the connect of that name
/// here where no connect is named so whole.
export function teamOf(s: Store, connect: string): Team | undefined {
  const all = teams(s);
  const whole = all.get(connect);
  if (whole !== undefined) return whole;
  const at = connect.indexOf("@");
  return at > 0 ? all.get(connect.slice(0, at)) : undefined;
}

/// A Slack person of a connect, as far as known: their name, email and profile picture's address ("" when not known).
export function knownPerson(s: Store, connect: string, user: string): { name: string; email: string; picture: string } | null {
  const t = teamOf(s, connect);
  const person = book(s, t?.book)[personKey(t?.id ?? "?", user)]?.person;
  const said = (v: Json) => (typeof v === "string" ? v : "");
  return person && typeof person.name === "string" ? { name: person.name, email: said(person.email), picture: said(person.picture) } : null;
}
