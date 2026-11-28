// A Comma connect: the station as a computer of a Comma workspace, whose agents work in the Comma Tasks given to it,
// as Slack's connect makes it the bot of a Slack workspace. It connects out to Comma (`<server>/v1/connect`, the
// connector protocol, with the connector token Comma's still.fail plugin gave) and speaks the Tasks protocol Comma's
// own stations speak (Cue systems/station/src/tasks/tasks.ts, as a station taking part in a Task Comma keeps):
// - task.invite: a Task for an agent here. Answered with the session it is to be (sessionKey of its thread); the
//   session is made as the first Message of the Task comes.
// - task.put: the Task's Messages, each heard as a message of its thread (the Task, channel TASK), from the Comma
//   member who said it; what the session here posted itself, and what it answered already, is not heard again.
// - task.post (to Comma): what the agent says in the thread, and where its turn stands at its end (all_done,
//   need_help: standsAt); a card it asks with goes as Comma's question card. task.posted_file: Comma reads the files of
//   a post while it waits for it. task.file: a file of a Task's Message, read a part at a time.
// - task.status: where the session stands. task.leave: the Task runs elsewhere; the session leaves its thread.
// - task.hello: as it connects, the Tasks it takes part in and how far it has each; Comma gives what it missed.
// - stats.index, task.index (to Comma): the workspace's statistics and its chats as Comma lists the Tasks its stations
//   host (stats.ts), what Comma lacks of them a page at a time, as it connects and as they change; Comma answers what
//   it holds.
// - task.read, task.say: the Router reads a chat of the Task index, or writes in it as itself (`chats`, module.ts).
// Comma's heartbeat is answered with one. Whatever else Comma asks (files, commands: a Comma station's) is refused.
import { randomUUID } from "node:crypto";
import { open } from "node:fs/promises";
import { arch, hostname, platform } from "node:os";
import { Effect } from "effect";
import type WebSocket from "ws";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { version } from "../ops/version.ts";
import type { BotIdentity } from "../connects/connections.ts";
import { personKey } from "../connects/keys.ts";
import type { NameBook } from "../connects/names.ts";
import { StatusLine } from "../connects/status.ts";
import { ConnectedSurface } from "../connects/surface.ts";
import { type Handler, type InboundFile, type ModelChoice, type Person, type ThreadRef, isNotice } from "../sessions/chat.ts";
import { sessionKey } from "../sessions/hub.ts";
import type { Attachment, Store } from "../store/store.ts";
import { type CommaStats, type IndexRow, type RevIndex, IndexSync, heldFrom, probePage, statsWire, taskWireFor, validRequesterEmail } from "./stats.ts";
import { type CommaTasks, type Start, type Task, type TaskLinks, TASK_CHANNEL, validTaskLinks } from "./tasks.ts";

type Json = any;

/// Comma's heartbeat comes every 15 seconds: a socket that said nothing for 45 is gone.
const PING_MS = 15_000;
const STALE_MS = 45_000;
/// How long a request to Comma is waited for; a post that names files longer (Comma reads them from here first).
const REQUEST_MS = 30_000;
const FILE_POST_MS = 30 * 60_000;
/// Bytes one task.file or task.posted_file part carries at most (as Comma's stations: 256 KiB, base64).
const FILE_PART = 256 * 1024;
/// A post brings at most this many files.
const POST_FILES = 20;
/// The Tasks protocol it speaks (SalixStore.StationReadiness): task.invite/put/post/hello.
const TASKS_VERSION = 2;
/// Comma's question card takes two to six choices.
const QUESTION_CHOICES = [2, 6] as const;
/// Maximum number of workspace stations reported in capabilities.stillfail_workspace.
const MAX_WORKSPACE_STATIONS = 100;

/// Quantization bucket for reported owner activity timestamps so active reading sends at most one metadata frame per 30s.
export const OWNER_ACTIVE_BUCKET_MS = 30_000;
/// Maximum forward clock skew tolerated when accepting peer-reported activity timestamps.
export const MAX_PEER_ACTIVE_SKEW_MS = 5 * 60_000;
const MAX_ACTIVE_VIEWERS = 32;

/// Rounds a positive Unix millisecond timestamp down to its 30-second bucket, or null when invalid.
export function quantizeOwnerActiveAt(at: number | null | undefined): number | null {
  if (typeof at !== "number" || !Number.isFinite(at) || at <= 0) return null;
  const bucket = Math.floor(at / OWNER_ACTIVE_BUCKET_MS) * OWNER_ACTIVE_BUCKET_MS;
  return bucket > 0 ? bucket : null;
}

/// Wire payload attached to `comma.changed` so a peer station hosting the workspace's Comma connect
/// learns when viewers were recently active on this station.
export type PeerOwnerActivity = {
  at: number;
  byViewer?: Record<string, number>;
};

function setBoundedMax(map: Map<string, number>, key: string, bucket: number): boolean {
  const prev = map.get(key);
  if (prev !== undefined && bucket <= prev) return false;
  map.set(key, bucket);
  if (map.size > MAX_ACTIVE_VIEWERS) {
    let oldestKey: string | null = null;
    let oldestAt = Infinity;
    for (const [k, v] of map) {
      if (v < oldestAt) {
        oldestAt = v;
        oldestKey = k;
      }
    }
    if (oldestKey !== null && oldestKey !== key) map.delete(oldestKey);
  }
  return true;
}

/// Tracks quantized 30s activity buckets from local reads and workspace peers without re-gossiping peer data.
export class OwnerActivity {
  private readonly localByViewer = new Map<string, number>();
  private localLatestAt: number | null = null;
  private readonly mergedByViewer = new Map<string, number>();
  private unattributedActiveAt: number | null = null;
  private mergedLatestAt: number | null = null;

