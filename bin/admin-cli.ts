// Admin CLI (`stillfail admin …`): talks to still.fail cloud's `/v1/admin/*` endpoints with an Admin API key (`sfa_…`).
// Zero external dependencies; natively supports HTTPS_PROXY CONNECT tunnels + custom CA bundles (`secret_run` proxy mode).
import { readFile } from "node:fs/promises";
import * as http from "node:http";
import * as https from "node:https";
import { isIP } from "node:net";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import * as tls from "node:tls";
import { pathToFileURL } from "node:url";

export interface CliIo {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
  env: Record<string, string | undefined>;
  argv0?: string | undefined;
}

interface HttpResult {
  status: number;
  body: string;
}

const USAGE = `Usage: stillfail admin [options] <command> ...

Options:
  --origin <url>    Cloud origin (default: STILLFAIL_ADMIN_ORIGIN / STILLFAIL_ORIGIN / cloud.json)
  --key <key>       Admin API key (default: STILLFAIL_ADMIN_KEY / STILLFAIL_SECRET)
  --json            Print raw JSON response
  -h, --help        Show help

Commands:
  whoami
  users list [--query <q>] [--filter <f>]
  users get <sub-or-email>
  users beta <sub-or-email> on|off
  users may-create <sub-or-email> on|off
  users block <sub-or-email> on|off
  pending set <email> [--beta on|off] [--may-create on|off]
  pending remove <email>
  workspaces list [--query <q>]
  workspaces get <id>
  workspaces create <name> --owner <email> [--owner <email>...] [--members <n>] [--stations <n>]
  workspaces limits <id> (--members <n> [--stations <n>] | --reset)
  workspaces add-owners <id> <email...>
  workspaces remove-added <id> <email>
  workspaces enroll <id> <station-name>
  workspaces delete <id> --yes
  codes list [--filter all|open|used|expired|revoked]
  codes create [--note <text>] [--days <n>] [--beta]
  codes revoke <code>
  feedback list [--status <s|all>] [--area <a>] [--query <q>]
  feedback get <id-or-FB-n>
  feedback status <id-or-FB-n> <new|triaged|fixed|wontfix>
  feedback reply <id-or-FB-n> <text>
  relays list
  relays stats
  relays put <url> <name> [--target <relay-url>]
  relays rename <url> <name> [--target <relay-url>]
  relays remove <url>
  relays token <name> [--url <url>] [--target <relay-url>]
  relays token-revoke <id>
  relays mesh-token <name>
  relays mesh-remove <node>
  audit [--kind <k>] [--limit <n>]
`;

class CliError extends Error {
  readonly code: number;
  constructor(message: string, code = 1) {
    super(message);
    this.code = code;
  }
}

function isNoProxy(hostname: string, noProxy: string | undefined): boolean {
  if (!noProxy) return false;
  const host = hostname.toLowerCase();
  for (const raw of noProxy.split(",")) {
    const entry = raw.trim().toLowerCase();
    if (!entry) continue;
    if (entry === "*") return true;
    const clean = entry.replace(/^\./, "");
    if (host === clean || host.endsWith(`.${clean}`)) return true;
  }
  return false;
}

async function loadCa(env: Record<string, string | undefined>): Promise<string[] | undefined> {
  const paths = [env.SSL_CERT_FILE, env.NODE_EXTRA_CA_CERTS].filter((p): p is string => Boolean(p && p.trim()));
  if (paths.length === 0) return undefined;
  const extra: string[] = [];
  for (const p of new Set(paths)) {
    try {
      extra.push(await readFile(p, "utf8"));
    } catch {
      // ignore unreadable extra CA path
    }
  }
  if (extra.length === 0) return undefined;
  return [...tls.rootCertificates, ...extra];
}

function readStream(res: http.IncomingMessage): Promise<HttpResult> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    res.on("data", (c: Buffer) => chunks.push(c));
    res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
    res.on("error", reject);
  });
}

const REQUEST_TIMEOUT_MS = 30_000;
const DAY_SEC = 86_400;

function nowSec(): number {
  return Math.floor((performance.timeOrigin + performance.now()) / 1000);
}

