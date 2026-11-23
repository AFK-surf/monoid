// A station must not send a closed-enum runtime to a client that cannot decode it. New clients advertise their
// runtime vocabulary; requests without it retain the pre-Hermes wire vocabulary. Project metadata only,
// following its schema: never rewrite user messages, tool inputs/results, files, previews or module payloads.
import { StringDecoder } from "node:string_decoder";
import { runtimeView, OMIT } from "../read/runtime-view.ts";
export { runtimeView } from "../read/runtime-view.ts";
import type { Ty } from "../../../client/core-ts/src/shapes/dsl.ts";
import { RUNTIME_KINDS } from "../agents/runtime.ts";
import { error, type Answer, type Request } from "./request.ts";
import { tr } from "../ops/i18n.ts";

export const RUNTIMES_HEADER = "stillfail-runtimes";
export const PROFILE_SERVICES_HEADER = "stillfail-profile-services";
const LEGACY = ["claude", "codex", "dsh", "grok", "cursor", "devin"];
const object = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
export function clientRuntimes(headers: Record<string, string>): Set<string> {
  const value = Object.entries(headers).find(([k]) => k.toLowerCase() === RUNTIMES_HEADER)?.[1];
  return new Set(value === undefined ? LEGACY : value.split(",").map(s => s.trim()).filter(s => /^[a-z][a-z0-9-]{0,39}$/.test(s)));
}
export function clientProfileServices(headers: Record<string, string>): boolean {
  const value = Object.entries(headers).find(([k]) => k.toLowerCase() === PROFILE_SERVICES_HEADER)?.[1];
  return value?.trim() === "1";
}

function entriesView(value: unknown, supported: Set<string>): unknown {
  if (!object(value) || !Array.isArray(value.entries)) return value;
  return { ...value, entries: value.entries.map((entry: unknown) => {
    if (!object(entry) || typeof entry.authorRuntime !== "string" || supported.has(entry.authorRuntime)) return entry;
    const copy = { ...entry }; delete copy.authorRuntime; return copy;
  }) };
}

function shapeFor(path: string): Ty | undefined {
  if (path === "/overview") return "Overview";
  if (path === "/sessions") return { vec: "Session" };
  if (/^\/sessions\/[^/]+$/.test(path)) return "SessionDetail";
  if (path === "/threads") return { vec: "ChatThread" };
  if (/^\/threads\/[^/]+$/.test(path)) return "ChatThread";
  if (path === "/chats") return { vec: "ChatItem" };
  return undefined;
}

const EVENTS: Record<string, Ty> = { overview: "Overview", session: "Session" };
function frame(text: string, supported: Set<string>, supportsServices: boolean): string {
  const lines = text.split("\n");
  const event = lines.find(l => l.startsWith("event: "))?.slice(7);
  const i = lines.findIndex(l => l.startsWith("data: "));
  const type = event && EVENTS[event];
  if (i < 0 || (!type && event !== "thread")) return text;
  const value = JSON.parse(lines[i]!.slice(6));
  const view = event === "thread" ? entriesView(value, supported) : runtimeView(type!, value, supported, supportsServices);
  if (view === OMIT && event === "session") {
    // Keep the event's id for resumable streams and remove an obsolete cached session.
    lines[lines.findIndex(l => l.startsWith("event: "))] = "event: session-removed";
    lines[i] = `data: ${JSON.stringify({ key: value.key })}`;
  } else lines[i] = `data: ${JSON.stringify(view === OMIT ? null : view)}`;
  return lines.join("\n");
}

/// The event a frame names (`event: `), read from its head alone: none once its data begins.
function eventOf(text: string): string | undefined {
  for (let at = 0; ;) {
    const end = text.indexOf("\n", at);
    const line = end < 0 ? text.slice(at) : text.slice(at, end);
    if (line.startsWith("data: ")) return undefined;
    if (line.startsWith("event: ")) return line.slice(7);
    if (end < 0) return undefined;
    at = end + 1;
  }
}
/// Whether `frame` changes a frame at all: the rest (live rates, shared chats, jobs, pings) goes out as it came.
const projected = (text: string) => {
  const event = eventOf(text);
  return event === "thread" || (event !== undefined && Object.hasOwn(EVENTS, event));
};

/// What older clients of the same vocabulary are told of one event is the same text: made once for all their streams,
/// and the same string, so the program carrying them is handed it once (mesh/served.ts `#piece`). Every event went
/// through `frame` again for each such stream (a JSON parse, the view, a stringify), and a station with dozens of them
/// spent seconds of its thread on each burst of events (mm2, 0.1.11070). Only frames `frame` changes are kept, the
/// latest of them within FRAMES_KEPT and FRAME_BYTES_KEPT: a burst tells its streams one after another.
const FRAMES_KEPT = 64;
const FRAME_BYTES_KEPT = 4 * 1024 * 1024;
const framed = new Map<string, string>();
let framedBytes = 0;
function frameOnce(vocabulary: string, text: string, supported: Set<string>, supportsServices: boolean): string {
  if (!projected(text)) return text + "\n\n";
  const key = `${vocabulary}\0${text}`;
  const had = framed.get(key);
  if (had !== undefined) return had;
  const made = frame(text, supported, supportsServices) + "\n\n";
  framed.set(key, made);
  framedBytes += key.length + made.length;
  while (framed.size > FRAMES_KEPT || (framedBytes > FRAME_BYTES_KEPT && framed.size > 1)) {
    const [oldKey, oldMade] = framed.entries().next().value!;
    framed.delete(oldKey);
    framedBytes -= oldKey.length + oldMade.length;
  }
  return made;
}

