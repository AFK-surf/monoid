// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/slack-known.ts's.
//
// What Slack calls people and channels, as the readers know it: the station's names book (<data>/slack-names.json,
// src/connects/names.ts, kept by the connects' connections) and the connects' Slack workspaces (config.json), each read
// again when its file changed. A name not in the book is not known yet: the connection looks it up when it hears of
// the person or channel, and the pages are told to read again then.
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { NAMES_FILE, REMOTE_FILE, channelKey } from "../../src/connects/keys.ts";
import { type Person, type Team, bookOf, configTeams, personIn, remoteTeams, teamIn } from "../../src/read/slack-known.ts";
import type { Json, Store } from "./store.ts";

export type { Team };

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

/// Every connect's place (config.json's, and those of other stations whose chats run here), as the files have them now.
export function teams(s: Store): Map<string, Team> {
  const own = readJson(join(s.dataDir, "config.json"), new Map<string, Team>(), configTeams);
  const others = readJson(join(s.dataDir, REMOTE_FILE), new Map<string, Team>(), remoteTeams);
  return others.size === 0 ? own : new Map([...others, ...own]);
}

/// The names book a connect's are in: Slack's (<data>/slack-names.json), Feishu's (feishu-names.json), Comma's or a group's.
export function book(s: Store, platform: keyof typeof NAMES_FILE = "slack"): Record<string, Json> {
  return readJson(join(s.dataDir, NAMES_FILE[platform]), {}, bookOf);
}

/// A connect's place on its platform, by its id (slack-known.ts `teamIn`).
export const teamOf = (s: Store, connect: string): Team | undefined => teamIn(teams(s), connect);

/// A Slack person of a connect, as far as known: their name, email and profile picture's address ("" when not known).
export function knownPerson(s: Store, connect: string, user: string): Person | null {
  const t = teamOf(s, connect);
  return personIn(book(s, t?.book), t, user);
}

/// A connect's Slack workspace's name, when known.
export function teamName(s: Store, connect: string): string | null {
  const name = teams(s).get(connect)?.name ?? "";
  return name === "" ? null : name;
}

/// A channel's name of a connect's Slack, as far as known (null for a direct message, or not known yet).
export function knownChannel(s: Store, connect: string | null, channel: string): string | null {
  if (connect === null) return null;
  const t = teamOf(s, connect);
  const name = book(s, t?.book)[channelKey(t?.id ?? "?", channel)]?.channel;
  return typeof name === "string" ? name : null;
}

/// A creator reference `slack:<connect>:<user>` in words: never waits on Slack — what is known
/// now; null when the reference is not a Slack one.
export function slackCreator(s: Store, reference: string): Json | null {
  if (!reference.startsWith("slack:")) return null;
  const rest = reference.slice("slack:".length);
  const colon = rest.indexOf(":");
  if (colon <= 0 || colon >= rest.length - 1) return null;
  const [connect, user] = [rest.slice(0, colon), rest.slice(colon + 1)];
  const person = knownPerson(s, connect, user);
  const v: Json = { id: reference, name: person?.name ? person.name : user, email: person?.email ? person.email : null, via: teamOf(s, connect)?.book ?? "slack" };
  if (person?.picture) v.picture = person.picture;
  return v;
}