async function httpRequest(
  urlStr: string,
  method: string,
  headers: Record<string, string>,
  body: string | null,
  env: Record<string, string | undefined>,
): Promise<HttpResult> {
  const url = new URL(urlStr);
  const ca = await loadCa(env);
  const proxyUrlStr = url.protocol === "https:" ? (env.HTTPS_PROXY || env.https_proxy) : undefined;
  const useProxy = Boolean(proxyUrlStr && !isNoProxy(url.hostname, env.NO_PROXY || env.no_proxy));

  if (useProxy && proxyUrlStr) {
    const proxyUrl = new URL(proxyUrlStr);
    const targetHost = url.hostname;
    const targetPort = Number(url.port) || 443;
    const proxyHeaders: Record<string, string> = { Host: `${targetHost}:${targetPort}` };
    if (proxyUrl.username || proxyUrl.password) {
      const auth = Buffer.from(`${decodeURIComponent(proxyUrl.username)}:${decodeURIComponent(proxyUrl.password)}`, "utf8").toString("base64");
      proxyHeaders["Proxy-Authorization"] = `Basic ${auth}`;
    }
    const tunnelSocket = await new Promise<import("node:net").Socket>((resolve, reject) => {
      const connectReq = http.request({
        hostname: proxyUrl.hostname,
        port: Number(proxyUrl.port) || 80,
        method: "CONNECT",
        path: `${targetHost}:${targetPort}`,
        headers: proxyHeaders,
      });
      connectReq.setTimeout(REQUEST_TIMEOUT_MS, () => connectReq.destroy(new Error("proxy CONNECT timed out")));
      connectReq.on("connect", (res, socket, head) => {
        if (res.statusCode !== 200) {
          socket.destroy();
          reject(new Error(`proxy CONNECT failed with status ${res.statusCode}`));
          return;
        }
        if (head.length > 0) socket.unshift(head);
        resolve(socket);
      });
      connectReq.on("error", reject);
      connectReq.end();
    });

    return await new Promise<HttpResult>((resolve, reject) => {
      const reqHeaders: Record<string, string> = {
        ...headers,
        Connection: "close",
        ...(body !== null ? { "Content-Length": String(Buffer.byteLength(body)) } : {}),
      };
      const opts: https.RequestOptions & { socket?: import("node:net").Socket } = {
        hostname: targetHost,
        port: targetPort,
        path: `${url.pathname}${url.search}`,
        method,
        headers: reqHeaders,
        agent: false,
        socket: tunnelSocket,
        ...(isIP(targetHost) ? {} : { servername: targetHost }),
        ...(ca ? { ca } : {}),
      };
      const req = https.request(opts, (res) => {
        readStream(res).then(resolve, reject);
      });
      req.setTimeout(REQUEST_TIMEOUT_MS, () => req.destroy(new Error("request timed out")));
      req.on("error", (err) => {
        tunnelSocket.destroy();
        reject(err);
      });
      if (body !== null) req.write(body);
      req.end();
    });
  }

  return new Promise<HttpResult>((resolve, reject) => {
    const reqHeaders: Record<string, string> = {
      ...headers,
      ...(body !== null ? { "Content-Length": String(Buffer.byteLength(body)) } : {}),
    };
    const isHttps = url.protocol === "https:";
    const opts: https.RequestOptions = {
      hostname: url.hostname,
      port: url.port ? Number(url.port) : isHttps ? 443 : 80,
      path: `${url.pathname}${url.search}`,
      method,
      headers: reqHeaders,
      ...(isHttps && ca ? { ca } : {}),
    };
    const req = (isHttps ? https.request : http.request)(opts, (res) => {
      readStream(res).then(resolve, reject);
    });
    req.setTimeout(REQUEST_TIMEOUT_MS, () => req.destroy(new Error("request timed out")));
    req.on("error", reject);
    if (body !== null) req.write(body);
    req.end();
  });
}

async function resolveOrigin(explicit: string | undefined, env: Record<string, string | undefined>, cmdName: string): Promise<string> {
  const fromEnv = explicit || env.STILLFAIL_ADMIN_ORIGIN || env.STILLFAIL_ORIGIN;
  if (fromEnv) return fromEnv.replace(/\/+$/, "");
  const isMonoid = cmdName === "monoid";
  const dataDir = env.STILLFAIL_DATA || join(homedir(), isMonoid ? ".monoid" : ".stillfail");
  try {
    const raw = await readFile(join(dataDir, "mesh", "cloud.json"), "utf8");
    const parsed = JSON.parse(raw) as { origin?: unknown };
    if (typeof parsed.origin === "string" && /^https?:\/\//.test(parsed.origin)) {
      return parsed.origin.replace(/\/+$/, "");
    }
  } catch {
    // no cloud.json
  }
  return isMonoid ? "https://app.monoid.build" : "https://app.still.fail";
}

