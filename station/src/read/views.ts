// What the station still makes of the pages' views on its main thread (views.ts was the sidebar, GET /chats, and thread
// entries, GET /threads/:id/entries, ported from the Rust station's admin/views.rs with the same JSON, field for field):
// a chat's title by the core's rule, and entries with their authors' names as the event stream tells them (`said`,
// services.ts), in the language asked (`spokenIn`). The rest of the pages' views are the MoonBit reader's; the
// TypeScript that answered them is the tests' (test/reference/views.ts).
import { type Lang, tr as translate } from "../ops/i18n.ts";
import * as store from "./store.ts";
import { Refused as HttpError } from "../api/request.ts";
import { entryJson } from "../store/archive.ts";
import * as titles from "../../../client/core-ts/src/titles.ts";
import type { KnownNames, Person } from "./slack-known.ts";
import { type AuthorKind, type EntryRow, type Json, type SessionRow, type Store, type ThreadRow, STILLFAIL_SURFACE } from "./store.ts";
import { STATION_AUTHOR, STILLFAIL_CONNECT } from "../store/rows.ts";

/// An error with the status the admin API answers it with (admin/mod.rs `http_error`): the routes' own.
export { HttpError };

// ---- words, in the language of the request (`spoken()`) ----

/// The language the request being answered asks in (one request at a time in a worker).
let spokenLang: Lang = "zh";
/// What `make` makes with the words in `lang`, off the readers (each read sets its own): the words as they were after.
export function spokenIn<T>(lang: Lang, make: () => T): T {
  const was = spokenLang;
  spokenLang = lang;
  try {
    return make();
  } finally {
    spokenLang = was;
  }
}
export const tr = (key: string, args: Record<string, string> = {}) => translate(spokenLang, key, args);

/// What a chat with no name yet is called.
export const untitled = () => tr("station.chat.untitled");

// ---- the station's config: its connects' names, and whether the archive review is on ----

type Connect = { id: string; name: string };
type Config = { connects: Connect[]; reviews: boolean };
const configs = new WeakMap<object, Config>();

/// The config's connects (config.rs), each with what it is called (Connect::name: its bot's name, else its id), and
/// whether the decision reviews done chats for the archive (automaticDecisions.completion); made again only for a
/// config changed (ops/config.ts `raw` gives the same object until then).
export function configOf(raw: Json): Config {
  const object = raw !== null && typeof raw === "object" ? raw : null;
  const had = object === null ? undefined : configs.get(object);
  if (had !== undefined) return had;
  const connects: Connect[] = [];
  const reviews = raw?.automaticDecisions?.completion?.enabled === true;
  for (const c of Array.isArray(raw?.connects) ? raw.connects : []) {
    const bot = typeof c?.slack?.botName === "string" && c.slack.botName !== "" ? c.slack.botName : undefined;
    if (typeof c?.id === "string") connects.push({ id: c.id, name: bot ?? c.id });
  }
  const config = { connects, reviews };
  if (object !== null) configs.set(object, config);
  return config;
}

/// What the shared chat list is made with of a config.json (`configOf`), as text to be compared: a change of anything
/// else in it (profiles, their checks, shares) changes no chat row.
export const rowsMadeWith = (raw: Json): string => JSON.stringify(configOf(raw));

/// What the views are made with: the store, the config's connects, and who a platform's person is (slack-known.ts).
export type Api = { store: Store; connects: Connect[]; reviews: boolean; person: (connect: string, user: string) => Person | null };
/// The views' `Api` from the config the station holds in memory and the names it knows (`KnownNames`): no file read.
export const apiOf = (s: Store, config: Json, known: KnownNames): Api => ({ store: s, ...configOf(config), person: (connect, user) => known.person(connect, user) });

/// The name a chat has been given: by people, else by its agent.
export function given(thread: ThreadRow): string | null {
  return titles.givenTitle(thread);
}

/// What a thread is called, by the one rule the core names it by too (client/core-ts/src/titles.ts).
export function titleOf(thread: ThreadRow, firstText: string | null, channelName: string | null): string {
  return titles.chatTitle(thread, firstText, channelName, { untitled: untitled(), directMessage: tr("station.chat.directMessage") });
}

/// An author's name; `picture`, where given, their picture's address (a Slack person's own, as their Slack shows it).
export type Names = ((kind: AuthorKind, author: string) => string | null) & { picture?: (kind: AuthorKind, author: string) => string | null };

