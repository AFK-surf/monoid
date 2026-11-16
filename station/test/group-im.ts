// An IM server of AFK-surf/group's protocol (`im/1`) for the group connect's tests: on an endpoint the test gives it
// (a mesh in memory, or the addon's on 127.0.0.1), its connections taken by the mesh's own loop and door
// (src/mesh/accept.ts, door.ts, wire.ts) and its event stream the station's event log (src/api/event-log.ts), as the
// IM's server is made of them. What it answers is the server's routes as group's protocol.ts and server/api.ts say
// them, with the files, edits and replies of the contract the connect is written to; who is let in is by the device's
// key, a code good once to join by. The test speaks for the people (`say`, `upload`, `edit`) as the server would take
// what their devices sent.
import { createHash, randomBytes } from "node:crypto";
import { Effect, Exit, Fiber, Scope } from "effect";
import { EventLog } from "../src/api/event-log.ts";
import { accept } from "../src/mesh/accept.ts";
import { door, type Admit } from "../src/mesh/door.ts";
import type { Connection, Endpoint } from "../src/mesh/endpoint.ts";
import { type Answer, type Asked, send } from "../src/mesh/wire.ts";

type Json = any;

export type ImFile = { id: string; name: string; mime: string; size: number; sha256: string; width?: number; height?: number; bytes: Buffer };
export type ImMessage = { n: number; id: string; from: string; text: string; at: number; files?: Omit<ImFile, "bytes">[]; replyTo?: number; edited?: number; deleted?: number };
type Conv = { id: string; kind: "private" | "group"; members: string[]; name: string | null; by: string; at: number; messages: ImMessage[]; files: Map<string, ImFile> };

