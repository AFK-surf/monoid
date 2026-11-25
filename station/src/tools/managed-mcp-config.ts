// Configuration, validation, secret masking, tool naming, and content bounding for
// station-managed third-party MCP servers (`config.json` `mcpServers`).
import { createHash } from "node:crypto";
import { ENV_NAME, MOST_VALUE, maskValue } from "../ops/agent-env.ts";
import { type Content, INDIRECT, SPEAKS, SPEAKS_WRITING } from "./mcp.ts";

/// Maximum number of managed MCP servers configured on one station.
export const MOST_SERVERS = 32;
/// Maximum env vars or HTTP headers per server.
export const MOST_ENTRIES = 32;
/// Maximum command arguments per stdio server.
export const MOST_ARGS = 64;
/// Maximum tools exposed by a single managed MCP server.
export const MOST_TOOLS_PER_SERVER = 128;
/// Maximum length of an exported tool name (leaves room for runtime prefixes like `mcp__stillfail__`, 16 chars, under Claude's 64-char limit).
export const MAX_TOOL_NAME_LEN = 48;
/// Maximum serialized bytes of a single tool call result before truncation.
export const MAX_RESULT_BYTES = 256 * 1024;

/// Allowed server names: ASCII alphanumeric, `-`, `_`, starting with alphanumeric, max 64 chars, and no `__` separator.
export const SERVER_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/;
const HEADER_NAME_RE = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
const RESERVED_LOWER = new Set(["stillfail", "mcp_servers", INDIRECT.toLowerCase(), SPEAKS_WRITING.toLowerCase(), ...SPEAKS.map((s) => s.toLowerCase())]);

export type StdioMcpServerConfig = {
  command: string;
  args?: string[];
  env?: Record<string, string>;
  enabled?: boolean;
  shared?: boolean;
};

export type RemoteMcpServerConfig = {
  type: "http" | "sse";
  url: string;
  headers?: Record<string, string>;
  enabled?: boolean;
  shared?: boolean;
};

export type ManagedMcpServerConfig = StdioMcpServerConfig | RemoteMcpServerConfig;
export type ManagedMcpConfig = Record<string, ManagedMcpServerConfig>;

export type ManagedMcpStatus = "disabled" | "connecting" | "ready" | "reconnecting" | "failed" | "stopped";

export type ManagedMcpServerView = {
  name: string;
  transport: "stdio" | "http" | "sse";
  enabled: boolean;
  shared: boolean;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  url?: string;
  headers?: Record<string, string>;
  status: ManagedMcpStatus;
  toolCount: number;
  tools: string[];
  error: string | null;
};

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);

export function isRemoteConfig(entry: ManagedMcpServerConfig): entry is RemoteMcpServerConfig {
  return "type" in entry && (entry.type === "http" || entry.type === "sse");
}

/// Throws what is wrong with a server name.
export function checkServerName(name: string): void {
  if (!SERVER_NAME_RE.test(name) || name.includes("__")) {
    throw new Error(`mcpServers: invalid server name ${JSON.stringify(name)} (use letters, digits, '-' or '_', no '__', max 64 chars)`);
  }
  const lower = name.toLowerCase();
  if (RESERVED_LOWER.has(lower) || lower.startsWith("stillfail-") || lower.startsWith("stillfail_")) {
    throw new Error(`mcpServers: server name ${JSON.stringify(name)} is reserved`);
  }
}

function checkStringMap(map: unknown, path: string, keyRe: RegExp, keyLabel: string): void {
  if (map === undefined || map === null) return;
  if (!isObject(map)) throw new Error(`${path}: must be an object`);
  const entries = Object.entries(map);
  if (entries.length > MOST_ENTRIES) throw new Error(`${path}: at most ${MOST_ENTRIES} entries`);
  for (const [k, v] of entries) {
    if (!keyRe.test(k)) throw new Error(`${path}: invalid ${keyLabel} ${JSON.stringify(k)}`);
    if (typeof v !== "string") throw new Error(`${path}.${k}: must be a string`);
    if (v.length > MOST_VALUE || /[\0\n\r]/.test(v)) throw new Error(`${path}.${k}: one line of at most ${MOST_VALUE} characters`);
  }
}