function parseBool(value: string | undefined, label: string): boolean {
  if (value === "on" || value === "true") return true;
  if (value === "off" || value === "false") return false;
  throw new CliError(`expected on|off for ${label}`, 2);
}

function parseIntOpt(value: string | undefined, label: string): number {
  const n = Number(value);
  if (!value || !Number.isInteger(n) || n < 1) throw new CliError(`invalid integer for ${label}: ${value ?? ""}`, 2);
  return n;
}

function fmtTime(sec: unknown): string {
  if (typeof sec !== "number" || !Number.isFinite(sec) || sec <= 0) return "-";
  return new Date(sec * 1000).toISOString().replace("T", " ").slice(0, 16) + "Z";
}

function parseArgs(argv: string[]): {
  json: boolean;
  help: boolean;
  origin?: string | undefined;
  key?: string | undefined;
  rest: string[];
} {
  let json = false;
  let help = false;
  let origin: string | undefined;
  let key: string | undefined;
  const rest: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--json") json = true;
    else if (a === "-h" || a === "--help") help = true;
    else if (a === "--origin") {
      origin = argv[++i];
      if (!origin) throw new CliError("--origin requires a value", 2);
    } else if (a === "--key") {
      key = argv[++i];
      if (!key) throw new CliError("--key requires a value", 2);
    } else {
      rest.push(a);
    }
  }
  return { json, help, origin, key, rest };
}

function takeFlags(args: string[], valueFlags: Set<string>, boolFlags: Set<string>, multiFlags = new Set<string>()): {
  pos: string[];
  flags: Map<string, string>;
  multi: Map<string, string[]>;
  bools: Set<string>;
} {
  const pos: string[] = [];
  const flags = new Map<string, string>();
  const multi = new Map<string, string[]>();
  const bools = new Set<string>();
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (boolFlags.has(a)) {
      bools.add(a);
    } else if (multiFlags.has(a)) {
      const v = args[++i];
      if (v === undefined) throw new CliError(`${a} requires a value`, 2);
      const list = multi.get(a) ?? [];
      list.push(v);
      multi.set(a, list);
    } else if (valueFlags.has(a)) {
      const v = args[++i];
      if (v === undefined) throw new CliError(`${a} requires a value`, 2);
      flags.set(a, v);
    } else if (a.startsWith("-")) {
      throw new CliError(`unknown option: ${a}`, 2);
    } else {
      pos.push(a);
    }
  }
  return { pos, flags, multi, bools };
}

