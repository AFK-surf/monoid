// Where a chat is relayed: what the picker shows of the places `chat.relayPlaces` read (the mbui app's sfpages
// relay.mbt). The places of every bot in one list, each once however many bots of its workspace are in it (a channel is
// what a person picks; the bot is a step after it, pengxiao 2026-11-16): those whose name has what was typed (those
// starting with it first), relayed to before (the latest first), then by name; nothing typed, of more than FEW places
// with some relayed to before, only the first RECENT of those unless all were asked for; public channels no bot is in
// yet where a bot of theirs may join one (`open`), marked so. A Slack message's link typed in place of a search. For the
// place picked (`via`): the bot that replies there (the one picked, else the chat's own, else one in it, else one that
// joins it), and every bot of its workspace with where it stands there: in it, joins it as it relays (a public channel,
// the bot let join: channels:join), not in it, or (a private one) only a person there can invite it. Asked of the core as
// `chat.relayView`; self-contained.

/// A place a connect's bot is in: a channel (a new thread there), a topic group (a new topic), a group (its
/// conversation taken over) or a group connect's space (a new topic of its own); `used`, when it was last relayed to (ms).
export type RelayPlace = { id: string; name: string; kind: "channel" | "topics" | "group" | "space"; private?: boolean; used?: number };
/// A connect a chat can be relayed through, with its places (none, and why, when they could not be read).
export type RelayConnect = {
  id: string;
  kind: "slack" | "feishu" | "lark" | "group";
  name: string;
  team: string | null;
  /// Its workspace's id (a Slack team's, a Feishu tenant's): the places of bots of one are the same places.
  teamId?: string | null;
  botImage?: string | null;
  preferred?: boolean;
  places: RelayPlace[];
  /// Whether its bot may join a public channel itself (Slack's channels:join).
  joins?: boolean;
  /// The public channels of its workspace it is not in, where it `joins`.
  open?: RelayPlace[];
  error?: string;
};

/// A place offered: its connect's id and kind, the place, its name as people know it (`#name`, 🔒 before a private
/// channel's), what relaying there does (`note`: a new thread, a new topic, the group's conversation taken over) and
/// what its row says of it at its end in the list (`aside`: none for a channel's new thread).
/// `key`: the place in its workspace (what the picker asks `via` of); `connect`: the bot that replies there unless
/// another is picked.
export type RelayRow = { key: string; connect: string; kind: RelayConnect["kind"]; place: RelayPlace; name: string; note: string; aside: string | null };

/// Where a bot stands in the place picked: in it, joins it as it relays, not in it (and cannot join it), or only a
/// person there can invite it (a private channel: `invite`, what they send there).
export type RelayBotState = "in" | "join" | "out" | "invite";

/// Who replies in the place picked: the bot (`joins`: it joins the place as it relays), and every bot of its workspace
/// with where it stands there.
export type RelayVia = { bot: string; joins: boolean; bots: { id: string; label: string; state: RelayBotState; invite?: string }[] };

/// What the picker shows: the Slack message's link typed (its thread offered instead), the bot gone on through, the
/// bots to pick from (several only), the places offered, whether they are only those relayed to before (`recent`, of
/// `total`), why none are (`empty`: nothing at all, or nothing matches), and the connects whose places were not read.
export type RelayView = {
  link: string | null;
  bot: string | null;
  bots: { id: string; label: string }[];
  rows: RelayRow[];
  recent: boolean;
  total: number;
  empty: "noPlaces" | "noMatch" | null;
  unread: string[];
  via?: RelayVia;
};

type Words = (key: string, args?: Record<string, string | number>) => string;

/** How many places relayed to before are offered first, before 「显示全部」; with no more than FEW in all, all are. */
export const RECENT = 5;
export const FEW = 8;

/** What was typed, as a link to a Slack message (the station finds its workspace among its connects'); else null. */
export function slackLink(typed: string): string | null {
  const s = typed.trim();
  return /^https?:\/\/[^/\s]+\/archives\/[A-Z0-9]+\/p\d{16}/.test(s) ? s : null;
}

