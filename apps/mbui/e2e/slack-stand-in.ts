// Slack as the move drill's stations see it (e2e/move.ts, part 4s): its Web API and Socket Mode on local ports, one
// port a station (each station is pointed at its own by $STILLFAIL_SLACK_API, read from `<its dir>/slack-api` as
// scripts/e2e-local.sh starts it), so every call and every socket is known by the station that made it. One Slack
// behind them all: one Slack workspace, its apps known by their app tokens (each app's sockets and events its own),
// each app's bot by its bot token.
//
// What it answers is what Slack answers, as the station's own stand-in has it (station/test/slack-fake.ts and
// test/slack-e2e.test.ts: auth.test and users.info of a bot, apps.connections.open's socket, chat.postMessage's ts, the
// `events_api` envelope); what it does beyond that is Slack's own documented Socket Mode, kept to: a `hello` as a
// socket opens, an event delivered on one open socket of the app, acknowledged by its `envelope_id`, and sent again
// (`retry_attempt`, `retry_reason`) where the socket it went down closed before it was acknowledged. Nothing else is
// made up: every other method is answered `{ ok: true }` and listed (`generic`), so the run says what it answered
// without knowing it.
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createRequire } from "node:module";
import { join } from "node:path";

type J = any;

/// A call a station made: which station (its port), the method, the bearer token, the fields.
export type Call = { station: string; method: string; auth: string; params: Record<string, string>; at: number };
/// A socket a station opened: by which station, when it opened and closed (0: open), what came up it.
export type Socket = { station: string; app: string; n: number; opened: number; closed: number; ws: J; acked: Set<string> };
/// An event sent: its envelope id, what it carries, each delivery (socket, when, the attempt), when acknowledged and by
/// which station.
export type Sent = { id: string; app: string; event: J; deliveries: { station: string; n: number; at: number; attempt: number }[]; acked: { station: string; at: number } | null };

export const TEAM = "T1";
/// An app of the workspace: its app token (Socket Mode), its bot's token and user.
export type App = { app: string; bot: string; user: string };

export class SlackStandIn {
  readonly servers = new Map<string, { server: Server; base: string }>();
  readonly calls: Call[] = [];
  readonly sockets: Socket[] = [];
  readonly sent = new Map<string, Sent>();
  /// Methods answered `{ ok: true }` and nothing else, with how many times each.
  readonly generic = new Map<string, number>();
  /// Of each app (by its app token): the most sockets open at once, and each moment none was (from, to; to 0 while
  /// still none, from 0: before its first).
  readonly most = new Map<string, number>();
  readonly none = new Map<string, { from: number; to: number }[]>();
  /// The app token each socket address was given for (apps.connections.open's).
  private readonly appOf = new Map<number, string>();
  private ts = 1;
  private n = 0;
  private waiters = new Set<() => void>();
  private readonly WebSocketServer: J;
  private queue: string[] = [];
  private gaps(app: string) {
    if (!this.none.has(app)) this.none.set(app, [{ from: 0, to: 0 }]);
    return this.none.get(app)!;
  }

  readonly apps: App[];
  /// Told each socket's opening and closing as it happens, with how many of its app's are open then.
  told: (line: string) => void;
  constructor(src: string, apps: App[], told: (line: string) => void = () => {}) {
    this.apps = apps;
    this.told = told;
    // (the station's own `ws`, as its stand-in uses it: nothing installed for the drill)
    this.WebSocketServer = createRequire(join(src, "station", "package.json"))("ws").WebSocketServer;
  }

