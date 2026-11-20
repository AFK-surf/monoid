// An anchor of AFK-surf/group's protocol (`im/2`) for the group connect's tests: on an endpoint the test gives it (a
// mesh in memory, or the addon's on 127.0.0.1), its connections taken by the mesh's own loop and door
// (src/mesh/accept.ts, door.ts, wire.ts), as the IM's anchor is made of the same framing. What it answers is the
// anchor's routes as core/src/im/anchor.mbt says them (the members, `POST /sync`, `POST /events`, the stream, a space's
// events and files, a file put a piece at a time as wave 4 has it), with what wave 3 adds (`live`, `stop`, a space's
// devices, `secrets`); what it takes is checked as
// the anchor checks it (the device's signature and its member's, the space the author's, the count after the last,
// what its kind asks) and stamped in its place. Who is let in is by the device's key, a code good once to join by.
//
// The test speaks for the people through their own devices (`Person`: a key of their own, each event signed by it, as
// their app would say it), and presses what their apps would (`resolve`, `stop`, a secret handed directly).
import { randomBytes } from "node:crypto";
import { Effect, Exit, Fiber, Scope } from "effect";
import { accept } from "../src/mesh/accept.ts";
import { door, type Admit } from "../src/mesh/door.ts";
import type { Connection, Endpoint, Endpoints } from "../src/mesh/endpoint.ts";
import { Reader, type Answer, type Asked, send, writeLine } from "../src/mesh/wire.ts";
import { type GroupEvent, LOBBY, type Stamped, deviceOfKey, directId, eventId, eventOf, isSpaceId, isTopicId, sha256Hex, signEvent, signingKey, verified } from "../src/group/event.ts";
import { SECRET_ALPN } from "../src/group/link.ts";

type Json = any;

export type ImFile = { sha256: string; name: string; mime: string; size: number; width?: number; height?: number; by: string; held: string; bytes: Buffer };
type Msg = { id: string; aseq: number; n: number; topic: string; kind: string; author: string; text: string; files: Json[]; replyTo: string; deleted: boolean; open: boolean; input: string; options: string[]; assignee: string };
type Space = { id: string; kind: "direct" | "space"; name: string; members: string[]; by: string; at: number; lastAseq: number; lastN: number; events: Stamped[]; said: Map<string, number>; topics: Map<string, { title: string; branchedFrom: string }>; msgs: Map<string, Msg>; files: Map<string, ImFile> };