/// Validates a single server entry; throws on error.
export function checkServerEntry(name: string, entry: unknown): void {
  checkServerName(name);
  const p = `mcpServers.${name}`;
  if (!isObject(entry)) throw new Error(`${p}: must be an object`);
  if (entry.enabled !== undefined && typeof entry.enabled !== "boolean") throw new Error(`${p}.enabled: must be a boolean`);
  if (entry.shared !== undefined && typeof entry.shared !== "boolean") throw new Error(`${p}.shared: must be a boolean`);

  const hasType = entry.type !== undefined;
  const hasUrl = entry.url !== undefined;
  const hasCommand = entry.command !== undefined;

  if (hasType || hasUrl) {
    if (hasCommand) throw new Error(`${p}: cannot specify both command and url/type`);
    if (entry.type !== "http" && entry.type !== "sse") throw new Error(`${p}.type: must be "http" or "sse"`);
    if (typeof entry.url !== "string" || entry.url.trim() === "") throw new Error(`${p}.url: must be a non-empty string`);
    let parsed: URL;
    try {
      parsed = new URL(entry.url);
    } catch {
      throw new Error(`${p}.url: invalid URL`);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error(`${p}.url: must use http or https`);
    if (entry.args !== undefined || entry.env !== undefined) throw new Error(`${p}: args/env are only for stdio servers`);
    checkStringMap(entry.headers, `${p}.headers`, HEADER_NAME_RE, "header name");
  } else {
    if (typeof entry.command !== "string" || entry.command.trim() === "" || /[\0\n\r]/.test(entry.command)) {
      throw new Error(`${p}.command: must be a non-empty single-line string`);
    }
    if (entry.command.length > MOST_VALUE) throw new Error(`${p}.command: at most ${MOST_VALUE} characters`);
    if (entry.args !== undefined) {
      if (!Array.isArray(entry.args)) throw new Error(`${p}.args: must be an array of strings`);
      if (entry.args.length > MOST_ARGS) throw new Error(`${p}.args: at most ${MOST_ARGS} arguments`);
      for (let i = 0; i < entry.args.length; i++) {
        const a = entry.args[i];
        if (typeof a !== "string" || a.length > MOST_VALUE || a.includes("\0")) {
          throw new Error(`${p}.args[${i}]: must be a string of at most ${MOST_VALUE} characters`);
        }
      }
    }
    if (entry.headers !== undefined) throw new Error(`${p}: headers are only for http/sse servers`);
    checkStringMap(entry.env, `${p}.env`, ENV_NAME, "environment variable name");
  }
}

/// Validates `config.json`'s `mcpServers` field (`accounts/check.ts`).
export function checkManagedMcp(set: unknown): void {
  if (set === undefined || set === null) return;
  if (!isObject(set)) throw new Error("mcpServers: must be an object mapping server names to configurations");
  const entries = Object.entries(set);
  if (entries.length > MOST_SERVERS) throw new Error(`mcpServers: at most ${MOST_SERVERS} servers`);
  for (const [name, entry] of entries) checkServerEntry(name, entry);
}

function normalizeEntry(entry: Record<string, unknown>): ManagedMcpServerConfig {
  const enabled = entry.enabled === false ? false : undefined;
  const shared = entry.shared === true ? true : undefined;
  if (entry.type === "http" || entry.type === "sse") {
    const headers = isObject(entry.headers)
      ? Object.fromEntries(Object.entries(entry.headers).filter((e): e is [string, string] => typeof e[1] === "string"))
      : undefined;
    return {
      type: entry.type,
      url: String(entry.url),
      ...(headers && Object.keys(headers).length > 0 ? { headers } : {}),
      ...(enabled === false ? { enabled: false } : {}),
      ...(shared === true ? { shared: true } : {}),
    };
  }
  const args = Array.isArray(entry.args) ? entry.args.filter((a): a is string => typeof a === "string") : undefined;
  const env = isObject(entry.env)
    ? Object.fromEntries(Object.entries(entry.env).filter((e): e is [string, string] => typeof e[1] === "string"))
    : undefined;
  return {
    command: String(entry.command),
    ...(args && args.length > 0 ? { args } : {}),
    ...(env && Object.keys(env).length > 0 ? { env } : {}),
    ...(enabled === false ? { enabled: false } : {}),
    ...(shared === true ? { shared: true } : {}),
  };
}

/// Reads validated `mcpServers` from a raw config object.
export function managedMcpConfig(raw: unknown): ManagedMcpConfig {
  const set = isObject(raw) ? raw.mcpServers : undefined;
  if (!isObject(set)) return {};
  const out: ManagedMcpConfig = {};
  for (const [name, entry] of Object.entries(set)) {
    try {
      checkServerEntry(name, entry);
      out[name] = normalizeEntry(entry as Record<string, unknown>);
    } catch {
      // Ignore malformed entries when reading defensively; edits are rejected by checkConfig.
    }
  }
  return out;
}

function preserveMaskedMap(
  incoming: Record<string, string> | undefined,
  previous: Record<string, string> | undefined,
): Record<string, string> | undefined {
  if (!incoming) return undefined;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(incoming)) {
    const prev = previous?.[k];
    out[k] = prev !== undefined && v === maskValue(prev) ? prev : v;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

/// Applies a `{ [name]: entry | null }` patch onto `before`, preserving any `env`/`headers` values sent back masked.
export function mergeManagedMcpPatch(before: ManagedMcpConfig, patch: Record<string, unknown>): ManagedMcpConfig {
  const next: ManagedMcpConfig = { ...before };
  for (const [name, value] of Object.entries(patch)) {
    if (value === null) {
      delete next[name];
      continue;
    }
    checkServerEntry(name, value);
    const normalized = normalizeEntry(value as Record<string, unknown>);
    const prev = before[name];
    if (isRemoteConfig(normalized)) {
      const prevHeaders = prev && isRemoteConfig(prev) ? prev.headers : undefined;
      const headers = preserveMaskedMap(normalized.headers, prevHeaders);
      next[name] = {
        type: normalized.type,
        url: normalized.url,
        ...(headers ? { headers } : {}),
        ...(normalized.enabled === false ? { enabled: false } : {}),
        ...(normalized.shared === true ? { shared: true } : {}),
      };
    } else {
      const prevEnv = prev && !isRemoteConfig(prev) ? prev.env : undefined;
      const env = preserveMaskedMap(normalized.env, prevEnv);
      next[name] = {
        command: normalized.command,
        ...(normalized.args ? { args: normalized.args } : {}),
        ...(env ? { env } : {}),
        ...(normalized.enabled === false ? { enabled: false } : {}),
        ...(normalized.shared === true ? { shared: true } : {}),
      };
    }
  }
  checkManagedMcp(next);
  return next;
}

function maskMap(map: Record<string, string> | undefined): Record<string, string> | undefined {
  if (!map || Object.keys(map).length === 0) return undefined;
  return Object.fromEntries(
    Object.entries(map)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([k, v]) => [k, maskValue(v)]),
  );
}

/// Masked view of one server config combined with its live runtime state.
export function maskServerView(
  name: string,
  entry: ManagedMcpServerConfig,
  runtime: { status: ManagedMcpStatus; tools: string[]; error: string | null },
): ManagedMcpServerView {
  const enabled = entry.enabled !== false;
  const shared = entry.shared === true;
  if (isRemoteConfig(entry)) {
    const headers = maskMap(entry.headers);
    return {
      name,
      transport: entry.type,
      enabled,
      shared,
      url: entry.url,
      ...(headers ? { headers } : {}),
      status: enabled ? runtime.status : "disabled",
      toolCount: runtime.tools.length,
      tools: runtime.tools,
      error: runtime.error,
    };
  }
  const env = maskMap(entry.env);
  return {
    name,
    transport: "stdio",
    enabled,
    shared,
    command: entry.command,
    ...(entry.args && entry.args.length > 0 ? { args: [...entry.args] } : {}),
    ...(env ? { env } : {}),
    status: enabled ? runtime.status : "disabled",
    toolCount: runtime.tools.length,
    tools: runtime.tools,
    error: runtime.error,
  };
}

/// Config-only masked view (used when live manager is unavailable, e.g., in static overview tests).
export function managedMcpConfigView(raw: unknown): ManagedMcpServerView[] {
  const cfg = managedMcpConfig(raw);
  return Object.keys(cfg)
    .sort()
    .map((name) => {
      const entry = cfg[name]!;
      return maskServerView(name, entry, {
        status: entry.enabled === false ? "disabled" : "stopped",
        tools: [],
        error: null,
      });
    });
}

/// Deterministic canonical JSON for stable schema hashing and config equality checks.
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj).sort();
  const parts: string[] = [];
  for (const k of keys) {
    if (obj[k] === undefined) continue;
    parts.push(`${JSON.stringify(k)}:${canonicalJson(obj[k])}`);
  }
  return `{${parts.join(",")}}`;
}