/** A place as people know it: a channel's `#name` (🔒 before a private one's), else its name. */
export const placeName = (p: RelayPlace): string => (p.kind === "channel" ? `${p.private ? "🔒 " : ""}#${p.name}` : p.name);

/** What relaying to a place does: a new thread, a new topic, the group's conversation taken over, or a space's new topic. */
export const kindNote = (p: RelayPlace, t: Words): string =>
  t(p.kind === "channel" ? "web-main.relay.kind.channel" : p.kind === "topics" ? "web-main.relay.kind.topics" : p.kind === "space" ? "web-main.relay.kind.space" : "web-main.relay.kind.group");

/** The bot it goes on through: the one picked (`chosen`), else the chat's own (the station's preferred), else the first. */
export function relayBot(connects: readonly RelayConnect[], chosen: string | null): RelayConnect | null {
  return connects.find((c) => c.id === chosen) ?? connects.find((c) => c.preferred === true) ?? connects[0] ?? null;
}

/** A bot as people know it: its name, with its workspace (Slack) or tenant (Feishu) when `connects` are in several. */
export const botLabel = (c: RelayConnect, connects: readonly RelayConnect[]): string =>
  c.team !== null && new Set(connects.map((o) => o.team)).size > 1 ? `${c.name} · ${c.team}` : c.name;

const byName = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * The places offered of `connects`: those whose name has what was typed (those starting with it first), else all of
 * them; then those relayed to before (the latest first), then by name. Nothing typed, more than FEW and some relayed to
 * before, only the first RECENT of those (`recent`) unless all were asked for.
 */
export function arrange(connects: readonly RelayConnect[], query: string, all: boolean): { rows: { connect: RelayConnect; place: RelayPlace }[]; recent: boolean; total: number } {
  const q = query.trim().toLowerCase();
  const rows = connects.flatMap((connect) => connect.places.map((place) => ({ connect, place })));
  const total = rows.length;
  const shown = q === "" ? rows : rows.filter((r) => r.place.name.toLowerCase().includes(q));
  const first = (r: { place: RelayPlace }) => (q !== "" && r.place.name.toLowerCase().startsWith(q) ? 0 : 1);
  shown.sort((a, b) => first(a) - first(b) || (b.place.used ?? -1) - (a.place.used ?? -1) || byName(a.place.name.toLowerCase(), b.place.name.toLowerCase()));
  const used = shown.filter((r) => r.place.used !== undefined);
  if (q === "" && !all && total > FEW && used.length > 0) return { rows: used.slice(0, RECENT), recent: true, total };
  return { rows: shown, recent: false, total };
}

/** The workspace a connect's bot is in: its id where known, else its name. */
const teamOf = (c: RelayConnect): string => c.teamId || c.team || c.id;

/** A place in its workspace, as the picker asks of it. */
const keyOf = (c: RelayConnect, p: RelayPlace): string => `${c.kind}:${teamOf(c)}/${p.id}`;

/** A place, the bots of its workspace in it, and those that would join it (none in it yet). */
type Gathered = { key: string; place: RelayPlace; first: RelayConnect; in: RelayConnect[]; open: boolean };

/** Every place once: those some bot is in (`used` the latest of theirs), then public channels a bot may join that none is in. */
function gather(connects: readonly RelayConnect[]): Gathered[] {
  const by = new Map<string, Gathered>();
  for (const c of connects)
    for (const p of c.places) {
      const key = keyOf(c, p);
      const g = by.get(key);
      if (g === undefined) by.set(key, { key, place: p, first: c, in: [c], open: false });
      else {
        g.in.push(c);
        if ((p.used ?? -1) > (g.place.used ?? -1)) g.place = { ...g.place, used: p.used! };
      }
    }
  for (const c of connects)
    if (c.joins === true)
      for (const p of c.open ?? []) {
        const key = keyOf(c, p);
        if (!by.has(key)) by.set(key, { key, place: p, first: c, in: [], open: true });
      }
  return [...by.values()];
}