export async function runAdminCli(argv: string[], io: CliIo): Promise<number> {
  let parsed: ReturnType<typeof parseArgs>;
  try {
    parsed = parseArgs(argv);
  } catch (err) {
    io.stderr(`${err instanceof Error ? err.message : String(err)}\n`);
    return err instanceof CliError ? err.code : 2;
  }

  if (parsed.help || parsed.rest.length === 0) {
    io.stdout(USAGE);
    return 0;
  }

  const apiKey = parsed.key || io.env.STILLFAIL_ADMIN_KEY || io.env.STILLFAIL_SECRET || "";
  if (!apiKey) {
    io.stderr("error: missing Admin API key (set STILLFAIL_ADMIN_KEY, STILLFAIL_SECRET, or --key)\n");
    return 1;
  }

  const cmdName = basename(io.argv0 || "stillfail");
  const origin = await resolveOrigin(parsed.origin, io.env, cmdName);

  const call = async <T = any>(method: string, path: string, body?: unknown): Promise<T> => {
    const payload = body !== undefined ? JSON.stringify(body) : null;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${apiKey}`,
      Accept: "application/json",
      ...(payload !== null ? { "Content-Type": "application/json" } : {}),
    };
    const res = await httpRequest(`${origin}${path}`, method, headers, payload, io.env);
    let data: unknown = null;
    if (res.body.trim()) {
      try {
        data = JSON.parse(res.body);
      } catch {
        data = { raw: res.body };
      }
    }
    if (res.status < 200 || res.status >= 300) {
      const errCode = data && typeof data === "object" && "error" in data ? String((data as { error: unknown }).error) : `http_${res.status}`;
      const detail = data && typeof data === "object" && "reason" in data ? ` (${String((data as { reason: unknown }).reason)})` : "";
      throw new CliError(`request failed (${res.status}): ${errCode}${detail}`, 1);
    }
    return data as T;
  };

  const outJson = (v: unknown) => io.stdout(`${JSON.stringify(v, null, 2)}\n`);

  const resolveUser = async (ref: string): Promise<{ sub: string; email: string; name: string; [k: string]: unknown }> => {
    const data = await call<{ users: { sub: string; email: string; name: string }[] }>("GET", "/v1/admin/users");
    const lower = ref.toLowerCase();
    const found = data.users.find((u) => u.sub === ref || u.email.toLowerCase() === lower);
    if (!found) throw new CliError(`user not found: ${ref}`, 1);
    return found;
  };

  const resolveFeedbackId = async (ref: string): Promise<string> => {
    if (/^[0-9A-Z]{26}$/.test(ref)) return ref;
    const data = await call<{ item: { id: string } }>("GET", `/v1/admin/feedback/${encodeURIComponent(ref)}`);
    return data.item.id;
  };

  const [group, sub, ...args] = parsed.rest;

  try {
    if (group === "whoami") {
      const data = await call<{ email: string; key?: { id: string; name: string; prefix: string } }>("GET", "/v1/admin/me");
      if (parsed.json) outJson(data);
      else io.stdout(data.key ? `${data.email} (key: ${data.key.name} ${data.key.prefix}…)\n` : `${data.email}\n`);
      return 0;
    }

    if (group === "users") {
      if (sub === "list") {
        const { flags } = takeFlags(args, new Set(["--query", "--filter"]), new Set());
        const data = await call<{ users: any[]; pending: any[] }>("GET", "/v1/admin/users");
        const q = (flags.get("--query") ?? "").toLowerCase();
        const f = flags.get("--filter") ?? "all";
        const now = nowSec();
        if (f === "pending") {
          let pending = data.pending ?? [];
          if (q) pending = pending.filter((p) => String(p.email ?? "").toLowerCase().includes(q));
          if (parsed.json) outJson({ users: [], pending });
          else {
            for (const p of pending) {
              const tags = [p.beta ? "beta" : "", p.may_create ? "standard" : ""].filter(Boolean).join(",");
              io.stdout(`pending\t${p.email}\t[${tags || "none"}]\tadded:${fmtTime(p.added_at)}\n`);
            }
          }
          return 0;
        }
        let users = data.users;
        if (q) users = users.filter((u) => `${u.name} ${u.email} ${u.sub}`.toLowerCase().includes(q));
        if (f === "active") users = users.filter((u) => typeof u.last_seen === "number" && now - u.last_seen < 7 * DAY_SEC);
        else if (f === "new") users = users.filter((u) => typeof u.created_at === "number" && now - u.created_at < 7 * DAY_SEC);
        else if (f === "dormant") users = users.filter((u) => typeof u.last_seen !== "number" || now - u.last_seen > 30 * DAY_SEC);
        else if (f === "beta") users = users.filter((u) => u.beta);
        else if (f === "blocked") users = users.filter((u) => u.blocked);
        else if (f === "creators") users = users.filter((u) => u.may_create);
        else if (f === "stuck") users = users.filter((u) => !u.admission);
        if (parsed.json) outJson({ users, pending: data.pending });
        else {
          for (const u of users) {
            const tags = [u.plan, u.beta ? "beta" : "", u.blocked ? "blocked" : ""].filter(Boolean).join(",");
            io.stdout(`${u.sub}\t${u.email}\t${u.name || "-"}\t[${tags}]\tseen:${fmtTime(u.last_seen)}\n`);
          }
        }
        return 0;
      }
      if (sub === "get") {
        const ref = args[0];
        if (!ref) throw new CliError("usage: users get <sub-or-email>", 2);
        const u = await resolveUser(ref);
        if (parsed.json) outJson(u);
        else io.stdout(`${u.email} (${u.sub})\nname: ${u.name || "-"}\nplan: ${u.plan ?? "-"}\nbeta: ${Boolean(u.beta)}\nblocked: ${Boolean(u.blocked)}\n`);
        return 0;
      }
      if (sub === "beta" || sub === "may-create" || sub === "block") {
        const [ref, state] = args;
        if (!ref || !state) throw new CliError(`usage: users ${sub} <sub-or-email> on|off`, 2);
        const on = parseBool(state, sub);
        const u = await resolveUser(ref);
        const data = await call("POST", `/v1/admin/users/${encodeURIComponent(u.sub)}/${sub}`, { on });
        if (parsed.json) outJson(data);
        else io.stdout(`${u.email}: ${sub}=${on ? "on" : "off"}\n`);
        return 0;
      }
      throw new CliError(`unknown users subcommand: ${sub ?? ""}`, 2);
    }

    if (group === "pending") {
      if (sub === "set") {
        const { pos, flags } = takeFlags(args, new Set(["--beta", "--may-create"]), new Set());
        const email = pos[0];
        if (!email) throw new CliError("usage: pending set <email> [--beta on|off] [--may-create on|off]", 2);
        const body: Record<string, unknown> = { email };
        if (flags.has("--beta")) body.beta = parseBool(flags.get("--beta"), "--beta");
        if (flags.has("--may-create")) body.may_create = parseBool(flags.get("--may-create"), "--may-create");
        const data = await call("POST", "/v1/admin/pending", body);
        if (parsed.json) outJson(data);
        else io.stdout(`updated pending rights for ${email}\n`);
        return 0;
      }
      if (sub === "remove") {
        const email = args[0];
        if (!email) throw new CliError("usage: pending remove <email>", 2);
        const data = await call("POST", "/v1/admin/pending/remove", { email });
        if (parsed.json) outJson(data);
        else io.stdout(`removed pending rights for ${email}\n`);
        return 0;
      }
      throw new CliError(`unknown pending subcommand: ${sub ?? ""}`, 2);
    }

    if (group === "workspaces") {
      if (sub === "list") {
        const { flags } = takeFlags(args, new Set(["--query"]), new Set());
        const data = await call<{ workspaces: any[] }>("GET", "/v1/admin/workspaces");
        const q = (flags.get("--query") ?? "").toLowerCase();
        const list = q ? data.workspaces.filter((w) => `${w.name} ${w.id}`.toLowerCase().includes(q)) : data.workspaces;
        if (parsed.json) outJson({ workspaces: list });
        else {
          for (const w of list) {
            io.stdout(`${w.id}\t${w.name}\tplan:${w.plan ?? "-"}\tmembers:${w.members?.length ?? 0}\tstations:${w.stations?.length ?? 0}\n`);
          }
        }
        return 0;
      }
      if (sub === "get") {
        const id = args[0];
        if (!id) throw new CliError("usage: workspaces get <id>", 2);
        const data = await call<{ workspaces: any[] }>("GET", "/v1/admin/workspaces");
        const w = data.workspaces.find((x) => x.id === id);
        if (!w) throw new CliError(`workspace not found: ${id}`, 1);
        if (parsed.json) outJson(w);
        else io.stdout(`${w.name} (${w.id})\nplan: ${w.plan ?? "-"}\nmembers: ${w.members?.length ?? 0}/${w.seats ?? "-"}\nstations: ${w.stations?.length ?? 0}\n`);
        return 0;
      }
      if (sub === "create") {
        const { pos, flags, multi } = takeFlags(args, new Set(["--members", "--stations"]), new Set(), new Set(["--owner"]));
        const name = pos[0];
        const owners = multi.get("--owner") ?? [];
        if (!name || owners.length === 0) throw new CliError("usage: workspaces create <name> --owner <email> [--owner <email>...] [--members <n>] [--stations <n>]", 2);
        const members = flags.has("--members") ? parseIntOpt(flags.get("--members"), "--members") : 20;
        const stations = flags.has("--stations") ? parseIntOpt(flags.get("--stations"), "--stations") : 64;
        const data = await call<{ id: string }>("POST", "/v1/admin/workspaces", { name, owners, members, stations });
        if (parsed.json) outJson(data);
        else io.stdout(`created workspace ${data.id} (${name})\n`);
        return 0;
      }
      if (sub === "limits") {
        const { pos, flags, bools } = takeFlags(args, new Set(["--members", "--stations"]), new Set(["--reset"]));
        const id = pos[0];
        if (!id) throw new CliError("usage: workspaces limits <id> (--members <n> [--stations <n>] | --reset)", 2);
        let body: Record<string, unknown>;
        if (bools.has("--reset")) {
          body = { reset: true };
        } else if (flags.has("--members")) {
          body = {
            members: parseIntOpt(flags.get("--members"), "--members"),
            stations: flags.has("--stations") ? parseIntOpt(flags.get("--stations"), "--stations") : 64,
          };
        } else {
          throw new CliError("specify --members <n> or --reset", 2);
        }
        const data = await call("POST", `/v1/admin/workspaces/${encodeURIComponent(id)}/limits`, body);
        if (parsed.json) outJson(data);
        else io.stdout(`updated limits for ${id}\n`);
        return 0;
      }
      if (sub === "add-owners") {
        const [id, ...emails] = args;
        if (!id || emails.length === 0) throw new CliError("usage: workspaces add-owners <id> <email...>", 2);
        const data = await call("POST", `/v1/admin/workspaces/${encodeURIComponent(id)}/owners`, { emails });
        if (parsed.json) outJson(data);
        else io.stdout(`added owners to ${id}: ${emails.join(", ")}\n`);
        return 0;
      }
      if (sub === "remove-added") {
        const [id, email] = args;
        if (!id || !email) throw new CliError("usage: workspaces remove-added <id> <email>", 2);
        const data = await call("POST", `/v1/admin/workspaces/${encodeURIComponent(id)}/added/remove`, { email });
        if (parsed.json) outJson(data);
        else io.stdout(`removed pending owner ${email} from ${id}\n`);
        return 0;
      }
      if (sub === "enroll") {
        const [id, name] = args;
        if (!id || !name) throw new CliError("usage: workspaces enroll <id> <station-name>", 2);
        const data = await call<{ command: string; install: string }>("POST", `/v1/admin/workspaces/${encodeURIComponent(id)}/enrollments`, { name });
        if (parsed.json) outJson(data);
        else io.stdout(`${data.install}\n`);
        return 0;
      }
      if (sub === "delete") {
        const { pos, bools } = takeFlags(args, new Set(), new Set(["--yes"]));
        const id = pos[0];
        if (!id) throw new CliError("usage: workspaces delete <id> --yes", 2);
        if (!bools.has("--yes")) throw new CliError("refusing to delete workspace without --yes", 2);
        const data = await call("POST", `/v1/admin/workspaces/${encodeURIComponent(id)}/delete`, {});
        if (parsed.json) outJson(data);
        else io.stdout(`deleted workspace ${id}\n`);
        return 0;
      }
      throw new CliError(`unknown workspaces subcommand: ${sub ?? ""}`, 2);
    }

    if (group === "codes") {
      if (sub === "list") {
        const { flags } = takeFlags(args, new Set(["--filter"]), new Set());
        const data = await call<{ codes: any[] }>("GET", "/v1/admin/invite-codes");
        const filter = flags.get("--filter") ?? "all";
        const now = nowSec();
        const stateOf = (c: any): string => {
          if (c.used_at || c.used_by) return "used";
          if (c.revoked_at) return "revoked";
          if (typeof c.expires_at === "number" && c.expires_at <= now) return "expired";
          return "open";
        };
        const codes = data.codes.filter((c) => filter === "all" || stateOf(c) === filter);
        if (parsed.json) outJson({ codes });
        else {
          for (const c of codes) {
            const st = stateOf(c);
            io.stdout(`${c.code}\t${st}\t${c.beta ? "beta\t" : ""}${c.note || "-"}\texp:${fmtTime(c.expires_at)}\n`);
          }
        }
        return 0;
      }
      if (sub === "create") {
        const { flags, bools } = takeFlags(args, new Set(["--note", "--days"]), new Set(["--beta"]));
        const body: Record<string, unknown> = {};
        if (flags.has("--note")) body.note = flags.get("--note");
        if (flags.has("--days")) body.days = parseIntOpt(flags.get("--days"), "--days");
        if (bools.has("--beta")) body.beta = true;
        const data = await call<{ code: string; url: string }>("POST", "/v1/admin/invite-codes", body);
        if (parsed.json) outJson(data);
        else io.stdout(`${data.code}\t${data.url}\n`);
        return 0;
      }
      if (sub === "revoke") {
        const code = args[0];
        if (!code) throw new CliError("usage: codes revoke <code>", 2);
        const data = await call("POST", `/v1/admin/invite-codes/${encodeURIComponent(code)}/revoke`, {});
        if (parsed.json) outJson(data);
        else io.stdout(`revoked code ${code}\n`);
        return 0;
      }
      throw new CliError(`unknown codes subcommand: ${sub ?? ""}`, 2);
    }

    if (group === "feedback") {
      if (sub === "list") {
        const { flags } = takeFlags(args, new Set(["--status", "--area", "--query"]), new Set());
        const data = await call<{ feedback: any[] }>("GET", "/v1/admin/feedback");
        const status = flags.get("--status") ?? "all";
        const area = flags.get("--area");
        const q = (flags.get("--query") ?? "").toLowerCase();
        let list = data.feedback;
        if (status !== "all") list = list.filter((f) => f.status === status);
        if (area) list = list.filter((f) => f.area === area);
        if (q) list = list.filter((f) => `fb-${f.number} ${f.title} ${f.body} ${f.reporter}`.toLowerCase().includes(q));
        if (parsed.json) outJson({ feedback: list });
        else {
          for (const f of list) {
            io.stdout(`FB-${f.number}\t[${f.status}]\t${f.area}\t${f.title}\n`);
          }
        }
        return 0;
      }
      if (sub === "get") {
        const ref = args[0];
        if (!ref) throw new CliError("usage: feedback get <id-or-FB-n>", 2);
        const data = await call<{ item: any }>("GET", `/v1/admin/feedback/${encodeURIComponent(ref)}`);
        if (parsed.json) outJson(data);
        else io.stdout(`FB-${data.item.number} [${data.item.status}] ${data.item.title}\n\n${data.item.body}\n`);
        return 0;
      }
      if (sub === "status") {
        const [ref, status] = args;
        if (!ref || !status) throw new CliError("usage: feedback status <id-or-FB-n> <new|triaged|fixed|wontfix>", 2);
        const id = await resolveFeedbackId(ref);
        const data = await call("POST", `/v1/admin/feedback/${encodeURIComponent(id)}/status`, { status });
        if (parsed.json) outJson(data);
        else io.stdout(`${ref}: status=${status}\n`);
        return 0;
      }
      if (sub === "reply") {
        const [ref, ...words] = args;
        const text = words.join(" ");
        if (!ref || !text) throw new CliError("usage: feedback reply <id-or-FB-n> <text>", 2);
        const id = await resolveFeedbackId(ref);
        const data = await call("POST", `/v1/admin/feedback/${encodeURIComponent(id)}/reply`, { text });
        if (parsed.json) outJson(data);
        else io.stdout(`replied to ${ref}\n`);
        return 0;
      }
      throw new CliError(`unknown feedback subcommand: ${sub ?? ""}`, 2);
    }

    if (group === "relays") {
      if (sub === "list") {
        const data = await call<{ relays: any[]; tokens: any[]; mesh?: any[] }>("POST", "/v1/admin/relays/list", {});
        if (parsed.json) outJson(data);
        else {
          for (const r of data.relays ?? []) {
            io.stdout(`${r.name}\t${r.url}${r.target ? `\t-> ${r.target}` : ""}\n`);
          }
        }
        return 0;
      }
      if (sub === "stats") {
        const data = await call("GET", "/v1/admin/relays");
        outJson(data);
        return 0;
      }
      if (sub === "put") {
        const { pos, flags } = takeFlags(args, new Set(["--target"]), new Set());
        const [url, name] = pos;
        if (!url || !name) throw new CliError("usage: relays put <url> <name> [--target <relay-url>]", 2);
        const body: Record<string, unknown> = { url, name };
        if (flags.has("--target")) body.target = flags.get("--target");
        const data = await call("POST", "/v1/admin/relays/put", body);
        if (parsed.json) outJson(data);
        else io.stdout(`put relay ${name} (${url})\n`);
        return 0;
      }
      if (sub === "rename") {
        const { pos, flags } = takeFlags(args, new Set(["--target"]), new Set());
        const [url, name] = pos;
        if (!url || !name) throw new CliError("usage: relays rename <url> <name> [--target <relay-url>]", 2);
        let target = flags.get("--target");
        if (target === undefined) {
          const listed = await call<{ relays: { url: string; target?: string | null }[] }>("POST", "/v1/admin/relays/list", {});
          const existing = listed.relays.find((r) => r.url === url);
          if (existing?.target) target = existing.target;
        }
        const body: Record<string, unknown> = { url, name, ...(target ? { target } : {}) };
        const data = await call("POST", "/v1/admin/relays/put", body);
        if (parsed.json) outJson(data);
        else io.stdout(`renamed relay ${url} -> ${name}${target ? ` (target: ${target})` : ""}\n`);
        return 0;
      }
      if (sub === "remove") {
        const url = args[0];
        if (!url) throw new CliError("usage: relays remove <url>", 2);
        const data = await call("POST", "/v1/admin/relays/remove", { url });
        if (parsed.json) outJson(data);
        else io.stdout(`removed relay ${url}\n`);
        return 0;
      }
      if (sub === "token") {
        const { pos, flags } = takeFlags(args, new Set(["--url", "--target"]), new Set());
        const name = pos[0];
        if (!name) throw new CliError("usage: relays token <name> [--url <url>] [--target <relay-url>]", 2);
        const body: Record<string, unknown> = { name };
        if (flags.has("--url")) body.url = flags.get("--url");
        if (flags.has("--target")) body.target = flags.get("--target");
        const data = await call<{ command: string }>("POST", "/v1/admin/relays/token", body);
        if (parsed.json) outJson(data);
        else io.stdout(`${data.command}\n`);
        return 0;
      }
      if (sub === "token-revoke") {
        const id = args[0];
        if (!id) throw new CliError("usage: relays token-revoke <id>", 2);
        const data = await call("POST", "/v1/admin/relays/token/revoke", { id });
        if (parsed.json) outJson(data);
        else io.stdout(`revoked relay token ${id}\n`);
        return 0;
      }
      if (sub === "mesh-token") {
        const name = args[0];
        if (!name) throw new CliError("usage: relays mesh-token <name>", 2);
        const data = await call("POST", "/v1/admin/relays/mesh-token", { name });
        outJson(data);
        return 0;
      }
      if (sub === "mesh-remove") {
        const node = args[0];
        if (!node) throw new CliError("usage: relays mesh-remove <node>", 2);
        const data = await call("POST", "/v1/admin/relays/mesh-remove", { node });
        if (parsed.json) outJson(data);
        else io.stdout(`removed mesh relay ${node}\n`);
        return 0;
      }
      throw new CliError(`unknown relays subcommand: ${sub ?? ""}`, 2);
    }

    if (group === "audit") {
      const restAudit = sub ? [sub, ...args] : args;
      const { flags } = takeFlags(restAudit, new Set(["--kind", "--limit"]), new Set());
      const data = await call<{ audit: any[] }>("GET", "/v1/admin/audit");
      const kind = flags.get("--kind");
      const limit = flags.has("--limit") ? parseIntOpt(flags.get("--limit"), "--limit") : 50;
      let list = data.audit;
      if (kind) {
        list = list.filter((e) => {
          const a = String(e.action ?? "");
          if (kind === "users") return a.startsWith("user.") || a.startsWith("pending.");
          if (kind === "workspaces") return a.startsWith("workspace.");
          if (kind === "codes") return a.startsWith("code.");
          if (kind === "feedback") return a.startsWith("feedback.");
          if (kind === "relays") return a.startsWith("relay.");
          if (kind === "keys") return a.startsWith("key.");
          return a.startsWith(`${kind}.`) || a === kind;
        });
      }
      list = list.slice(0, limit);
      if (parsed.json) outJson({ audit: list });
      else {
        for (const e of list) {
          io.stdout(`${fmtTime(e.created_at)}\t${e.actor}\t${e.action}\t${e.target}${e.detail ? `\t${e.detail}` : ""}\n`);
        }
      }
      return 0;
    }

    throw new CliError(`unknown command: ${group}`, 2);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    io.stderr(`error: ${msg.split(apiKey).join("[redacted]")}\n`);
    return err instanceof CliError ? err.code : 1;
  }
}

async function main(): Promise<void> {
  const code = await runAdminCli(process.argv.slice(2), {
    stdout: (s) => process.stdout.write(s),
    stderr: (s) => process.stderr.write(s),
    env: process.env,
    argv0: process.env.STILLFAIL_CMD || process.argv[1],
  });
  process.exitCode = code;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void main();
}
