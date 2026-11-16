// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/slack-known.ts's.
//
// What Slack calls people and channels, as the readers know it: the station's names book (<data>/slack-names.json,
// src/connects/names.ts, kept by the connects' connections) and the connects' Slack workspaces (config.json), each read
// again when its file changed. A name not in the book is not known yet: the connection looks it up when it hears of
// the person or channel, and the pages are told to read again then.
import { channelKey } from "../../src/connects/keys.ts";
import type { Json, Store } from "./store.ts";
import { teams, teamOf, book, knownPerson } from "../../src/read/slack-known.ts";

export * from "../../src/read/slack-known.ts";
export { teams, teamOf, book, knownPerson };

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