/** The bot that replies in a place unless another is picked: the chat's own where it is in it, else the first in it, else the first that joins it. */
const replier = (g: Gathered, connects: readonly RelayConnect[]): RelayConnect =>
  g.in.find((c) => c.preferred === true) ?? g.in[0] ?? connects.find((c) => c.preferred === true && teamOf(c) === teamOf(g.first) && c.joins === true) ?? g.first;

/** Where a bot of the place's workspace stands there. */
function stateIn(g: Gathered, c: RelayConnect): RelayBotState {
  if (g.in.includes(c)) return "in";
  if (g.place.private === true) return c.kind === "slack" ? "invite" : "out";
  return c.kind === "slack" && g.place.kind === "channel" && c.joins === true ? "join" : "out";
}

/** Who replies in the place picked (`key`): the bot picked where it can, else as `replier` says; every bot of its workspace with where it stands. */
export function relayVia(connects: readonly RelayConnect[], key: string, chosen: string | null): RelayVia | null {
  const g = gather(connects).find((x) => x.key === key);
  if (g === undefined) return null;
  const team = connects.filter((c) => c.kind === g.first.kind && teamOf(c) === teamOf(g.first));
  const bots = team.map((c) => {
    const state = stateIn(g, c);
    return { id: c.id, label: c.name, state, ...(state === "invite" ? { invite: `/invite @${c.name}` } : {}) };
  });
  const picked = bots.find((b) => b.id === chosen && (b.state === "in" || b.state === "join"));
  const bot = picked?.id ?? replier(g, connects).id;
  return { bot, joins: bots.find((b) => b.id === bot)?.state === "join", bots };
}