/// Deterministic, order-independent, runtime-safe exported tool names (`^[a-zA-Z0-9_-]{1,48}$`) for one server.
/// Any tool whose sanitized name exceeds `MAX_TOOL_NAME_LEN` or collides with another tool on the same server receives
/// a hash suffix derived solely from `(server, originalToolName)`, so reordering upstream tools never swaps names.
export function exportedToolNames(server: string, tools: readonly string[]): Map<string, string> {
  const rawByTool = new Map<string, string>();
  const counts = new Map<string, number>();
  for (const tool of tools) {
    const sanitized = tool.replace(/[^a-zA-Z0-9_-]/g, "_").replace(/^_+|_+$/g, "") || "tool";
    const candidate = `${server}__${sanitized}`;
    rawByTool.set(tool, candidate);
    counts.set(candidate, (counts.get(candidate) ?? 0) + 1);
  }
  const out = new Map<string, string>();
  for (const tool of tools) {
    const candidate = rawByTool.get(tool)!;
    if (candidate.length <= MAX_TOOL_NAME_LEN && (counts.get(candidate) ?? 0) === 1) {
      out.set(tool, candidate);
    } else {
      const hash = createHash("sha256").update(`${server}\0${tool}`).digest("hex").slice(0, 8);
      const suffix = `_${hash}`;
      const prefixMax = MAX_TOOL_NAME_LEN - suffix.length;
      out.set(tool, `${candidate.slice(0, prefixMax)}${suffix}`);
    }
  }
  return out;
}

