// A profile's own MCP servers (config.json `profiles[].mcp`), given to its sessions beside the station's server on every
// runtime that takes servers per session: Claude Code (--mcp-config), Codex (the thread's config), GitHub Copilot (the
// SDK's session). One shape for all, the Copilot CLI's mcp-config.json entries: a local command (`command`, `args`,
// `env`) or a remote server (`type` http or sse, `url`, `headers`), and `enabled` false to keep one without using it.
// Edited by PUT /profiles/:id (accounts/index.ts putProfile), read masked by the overview, carried with the profile
// where it moves or is shared (share/index.ts portable). What a runtime's own home configures stays as it is: these
// are added to it, never written into it.
import { maskValue } from "../ops/agent-env.ts";
import { TOOL_SERVERS } from "./runtime.ts";

type Json = any;

export type McpServer = {
  type?: "stdio" | "http" | "sse";
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  url?: string;
  headers?: Record<string, string>;
  enabled?: boolean;
};

/// A server's name: what each runtime takes (Codex its config's keys, Copilot its tools' prefix).
const NAME = /^[A-Za-z0-9_-]{1,64}$/;
const VARIABLE = /^[A-Za-z_][A-Za-z0-9_]*$/;
/// The most servers a profile has, and of one's list and maps.
const MOST_SERVERS = 50;
const MOST_ITEMS = 100;
const MOST_TEXT = 8192;

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/// Whether a name is the station's: its server's, or one its tools' names would be read as (`stillfail-…`, any case).
export const reserved = (name: string) => TOOL_SERVERS.some((s) => name.toLowerCase() === s || name.toLowerCase().startsWith(`${s}-`) || name.toLowerCase().startsWith(`${s}_`));

const text = (v: unknown, what: string): string => {
  if (typeof v !== "string") throw new Error(`${what} must be a string`);
  if (v.length > MOST_TEXT) throw new Error(`${what} is too long`);
  return v;
};

function strings(v: unknown, what: string): string[] {
  if (!Array.isArray(v) || v.length > MOST_ITEMS) throw new Error(`${what} must be a list of at most ${MOST_ITEMS} strings`);
  return v.map((s, i) => text(s, `${what}[${i}]`));
}

/// A map of strings given, its values masked as the overview showed them keeping those it had (as a profile's env).
function map(v: unknown, before: Record<string, string> | undefined, what: string, keys: RegExp): Record<string, string> {
  if (!isObject(v) || Object.keys(v).length > MOST_ITEMS) throw new Error(`${what} must be a map of at most ${MOST_ITEMS} strings`);
  const out: Record<string, string> = {};
  for (const [k, value] of Object.entries(v)) {
    if (!keys.test(k)) throw new Error(`${what}: invalid name ${JSON.stringify(k)}`);
    const given = text(value, `${what}.${k}`);
    const had = before?.[k];
    out[k] = had !== undefined && given !== "" && given === maskValue(had) ? had : given;
  }
  return out;
}

/// One server as given, checked: local (a command) or remote (a URL), nothing else kept.
export function server(given: unknown, before?: McpServer): McpServer {
  if (!isObject(given)) throw new Error("a server must be an object");
  const type = given.type === undefined || given.type === "stdio" || given.type === "local" ? "stdio" : given.type;
  if (type !== "stdio" && type !== "http" && type !== "sse") throw new Error(`unknown server type ${JSON.stringify(given.type)}`);
  const out: McpServer = { type };
  if (type === "stdio") {
    const command = text(given.command, "command").trim();
    if (command === "") throw new Error("a local server needs a command");
    out.command = command;
    if (given.args !== undefined) out.args = strings(given.args, "args");
    if (given.env !== undefined) out.env = map(given.env, before?.env, "env", VARIABLE);
  } else {
    const url = text(given.url, "url").trim();
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw new Error(`url ${JSON.stringify(url)} is not a URL`);
    }
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") throw new Error("url must be http or https");
    out.url = url;
    if (given.headers !== undefined) out.headers = map(given.headers, before?.headers, "headers", /^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/);
  }
  if (given.enabled !== undefined && typeof given.enabled !== "boolean") throw new Error("enabled must be a boolean");
  if (given.enabled === false) out.enabled = false;
  return out;
}