  /// A port for station `name`: its Web API at `<base>` and its sockets beside it.
  async listen(name: string): Promise<string> {
    const wss = new this.WebSocketServer({ noServer: true });
    const server = createServer((req, res) => {
      void this.take(name, req).then(
        (body) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body)),
        (e) => res.writeHead(500).end(String(e)),
      );
    });
    server.on("upgrade", (req, socket, head) => {
      const m = /^\/socket\/([^/]+)\/(\d+)/.exec(req.url ?? "");
      if (m === null || m[1] !== name) return void socket.destroy();
      wss.handleUpgrade(req, socket, head, (ws: J) => this.opened(name, Number(m[2]), ws));
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/api`;
    this.servers.set(name, { server, base });
    return base;
  }

  /// The sockets open now (of one app).
  live(app?: string): Socket[] {
    return this.sockets.filter((s) => s.closed === 0 && (app === undefined || s.app === app));
  }

  /// Resolves once `f` gives something (looked at as anything is heard), or fails past `ms` saying `what`.
  until<T>(what: string, f: () => T | undefined | null | false, ms: number): Promise<T> {
    return new Promise((resolve, reject) => {
      const look = () => {
        const v = f();
        if (v === undefined || v === null || v === false) return;
        this.waiters.delete(look);
        clearTimeout(timer);
        resolve(v);
      };
      const timer = setTimeout(() => {
        this.waiters.delete(look);
        reject(new Error(`Slack's stand-in: no ${what} in ${ms / 1000} s`));
      }, ms);
      this.waiters.add(look);
      look();
    });
  }

  /// An event of Slack's (`events_api`) for app `app`, sent down an open socket of it now or, none open, as one opens:
  /// Slack keeps it.
  event(app: string, event: J): string {
    const id = `env-${++this.n}`;
    this.sent.set(id, { id, app, event, deliveries: [], acked: null });
    this.queue.push(id);
    this.deliver();
    return id;
  }

  /// A person's message in a thread (`thread` its first message's ts; none: a new conversation that mentions the bot).
  say(app: string, channel: string, text: string, thread?: string, user = "U42"): { ts: string; id: string } {
    const m = this.message(app, channel, text, thread, user);
    return { ts: m.ts, id: this.event(app, m.event) };
  }
  /// Such a message as Slack's event, not sent.
  message(app: string, channel: string, text: string, thread?: string, user = "U42"): { ts: string; event: J } {
    const ts = `${Math.floor(Date.now() / 1000)}.${String(100000 + (++this.ts % 900000)).padStart(6, "0")}`;
    const event = thread === undefined
      ? { type: "app_mention", channel, user, ts, text: `<@${this.botOf(app)}> ${text}`, team: TEAM }
      : { type: "message", channel, user, thread_ts: thread, ts, text: `<@${this.botOf(app)}> ${text}`, team: TEAM };
    return { ts, event };
  }

  /// The window a connect's move opens, given an event at each end of it: as station `to` asks for a socket of `app`
  /// (apps.connections.open: it took the connect), `last` goes at once down the socket of it open on another station
  /// (the one leaving, the last thing it is given; none open there, it waits as any event does), and `first` is the
  /// first thing down `to`'s new socket. What came of each: `ids` (their envelopes) once each is sent, `lastOn` where
  /// `last` went ("A#3", or "waited": none was open).
  arm(app: string, to: string, last: J, first: J): { ids: { last: string; first: string }; lastOn: string } {
    const armed = { app, to, last, first, ids: { last: "", first: "" }, lastOn: "" };
    this.armed = armed;
    return armed;
  }
  private armed: { app: string; to: string; last: J; first: J; ids: { last: string; first: string }; lastOn: string } | null = null;
  private sendOn(s: Socket, e: Sent) {
    const attempt = e.deliveries.length;
    e.deliveries.push({ station: s.station, n: s.n, at: Date.now(), attempt });
    s.ws.send(JSON.stringify({
      type: "events_api",
      envelope_id: e.id,
      payload: { token: "drill", team_id: TEAM, api_app_id: "A1", event: e.event, type: "event_callback", event_id: `Ev${e.id}`, event_time: Math.floor(Date.now() / 1000) },
      accepts_response_payload: false,
      ...(attempt > 0 ? { retry_attempt: attempt, retry_reason: "timeout" } : {}),
    }));
  }

  private botOf(app: string): string {
    return this.apps.find((a) => a.app === app)?.user ?? "";
  }

  /// What was posted into a thread (chat.postMessage with its thread_ts, or as its first message), by whom.
  posted(channel: string, thread: string): Call[] {
    return this.calls.filter((c) => c.method === "chat.postMessage" && c.params.channel === channel && c.params.thread_ts === thread);
  }

  async close(): Promise<void> {
    for (const s of this.sockets) if (s.closed === 0) s.ws.terminate();
    for (const { server } of this.servers.values()) {
      server.closeAllConnections();
      await new Promise<void>((r) => server.close(() => r()));
    }
  }

  private tell() {
    for (const w of [...this.waiters]) w();
  }

  private opened(station: string, n: number, ws: J) {
    const app = this.appOf.get(n) ?? "";
    const s: Socket = { station, app, n, opened: Date.now(), closed: 0, ws, acked: new Set() };
    this.sockets.push(s);
    const open = this.live(app).length;
    this.most.set(app, Math.max(this.most.get(app) ?? 0, open));
    const gap = this.gaps(app).at(-1);
    if (gap !== undefined && gap.to === 0) gap.to = s.opened;
    this.told(`Slack: ${app} socket ${station}#${n} opened at ${new Date(s.opened).toISOString().slice(11, 23)}, ${open} open: ${this.live(app).map((x) => `${x.station}#${x.n}`).join(",")}`);
    // (Socket Mode's first word on a socket: https://api.slack.com/apis/socket-mode, "hello")
    ws.send(JSON.stringify({ type: "hello", num_connections: open, debug_info: { host: "drill", approximate_connection_time: 18060 }, connection_info: { app_id: "A1" } }));
    // (the window's arriving end: its first event, before anything waiting)
    const armed = this.armed;
    if (armed !== null && armed.ids.last !== "" && armed.ids.first === "" && armed.app === app && armed.to === station) {
      const id = `env-${++this.n}`;
      const e: Sent = { id, app, event: armed.first, deliveries: [], acked: null };
      this.sent.set(id, e);
      armed.ids.first = id;
      this.armed = null;
      this.sendOn(s, e);
    }
    ws.on("message", (data: J) => {
      let m: J;
      try {
        m = JSON.parse(String(data));
      } catch {
        return;
      }
      const sent = typeof m?.envelope_id === "string" ? this.sent.get(m.envelope_id) : undefined;
      if (sent !== undefined) {
        s.acked.add(sent.id);
        if (sent.acked === null) sent.acked = { station, at: Date.now() };
      }
      this.tell();
    });
    ws.on("close", () => {
      s.closed = Date.now();
      if (this.live(app).length === 0) this.gaps(app).push({ from: s.closed, to: 0 });
      this.told(`Slack: ${app} socket ${station}#${n} closed at ${new Date(s.closed).toISOString().slice(11, 23)}, ${this.live(app).length} open: ${this.live(app).map((x) => `${x.station}#${x.n}`).join(",") || "none"}`);
      // (what went down it and was not acknowledged: Slack sends it again on another of the app's sockets)
      for (const e of this.sent.values()) {
        const last = e.deliveries.at(-1);
        if (e.acked === null && last !== undefined && last.station === station && last.n === n && !this.queue.includes(e.id)) this.queue.push(e.id);
      }
      this.deliver();
      this.tell();
    });
    this.deliver();
    this.tell();
  }

  /// What waits goes down the newest open socket of its app, in order; what has none open waits.
  private deliver() {
    const waiting = this.queue;
    this.queue = [];
    for (const id of waiting) {
      const e = this.sent.get(id)!;
      const s = this.live(e.app).at(-1);
      if (s === undefined) {
        this.queue.push(id);
        continue;
      }
      this.sendOn(s, e);
    }
  }

  private async take(station: string, req: IncomingMessage): Promise<J> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks);
    const type = String(req.headers["content-type"] ?? "");
    const params: Record<string, string> = {};
    if (type.startsWith("application/x-www-form-urlencoded")) for (const [k, v] of new URLSearchParams(raw.toString("utf8"))) params[k] = v;
    else if (type.startsWith("multipart/form-data")) {
      const form = await new Response(raw, { headers: { "content-type": type } }).formData();
      for (const [k, v] of form) if (typeof v === "string") params[k] = v;
    }
    const method = (req.url ?? "/").split("?")[0]!.replace(/^\/api\//, "").replace(/^\//, "");
    this.calls.push({ station, method, auth: String(req.headers.authorization ?? "").replace(/^Bearer /, ""), params, at: Date.now() });
    this.tell();
    // (as station/test/slack-fake.ts `bot` and FakeSlack answer them)
    const token = String(req.headers.authorization ?? "").replace(/^Bearer /, "");
    if (method === "auth.test") {
      const bot = this.apps.find((a) => a.bot === token);
      return bot === undefined ? { ok: false, error: "invalid_auth" } : { ok: true, user_id: bot.user, user: `${bot.user.toLowerCase()}_bot`, team: "Acme", team_id: TEAM, url: "https://acme.slack.com/", bot_id: `B${bot.user}` };
    }
    if (method === "users.info") {
      const bot = this.apps.find((a) => a.user === params.user);
      return bot !== undefined
        ? { ok: true, user: { id: bot.user, real_name: "ember", profile: { display_name: "ember", image_72: "https://avatars.slack-edge.com/ember_72.png" } } }
        : { ok: true, user: { id: params.user, name: "ada", real_name: "Ada L", profile: { display_name: "Ada", email: "Ada@Example.test" } } };
    }
    if (method === "apps.connections.open") {
      // (the window's leaving end: the last thing down the other station's socket, as this one asks for its own)
      const armed = this.armed;
      if (armed !== null && armed.ids.last === "" && armed.app === token && armed.to === station) {
        const id = `env-${++this.n}`;
        const e: Sent = { id, app: token, event: armed.last, deliveries: [], acked: null };
        this.sent.set(id, e);
        armed.ids.last = id;
        const leaving = this.live(token).filter((x) => x.station !== station).at(-1);
        if (leaving !== undefined) {
          armed.lastOn = `${leaving.station}#${leaving.n}`;
          this.sendOn(leaving, e);
        } else {
          armed.lastOn = "waited";
          this.queue.push(id);
        }
      }
      const n = ++this.n;
      this.appOf.set(n, token);
      return { ok: true, url: `${this.servers.get(station)!.base.replace(/^http/, "ws").replace(/\/api$/, "")}/socket/${station}/${n}` };
    }
    if (method === "chat.postMessage") return { ok: true, channel: params.channel, ts: `${8_000_000 + this.ts++}.000100` };
    this.generic.set(method, (this.generic.get(method) ?? 0) + 1);
    return { ok: true };
  }
}