function truncateUtf8(str: string, maxBytes: number): string {
  if (maxBytes <= 0) return "";
  const buf = Buffer.from(str, "utf8");
  if (buf.length <= maxBytes) return str;
  // Back off from any incomplete multi-byte UTF-8 sequence at the cut boundary.
  let end = maxBytes;
  while (end > 0 && (buf[end]! & 0xc0) === 0x80) end--;
  return buf.subarray(0, end).toString("utf8");
}

/// Preserves all MCP content items (text, image, resource, etc.) verbatim, truncating only if total bytes exceed `maxBytes`.
export function truncateContent(items: readonly Content[], maxBytes = MAX_RESULT_BYTES): Content[] {
  const notice = `\n\n[truncated: tool result exceeded ${Math.round(maxBytes / 1024)} KiB limit]`;
  const noticeBytes = Buffer.byteLength(notice, "utf8");
  let used = 0;
  const out: Content[] = [];
  let truncated = false;

  for (const item of items) {
    const rawSize = Buffer.byteLength(JSON.stringify(item), "utf8");
    if (used + rawSize <= maxBytes) {
      out.push(item);
      used += rawSize;
      continue;
    }
    truncated = true;
    const remaining = Math.max(0, maxBytes - used - noticeBytes);
    if (item && typeof item === "object" && (item as { type?: unknown }).type === "text" && typeof (item as { text?: unknown }).text === "string") {
      if (remaining > 0) {
        const sliced = truncateUtf8((item as { text: string }).text, remaining);
        out.push({ ...item, type: "text", text: `${sliced}${notice}` });
      } else {
        out.push({ type: "text", text: notice.trimStart() });
      }
      break;
    }
    if (
      item &&
      typeof item === "object" &&
      (item as { type?: unknown }).type === "resource" &&
      isObject((item as { resource?: unknown }).resource) &&
      typeof ((item as { resource: Record<string, unknown> }).resource).text === "string"
    ) {
      const res = (item as { resource: Record<string, unknown> }).resource;
      const overhead = rawSize - Buffer.byteLength(res.text as string, "utf8");
      const textBudget = Math.max(0, remaining - overhead);
      if (textBudget > 0) {
        out.push({
          ...item,
          type: "resource",
          resource: { ...res, text: `${truncateUtf8(res.text as string, textBudget)}${notice}` },
        });
      } else {
        out.push({ type: "text", text: notice.trimStart() });
      }
      break;
    }
    // Binary/image/blob item that does not fit in remaining budget: emit truncation note.
    out.push({ type: "text", text: notice.trimStart() });
    break;
  }

  if (!truncated && out.length === 0) return [];
  return out;
}