/// A profile's servers after an edit: `edit` names each server changed, an object to set it (whole: what it leaves out
/// is gone, masked values kept), null to remove it; those it does not name stay.
export function edited(before: unknown, edit: unknown): Record<string, McpServer> | undefined {
  const had = servers(before);
  if (edit === undefined) return Object.keys(had).length > 0 ? had : undefined;
  if (edit === null) return undefined;
  if (!isObject(edit)) throw new Error("mcp must be a map of servers by name");
  const out: Record<string, McpServer> = { ...had };
  for (const [name, given] of Object.entries(edit)) {
    if (given === null) {
      delete out[name];
      continue;
    }
    if (!NAME.test(name)) throw new Error(`server name ${JSON.stringify(name)}: letters, digits, - and _ (64 at most)`);
    if (reserved(name)) throw new Error(`server name ${JSON.stringify(name)} is the station's own`);
    out[name] = server(given, had[name]);
  }
  if (Object.keys(out).length > MOST_SERVERS) throw new Error(`a profile has at most ${MOST_SERVERS} MCP servers`);
  return Object.keys(out).length > 0 ? out : undefined;
}

/// A profile's servers as config.json keeps them: those that read as servers (one written by hand that does not is
/// left out, the rest still given).
export function servers(raw: unknown): Record<string, McpServer> {
  if (!isObject(raw)) return {};
  const out: Record<string, McpServer> = {};
  for (const [name, given] of Object.entries(raw)) {
    if (!NAME.test(name) || reserved(name)) continue;
    try {
      out[name] = server(given);
    } catch {}
  }
  return out;
}

/// What its sessions are given: its servers not turned off.
export function profileMcp(profile: { [key: string]: unknown }): Record<string, McpServer> {
  return Object.fromEntries(Object.entries(servers(profile.mcp)).filter(([, s]) => s.enabled !== false));
}

/// As the pages read them: by name, every value of `env` and `headers` masked.
export function mcpView(raw: unknown): Json[] {
  const masked = (m?: Record<string, string>) => (m === undefined ? undefined : Object.fromEntries(Object.entries(m).map(([k, v]) => [k, maskValue(v)])));
  return Object.entries(servers(raw))
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([name, s]) => ({ name, ...s, enabled: s.enabled !== false, ...(s.env ? { env: masked(s.env) } : {}), ...(s.headers ? { headers: masked(s.headers) } : {}) }));
}

/// For Claude Code's --mcp-config: each value of `env` and `headers` as a variable of the process (`vars`), named in the
/// config as `${NAME}`, which Claude Code expands, so no secret is on its command line.
export function claudeServers(given: Record<string, McpServer>, vars: Record<string, string>): Record<string, Json> {
  const out: Record<string, Json> = {};
  let n = 0;
  const hidden = (m: Record<string, string>) =>
    Object.fromEntries(Object.entries(m).map(([k, v]) => {
      const name = `STILLFAIL_MCP_VALUE_${n++}`;
      vars[name] = v;
      return [k, `\${${name}}`];
    }));
  for (const [name, s] of Object.entries(given)) {
    if (s.type === "stdio") out[name] = { type: "stdio", command: s.command, args: s.args ?? [], ...(s.env ? { env: hidden(s.env) } : {}) };
    else out[name] = { type: s.type, url: s.url, ...(s.headers ? { headers: hidden(s.headers) } : {}) };
  }
  return out;
}

/// For a Codex thread's config: `mcp_servers.<name>.…` keys. Codex speaks to remote servers over streamable HTTP only, so
/// an `sse` one is left out (`skipped`).
export function codexServers(given: Record<string, McpServer>): { config: Record<string, Json>; skipped: string[] } {
  const config: Record<string, Json> = {};
  const skipped: string[] = [];
  for (const [name, s] of Object.entries(given)) {
    const at = `mcp_servers.${name}`;
    if (s.type === "stdio") {
      config[`${at}.command`] = s.command;
      if (s.args) config[`${at}.args`] = s.args;
      if (s.env) config[`${at}.env`] = s.env;
    } else if (s.type === "http") {
      config[`${at}.url`] = s.url;
      if (s.headers) config[`${at}.http_headers`] = s.headers;
    } else skipped.push(name);
  }
  return { config, skipped };
}

/// For GitHub Copilot's SDK session (`mcp.servers`): its shapes, every tool of each.
export function copilotServers(given: Record<string, McpServer>): Record<string, Json> {
  const out: Record<string, Json> = {};
  for (const [name, s] of Object.entries(given)) {
    if (s.type === "stdio") out[name] = { type: "stdio", command: s.command, args: s.args ?? [], ...(s.env ? { env: s.env } : {}), tools: ["*"] };
    else out[name] = { type: s.type, url: s.url, ...(s.headers ? { headers: s.headers } : {}), tools: ["*"] };
  }
  return out;
}