/// One reader's stream: what it is yet to be sent.
class Feed implements AsyncIterable<Buffer> {
  readonly member: string;
  #pending: Buffer[] = [];
  #wake: (() => void) | null = null;
  #done = false;
  readonly #ended: () => void;
  constructor(member: string, ended: () => void) {
    this.member = member;
    this.#ended = ended;
  }
  push(text: string) {
    if (this.#done) return;
    this.#pending.push(Buffer.from(text));
    this.#wake?.();
  }
  end() {
    if (this.#done) return;
    this.#done = true;
    this.#ended();
    this.#wake?.();
  }
  [Symbol.asyncIterator](): AsyncIterator<Buffer> {
    return {
      next: async () => {
        while (this.#pending.length === 0 && !this.#done) await new Promise<void>((resolve) => (this.#wake = resolve));
        this.#wake = null;
        if (this.#pending.length === 0) return { done: true, value: undefined };
        const value = Buffer.concat(this.#pending);
        this.#pending = [];
        return { done: false, value };
      },
      return: async () => {
        this.end();
        return { done: true, value: undefined };
      },
    };
  }
}

const json = (status: number, body: unknown): Answer => ({ status, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(body)) });

export class ImServer {
  readonly endpoint: Endpoint;
  members = new Map<string, { id: string; name: string; owner: boolean; joined: number }>();
  devices = new Map<string, string>();
  codes = new Map<string, { member: string | null }>();
  conversations = new Map<string, Conv>();
  /// Every request asked, `METHOD path`, in order.
  asked: string[] = [];
  /// Every hello said, as it came.
  hellos: Json[] = [];
  #log = new EventLog<string[]>();
  #feeds = new Set<Feed>();
  #conns = new Set<Connection>();
  #scope = Effect.runSync(Scope.make());
  #serving: Fiber.Fiber<void> | null = null;
  #clock = 1_000;
  #waiters: (() => void)[] = [];

  constructor(endpoint: Endpoint) {
    this.endpoint = endpoint;
    const admit: Admit = (hello, conn) => this.#admit(hello, conn);
    this.#serving = Effect.runFork(
      accept(endpoint, { arrived: (conn) => void this.#conns.add(conn), serve: (conn) => door(conn, admit).finally(() => this.#conns.delete(conn)), failed: () => {}, closing: "server stopping" }).pipe(Scope.provide(this.#scope)),
    );
  }

  /// Once `f` holds: woken by what the server takes and says.
  async until(f: () => boolean) {
    while (!f()) await new Promise<void>((resolve) => this.#waiters.push(resolve));
  }
  #changed() {
    for (const w of this.#waiters.splice(0)) w();
  }

  member(name: string, owner = false): string {
    const id = randomBytes(6).toString("hex");
    this.members.set(id, { id, name, owner, joined: this.#clock });
    return id;
  }

  /// A code a new member joins by (`member` null) or another device of `member`'s.
  code(member: string | null = null): string {
    const letters = [...randomBytes(16)].map((b) => "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"[b & 31]).join("");
    const code = letters.match(/.{4}/g)!.join("-");
    this.codes.set(letters, { member });
    return code;
  }

  #admit(hello: Json, conn: Connection): ReturnType<Admit> {
    this.hellos.push(hello);
    this.#changed();
    const device = conn.remoteId();
    let member = this.devices.get(device) ?? null;
    let joined = false;
    if (member === null) {
      const said = typeof hello?.credential === "string" ? hello.credential.toUpperCase().replace(/[\s-]/g, "") : "";
      const code = said === "" ? undefined : this.codes.get(said);
      if (code === undefined) {
        const why = said === "" ? "not_joined" : "code_unknown";
        return { refused: { line: { error: why === "not_joined" ? "this device is nobody's: join with a code" : "no such code", code: "credential_refused", why }, code: 1, reason: "credential_refused", error: new Error(why) } };
      }
      this.codes.delete(said);
      member = code.member ?? this.member(typeof hello?.name === "string" && hello.name !== "" ? hello.name : "member");
      this.devices.set(device, member);
      joined = true;
      this.#tell("member", this.members.get(member), [...this.members.keys()]);
    }
    const who = this.members.get(member)!;
    return {
      line: { ok: true, member: who.id, name: who.name, owner: who.owner, joined },
      renew: () => ({ ok: true, member: who.id }),
      stream: () => (asked) => this.#answer(who.id, asked),
    };
  }

  #tell(event: string, data: unknown, to: string[]) {
    const told = this.#log.append(event, data, to, this.#clock);
    for (const feed of this.#feeds) if (to.includes(feed.member)) feed.push(told.text);
    this.#changed();
  }

  /// Every connection cut, as a network that went (the connect dials again).
  cut() {
    for (const conn of [...this.#conns]) conn.close(0, "cut");
    for (const feed of [...this.#feeds]) feed.end();
  }

  /// The log let go of what it kept: a stream that comes back is told it missed something.
  forget() {
    this.#log.clear();
  }

  #conv(id: string, member: string): Conv | null {
    const c = this.conversations.get(id);
    return c !== undefined && c.members.includes(member) ? c : null;
  }

  #listed(c: Conv, member: string) {
    const last = c.messages.at(-1) ?? null;
    const other = c.members.find((m) => m !== member);
    return { id: c.id, kind: c.kind, members: c.members, name: c.kind === "group" ? c.name : (other ? (this.members.get(other)?.name ?? null) : null), by: c.by, at: c.at, last: last?.n ?? 0, latest: last === null ? null : { n: last.n, from: last.from, name: this.members.get(last.from)?.name ?? "", text: last.text, at: last.at }, active: last?.at ?? c.at };
  }

  private_(a: string, b: string): string {
    const id = randomBytes(8).toString("hex");
    const c: Conv = { id, kind: "private", members: [a, b].sort(), name: null, by: a, at: this.#clock, messages: [], files: new Map() };
    this.conversations.set(id, c);
    this.#tell("conversation", { id, kind: c.kind, members: c.members, name: null, by: a, at: c.at }, c.members);
    return id;
  }

  group(name: string, by: string, members: string[]): string {
    const id = randomBytes(8).toString("hex");
    const c: Conv = { id, kind: "group", members: [...new Set([by, ...members])].sort(), name, by, at: this.#clock, messages: [], files: new Map() };
    this.conversations.set(id, c);
    this.#tell("conversation", { id, kind: c.kind, members: c.members, name, by, at: c.at }, c.members);
    return id;
  }

  add(conv: string, member: string) {
    const c = this.conversations.get(conv)!;
    c.members = [...new Set([...c.members, member])].sort();
    this.#tell("conversation", { id: c.id, kind: c.kind, members: c.members, name: c.name, by: c.by, at: c.at }, c.members);
  }

  /// A message taken from `from`'s device.
  say(conv: string, from: string, text: string, more: { files?: string[]; replyTo?: number } = {}): ImMessage {
    const c = this.conversations.get(conv)!;
    this.#clock += 1000;
    const files = (more.files ?? []).map((f) => c.files.get(f)!).map(({ bytes: _, ...f }) => f);
    const m: ImMessage = { n: c.messages.length + 1, id: randomBytes(6).toString("hex"), from, text, at: this.#clock, ...(files.length > 0 ? { files } : {}), ...(more.replyTo !== undefined ? { replyTo: more.replyTo } : {}) };
    c.messages.push(m);
    this.#tell("message", { ...m, conversation: conv }, c.members);
    return m;
  }

  upload(conv: string, name: string, mime: string, bytes: Buffer, shape: { width?: number; height?: number } = {}): ImFile {
    const c = this.conversations.get(conv)!;
    const file: ImFile = { id: randomBytes(6).toString("hex"), name, mime, size: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex"), ...shape, bytes };
    c.files.set(file.id, file);
    return file;
  }

  edit(conv: string, n: number, text: string) {
    const c = this.conversations.get(conv)!;
    const m = c.messages[n - 1]!;
    m.text = text;
    m.edited = this.#clock;
    this.#tell("message_updated", { ...m, conversation: conv }, c.members);
  }

  async #answer(member: string, asked: Asked) {
    const body = await asked.reader.rest();
    this.asked.push(`${asked.head.method} ${asked.head.path}`);
    this.#changed();
    const reply = this.#route(member, asked.head, body);
    await send(asked.stream, reply);
    await asked.stream.finish().catch(() => {});
  }

  #route(member: string, head: Json, body: Buffer): Answer {
    const url = new URL(head.path, "im://server");
    const path = url.pathname.split("/").filter((p) => p !== "");
    const asks = (method: string, ...parts: (string | null)[]) => head.method === method && path.length === parts.length && parts.every((p, i) => p === null || p === path[i]);
    const said = (): Json => {
      try {
        return JSON.parse(body.toString());
      } catch {
        return null;
      }
    };
    const NOT_THERE = json(404, { error: "no such conversation" });
    if (asks("GET", "members")) return json(200, { members: [...this.members.values()] });
    if (asks("POST", "me", "name")) {
      const name = said()?.name;
      if (typeof name !== "string" || name.trim() === "" || [...name].length > 40) return json(400, { error: "`name` is 1 to 40 characters" });
      const m = this.members.get(member)!;
      m.name = name.trim();
      this.#tell("member", m, [...this.members.keys()]);
      return json(200, { member: m });
    }
    if (asks("GET", "conversations")) return json(200, { conversations: [...this.conversations.values()].filter((c) => c.members.includes(member)).map((c) => this.#listed(c, member)) });
    if (asks("GET", "events")) {
      const since = url.searchParams.get("since");
      const feed = new Feed(member, () => this.#feeds.delete(feed));
      const resumes = since !== null && this.#log.has(since);
      if (resumes) for (const told of this.#log.after(since)) if (told.to.includes(member)) feed.push(told.text);
      if (!resumes) {
        if (since !== null) feed.push("event: missed\ndata: {}\n\n");
        feed.push(`id: ${this.#log.at()}\n\n`);
      }
      this.#feeds.add(feed);
      return { status: 200, headers: { "content-type": "text/event-stream", ...(resumes ? { "im-resumed": "1" } : {}) }, body: feed };
    }
    const c = path[0] === "conversations" && path[1] !== undefined ? this.#conv(path[1], member) : null;
    if (path[0] === "conversations" && c === null) return NOT_THERE;
    if (c !== null && asks("POST", "conversations", null, "leave")) {
      c.members = c.members.filter((m) => m !== member);
      this.#tell("left", { conversation: c.id }, [member]);
      return json(200, { conversation: c.id });
    }
    if (c !== null && asks("POST", "conversations", null, "files")) {
      const name = url.searchParams.get("name") ?? "";
      const side = (k: string) => (/^[1-9]\d{0,5}$/.test(url.searchParams.get(k) ?? "") ? Number(url.searchParams.get(k)) : undefined);
      const [width, height] = [side("width"), side("height")];
      const file = this.upload(c.id, name, url.searchParams.get("mime") ?? "application/octet-stream", body, width !== undefined && height !== undefined ? { width, height } : {});
      const { bytes: _, ...shown } = file;
      return json(201, { file: shown });
    }
    if (c !== null && asks("GET", "conversations", null, "files", null)) {
      const file = c.files.get(path[3]!);
      return file === undefined ? json(404, { error: "no such file" }) : { status: 200, headers: { "content-type": file.mime }, body: file.bytes };
    }
    if (c !== null && asks("POST", "conversations", null, "messages")) {
      const { id, text, files, replyTo } = said() ?? {};
      if (typeof id !== "string" || id === "") return json(400, { error: "`id` is 1-64 printable characters" });
      const again = c.messages.find((m) => m.from === member && m.id === id);
      if (again) return json(200, { message: again, again: true });
      if ((typeof text !== "string" || text === "") && !(Array.isArray(files) && files.length > 0)) return json(400, { error: "a message says something" });
      if (Array.isArray(files) && files.some((f) => !c.files.has(f))) return json(400, { error: "no such file" });
      this.#clock += 1000;
      const m: ImMessage = { n: c.messages.length + 1, id, from: member, text: typeof text === "string" ? text : "", at: this.#clock, ...(Array.isArray(files) && files.length > 0 ? { files: files.map((f: string) => (({ bytes: _, ...x }) => x)(c.files.get(f)!)) } : {}), ...(typeof replyTo === "number" ? { replyTo } : {}) };
      c.messages.push(m);
      this.#tell("message", { ...m, conversation: c.id }, c.members);
      return json(201, { message: m, again: false });
    }
    if (c !== null && asks("GET", "conversations", null, "messages")) {
      const q = url.searchParams;
      if (q.has("last") || q.has("before")) {
        const most = q.has("last") ? Number(q.get("last")) : 500;
        const before = q.has("before") ? Number(q.get("before")) : c.messages.length + 1;
        const upTo = c.messages.slice(0, Math.max(0, before - 1));
        const page = upTo.slice(Math.max(0, upTo.length - most));
        return json(200, { messages: page, more: upTo.length > page.length });
      }
      const after = Number(q.get("after") ?? 0);
      const rest = c.messages.slice(after);
      return json(200, { messages: rest.slice(0, 500), more: rest.length > 500 });
    }
    return json(404, { error: "no such request" });
  }

  async close() {
    for (const feed of [...this.#feeds]) feed.end();
    if (this.#serving !== null) await Effect.runPromise(Fiber.interrupt(this.#serving));
    await Effect.runPromise(Scope.close(this.#scope, Exit.void));
    await this.endpoint.close();
  }
}