/// Who wrote in a thread, in words and pictures: each author asked once. The local page's admin is named `admin`: none
/// for a device, whose client names them (core-ts entries.ts `authorNameOf`); the station's own word in its notices.
export function authorNames(api: Api, thread: number, admin: string | null = null): Names {
  const th = store.getThread(api.store, thread);
  const members = store.threadSessions(api.store, thread);
  const names = new Map<string, string | null>();
  const pictures = new Map<string, string>();
  const name = (kind: AuthorKind, author: string): string | null => {
    const key = `${kind}:${author}`;
    if (names.has(key)) return names.get(key)!;
    let name: string | null;
    if (kind === STATION_AUTHOR) name = "still.fail";
    else if (kind === "agent") {
      // An agent goes by the name of the connect it posts through (on the page, of the connect that started it).
      const session = store.getSession(api.store, author);
      const via = members.find((m) => m.session === author)?.connect;
      const connect = via !== undefined && via !== STILLFAIL_CONNECT ? via : (session?.connect ?? null);
      const c = api.connects.find((c) => c.id === connect);
      name = c ? c.name : (session?.title ?? null);
    } else if (th !== null && th.surface === STILLFAIL_SURFACE) {
      if (author === "local") {
        name = admin;
      } else if (author.startsWith("slack:")) {
        const rest = author.slice(6);
        const colon = rest.indexOf(":");
        if (colon > 0 && colon < rest.length - 1) {
          const connect = rest.slice(0, colon);
          const user = rest.slice(colon + 1);
          const person = api.person(connect, user);
          if (person?.picture) pictures.set(key, person.picture);
          name = person?.name ? person.name : (api.store.names.get(user) ?? user);
        } else {
          name = api.store.names.get(author) ?? author;
        }
      } else {
        name = api.store.names.get(author) ?? author;
      }
    } else {
      // A Slack person: by the name their connect's Slack gives them, as far as known.
      const connect = members.map((m) => m.connect).find((c) => c !== STILLFAIL_CONNECT) ?? null;
      const person = connect === null ? null : api.person(connect, author);
      name = person?.name ? person.name : null;
      if (person?.picture) pictures.set(key, person.picture);
    }
    names.set(key, name);
    return name;
  };
  const picture = (kind: AuthorKind, author: string): string | null => {
    name(kind, author);
    return pictures.get(`${kind}:${author}`) ?? null;
  };
  return Object.assign(name, { picture });
}

/// An author's picture where `names` gives one, as `authorPicture`.
export function pictureView(v: Json, names: Names, kind: AuthorKind, author: string) {
  const picture = names.picture?.(kind, author) ?? null;
  if (picture !== null) v.authorPicture = picture;
}

/// A post's declared kind as the pages read it: `declared` in the words from before, `ending` in today's.
export function declaredView(v: Json, declared: string | null) {
  if (declared !== null) {
    v.declared = store.saidBefore(declared);
    v.ending = store.ending(declared);
  }
}

/// Entries with their authors' names; an agent's also with its session's model and runtime (`authorModel`,
/// `authorRuntime`), so its mark is drawn before the client has read the session.
export function entryViews(api: Api, thread: number, entries: EntryRow[]): Json[] {
  const names = authorNames(api, thread);
  const sessions = new Map<string, SessionRow | null>();
  const origins = new Map<string, string | null>();
  return entries.map((e) => {
    const v = entryJson(e);
    v.authorName = names(e.authorKind, e.author);
    pictureView(v, names, e.authorKind, e.author);
    if (e.authorKind === "agent") {
      if (!sessions.has(e.author)) sessions.set(e.author, store.getSession(api.store, e.author));
      const session = sessions.get(e.author)!;
      if (session !== null) {
        if (typeof e.agentIdentity?.runtime === "string") v.authorRuntime = e.agentIdentity.runtime;
        else {
          if (!origins.has(e.author)) origins.set(e.author, store.originalRuntime(api.store, e.author));
          v.authorRuntime = origins.get(e.author) ?? session.runtime;
        }
        const model = e.agentIdentity != null ? e.agentIdentity.model : v.authorRuntime === session.runtime ? session.model : null;
        if (typeof model === "string") v.authorModel = model;
      }
    }
    declaredView(v, e.declared);
    // Its card, a post's options from before cards as an options card (EntryRow::card).
    const card = e.card !== undefined ? e.card : e.options !== undefined ? store.optionsCard(e.options) : undefined;
    if (card !== undefined) v.card = card;
    return v;
  });
}