/** What the picker shows of `connects` for what was typed, all asked for or not, the bot picked (null: none yet), and the place picked (`place`, its key: who replies there). */
export function relayView(connects: readonly RelayConnect[], query: string, all: boolean, chosen: string | null, t: Words, place: string | null = null): RelayView {
  const gathered = gather(connects);
  const several = new Set(connects.map((c) => teamOf(c))).size > 1;
  const q = query.trim().toLowerCase();
  const total = gathered.length;
  const shown = q === "" ? gathered : gathered.filter((g) => g.place.name.toLowerCase().includes(q));
  const first = (g: Gathered) => (q !== "" && g.place.name.toLowerCase().startsWith(q) ? 0 : 1);
  shown.sort((a, b) => first(a) - first(b) || Number(a.open) - Number(b.open) || (b.place.used ?? -1) - (a.place.used ?? -1) || byName(a.place.name.toLowerCase(), b.place.name.toLowerCase()));
  const used = shown.filter((g) => g.place.used !== undefined);
  const recent = q === "" && !all && total > FEW && used.length > 0;
  const rows = recent ? used.slice(0, RECENT) : shown;
  // (the bot a Slack message's link is gone on through: the one picked, else the chat's own)
  const bot = relayBot(connects, chosen);
  const view: RelayView = {
    link: slackLink(query),
    bot: bot?.id ?? null,
    bots: [],
    rows: rows.map((g) => {
      const note = kindNote(g.place, t);
      const by = replier(g, connects);
      const aside = g.open ? t("web-main.relay.unjoined") : g.place.kind !== "channel" ? note : several ? (by.team ?? null) : null;
      return { key: g.key, connect: by.id, kind: by.kind, place: g.place, name: placeName(g.place), note, aside };
    }),
    recent,
    total,
    empty: rows.length > 0 || connects.length === 0 ? null : q === "" ? "noPlaces" : "noMatch",
    unread: connects.flatMap((c) => (c.error !== undefined ? [c.error] : [])),
  };
  const via = place === null ? null : relayVia(connects, place, chosen);
  if (via !== null) view.via = via;
  return view;
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string => (typeof v === "string" ? v : "");

/** The connects as `chat.relayPlaces` answered them, given back by a client: what is not as it says left out. */
export function readConnects(v: unknown): RelayConnect[] {
  if (!Array.isArray(v)) return [];
  return v.filter(isObj).map((c) => {
    const kind = c.kind === "feishu" || c.kind === "lark" || c.kind === "group" ? c.kind : "slack";
    const places = (Array.isArray(c.places) ? c.places : []).filter(isObj).map((p) => {
      const place: RelayPlace = { id: str(p.id), name: str(p.name), kind: p.kind === "topics" || p.kind === "group" || p.kind === "space" ? p.kind : "channel" };
      if (p.private === true) place.private = true;
      if (typeof p.used === "number" && Number.isFinite(p.used)) place.used = p.used;
      return place;
    });
    const connect: RelayConnect = { id: str(c.id), kind, name: str(c.name), team: typeof c.team === "string" ? c.team : null, places };
    if (typeof c.teamId === "string" && c.teamId !== "") connect.teamId = c.teamId;
    if (c.joins === true) {
      connect.joins = true;
      connect.open = (Array.isArray(c.open) ? c.open : []).filter(isObj).map((p) => ({ id: str(p.id), name: str(p.name), kind: "channel" as const }));
    }
    if (typeof c.botImage === "string") connect.botImage = c.botImage;
    if (c.preferred === true) connect.preferred = true;
    if (typeof c.error === "string") connect.error = c.error;
    return connect;
  });
}

/// A person in the place picked (`chat.relayPeople`), as the note can mention them: as they are mentioned there (`id`),
/// the name people know them by, the other one they go by (`aka`), their picture.
export type RelayPerson = { id: string; name: string; aka?: string; picture?: string };

/// Who the note can mention now (`chat.relayMentions`): what is typed after its last `@` (null: none being typed) and
/// where that `@` is (-1 none: a menu closed for it stays closed till another), and those of the place it finds, each
/// with the note as it is once they are picked (`note`: `@name ` in place of it).
export type MentionView = { query: string | null; at: number; rows: (RelayPerson & { note: string })[] };

/** How many people are offered for an `@` at most. */
export const MENTIONS = 6;

/** What is typed of a mention at the end of the note: after its last `@` that starts it or follows a space, on one line, not too long; else null. */
export function mentionQuery(note: string): { at: number; query: string } | null {
  const at = note.lastIndexOf("@");
  if (at < 0 || (at > 0 && !/\s/.test(note[at - 1]!))) return null;
  const query = note.slice(at + 1);
  return /[\n\r]/.test(query) || query.length > 40 ? null : { at, query };
}

/** The people of `people` the note's `@` being typed finds (their name or other name has it, those starting with it first; then by name), at most MENTIONS. */
export function mentionView(people: readonly RelayPerson[], note: string): MentionView {
  const typed = mentionQuery(note);
  if (typed === null) return { query: null, at: -1, rows: [] };
  const q = typed.query.toLowerCase();
  const names = (p: RelayPerson) => [p.name, p.aka ?? ""].map((n) => n.toLowerCase());
  const first = (p: RelayPerson) => (names(p).some((n) => n.startsWith(q)) ? 0 : 1);
  const found = people.filter((p) => names(p).some((n) => n.includes(q)));
  found.sort((a, b) => first(a) - first(b) || byName(a.name.toLowerCase(), b.name.toLowerCase()));
  const before = note.slice(0, typed.at);
  return { query: typed.query, at: typed.at, rows: found.slice(0, MENTIONS).map((p) => ({ ...p, note: `${before}@${p.name} ` })) };
}

/** The people as `chat.relayPeople` answered them, given back by a client: what is not as it says left out. */
export function readPeople(v: unknown): RelayPerson[] {
  if (!Array.isArray(v)) return [];
  return v.filter(isObj).flatMap((p) => {
    if (str(p.id) === "" || str(p.name) === "") return [];
    const person: RelayPerson = { id: str(p.id), name: str(p.name) };
    if (str(p.aka) !== "") person.aka = str(p.aka);
    if (str(p.picture) !== "") person.picture = str(p.picture);
    return [person];
  });
}