  /// Records a local chat-read event. Returns true when the merged activity advanced.
  recordLocal(viewer: string | null | undefined, at: number | null | undefined): boolean {
    const bucket = quantizeOwnerActiveAt(at);
    if (bucket === null) return false;
    const normalized = typeof viewer === "string" ? viewer.trim().toLowerCase() : "";
    let moved = false;
    if (normalized !== "") {
      setBoundedMax(this.localByViewer, normalized, bucket);
      if (setBoundedMax(this.mergedByViewer, normalized, bucket)) moved = true;
    } else if (this.unattributedActiveAt === null || bucket > this.unattributedActiveAt) {
      this.unattributedActiveAt = bucket;
      moved = true;
    }
    if (this.localLatestAt === null || bucket > this.localLatestAt) {
      this.localLatestAt = bucket;
    }
    if (this.mergedLatestAt === null || bucket > this.mergedLatestAt) {
      this.mergedLatestAt = bucket;
      moved = true;
    }
    return moved;
  }

  /// Builds the wire payload of THIS station's local activity only (never re-broadcasts peer activity).
  /// When `allowedViewers` is provided, only includes viewers belonging to that workspace.
  localPayload(allowedViewers?: ReadonlySet<string> | null): PeerOwnerActivity | null {
    if (this.localLatestAt === null) return null;
    if (allowedViewers !== undefined && allowedViewers !== null) {
      const byViewer: Record<string, number> = {};
      let latest = 0;
      for (const [viewer, bucket] of this.localByViewer) {
        if (!allowedViewers.has(viewer)) continue;
        byViewer[viewer] = bucket;
        if (bucket > latest) latest = bucket;
      }
      if (latest > 0) return { at: latest, byViewer };
      return this.localByViewer.size === 0 ? { at: this.localLatestAt } : null;
    }
    if (this.localByViewer.size === 0) return { at: this.localLatestAt };
    const byViewer: Record<string, number> = {};
    for (const [viewer, bucket] of this.localByViewer) byViewer[viewer] = bucket;
    return { at: this.localLatestAt, byViewer };
  }

  /// Merges activity reported by a workspace peer over `comma.changed`. Returns true when merged state advanced.
  mergePeer(raw: unknown, now?: number | null): boolean {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return false;
    const maxAllowed = typeof now === "number" && Number.isFinite(now) && now > 0 ? now + MAX_PEER_ACTIVE_SKEW_MS : null;
    const accept = (value: unknown): number | null => {
      const bucket = quantizeOwnerActiveAt(typeof value === "number" ? value : null);
      if (bucket === null) return null;
      if (maxAllowed !== null && bucket > maxAllowed) return null;
      return bucket;
    };
    const obj = raw as Record<string, unknown>;
    let moved = false;
    const rawByViewer = obj.byViewer;
    const hasByViewer = rawByViewer !== null && typeof rawByViewer === "object" && !Array.isArray(rawByViewer);
    if (hasByViewer) {
      let seen = 0;
      for (const [rawKey, rawVal] of Object.entries(rawByViewer as Record<string, unknown>)) {
        if (++seen > MAX_ACTIVE_VIEWERS) break;
        const viewer = rawKey.trim().toLowerCase();
        if (viewer === "") continue;
        const bucket = accept(rawVal);
        if (bucket === null) continue;
        if (setBoundedMax(this.mergedByViewer, viewer, bucket)) moved = true;
        if (this.mergedLatestAt === null || bucket > this.mergedLatestAt) {
          this.mergedLatestAt = bucket;
          moved = true;
        }
      }
    }
    const at = accept(obj.at);
    if (at !== null) {
      if (!hasByViewer && (this.unattributedActiveAt === null || at > this.unattributedActiveAt)) {
        this.unattributedActiveAt = at;
        moved = true;
      }
      if (this.mergedLatestAt === null || at > this.mergedLatestAt) {
        this.mergedLatestAt = at;
        moved = true;
      }
    }
    return moved;
  }

  /// Returns the latest quantized bucket for `owner` (if known) or overall latest activity when `owner` is null.
  get(owner: string | null | undefined): number | null {
    const normalized = typeof owner === "string" ? owner.trim().toLowerCase() : "";
    if (normalized === "") return this.mergedLatestAt;
    const known = this.mergedByViewer.get(normalized) ?? null;
    if (known === null) return this.unattributedActiveAt;
    if (this.unattributedActiveAt === null) return known;
    return known >= this.unattributedActiveAt ? known : this.unattributedActiveAt;
  }
}

/// Metadata of this connect's still.fail workspace sent in capabilities.stillfail_workspace.
export type CommaWorkspaceMeta = {
  id: string;
  name: string;
  station: string;
  emoji?: string;
  icon?: string;
  stations: { id: string; name: string }[];
};

/// Builds the CommaWorkspaceMeta payload from a workspace membership and this station's id.
export function workspaceMetaOf(
  m: { workspace: string; workspace_name: string; workspace_emoji?: string; workspace_icon?: string; name: string; peers: any[] },
  selfId: string,
  fallbackHost: string = hostname(),
): CommaWorkspaceMeta {
  const selfName = m.name !== "" ? m.name : fallbackHost;
  const seen = new Map<string, number>();
  let stations: { id: string; name: string }[] = [];
  for (const p of Array.isArray(m.peers) ? m.peers : []) {
    if (typeof p?.id !== "string" || p.id === "") continue;
    if (seen.has(p.id)) continue;
    const name = typeof p?.name === "string" && p.name !== "" ? p.name : p.id;
    seen.set(p.id, stations.length);
    stations.push({ id: p.id, name });
  }
  if (selfId !== "") {
    const idx = seen.get(selfId);
    if (idx !== undefined) stations[idx] = { id: selfId, name: selfName };
    else stations.push({ id: selfId, name: selfName });
  }
  if (stations.length > MAX_WORKSPACE_STATIONS) {
    stations = stations.slice(0, MAX_WORKSPACE_STATIONS);
    if (selfId !== "" && !stations.some((s) => s.id === selfId)) {
      stations[MAX_WORKSPACE_STATIONS - 1] = { id: selfId, name: selfName };
    }
  }
  return {
    id: m.workspace,
    name: m.workspace_name,
    station: selfName,
    ...(typeof m.workspace_emoji === "string" && m.workspace_emoji !== "" ? { emoji: m.workspace_emoji } : {}),
    ...(typeof m.workspace_icon === "string" && m.workspace_icon !== "" ? { icon: m.workspace_icon } : {}),
    stations,
  };
}

