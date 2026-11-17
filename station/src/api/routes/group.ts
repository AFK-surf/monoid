// Group connects through the pages: one added (POST /group/connects: an IM server's endpoint id, its relays, the code
// the station joins it by and the name it joins as), and a group connect's part of its config entry (`groupEntry`, as
// any edit of a connect gives it: PUT /connects/:id with `group`). Editing, deleting and reconnecting a connect are
// every connect's (routes/connects.ts). Its key is made here as it is added and never given to a page.
import { randomBytes } from "node:crypto";
import type { Request } from "../request.ts";
import { type Answer, error } from "../request.ts";
import type { Route } from "../admin.ts";
import { log } from "../../ops/log.ts";
import { type Lang, stationLang, tr } from "../../ops/i18n.ts";
import type { EntryEdit } from "../../connects/connections.ts";
import { type ConnectEditDeps, Refused, connectEdits, connectSlug, get, input, isObject, ok, str } from "./connects.ts";

type Json = any;

/// A server's endpoint id: 64 hex.
const SERVER = /^[0-9a-f]{64}$/;
/// A code: 16 of the server's letters, in fours (its `hashOf`: hyphens and spaces aside, any case).
const CODE = /^[2-9A-HJ-NP-Z]{16}$/;
/// The longest name a member has there (the server's NAME_MOST).
const NAME_MOST = 40;

/// Relays as given: a list, or words of a text (lines, commas, spaces).
function relaysOf(v: unknown): string[] | null {
  const list = Array.isArray(v) ? v : typeof v === "string" ? v.split(/[\s,]+/) : null;
  if (list === null) return null;
  return [...new Set(list.filter((r): r is string => typeof r === "string").map((r) => r.trim()).filter((r) => r !== ""))];
}

const isRelay = (r: string) => {
  try {
    const u = new URL(r);
    return (u.protocol === "https:" || u.protocol === "http:") && u.hostname !== "";
  } catch {
    return false;
  }
};

/// A code as it is kept: its letters in capitals, in fours. Null: not one.
export function codeOf(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const letters = v.toUpperCase().replace(/[\s-]/g, "");
  return CODE.test(letters) ? letters.match(/.{4}/g)!.join("-") : null;
}

/// What is wrong with a connect's part as it would be (said in `lang`): none, an empty list.
function faults(g: Json, lang: Lang): string[] {
  const out: string[] = [];
  if (typeof g.server !== "string" || !SERVER.test(g.server)) out.push(tr(lang, "station.group.badServer"));
  const relays: string[] = Array.isArray(g.relays) ? g.relays : [];
  if (relays.length === 0) out.push(tr(lang, "station.group.noRelay"));
  else if (relays.some((r) => !isRelay(r))) out.push(tr(lang, "station.group.badRelay"));
  if (g.code === undefined && typeof g.memberId !== "string" && typeof g.bound !== "string") out.push(tr(lang, "station.group.noCode"));
  if (typeof g.botName === "string" && [...g.botName].length > NAME_MOST) out.push(tr(lang, "station.group.longName", { most: NAME_MOST }));
  return out;
}

/// A group connect's part of its config entry (`group`), from what was given and what it had: its server, relays, code
/// and name as given (a field not given stays as it was; a code given that is none is refused), its key kept (made
/// where it has none). Another server is another membership: who it was there and what it was bound by go.
export const groupEntryIn = (lang: Lang): EntryEdit => (given, had) => {
  if (!isObject(given) && had === null) return null;
  const g: Json = { ...(had ?? {}) };
  const server = str(get(given, "server"));
  if (server !== undefined && server.trim().toLowerCase() !== g.server) {
    g.server = server.trim().toLowerCase();
    for (const key of ["memberId", "name", "bound"]) delete g[key];
  }
  const relays = relaysOf(get(given, "relays"));
  if (relays !== null) g.relays = relays;
  const code = get(given, "code");
  if (typeof code === "string" && code.trim() !== "") {
    const kept = codeOf(code);
    if (kept === null) throw new Refused(400, tr(lang, "station.group.badCode"));
    g.code = kept;
  }
  const name = get(given, "botName");
  if (typeof name === "string") {
    if (name.trim() === "") delete g.botName;
    else g.botName = name.trim();
  } else if (name === null) delete g.botName;
  if (typeof g.key !== "string" || !SERVER.test(g.key)) g.key = randomBytes(32).toString("hex");
  const wrong = faults(g, lang);
  if (wrong.length > 0) throw new Refused(400, wrong.join(tr(lang, "station.list.semicolon")));
  return g;
};

/// As the pages' edits give it, said in the station's language.
export const groupEntry: EntryEdit = (given, had) => groupEntryIn(stationLang())(given, had);

export type GroupRoutesDeps = Omit<ConnectEditDeps, "entry">;

export const groupRoutes = (deps: GroupRoutesDeps): Route[] => {
  const answer = (f: (r: Request, args: string[]) => Promise<Answer> | Answer) => async (r: Request, args: string[]) => {
    try {
      return await f(r, args);
    } catch (e) {
      if (e instanceof Refused) return error(e.status, e.message);
      log.error("admin", "admin request failed", { path: r.path, error: (e as Error).message });
      return error(500, (e as Error).message);
    }
  };
  const { putConnect, raw, connectsRaw } = connectEdits({ ...deps, entry: (kind) => (kind === "group" ? groupEntry : undefined) });

  /// POST /group/connects: a connect made of a server, its relays and a code, connected once saved (it joins then:
  /// the overview says how that went).
  const create = async (r: Request) => {
    const i = input(r);
    const given = i.group;
    if (!isObject(given)) throw new Refused(400, tr(r.lang, "station.group.badServer"));
    // (checked in the asker's words before it is saved)
    groupEntryIn(r.lang)(given, null);
    if (codeOf(given.code) === null) throw new Refused(400, tr(r.lang, "station.group.noCode"));
    const taken = new Set(connectsRaw(raw()).map((c: Json) => c?.id));
    const base = connectSlug(typeof given.botName === "string" && given.botName.trim() !== "" ? given.botName : "group", "group");
    let id = base;
    for (let n = 2; taken.has(id); n++) id = `${base}-${n}`;
    const overview = await putConnect(r, id, { ...i, kind: "group", group: given });
    return ok({ id, overview });
  };

  return [{ method: "POST", pattern: /^\/group\/connects$/, handle: answer(create) }];
};