/// One reader's stream: what it is yet to be sent.
class Feed implements AsyncIterable<Buffer> {
  readonly member: string;
  readonly device: string;
  #pending: Buffer[] = [];
  #wake: (() => void) | null = null;
  #done = false;
  readonly #ended: () => void;
  constructor(member: string, device: string, ended: () => void) {
    this.member = member;
    this.device = device;
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
const text = (v: unknown) => (typeof v === "string" ? v : "");

/// A member's device as the test holds it: its key, and what it said in each space.
export class Person {
  readonly member: string;
  readonly key = randomBytes(32);
  readonly signer = signingKey(this.key.toString("hex"));
  readonly device = deviceOfKey(this.signer);
  readonly #said = new Map<string, { dseq: number; prev: string }>();
  #hlc = 0;
  constructor(member: string) {
    this.member = member;
  }
  sign(space: string, topic: string, kind: string, body: Json): GroupEvent {
    const last = this.#said.get(space) ?? { dseq: 0, prev: "" };
    const e = signEvent(this.signer, { space, author: this.member, device: this.device, dseq: last.dseq + 1, hlc: [++this.#hlc, 0], prev: last.prev, topic, kind, body });
    this.#said.set(space, { dseq: e.dseq, prev: eventId(e) });
    return e;
  }
}

export class ImServer {
  readonly endpoint: Endpoint;
  members = new Map<string, { id: string; name: string; owner: boolean; joined: number; removed?: number }>();
  devices = new Map<string, string>();
  codes = new Map<string, { member: string | null }>();
  spaces = new Map<string, Space>();
  people = new Map<string, Person>();
  /// Every request asked, `METHOD path`, in order; every hello said; every live state said, every event refused (its why).
  asked: string[] = [];
  hellos: Json[] = [];
  lives: Json[] = [];
  refusals: string[] = [];
  /// Secrets put through it (`POST /spaces/<id>/secrets`): only their ids, as the anchor keeps none.
  passed: string[] = [];
  /// An anchor from before decisions: `decision.ask` and `decision.resolve` refused as kinds it does not know.
  noDecisions = false;
  /// What came of files put a piece at a time, by `<sha256>.part.<member>` (anchor.mbt `part_path`); the largest body a
  /// file's ask carried; an anchor from before pieces (`GET …/uploads/…` no request of its, a piece's query not read).
  parts = new Map<string, Buffer>();
  largestPut = 0;
  noPieces = false;
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

  /// Once `f` holds: woken by what the anchor takes and says.
  async until(f: () => boolean) {
    while (!f()) await new Promise<void>((resolve) => this.#waiters.push(resolve));
  }
  #changed() {
    for (const w of this.#waiters.splice(0)) w();
  }

  /// A member with a device of their own (what the test speaks for them by).
  member(name: string, owner = false): string {
    const id = `m_${randomBytes(8).toString("hex")}`;
    this.members.set(id, { id, name, owner, joined: this.#clock });
    const person = new Person(id);
    this.people.set(id, person);
    this.devices.set(person.device, id);
    return id;
  }

  /// A code a new member joins by (`member` null) or another device of `member`'s.
  code(member: string | null = null): string {
    const letters = [...randomBytes(16)].map((b) => "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"[b & 31]).join("");
    this.codes.set(letters, { member });
    return letters.match(/.{4}/g)!.join("-");
  }

  #admit(hello: Json, conn: Connection): ReturnType<Admit> {
    this.hellos.push(hello);
    this.#changed();
    const device = conn.remoteId();
    let member = this.devices.get(device) ?? null;
    let joined = false;
    if (member !== null && this.members.get(member)?.removed !== undefined) member = null;
    if (member === null) {
      const said = typeof hello?.credential === "string" ? hello.credential.toUpperCase().replace(/[\s-]/g, "") : "";
      const code = said === "" ? undefined : this.codes.get(said);
      if (code === undefined) {
        const why = this.devices.has(device) ? "device_removed" : said === "" ? "not_joined" : "code_unknown";
        return { refused: { line: { error: why, code: "credential_refused", why }, code: 1, reason: "credential_refused", error: new Error(why) } };
      }
      this.codes.delete(said);
      if (code.member !== null) member = code.member;
      else {
        member = `m_${randomBytes(8).toString("hex")}`;
        this.members.set(member, { id: member, name: typeof hello?.name === "string" && hello.name !== "" ? hello.name : "member", owner: false, joined: this.#clock });
      }
      this.devices.set(device, member);
      joined = true;
      this.#tellAll("member", this.members.get(member));
    }
    const who = this.members.get(member)!;
    return {
      line: { ok: true, member: who.id, name: who.name, owner: who.owner, joined, community: "c".repeat(64) },
      renew: () => ({ ok: true, member: who.id }),
      stream: () => (asked) => this.#answer(who.id, device, asked),
    };
  }

  /// A member taken out: their devices let go, their connections closed.
  remove(member: string) {
    const m = this.members.get(member)!;
    m.removed = this.#clock;
    for (const conn of [...this.#conns]) if (this.devices.get(conn.remoteId()) === member) conn.close(1, "credential_revoked");
    for (const feed of [...this.#feeds]) if (feed.member === member) feed.end();
    this.#tellAll("member", m);
  }

  #tell(event: string, data: unknown, to: string[]) {
    const told = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const feed of this.#feeds) if (to.includes(feed.member)) feed.push(told);
    this.#changed();
  }
  #tellAll(event: string, data: unknown) {
    this.#tell(event, data, [...this.members.keys()]);
  }

  /// Every connection cut, as a network that went (the connect dials again).
  cut() {
    for (const conn of [...this.#conns]) conn.close(0, "cut");
    for (const feed of [...this.#feeds]) feed.end();
  }

  spaceJson(s: Space) {
    return { id: s.id, kind: s.kind, name: s.name, members: s.members, by: s.by, at: s.at, last_aseq: s.lastAseq, last_n: s.lastN };
  }

  // ── what the people's devices say ──

  #by(member: string): Person {
    return this.people.get(member)!;
  }

  /// An event of `from`'s device taken (failing the test where it is refused): its stamp.
  #said(from: string, e: GroupEvent): Stamped {
    const r = this.#take(from, this.#by(from).device, e);
    if (typeof r.aseq !== "number") throw new Error(`the anchor refused ${e.kind}: ${r.why}`);
    return this.spaces.get(e.space)!.events.at(-1)!;
  }

  /// The direct space of `a` and `b`, made by `a`.
  direct(a: string, b: string): string {
    const id = directId(a, b);
    const pair = a < b ? [a, b] : [b, a];
    this.#said(a, this.#by(a).sign(id, LOBBY, "space.create", { members: pair }));
    return id;
  }

  /// A space of these members, named, made by `by`.
  group(name: string, by: string, members: string[]): string {
    const id = `s_${randomBytes(12).toString("hex")}`;
    this.#said(by, this.#by(by).sign(id, LOBBY, "space.create", { name, members: [...new Set([by, ...members])] }));
    return id;
  }

  add(space: string, by: string, member: string) {
    this.#said(by, this.#by(by).sign(space, LOBBY, "space.members", { add: [member] }));
  }

  /// A topic opened by `by` (branched from the message of event `from`, where given): its id.
  topic(space: string, by: string, title: string, from = ""): string {
    const id = `t_${randomBytes(8).toString("hex")}`;
    this.#said(by, this.#by(by).sign(space, id, "topic.open", { topic: id, title, ...(from !== "" ? { branched_from: from } : {}) }));
    return id;
  }

  /// A message taken from `from`'s device: its stamp.
  say(space: string, from: string, words: string, more: { topic?: string; files?: string[]; replyTo?: string } = {}): Stamped {
    const s = this.spaces.get(space)!;
    const files = (more.files ?? []).map((sha) => s.files.get(sha)!).map(({ bytes: _, by: _b, held: _h, ...f }) => f);
    return this.#said(from, this.#by(from).sign(space, more.topic ?? LOBBY, "msg.post", { text: words, files, ...(more.replyTo ? { reply_to: more.replyTo } : {}) }));
  }

  /// A file put into a space by `by`, as their device uploads it.
  upload(space: string, by: string, name: string, mime: string, bytes: Buffer): ImFile {
    const file: ImFile = { sha256: sha256Hex(bytes), name, mime, size: bytes.length, by, held: "", bytes };
    this.spaces.get(space)!.files.set(file.sha256, file);
    return file;
  }

  edit(space: string, from: string, target: string, words: string): Stamped {
    const m = this.spaces.get(space)!.msgs.get(target)!;
    return this.#said(from, this.#by(from).sign(space, m.topic, "msg.edit", { target, text: words }));
  }

  /// A decision answered by `by`, as their app's button or field says it: the event, or why it was refused.
  resolve(space: string, by: string, target: string, choice: string): { aseq?: number; why?: string } {
    const m = this.spaces.get(space)!.msgs.get(target)!;
    return this.#take(by, this.#by(by).device, this.#by(by).sign(space, m.topic, "decision.resolve", { target, choice }));
  }

  /// Stop pressed by `by` on a stream's live state.
  stop(space: string, by: string, topic = LOBBY, target = "") {
    this.#tell("stop", { space, topic, by, target, message_ts: "", at: (this.#clock += 1000) }, this.spaces.get(space)!.members);
  }

  /// A secret handed by `from` through the anchor in passing (`POST /spaces/<id>/secrets`, then `secret` to `to`).
  secretThrough(space: string, from: string, to: string, label: string, value: string, topic = LOBBY): string {
    const id = randomBytes(8).toString("hex");
    this.passed.push(id);
    this.#tell("secret", { id, space, topic, from, device: this.#by(from).device, label, value, at: this.#clock }, [to]);
    return id;
  }

  /// A secret handed by `from`'s device directly to `to`'s (`im-secret/1`), dialled on `mesh` by its key (or by
  /// another's: `as`): what the receiving device answered.
  async secretDirect(mesh: Endpoints, space: string, from: string, toDevice: string, label: string, value: string, topic = LOBBY, as?: Buffer): Promise<Json> {
    const id = randomBytes(8).toString("hex");
    const mine = await mesh.bind({ secretKey: as ?? this.#by(from).key, alpns: [], relayUrls: [], discovery: false });
    try {
      const conn = await mine.connect({ id: toDevice }, Buffer.from(SECRET_ALPN));
      const stream = await conn.openBi();
      await writeLine(stream, { id, space, topic, from, label, value, at: this.#clock });
      await stream.finish();
      const answer = await new Reader(stream).line();
      conn.close(0, "done");
      return answer;
    } finally {
      await mine.close();
    }
  }

  // ── what the anchor takes ──

  #refused(who: string, device: string, e: GroupEvent): string | null {
    if (e.author !== who || e.device !== device) return "not_yours";
    if (!verified(e)) return "bad_signature";
    const decisions = ["decision.ask", "decision.resolve"];
    if (!["space.create", "space.members", "topic.open", "topic.patch", "msg.post", "msg.edit", "msg.unsend", "msg.react", ...(this.noDecisions ? [] : decisions), "secret.sent"].includes(e.kind)) return "kind";
    if (!isSpaceId(e.space) || !isTopicId(e.topic)) return "space";
    const s = this.spaces.get(e.space);
    if (s) {
      if (e.kind === "space.create") return "exists";
      if (!s.members.includes(e.author)) return "no_space";
    } else if (e.kind !== "space.create") return "no_space";
    if (e.dseq <= (s?.said.get(e.device) ?? 0)) return "dseq";
    if (e.topic !== LOBBY && !s?.topics.has(e.topic) && e.kind !== "topic.open") return "topic";
    const b = e.body ?? {};
    if (e.kind === "space.create") {
      const members: string[] = Array.isArray(b.members) ? b.members : [];
      if (!members.includes(e.author) || !members.every((m) => this.members.has(m))) return "members";
      if (e.space.startsWith("d_") && (members.length !== 2 || e.space !== directId(members[0]!, members[1]!))) return "members";
    }
    if (e.kind === "topic.open" && (e.topic !== b.topic || e.space.startsWith("d_"))) return "topic";
    if (e.kind === "topic.open" && text(b.branched_from) !== "" && !s?.msgs.has(b.branched_from)) return "branched_from";
    if (e.kind === "msg.post" || e.kind === "decision.ask") {
      const files: Json[] = Array.isArray(b.files) ? b.files : [];
      if (text(b.text).length > 20_000 || files.length > 10) return "too_long";
      if (text(b.text).trim() === "" && files.length === 0) return "empty";
      if (text(b.reply_to) !== "" && !s!.msgs.has(b.reply_to)) return "reply_to";
      for (const f of files) {
        const held = s!.files.get(f?.sha256);
        if (held === undefined || held.by !== e.author || held.held !== "" || held.size !== f.size) return "file";
      }
    }
    if (["msg.edit", "msg.unsend", "msg.react", "decision.resolve"].includes(e.kind)) {
      const m = s!.msgs.get(text(b.target));
      if (m === undefined) return "target";
      if (e.kind === "msg.edit" && (m.author !== e.author || m.deleted)) return "not_yours";
      if (e.kind === "decision.resolve") {
        if (m.kind !== "decision.ask" || !m.open) return "target";
        const choice = text(b.choice).trim();
        if (choice === "" || choice.length > 4000) return "empty";
        if (m.input === "options" && m.options.length > 0 && !m.options.includes(choice)) return "choice";
        if (m.assignee !== "" && m.assignee !== e.author) return "not_yours";
      }
    }
    return null;
  }

  #take(who: string, device: string, e: GroupEvent): Json {
    const id = eventId(e);
    const s0 = this.spaces.get(e.space);
    const again = s0?.events.find((x) => x.id === id);
    if (again) return { id, aseq: again.aseq, n: again.n, at: again.at };
    const why = this.#refused(who, device, e);
    if (why !== null) {
      this.refusals.push(why);
      this.#changed();
      return { id, error: `refused: ${why}`, why };
    }
    const before = s0 === undefined ? null : [...s0.members];
    if (e.kind === "space.create") {
      this.spaces.set(e.space, { id: e.space, kind: e.space.startsWith("d_") ? "direct" : "space", name: text(e.body.name), members: [...e.body.members], by: e.author, at: this.#clock, lastAseq: 0, lastN: 0, events: [], said: new Map(), topics: new Map(), msgs: new Map(), files: new Map() });
    }
    const s = this.spaces.get(e.space)!;
    const numbered = e.kind === "msg.post" || e.kind === "decision.ask" || e.kind === "secret.sent";
    this.#clock += 1000;
    const stamped: Stamped = { id, event: e, aseq: s.lastAseq + 1, n: numbered ? s.lastN + 1 : 0, at: this.#clock };
    s.lastAseq = stamped.aseq;
    if (numbered) s.lastN = stamped.n;
    s.events.push(stamped);
    s.said.set(e.device, e.dseq);
    const b = e.body ?? {};
    if (e.kind === "space.members") {
      const gone = new Set<string>([...(b.remove ?? []), ...(b.leave === true ? [e.author] : [])]);
      s.members = [...new Set([...s.members, ...(b.add ?? [])])].filter((m) => !gone.has(m));
      if (typeof b.name === "string") s.name = b.name;
    }
    if (e.kind === "topic.open") s.topics.set(b.topic, { title: text(b.title), branchedFrom: text(b.branched_from) });
    if (e.kind === "msg.post" || e.kind === "decision.ask") {
      const options = (Array.isArray(b.options) ? b.options : []).map((o: Json) => (typeof o === "string" ? o : text(o?.label)));
      s.msgs.set(id, { id, aseq: stamped.aseq, n: stamped.n, topic: e.topic, kind: e.kind, author: e.author, text: text(b.text), files: b.files ?? [], replyTo: text(b.reply_to), deleted: false, open: e.kind === "decision.ask", input: b.input === "text" ? "text" : "options", options, assignee: text(b.assignee) });
      for (const f of b.files ?? []) s.files.get(f.sha256)!.held = id;
    }
    if (e.kind === "msg.edit") s.msgs.get(b.target)!.text = text(b.text);
    if (e.kind === "decision.resolve") s.msgs.get(b.target)!.open = false;
    if (e.kind === "space.create" || e.kind === "space.members") {
      this.#tell("space", this.spaceJson(s), s.members);
      const gone = (before ?? []).filter((m) => !s.members.includes(m));
      if (gone.length > 0) this.#tell("left", { space: s.id }, gone);
    }
    this.#tell("event", { space: s.id, stamped }, s.members);
    return { id, aseq: stamped.aseq, n: stamped.n, at: stamped.at };
  }

  /// The messages of a stream as the anchor keeps them (`topic`: "lobby" for its lobby).
  messages(space: string, topic = LOBBY): Msg[] {
    return [...this.spaces.get(space)!.msgs.values()].filter((m) => m.topic === topic);
  }

  async #answer(member: string, device: string, asked: Asked) {
    const body = await asked.reader.rest();
    this.asked.push(`${asked.head.method} ${asked.head.path}`);
    this.#changed();
    const reply = this.#route(member, device, asked.head, body);
    await send(asked.stream, reply);
    await asked.stream.finish().catch(() => {});
  }

  #route(member: string, device: string, head: Json, body: Buffer): Answer {
    if (this.devices.get(device) !== member || this.members.get(member)?.removed !== undefined) return json(401, { error: "this device was removed" });
    const url = new URL(head.path, "im://anchor");
    const path = url.pathname.split("/").filter((p) => p !== "");
    const asks = (method: string, ...parts: (string | null)[]) => head.method === method && path.length === parts.length && parts.every((p, i) => p === null || p === path[i]);
    const said = (): Json => {
      try {
        return JSON.parse(body.toString());
      } catch {
        return null;
      }
    };
    if (asks("GET", "members")) return json(200, { members: [...this.members.values()] });
    if (asks("POST", "me", "name")) {
      const name = said()?.name;
      if (typeof name !== "string" || name.trim() === "" || [...name].length > 40) return json(400, { error: "a name is 1 to 40 characters" });
      const m = this.members.get(member)!;
      m.name = name.trim();
      this.#tellAll("member", m);
      return json(200, m);
    }
    if (asks("GET", "events")) {
      const feed = new Feed(member, device, () => this.#feeds.delete(feed));
      feed.push(`event: ready\ndata: ${JSON.stringify({ community: "c".repeat(64) })}\n\n`);
      this.#feeds.add(feed);
      return { status: 200, headers: { "content-type": "text/event-stream" }, body: feed };
    }
    if (asks("POST", "sync")) {
      const since: Record<string, unknown> = said()?.since ?? {};
      const mine = [...this.spaces.values()].filter((s) => s.members.includes(member));
      const events: Stamped[] = [];
      const dseq: Record<string, number> = {};
      let more = false;
      for (const s of mine) {
        const after = typeof since[s.id] === "number" ? (since[s.id] as number) : 0;
        const got = s.events.filter((x) => x.aseq > after).slice(0, Math.max(0, 2000 - events.length));
        if (after + got.length < s.lastAseq) more = true;
        events.push(...got);
        const last = s.said.get(device);
        if (last !== undefined) dseq[s.id] = last;
      }
      const left = Object.keys(since).filter((id) => !mine.some((s) => s.id === id));
      return json(200, { spaces: mine.map((s) => this.spaceJson(s)), events, more, left, dseq });
    }
    if (asks("POST", "events")) {
      const all = said()?.events;
      const results = (Array.isArray(all) ? all : []).map((j: Json) => {
        const e = eventOf(j);
        return e === null ? { error: "not an event", why: "malformed" } : this.#take(member, device, e);
      });
      return json(200, { results });
    }
    const s = path[0] === "spaces" && path[1] !== undefined ? this.spaces.get(path[1]) : undefined;
    if (path[0] === "spaces" && (s === undefined || !s.members.includes(member))) return json(404, { error: "no such space" });
    if (s !== undefined && asks("GET", "spaces", null, "events")) {
      const after = Number(url.searchParams.get("after") ?? 0);
      return json(200, { events: s.events.filter((x) => x.aseq > after).slice(0, 500) });
    }
    if (s !== undefined && asks("GET", "spaces", null, "uploads", null) && !this.noPieces) {
      return json(200, { have: this.parts.get(`${path[3]}.part.${member}`)?.length ?? 0 });
    }
    if (s !== undefined && asks("POST", "spaces", null, "files")) this.largestPut = Math.max(this.largestPut, body.length);
    if (s !== undefined && asks("POST", "spaces", null, "files") && url.searchParams.has("sha256") && !this.noPieces) return this.#piece(s, member, url, body);
    if (s !== undefined && asks("POST", "spaces", null, "files")) {
      const file = this.upload(s.id, member, url.searchParams.get("name") ?? "", url.searchParams.get("mime") ?? "application/octet-stream", body);
      const side = (k: string) => (/^[1-9]\d{0,5}$/.test(url.searchParams.get(k) ?? "") ? Number(url.searchParams.get(k)) : undefined);
      const [width, height] = [side("width"), side("height")];
      if (width !== undefined && height !== undefined) Object.assign(file, { width, height });
      const { bytes: _, by: _b, held: _h, ...shown } = file;
      return json(201, { file: shown });
    }
    if (s !== undefined && asks("GET", "spaces", null, "files", null)) {
      const file = s.files.get(path[3]!);
      return file === undefined ? json(404, { error: "no such file" }) : { status: 200, headers: { "content-type": file.mime }, body: file.bytes };
    }
    if (s !== undefined && asks("POST", "spaces", null, "live")) {
      const b = said() ?? {};
      const live = { space: s.id, topic: text(b.topic) || LOBBY, author: member, device, state: text(b.state), text: text(b.text), stoppable: b.stoppable !== false, message_ts: text(b.message_ts), at: this.#clock };
      this.lives.push(live);
      this.#tell("live", live, s.members);
      return json(200, { ok: true });
    }
    if (s !== undefined && asks("GET", "spaces", null, "devices")) {
      const of = url.searchParams.get("member") ?? "";
      if (!s.members.includes(of)) return json(404, { error: "no such space" });
      return json(200, { devices: [...this.devices.entries()].filter(([, m]) => m === of).map(([d]) => d) });
    }
    return json(404, { error: "no such request" });
  }

  /// A piece of a file put a piece at a time (anchor.mbt `upload_piece`): appended where `from` is what came of it, kept
  /// as the file once all of it came and it is what its sha256 says.
  #piece(s: Space, member: string, url: URL, body: Buffer): Answer {
    const q = (k: string) => url.searchParams.get(k) ?? "";
    const sha = q("sha256");
    const size = Number(q("size"));
    const from = Number(q("from"));
    if (!/^[0-9a-f]{64}$/.test(sha)) return json(400, { error: "a file's sha256 is 64 hex" });
    if (!Number.isSafeInteger(size) || size < 1 || size > 512 * 1024 * 1024) return json(413, { error: "a file is 1 byte to 512 MiB" });
    const put = () => {
      const whole = [...this.spaces.values()].flatMap((x) => [...x.files.values()]).find((f) => f.sha256 === sha)!;
      const file = this.upload(s.id, member, q("name"), q("mime") || "application/octet-stream", whole.bytes);
      const side = (k: string) => (/^[1-9]\d{0,5}$/.test(q(k)) ? Number(q(k)) : undefined);
      if (side("width") !== undefined && side("height") !== undefined) Object.assign(file, { width: side("width"), height: side("height") });
      const { bytes: _, by: _b, held: _h, ...shown } = file;
      return json(201, { file: shown });
    };
    if ([...this.spaces.values()].some((x) => x.files.get(sha)?.size === size)) return put();
    const key = `${sha}.part.${member}`;
    const have = this.parts.get(key) ?? Buffer.alloc(0);
    if (from !== have.length) return json(409, { error: "the file's next piece is another", have: have.length });
    const now = Buffer.concat([have, body]);
    if (now.length > size) {
      this.parts.delete(key);
      return json(400, { error: "more of the file came than its size" });
    }
    this.parts.set(key, now);
    if (now.length < size) return json(202, { have: now.length });
    this.parts.delete(key);
    if (sha256Hex(now) !== sha) return json(422, { error: "the file that came is not the one its sha256 names: it is put again from its start" });
    this.upload(s.id, member, q("name"), q("mime"), now);
    return put();
  }

  async close() {
    for (const feed of [...this.#feeds]) feed.end();
    if (this.#serving !== null) await Effect.runPromise(Fiber.interrupt(this.#serving));
    await Effect.runPromise(Scope.close(this.#scope, Exit.void));
    await this.endpoint.close();
  }
}