/// A Message of a Task, as task.put gives it. `author.name`, `email`, `picture`: who said it, as Comma shows them.
type TaskMessage = {
  seq: number;
  author: { kind: string; id: string; session?: string; name?: string; email?: string; picture?: string };
  text: string;
  id?: string;
  files?: { index: number; name: string; size: number }[];
  milestones?: string[];
};

/// A Message's ts in its thread here: its seq at Comma, so what is given again is one message.
export const seqTs = (seq: number) => `${seq}.000000`;

const text = (v: Json, key: string): string => (v !== null && typeof v === "object" && typeof v[key] === "string" ? v[key].trim() : "");
const count = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null);

/// Comma's address for its connector socket: `server` (https or http) as a WebSocket address, with who dials and the
/// still.fail workspace the connect is of (Comma takes one connect of a workspace in a Group: its usage counted once).
export function connectUrl(server: string, name: string, workspace: string | null = null): string {
  const url = new URL("/v1/connect", server.replace(/\/+$/, "") + "/");
  url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
  url.searchParams.set("name", name);
  if (workspace !== null) url.searchParams.set("stillfail_workspace", workspace);
  url.searchParams.set("os", platform());
  url.searchParams.set("arch", arch());
  return url.toString();
}

/// A card as Comma's question card (SalixIM.ConversationQuestion), where it is one: options, two to six of them (the
/// recommended one marked). A text card, or a single option, is said in the words alone.
export function questionOf(card: Json | null | undefined, prompt: string): Json | null {
  if (card?.type !== "options" || !Array.isArray(card.options)) return null;
  const options = card.options.filter((o: Json) => typeof o?.label === "string" && o.label.trim() !== "");
  if (options.length < QUESTION_CHOICES[0] || options.length > QUESTION_CHOICES[1]) return null;
  return {
    type: "question",
    prompt: Array.from(prompt.trim() || options.map((o: Json) => o.label).join(" / ")).slice(0, 600).join(""),
    choices: options.map((o: Json, i: number) => ({
      id: `o${i + 1}`,
      label: Array.from(o.label.trim()).slice(0, 100).join(""),
      ...(typeof o.detail === "string" && o.detail.trim() !== "" ? { description: Array.from(o.detail.trim()).slice(0, 300).join("") } : {}),
      ...(o.recommended === true ? { recommended: true } : {}),
    })),
    multi_select: false,
    allow_other: true,
  };
}

/// A part of `path` from `offset`, at most FILE_PART bytes (base64); `missing` when it is no longer there. Read off the
/// main thread: a Router reads a file a part at a time, and a disk kept busy would hold every request meanwhile.
async function readPart(file: Attachment, offset: number): Promise<Json> {
  let fh: Awaited<ReturnType<typeof open>>;
  try {
    fh = await open(file.path, "r");
  } catch {
    return { missing: "no longer on its station" };
  }
  try {
    const size = (await fh.stat()).size;
    const part = Buffer.alloc(Math.max(0, Math.min(FILE_PART, size - offset)));
    const { bytesRead } = part.length > 0 ? await fh.read(part, 0, part.length, offset) : { bytesRead: 0 };
    return { name: file.name, size, offset, data: part.subarray(0, bytesRead).toString("base64") };
  } finally {
    await fh.close().catch(() => {});
  }
}

/// Nothing is said in a Task while the agent works: Comma shows a Task's Worker as working by itself.
class Quiet extends StatusLine {
  protected async show(): Promise<boolean> {
    return true;
  }
}

export type CommaSurfaceOptions = {
  connect: string;
  /// Comma's address (`https://…`) and the connector token its still.fail plugin gave.
  server: string;
  token: string;
  /// What the station is called among the Group's computers.
  name: string;
  /// The still.fail workspace the connect is of; null before the station is in one.
  workspace?: string | null;
  /// The still.fail email of the person who owns this Comma connect, when known.
  ownerEmail?: string | null;
  tasks: CommaTasks;
  store: Store;
  /// The models its sessions can run (the hub's `modelsFor` the connect).
  models: () => ModelChoice[];
  book?: NameBook | null;
  lang?: Lang;
  /// The workspace's statistics and Task index it sends Comma; none, none are sent.
  stats?: CommaIndexes | (() => CommaIndexes) | null;
  /// The chats of the Task index as the Router reads and writes in them; none, it does neither.
  chats?: CommaChats | null;
  /// Do not send an index while the previous process can still send its own.
  previousExited?: Promise<void>;
  /// The home workspace for this surface has not changed since it was created.
  inScope?: () => boolean;
  /// Metadata of this connect's still.fail workspace, reported in capabilities.stillfail_workspace.
  workspaceMeta?: () => CommaWorkspaceMeta | null;
  /// Subscribes to workspace metadata changes so an open socket pushes updated metadata frames.
  onWorkspaceMetaChange?: (changed: () => void) => () => void;
  /// Last activity timestamp (Unix ms) of the owner in still.fail, quantized to 30s buckets and reported in capabilities.stillfail_owner_active_at.
  ownerActiveAt?: () => number | null;
  /// Subscribes to owner activity updates so an open socket pushes updated metadata frames when the 30s bucket advances.
  onOwnerActiveChange?: (changed: () => void) => () => void;
  /// This station's id (cloud.state?.station ?? null), used to scope connect-level task.index fields.
  stationId?: () => string | null;
};

export type CommaIndexes = Pick<CommaStats, "stats" | "tasks" | "start">;

