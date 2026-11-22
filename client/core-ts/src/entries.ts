// A thread's entries merged into its messages: the one place edits are applied. A message shows its
// latest edit's text, attachments and quotes, marked edited.
import { get, isObject, sharedValue } from "./util.ts";
import { t } from "./i18n.ts";

/// The message each entry makes (an entry held is the same object while it does not change: data.ts): made once, so the
/// messages of what did not change are the objects they were, which what is made of them keeps (views.ts).
const made = new WeakMap<object, Record<string, unknown>>();
/// What edits made of a message, by the entry that made it: the edits, in order, the message they made (a copy, the one
/// the entry made left as it was) and those that changed its words (`source` hears them again). The same edits make the
/// same object, so an edited message is kept by what is made of it as one never edited is.
const editedBy = new WeakMap<object, { edits: object[]; message: Record<string, unknown>; heard: object[] }>();

/// An entry's number in its thread.
export function nOf(entry: unknown): number | null {
  const n = get(entry, "n");
  return typeof n === "number" && Number.isInteger(n) && n >= 0 ? n : null;
}

/// The messages of a run of entries, in thread order (`seq` is the message's n). `source`, when supplied, hears each
/// message and each edit changing its words; the last entry it hears for a message supplied its current words. Where
/// nothing hears them, the same entries (each the object it was, data.ts) give back the very list they gave the last
/// time it was asked of that list: a chat is made again on each change while its agent is working, its entries the same,
/// and those who read the list never write on it. (By what the list holds, not by the list alone: a list a page holds
/// may be the one it held, put together again in place.)
export function merge(entries: unknown[], source?: (seq: number, entry: object) => void): Record<string, unknown>[] {
  if (source !== undefined) return mergeNow(entries, source);
  const was = mergedOf.get(entries);
  if (was !== undefined && was.of.length === entries.length && was.of.every((e, i) => e === entries[i])) return was.out;
  const out = mergeNow(entries);
  mergedOf.set(entries, { of: [...entries], out });
  return out;
}

/// What `merge` made of a list of entries, by the list: the entries it held then, and the messages.
const mergedOf = new WeakMap<object, { of: unknown[]; out: Record<string, unknown>[] }>();

function mergeNow(entries: unknown[], source?: (seq: number, entry: object) => void): Record<string, unknown>[] {
  // Each message's entry and the edits put on it after it, in order.
  const runs = new Map<number, { entry: Record<string, unknown>; edits: Record<string, unknown>[] }>();
  for (const entry of entries) {
    const n = nOf(entry);
    if (n === null || !isObject(entry)) continue;
    if (entry.kind === "message") runs.set(n, { entry, edits: [] });
    else if (entry.kind === "edit") {
      const target = entry.target;
      if (typeof target === "number") runs.get(target)?.edits.push(entry);
    }
  }
  return [...runs.keys()].sort((a, b) => a - b).map((n) => {
    const { entry, edits } = runs.get(n)!;
    const message = messageOf(n, entry);
    source?.(n, entry);
    if (edits.length === 0) return message;
    const was = editedBy.get(entry);
    if (was !== undefined && was.edits.length === edits.length && was.edits.every((e, i) => e === edits[i])) {
      if (source) for (const e of was.heard) source(n, e);
      return was.message;
    }
    const out = { ...message };
    const heard: object[] = [];
    for (const edit of edits) {
      // Its card restated by its author (a vault request's outcome): the card alone when the words are the same.
      if (isObject(edit.card)) {
        out.card = edit.card;
        if ((edit.text ?? "") === out.text) continue;
      }
      const text = edit.text === undefined ? "" : edit.text;
      if (text !== out.text) {
        heard.push(edit);
        source?.(n, edit);
      }
      out.text = text;
      out.attachments = edit.attachments === undefined ? [] : edit.attachments;
      out.quotes = edit.quotes === undefined ? [] : edit.quotes;
      out.editedAt = edit.at === undefined ? null : edit.at;
    }
    const shared = sharedValue(out);
    editedBy.set(entry, { edits, message: shared, heard });
    return shared;
  });
}

/// The message entry `n` makes, made once (`made`).
function messageOf(n: number, entry: Record<string, unknown>): Record<string, unknown> {
  const once = made.get(entry);
  if (once !== undefined) return once;
  const field = (name: string) => (entry[name] === undefined ? null : entry[name]);
  const message: Record<string, unknown> = {
    seq: n,
    thread: field("thread"),
    ts: field("ts"),
    authorKind: field("authorKind"),
    author: field("author"),
    agentIdentity: field("agentIdentity"),
    authorName: authorNameOf(field("authorKind"), field("author"), field("authorName")),
    text: entry.text === undefined ? "" : entry.text,
    attachments: entry.attachments === undefined ? [] : entry.attachments,
    quotes: entry.quotes === undefined ? [] : entry.quotes,
    declared: field("declared"),
    createdAt: field("at"),
    editedAt: null,
  };
  if (typeof entry.authorPicture === "string") message.authorPicture = entry.authorPicture;
  if (typeof entry.authorModel === "string") message.authorModel = entry.authorModel;
  if (typeof entry.authorRuntime === "string") message.authorRuntime = entry.authorRuntime;
  if (typeof entry.ending === "string") message.ending = entry.ending;
  if (typeof entry.profile === "string") message.profile = entry.profile;
  if (typeof entry.runtime === "string") message.runtime = entry.runtime;
  if (Array.isArray(entry.options) && entry.options.length > 0) message.options = entry.options;
  if (isObject(entry.card)) message.card = entry.card;
  // What two chats' agents wrote each other (views.ts isLetter): which way, and the other chat.
  if (isObject(entry.letter)) message.letter = entry.letter;
  // The station's notice that a chat's run changed: how it ran and runs (run-change.ts).
  if (isObject(entry.change)) message.change = entry.change;
  const shared = sharedValue(message);
  made.set(entry, shared);
  return shared;
}

/// What a message's author is called: as its station names them, the local page's admin (whom a station names no more:
/// station/src/read/views.ts `authorNames`) in this device's words.
export function authorNameOf(kind: unknown, author: unknown, named: unknown): unknown {
  return (named === null || named === undefined) && kind === "person" && author === "local" ? t("station.author.admin") : named;
}