/// A piece of the stream, whole events each ending with a blank line (events.ts `raw`), as an older client is told it:
/// one event (nearly every piece) is the kept string itself, one `frame` leaves as it is the piece itself; a last
/// event with no blank line after it (none told so) is made apart, not kept.
function piece(vocabulary: string, text: string, supported: Set<string>, supportsServices: boolean): string {
  const first = text.indexOf("\n\n");
  if (first >= 0 && first === text.length - 2) return projected(text) ? frameOnce(vocabulary, text.slice(0, first), supported, supportsServices) : text;
  let out = "";
  let at = 0;
  for (let end; (end = text.indexOf("\n\n", at)) >= 0; at = end + 2) out += frameOnce(vocabulary, text.slice(at, end), supported, supportsServices);
  return at < text.length ? out + frame(text.slice(at), supported, supportsServices) : out;
}

async function* events(body: AsyncIterable<Buffer>, vocabulary: string, supported: Set<string>, supportsServices: boolean) {
  const decoder = new StringDecoder("utf8");
  let pending = "";
  for await (const chunk of body) {
    pending += decoder.write(chunk);
    let end;
    while ((end = pending.indexOf("\n\n")) >= 0) {
      yield Buffer.from(frameOnce(vocabulary, pending.slice(0,end), supported, supportsServices));
      pending = pending.slice(end+2);
    }
  }
  pending += decoder.end();
  if (pending) yield Buffer.from(frame(pending, supported, supportsServices));
}

type Relayed = AsyncIterableIterator<Buffer> & { relay?: (send: (text: string) => void, ended: () => void) => void };

/// The event stream as an older client is told it. Where the stream is carried piece by piece (`relay`: events.ts, the
/// MoonBit program writing it), each piece goes as it is told, so the program is given one text for every stream told
/// it alike; ending the stream ends the one it reads.
function compatStream(inner: Relayed, supported: Set<string>, supportsServices: boolean): Relayed {
  const vocabulary = `${[...supported].sort().join(",")}|${supportsServices ? 1 : 0}`;
  const read = events(inner, vocabulary, supported, supportsServices);
  const body: Relayed = {
    [Symbol.asyncIterator]: () => body,
    next: () => read.next(),
    return: async () => {
      await inner.return?.();
      return read.return(undefined);
    },
  };
  const relay = inner.relay;
  if (typeof relay === "function") {
    body.relay = (send, ended) => relay.call(inner, (text) => send(piece(vocabulary, text, supported, supportsServices)), ended);
  }
  return body;
}

export function runtimeCompatible(r: Request, answer: Answer): Answer {
  if (answer.status < 200 || answer.status >= 300) return answer;
  const supported = clientRuntimes(r.headers);
  const supportsServices = clientProfileServices(r.headers);
  if (RUNTIME_KINDS.every(k => supported.has(k)) && supportsServices) return answer;
  const path = r.path.replace(/\/+$/, "");
  if (path === "/events" && !Buffer.isBuffer(answer.body)) return { ...answer, body: compatStream(answer.body as Relayed, supported, supportsServices) };
  if (!Buffer.isBuffer(answer.body) || !(answer.headers["content-type"] ?? "").startsWith("application/json")) return answer;
  // Project after idempotent response caching, including each answer in a batch. Reusing a write key from a
  // different client must neither repeat the write nor reuse the previous client's filtered view.
  if (path === "/batch") {
    const gets = JSON.parse(r.body.toString("utf8"))?.gets;
    const raw = JSON.parse(answer.body.toString("utf8"));
    if (!Array.isArray(gets) || !Array.isArray(raw?.answers)) return answer;
    const answers = raw.answers.map((a: any, i: number) => {
      if (typeof gets[i] !== "string") return a;
      const projected = runtimeCompatible({ ...r, method: "GET", path: gets[i].split("?")[0] },
        { status: a.status, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(a.body)) });
      return { ...a, status: projected.status, body: JSON.parse(String(projected.body)) };
    });
    const headers = { ...answer.headers }; delete headers["content-length"];
    return { ...answer, headers, body: Buffer.from(JSON.stringify({ ...raw, answers })) };
  }
  let type = shapeFor(path);
  // Account writes return an overview, sometimes wrapped with the newly created id. Read-only old clients must
  // not be broken by an unrelated account edit either. Files/preview/module replies never enter this branch.
  const entries = /^\/threads\/[^/]+\/entries$/.test(path);
  const account = /^\/(profiles|logins|automatic-decisions|archiving|auto-chats|connects|slack|feishu|group|me\/slack)(\/|$)/.test(path);
  if (!type && !account && !entries) return answer;
  const raw = JSON.parse(answer.body.toString("utf8"));
  let view: unknown;
  if (entries) view = entriesView(raw, supported);
  else if (account && object(raw)) {
    view = "overview" in raw ? { ...raw, overview: runtimeView("Overview", raw.overview, supported, supportsServices) } : runtimeView("Overview", raw, supported, supportsServices);
  } else view = runtimeView(type!, raw, supported, supportsServices);
  if (view === OMIT) return error(426, tr(r.lang, "station.admin.updateClientForRuntime"));
  const headers = { ...answer.headers }; delete headers["content-length"];
  return { ...answer, headers, body: Buffer.from(JSON.stringify(view)) };
}