/// The chats of the Task index (a ref: stats.ts chatRef), as the Router reads one (`task.read`), reads an attached file
/// (`task.read_file`), and writes in it as itself (`task.say`, once per key).
export type CommaChats = {
  read(ref: string, after: number, limit: number): Promise<Json>;
  readFile?(ref: string, seq: number, file: string, offset: number): Promise<Json>;
  say(ref: string, text: string, key: string, requester: string, connect: string, closeCard?: boolean, expectedCardSeq?: number, requesterEmail?: string): Promise<Json>;
};

export class CommaSurface extends ConnectedSurface {
  protected readonly kind = "comma";
  private readonly id: string;
  private readonly server: string;
  private readonly token: string;
  private readonly name: string;
  private readonly ofWorkspace: string | null;
  private readonly ownerEmail: string | null;
  private readonly tasks: CommaTasks;
  private readonly store: Store;
  private readonly models: () => ModelChoice[];
  private readonly lang: Lang;
  private readonly stats: CommaIndexes | (() => CommaIndexes) | null;
  private readonly chats: CommaChats | null;
  private readonly previousExited: Promise<void>;
  private readonly inScope: () => boolean;
  private readonly workspaceMeta: (() => CommaWorkspaceMeta | null) | null;
  private readonly onWorkspaceMetaChange: ((changed: () => void) => () => void) | null;
  private readonly ownerActiveAt: (() => number | null) | null;
  private readonly onOwnerActiveChange: ((changed: () => void) => () => void) | null;
  private readonly stationId: (() => string | null) | null;
  /// Stays the same across the sockets of one process (Comma tells a process replaced from a socket dialed again).
  private readonly instance = randomUUID();
  /// The socket now, once Comma said it is connected; and the requests to Comma waiting for their answer.
  private socket_: WebSocket | null = null;
  private stopWorkspaceMeta: (() => void) | null = null;
  private stopOwnerActive: (() => void) | null = null;
  private lastMetadataJson: string | null = null;
  private waiting = new Map<string, { resolve: (v: Json) => void; reject: (e: Error) => void }>();
  /// The people of the Tasks, as Comma said with their Messages.
  private people = new Map<string, Person>();
  /// The files of the posts Comma has not answered yet, by the post's key: it reads them (task.posted_file) first.
  private posting = new Map<string, { task: string; files: Attachment[] }>();
  /// The files of the Messages being heard, by the id they are named by here, until they are fetched.
  private shared = new Map<string, { task: string; session: string; seq: number; id?: string; index: number }>();
  private handler: Handler | null = null;

  constructor(options: CommaSurfaceOptions) {
    super({ connect: options.connect, book: options.book ?? null, pingMs: PING_MS, staleMs: STALE_MS });
    this.id = options.connect;
    this.server = options.server;
    this.token = options.token;
    this.name = options.name;
    this.ofWorkspace = options.workspace ?? null;
    const rawOwner = typeof options.ownerEmail === "string" ? options.ownerEmail.trim().toLowerCase() : "";
    this.ownerEmail = /^[^\s@]+@[^\s@]+$/.test(rawOwner) && rawOwner.length <= 200 ? rawOwner : null;
    this.tasks = options.tasks;
    this.store = options.store;
    this.models = options.models;
    this.lang = options.lang ?? stationLang();
    this.stats = options.stats ?? null;
    this.chats = options.chats ?? null;
    this.previousExited = options.previousExited ?? Promise.resolve();
    this.inScope = options.inScope ?? (() => true);
    this.workspaceMeta = options.workspaceMeta ?? null;
    this.onWorkspaceMetaChange = options.onWorkspaceMetaChange ?? null;
    this.ownerActiveAt = options.ownerActiveAt ?? null;
    this.onOwnerActiveChange = options.onOwnerActiveChange ?? null;
    this.stationId = options.stationId ?? null;
  }

  // ── the connection ─────────────────────────────────────────────────────────────────────────────────────────────

  protected async identify(): Promise<BotIdentity> {
    return { team: "Comma", teamId: "", url: this.server, botUserId: `stillfail:${this.id}`, botName: this.name, botImage: null, botId: "" };
  }

  protected async address(): Promise<string> {
    return connectUrl(this.server, this.name, this.ofWorkspace);
  }

  runSocket(url: string, handler: Handler): Effect.Effect<void, Error> {
    this.handler = handler;
    const headers = { authorization: `Bearer ${this.token}`, "x-salix-connector-instance-id": this.instance, "user-agent": `stillfail-station/${version()}` };
    return this.socketTo(
      url,
      {
        message: (socket, data, said) => {
          let frame: Json;
          try {
            frame = JSON.parse(data.toString());
          } catch {
            return;
          }
          this.frame(socket, frame, said.end);
        },
      },
      headers,
    ).pipe(Effect.ensuring(Effect.sync(() => this.closed())));
  }

  private frame(socket: WebSocket, frame: Json, end: (error: Error | null) => void) {
    switch (frame?.type) {
      case "connected":
        this.socket_ = socket;
        log.info("comma", "connected to Comma", { connect: this.id, device: frame.device_id, run: frame.connector_run_id });
        this.sendMetadata(true);
        if (this.stopWorkspaceMeta === null && this.onWorkspaceMetaChange !== null) {
          this.stopWorkspaceMeta = this.onWorkspaceMetaChange(() => {
            if (this.socket_ !== null && this.inScope()) this.sendMetadata(false);
          });
        }
        if (this.stopOwnerActive === null && this.onOwnerActiveChange !== null) {
          this.stopOwnerActive = this.onOwnerActiveChange(() => {
            if (this.socket_ !== null && this.inScope()) this.sendMetadata(false);
          });
        }
        this.hello();
        if (this.stats !== null && this.inScope()) {
          void this.sendIndex(socket, "stats.index", statsWire);
          void this.sendIndex(socket, "task.index", taskWireFor(this.id, this.stationId?.() ?? null));
        }
        return;
      case "heartbeat":
        this.send({ type: "heartbeat" });
        return;
      case "response":
      case "error": {
        const w = this.waiting.get(String(frame.id ?? ""));
        if (!w) return;
        this.waiting.delete(String(frame.id));
        if (frame.type === "response") w.resolve(frame.result ?? null);
        else w.reject(new Error(typeof frame.error === "string" ? frame.error : "Comma refused it"));
        return;
      }
      case "request": {
        const id = String(frame.id ?? "");
        const method = String(frame.method ?? "");
        const refuse = (error: Error) => {
          if (this.socket_ !== socket) return;
          log.info("comma", "a request from Comma was refused", { connect: this.id, method, error: error.message });
          this.send({ id, type: "error", error: error.message });
        };
        this.handle(method, frame.params ?? {}).then(
          (result) => {
            if (this.socket_ !== socket) return;
            try {
              if (method === "task.read" && !this.inScope()) throw new Error("the workspace changed while reading");
            } catch (error) {
              refuse(error as Error);
              return;
            }
            if (this.socket_ === socket) this.send({ id, type: "response", result });
          },
          refuse,
        );
        return;
      }
      default:
        if (frame?.type === "close") end(null);
    }
  }

  private closed() {
    this.socket_ = null;
    this.stopWorkspaceMeta?.();
    this.stopWorkspaceMeta = null;
    this.stopOwnerActive?.();
    this.stopOwnerActive = null;
    this.lastMetadataJson = null;
    for (const [id, w] of this.waiting) {
      w.reject(new Error("Comma is not connected"));
      this.waiting.delete(id);
    }
  }

  private sendMetadata(force = false) {
    if (this.socket_ === null) return;
    const frame = {
      type: "metadata",
      capabilities: this.capabilities(),
      skills: [],
      system_info: { os: platform(), arch: arch(), hostname: this.name },
    };
    const json = JSON.stringify(frame);
    if (!force && json === this.lastMetadataJson) return;
    this.lastMetadataJson = json;
    this.send(frame);
  }

  private send(frame: Json) {
    try {
      this.socket_?.send(JSON.stringify(frame));
    } catch (error) {
      log.warn("comma", "a frame to Comma was not sent", { connect: this.id, error: (error as Error).message });
    }
  }

  /// Asks Comma: its answer, or why not (not connected, refused, no answer in time).
  private ask(method: string, params: Json, ms = REQUEST_MS): Promise<Json> {
    if (this.socket_ === null) {
      const err = new Error(tr(this.lang, "station.comma.notConnected")) as Error & { notSent?: boolean };
      err.notSent = true;
      return Promise.reject(err);
    }
    const id = randomUUID();
    let wake: (() => void) | null = null;
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      wake?.();
      wake = null;
    };
    const awaitSettled = Effect.callback<void>((resume) => {
      if (settled) {
        resume(Effect.void);
        return;
      }
      wake = () => resume(Effect.void);
      return Effect.sync(() => {
        wake = null;
      });
    });
    return new Promise((resolve, reject) => {
      this.waiting.set(id, {
        resolve: (value) => {
          settle();
          resolve(value);
        },
        reject: (error) => {
          settle();
          reject(error);
        },
      });
      this.send({ id, type: "request", method, params });
      // Not answered in time, on the surface's clock: given up.
      // Interrupt the timeout as soon as the request settles or closes instead of holding a 30 s / 30 m timer open.
      void this.run(
        awaitSettled.pipe(
          Effect.timeoutOrElse({
            duration: ms,
            orElse: () =>
              Effect.sync(() => {
                if (this.waiting.delete(id)) {
                  settle();
                  reject(new Error(`Comma did not answer ${method} in time`));
                }
              }),
          }),
        ),
      ).catch(() => {});
    });
  }

  /// What the computer says it can do: take Tasks, on these models.
  private capabilities(): Json {
    const models: Record<string, string[]> = {};
    for (const m of this.models()) {
      const known = (models[m.runtime] ??= []);
      if (m.model !== null && !known.includes(m.model)) known.push(m.model);
    }
    const meta = this.inScope() ? (this.workspaceMeta?.() ?? null) : null;
    const activeAt = this.inScope() ? quantizeOwnerActiveAt(this.ownerActiveAt?.()) : null;
    return {
      scope: "",
      persistent_processes: false,
      computer_use_tool: false,
      host_access_required: false,
      execution_boundary: "stillfail-connect",
      runtime_probe: false,
      tasks: TASKS_VERSION,
      task_models: models,
      ...(this.stats === null ? {} : { stats_index: 1, task_index: 1 }),
      ...(this.chats === null ? {} : { task_say_cas: 1, ...(this.chats.readFile ? { task_read_file: 1 } : {}) }),
      ...(this.ownerEmail === null ? {} : { stillfail_owner_email: this.ownerEmail }),
      ...(activeAt === null ? {} : { stillfail_owner_active_at: activeAt }),
      ...(meta === null ? {} : { stillfail_workspace: meta }),
    };
  }

  /// Tells Comma it is here, and how far it has each Task it takes part in: Comma gives what it missed.
  private hello() {
    const tasks = this.tasks.taking(this.id).map((t) => ({ task: t.task, fetched: t.fetched }));
    this.ask("task.hello", { tasks }).catch((error) => log.info("comma", "Comma was not told the station is here", { connect: this.id, error: (error as Error).message }));
  }

  /// Keeps Comma's copy of an index current while `socket` is the connection: asks what Comma holds, sends what it
  /// lacks a page at a time, and again a second after it changed. Comma answers `rate_limited` to more than a few pages
  /// a second; any other refusal ends it until the next connection.
  private async sendIndex(socket: WebSocket, method: "stats.index" | "task.index", wire: (row: IndexRow) => Json | null) {
    let changed: () => void = () => {};
    let moved = new Promise<void>((resolve) => (changed = resolve));
    let stop = () => {};
    let didClose = false;
    const live = () => !didClose && this.socket_ === socket && this.inScope();
    const closed = new Promise<void>((resolve) => socket.once("close", () => { didClose = true; resolve(); }));
    let following: IndexSync | null = null;
    try {
      // An older process may still be sending the unscoped index. Clear or send ours only after it has exited.
      await Promise.race([this.previousExited, closed]);
      if (!live() || this.stats === null) return;
      // A scoped database may still be in use by the previous process; open and build it after handover.
      const indexes = typeof this.stats === "function" ? this.stats() : this.stats;
      indexes.start();
      const stats = method === "stats.index" ? indexes.stats : indexes.tasks;
      stop = stats.listen(() => changed());
      // An old sender uses the old epoch and does not register its readers here. Let it finish before this one resets.
      await Promise.race([stats.ready, closed]);
      if (!live()) return;
      const retryWait = (ms: number) => new Promise<boolean>((resolve) => {
        let cancel = () => {};
        const finish = (open: boolean) => { cancel(); socket.off("close", onClose); resolve(open); };
        const onClose = () => finish(false);
        socket.once("close", onClose);
        cancel = wall.after(ms, () => finish(true)); // timer: retry a locked index with backoff
        if (!live()) finish(false);
      });
      const readIndex = async <T>(read: () => T): Promise<{ value: T } | null> => {
        let delay = 25;
        while (live()) {
          try { return { value: read() }; }
          catch (error) {
            const code = (error as { errcode?: number }).errcode;
            if (code === undefined || ((code & 0xff) !== 5 && (code & 0xff) !== 6)) throw error;
            // An old connection can hold the index during guard installation or acknowledgement. Retry that work,
            // with backoff, until it succeeds or this socket closes.
            if (!await retryWait(delay)) return null;
            delay = Math.min(delay * 2, 2000);
          }
        }
        return null;
      };
      const started = await readIndex(() => new IndexSync(stats, wire));
      if (started === null) return;
      const sync = following = started.value;
      const initial = await readIndex(() => probePage(stats));
      if (initial === null) return;
      let page = initial.value;
      while (live()) {
        let answer: Json;
        try {
          answer = await this.ask(method, page);
        } catch (error) {
          const reason = (error as Error).message;
          if (reason !== "rate_limited") {
            // Only report known Comma codes; a peer's other text can contain private data.
            if (live()) log.info("comma", "an index was not sent", { connect: this.id, method,
              error: ["invalid_page", "page_too_large", "too_many_rows", "too_many_tasks", "not_this_group",
                "station_connection_changed"].includes(reason) ? reason : "no answer or unrecognized refusal" });
            return;
          }
          await wall.sleep(1000);
          continue;
        }
        if (!live()) return;
        const held = heldFrom(answer);
        if (held === null) return;
        const read = await readIndex(() => sync.next(held));
        if (read === null) return;
        const next = read.value;
        if (next !== null) {
          page = next;
          await wall.sleep(300);
          continue;
        }
        // Nothing more to send: until the statistics change, a second's changes together.
        await Promise.race([moved, closed]);
        moved = new Promise<void>((resolve) => (changed = resolve));
        await wall.sleep(1000);
        if (!live()) return;
        const readAfterChange = await readIndex(() => sync.next(held) ?? probePage(stats));
        if (readAfterChange === null) return;
        page = readAfterChange.value;
      }
    } catch (error) {
      log.info("comma", "an index was not sent", { connect: this.id, method, error: (error as Error).message });
    } finally {
      stop();
      following?.close();
    }
  }

  // ── what Comma asks ────────────────────────────────────────────────────────────────────────────────────────────

  private async handle(method: string, params: Json): Promise<Json> {
    switch (method) {
      case "task.invite":
        return this.invited(params);
      case "task.put":
        return await this.put(params);
      case "task.status":
        return this.standing(params);
      case "task.leave":
        return this.leave(params);
      case "task.posted_file":
        return await this.postedFile(params);
      case "task.read": {
        if (this.chats === null || !this.inScope()) throw new Error("task.read is not something this station does in this workspace");
        const after = typeof params?.after === "number" && params.after >= 0 ? params.after : 0;
        const limit = typeof params?.limit === "number" && params.limit > 0 ? Math.min(params.limit, 100) : 100;
        const result = await this.chats.read(text(params, "task"), after, limit);
        if (!this.inScope()) throw new Error("the workspace changed while reading");
        return result;
      }
      case "task.read_file": {
        if (this.chats === null || !this.chats.readFile || !this.inScope()) throw new Error("task.read_file is not something this station does in this workspace");
        const seq = params?.seq;
        if (typeof seq !== "number" || !Number.isSafeInteger(seq) || seq <= 0) throw new Error("seq must be a positive integer");
        const file = text(params, "file");
        if (file.trim() === "") throw new Error("file is required");
        const offset = params?.offset === undefined || params?.offset === null ? 0 : params.offset;
        if (typeof offset !== "number" || !Number.isSafeInteger(offset) || offset < 0) throw new Error("offset must be a non-negative integer");
        const result = await this.chats.readFile(text(params, "task"), seq, file, offset);
        if (!this.inScope()) throw new Error("the workspace changed while reading");
        return result;
      }
      case "task.say": {
        if (this.chats === null || !this.inScope()) throw new Error("task.say is not something this station does in this workspace");
        const said = text(params, "text");
        if (said.trim() === "") throw new Error("text is required");
        let expectedCardSeq: number | undefined;
        if (params?.expected_card_seq !== undefined && params?.expected_card_seq !== null) {
          if (typeof params.expected_card_seq !== "number" || !Number.isSafeInteger(params.expected_card_seq) || params.expected_card_seq <= 0) {
            throw new Error("expected_card_seq must be a positive integer");
          }
          expectedCardSeq = params.expected_card_seq;
        }
        // As people see who writes: its Group (several Comma workspaces and Agent Swarms may write here).
        const who = text(params, "requester_name") || text(params, "requester") || "Router";
        const requesterEmail = validRequesterEmail(params?.requester_email);
        const result = await this.chats.say(text(params, "task"), said, text(params, "key"), who, this.id, params?.close_card === true, expectedCardSeq, requesterEmail);
        if (!this.inScope()) throw new Error("the workspace changed while writing");
        return result;
      }
      default:
        throw new Error(`${method} is not something a still.fail station does`);
    }
  }

  private session(t: Task): string {
    return sessionKey(this.id, TASK_CHANNEL, t.threadTs);
  }

  /// The model a Task asked for, as the station runs it: that runtime and model where a profile runs them, that runtime's
  /// default where only the runtime is; none asked, the connect's own. Throws where it runs neither.
  private choice(start: Start): ModelChoice | undefined {
    if (start.runtime === null) return undefined;
    const models = this.models().filter((m) => m.runtime === start.runtime);
    if (models.length === 0) throw new Error(tr(this.lang, "station.comma.noRuntime", { runtime: start.runtime }));
    if (start.model !== null && models.some((m) => m.model === start.model)) return { runtime: start.runtime, model: start.model };
    return { runtime: start.runtime, model: null };
  }

  /// task.invite: the session the Task is to be here (made as its first Message is heard).
  private invited(params: Json): Json {
    const task = text(params, "task");
    if (task === "") throw new Error("task is required");
    const s = params?.start;
    if (s === null || typeof s !== "object" || Array.isArray(s)) throw new Error("start is required");
    const had = this.tasks.get(this.id, task);
    if (params?.replace === true) throw new Error(tr(this.lang, "station.comma.oneModel"));
    const start: Start = { requester: text(s, "requester"), title: text(s, "title") || null, runtime: text(s, "runtime") || null, model: text(s, "model") || null };
    this.choice(start);
    const links = validTaskLinks(params?.links);
    const t = had !== null && had.left !== true ? had : this.tasks.invited(this.id, task, start, count(params?.answered) ?? 0, links);
    if (links !== null) {
      this.tasks.setLinks(this.id, task, links);
      this.syncThreadLinks(t.threadTs, links);
    }
    log.info("comma", "a Comma Task for an agent here", { connect: this.id, task, session: this.session(t) });
    return { session: this.session(t), thread: `${TASK_CHANNEL}/${t.threadTs}` };
  }

  /// task.put: the Task's Messages, each heard in its thread here in order.
  private async put(params: Json): Promise<Json> {
    const task = text(params, "task");
    const t = this.tasks.get(this.id, task);
    if (t === null) return { unknown: true, gone: true };
    if (t.left === true) return { gone: true };
    const links = validTaskLinks(params?.links);
    if (links !== null) this.tasks.setLinks(this.id, task, links);
    const answered = Math.max(t.answered, count(params?.answered) ?? 0);
    const session = this.session(t);
    const messages = (Array.isArray(params?.messages) ? (params.messages as TaskMessage[]) : []).filter((m) => count(m?.seq) !== null).sort((a, b) => a.seq - b.seq);
    let first = this.store.getSession(session) === null;
    for (const m of messages) {
      const said = typeof m.text === "string" ? m.text : "";
      if (typeof m.author?.session === "string") {
        // Replayed own-session station notices reconcile in-flight proposal outboxes without waking the agent.
        if (m.author.session === session && isNotice(said) && this.handler) {
          await this.handler({
            type: "ownNotice",
            message: { channel: TASK_CHANNEL, threadTs: t.threadTs, ts: seqTs(m.seq), user: this.botUserId(), text: said, addressed: false },
          });
        }
        continue;
      }
      // What the session here answered already is not heard again.
      if (m.seq <= answered) continue;
      const files: InboundFile[] = (Array.isArray(m.files) ? m.files : [])
        .filter((f) => count(f?.index) !== null && typeof f?.name === "string" && f.name !== "" && count(f?.size) !== null)
        .map((f) => {
          const id = `${task}:${m.seq}-${f.index}`;
          const loc = { task, session, seq: m.seq, ...(typeof m.id === "string" ? { id: m.id } : {}), index: f.index };
          return { id, name: f.name, size: f.size, url: `comma:${JSON.stringify(loc)}` };
        });
      if (said === "" && files.length === 0) continue;
      const user = this.learn(m.author);
      await this.handler!({
        type: "message",
        message: { channel: TASK_CHANNEL, threadTs: t.threadTs, ts: seqTs(m.seq), user, text: said, addressed: true, files, ...(first ? { model: this.choice(t.start) } : {}) },
      });
      first = false;
    }
    const effective = links ?? t.links ?? null;
    if (effective !== null) this.syncThreadLinks(t.threadTs, effective);
    this.tasks.given(this.id, task, count(params?.through), count(params?.answered));
    return { through: count(params?.through) };
  }

  private syncThreadLinks(threadTs: string, links: TaskLinks): void {
    const thread = this.store.threadAt(this.surface(), TASK_CHANNEL, threadTs);
    if (thread !== null) this.store.setThreadLinks(thread.id, links);
  }

  /// Who said a Message, by their id here (a person's Comma id; an agent's, its Router, `agent:<id>`), as Comma says.
  private learn(author: TaskMessage["author"] | undefined): string {
    const kind = author?.kind;
    const id = typeof author?.id === "string" && author.id !== "" ? author.id : "comma";
    const user = kind === "person" ? id : `agent:${id}`;
    const name = typeof author?.name === "string" && author.name !== "" ? author.name : kind === "person" ? tr(this.lang, "station.comma.member") : "Comma";
    const person: Person = { name, email: kind === "person" && typeof author?.email === "string" ? author.email : "", picture: typeof author?.picture === "string" ? author.picture : "" };
    this.people.set(user, person);
    this.book?.person(personKey(this.id, user), async () => person, (known) => known.name !== person.name || (known.picture ?? "") !== person.picture || known.email !== person.email);
    return user;
  }

  /// task.status: where the Task's session stands. A read.
  private standing(params: Json): Json {
    const gone = { state: "gone", pending: 0, for_ms: null, last_failure: null };
    const t = this.tasks.get(this.id, text(params, "task"));
    if (t === null || t.left === true) return gone;
    const row = this.store.getSession(this.session(t));
    // Invited, its first Message not heard yet: idle, waiting for it.
    if (row === null) return { state: "idle", pending: 0, for_ms: null, last_failure: null };
    return { state: row.running ? "running" : "idle", pending: this.store.pendingCount(row.key), for_ms: null, last_failure: null };
  }

  /// task.leave: the Task runs elsewhere now. Its session leaves the thread; the thread stays, as what was said.
  private leave(params: Json): Json {
    const task = text(params, "task");
    const t = this.tasks.get(this.id, task);
    if (t === null) return {};
    this.tasks.left(this.id, task);
    const thread = this.store.threadAt(this.surface(), TASK_CHANNEL, t.threadTs);
    if (thread !== null) this.store.leaveThread(thread.id, this.session(t));
    log.info("comma", "a Comma Task runs elsewhere now", { connect: this.id, task });
    return {};
  }

  private surface(): string {
    return `comma:${this.id}`;
  }

  /// task.posted_file: a part of a file of a post Comma has not answered yet.
  private async postedFile(params: Json): Promise<Json> {
    const posting = this.posting.get(text(params, "key"));
    const index = count(params?.index);
    if (!posting || posting.task !== text(params, "task") || index === null) return { missing: "no such post" };
    const file = posting.files[index];
    return file ? await readPart(file, count(params?.offset) ?? 0) : { missing: "no such file" };
  }

  // ── the surface ────────────────────────────────────────────────────────────────────────────────────────────────

  async post(thread: ThreadRef, message: string, files: Attachment[], card?: Json | null): Promise<string> {
    return await this.say(thread, message, files, card ?? null, null);
  }

  /// Writes into the Task at Comma: its seq there, as the ts the message is kept by here.
  private async say(thread: ThreadRef, message: string, files: Attachment[], card: Json | null, declared: "all_done" | "need_help" | null): Promise<string> {
    const t = this.tasks.byThread(this.id, thread.threadTs);
    if (t === null) throw new Error(`no Comma Task ${thread.channel}/${thread.threadTs} here`);
    if (files.length > POST_FILES) throw new Error(`a post brings at most ${POST_FILES} files`);
    const key = randomUUID();
    const question = questionOf(card, message);
    const request = {
      task: t.task, session: this.session(t), text: message, key, declared,
      ...(question !== null ? { question } : {}),
      ...(files.length > 0 ? { files: files.map((f, index) => ({ index, name: f.name, size: f.size })) } : {}),
    };
    if (files.length > 0) this.posting.set(key, { task: t.task, files });
    let answer: Json;
    try {
      answer = await this.ask("task.post", request, files.length > 0 ? FILE_POST_MS : REQUEST_MS);
    } finally {
      this.posting.delete(key);
    }
    const seq = count(answer?.seq);
    if (seq === null) throw new Error("Comma answered without the Message's seq");
    return seqTs(seq);
  }

  /// Where the turn stands at its end, written into the Task: Comma takes the Task as done, or as waiting for its people.
  standsAt(thread: ThreadRef, stands: { kind: "done" | "need" | "left"; words: string | null } | null) {
    if (stands === null || stands.kind === "left") return;
    const words = stands.words?.trim() || tr(this.lang, stands.kind === "done" ? "station.comma.done" : "station.comma.need");
    this.say(thread, words, [], null, stands.kind === "done" ? "all_done" : "need_help").catch((error) =>
      log.warn("comma", "where a turn stands was not said in its Comma Task", { connect: this.id, thread: thread.threadTs, error: (error as Error).message }),
    );
  }

  /// A file of a Task's Message, read from Comma a part at a time.
  async download(file: InboundFile): Promise<Uint8Array> {
    let at = this.shared.get(file.id);
    if (!at && typeof file.url === "string" && file.url.startsWith("comma:")) {
      try {
        const parsed = JSON.parse(file.url.slice("comma:".length));
        if (typeof parsed?.task === "string" && typeof parsed?.session === "string" && count(parsed?.seq) !== null && count(parsed?.index) !== null) {
          at = { task: parsed.task, session: parsed.session, seq: parsed.seq, ...(typeof parsed.id === "string" ? { id: parsed.id } : {}), index: parsed.index };
        }
      } catch {}
    }
    if (!at) throw new Error("no such file of the Task");
    const parts: Buffer[] = [];
    for (let have = 0; have < file.size; ) {
      const answer = await this.ask("task.file", { task: at.task, session: at.session, seq: at.seq, ...(at.id ? { id: at.id } : {}), index: at.index, offset: have });
      if (typeof answer?.missing === "string") throw new Error(answer.missing);
      const data = typeof answer?.data === "string" ? Buffer.from(answer.data, "base64") : null;
      if (count(answer?.offset) !== have || data === null || data.length === 0 || have + data.length > file.size) throw new Error(`Comma gave a wrong part of ${file.name} at ${have}`);
      parts.push(data);
      have += data.length;
    }
    return Buffer.concat(parts);
  }

  /// A Task has no link of its own here: the session's page is not said in it.
  sessionLink(): string | null {
    return null;
  }

  mention(user: string): string {
    return `@${this.people.get(user)?.name ?? this.knownPerson(user)?.name ?? user}`;
  }

  knownPerson(user: string): Person | null {
    const had = this.people.get(user);
    if (had) return had;
    return this.book?.person(personKey(this.id, user), async () => null) ?? null;
  }

  protected async lookUp(user: string): Promise<Person | null> {
    return this.people.get(user) ?? null;
  }

  protected async lookUpEmail(email: string): Promise<string | null> {
    for (const [user, p] of this.people) if (p.email.toLowerCase() === email) return user;
    return null;
  }

  protected statusLine(): StatusLine {
    return new Quiet((effect) => this.run(effect), 1000);
  }
}
