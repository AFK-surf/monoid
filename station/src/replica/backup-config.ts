// Backup targets configuration (config.json `backup`): which workspace stations keep this station's copies (auto
// rendezvous or a manual list, empty for none), whether this station accepts copies of others, and any external
// S3/R2-compatible object storage targets (end-to-end encrypted before leaving the station).
// Secrets (`secretAccessKey`, `encryptionKey`) stay in config.json (0600) and are never returned in overview or GET.
import { createHash, randomBytes } from "node:crypto";
import { maskValue } from "../ops/agent-env.ts";
import { STATION } from "./format.ts";

export type S3TargetConfig = {
  id: string;
  name: string;
  endpoint: string;
  region: string;
  bucket: string;
  prefix?: string;
  forcePathStyle?: boolean;
  accessKeyId: string;
  secretAccessKey: string;
  encryptionKey: string;
  includeTranscripts?: boolean;
};

export type NormalizedS3Target = {
  id: string;
  name: string;
  endpoint: string;
  region: string;
  bucket: string;
  prefix: string;
  forcePathStyle: boolean;
  accessKeyId: string;
  secretAccessKey: string;
  encryptionKey: string;
  includeTranscripts: boolean;
};

export type BackupConfig = {
  stations?: "auto" | string[];
  acceptOthers?: boolean;
  s3?: S3TargetConfig[];
  /// The most every backup upload together may take of the uplink, in megabits a second (0: no limit).
  uploadMbps?: number;
};

export type NormalizedBackupConfig = {
  mode: "auto" | "manual";
  stations: string[];
  acceptOthers: boolean;
  s3: NormalizedS3Target[];
  /// `readBackupConfig` always sets it (DEFAULT_UPLOAD_MBPS unless configured).
  uploadMbps?: number;
};

export type S3TargetStatus = {
  to: number;
  at: number | null;
  error: string | null;
  reason: "offline" | "old" | "error" | null;
};

export type BackupPeerView = {
  station: string;
  name: string;
  acceptOthers: boolean;
  online: boolean;
};

export type S3TargetView = {
  id: string;
  name: string;
  endpoint: string;
  region: string;
  bucket: string;
  prefix: string;
  forcePathStyle: boolean;
  accessKeyMask: string;
  keyFingerprint: string;
  includeTranscripts: boolean;
  to: number;
  at: number | null;
  error: string | null;
  reason: "offline" | "old" | "error" | null;
};

export type BackupView = {
  mode: "auto" | "manual";
  stations: string[];
  acceptOthers: boolean;
  peers: BackupPeerView[];
  s3: S3TargetView[];
  /// The most backup uploads take of the uplink, in megabits a second (0: no limit).
  uploadMbps: number;
};

export const S3_ID = /^[a-z0-9_-]{1,32}$/;
export const ENC_KEY = /^[0-9a-f]{64}$/;
export const S3_BUCKET = /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/;
export const DEFAULT_PREFIX = "stillfail-backup";
export const DEFAULT_REGION = "auto";
/// What backups take of the uplink unless set: a first copy of many GB must not fill a home line (replica/pace.ts).
export const DEFAULT_UPLOAD_MBPS = 8;

const isMbps = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0;

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);

export function normalizePrefix(prefix: unknown): string {
  if (prefix === undefined || prefix === null) return DEFAULT_PREFIX;
  if (typeof prefix !== "string") throw new Error("s3.prefix must be a string");
  return prefix.trim().replace(/^\/+|\/+$/g, "");
}

export function validateEndpoint(endpoint: unknown): string {
  if (typeof endpoint !== "string" || endpoint.trim() === "") throw new Error("s3.endpoint is required");
  let u: URL;
  try {
    u = new URL(endpoint.trim());
  } catch {
    throw new Error("s3.endpoint must be a valid URL");
  }
  const host = u.hostname.toLowerCase();
  const isLoopback = host === "127.0.0.1" || host === "localhost" || host === "[::1]" || host === "::1";
  if (u.protocol !== "https:" && !(u.protocol === "http:" && isLoopback)) {
    throw new Error("s3.endpoint must use https:// (http:// is allowed only for loopback)");
  }
  if (u.search !== "" || u.hash !== "") throw new Error("s3.endpoint must not contain query or fragment");
  return u.toString().replace(/\/+$/, "");
}

export function validateBucket(bucket: unknown): string {
  if (typeof bucket !== "string" || !S3_BUCKET.test(bucket) || bucket.includes("..")) {
    throw new Error("s3.bucket must be a valid S3 bucket name (3-63 lowercase letters, digits, dots, or hyphens)");
  }
  return bucket;
}

export function keyFingerprint(encryptionKey: string): string {
  if (!ENC_KEY.test(encryptionKey)) return "";
  return createHash("sha256").update(Buffer.from(encryptionKey, "hex")).digest("hex").slice(0, 8);
}

export function normalizeS3Target(raw: unknown, index: number): NormalizedS3Target {
  if (!isObject(raw)) throw new Error(`backup.s3[${index}] must be an object`);
  const id = raw.id;
  if (typeof id !== "string" || !S3_ID.test(id)) throw new Error(`backup.s3[${index}].id must match /^[a-z0-9_-]{1,32}$/`);
  const name = typeof raw.name === "string" ? raw.name.trim() : "";
  if (name === "") throw new Error(`backup.s3[${index}].name is required`);
  const endpoint = validateEndpoint(raw.endpoint);
  const region = raw.region === undefined || raw.region === null || raw.region === ""
    ? DEFAULT_REGION
    : typeof raw.region === "string"
      ? raw.region.trim()
      : (() => { throw new Error(`backup.s3[${index}].region must be a string`); })();
  const bucket = validateBucket(raw.bucket);
  const prefix = normalizePrefix(raw.prefix);
  if (raw.forcePathStyle !== undefined && typeof raw.forcePathStyle !== "boolean") {
    throw new Error(`backup.s3[${index}].forcePathStyle must be a boolean`);
  }
  const forcePathStyle = raw.forcePathStyle !== false;
  const accessKeyId = typeof raw.accessKeyId === "string" ? raw.accessKeyId.trim() : "";
  if (accessKeyId === "") throw new Error(`backup.s3[${index}].accessKeyId is required`);
  const secretAccessKey = typeof raw.secretAccessKey === "string" ? raw.secretAccessKey : "";
  if (secretAccessKey === "") throw new Error(`backup.s3[${index}].secretAccessKey is required`);
  const encryptionKey = typeof raw.encryptionKey === "string" ? raw.encryptionKey : "";
  if (!ENC_KEY.test(encryptionKey)) throw new Error(`backup.s3[${index}].encryptionKey must be a 64-character lowercase hex string`);
  if (raw.includeTranscripts !== undefined && typeof raw.includeTranscripts !== "boolean") {
    throw new Error(`backup.s3[${index}].includeTranscripts must be a boolean`);
  }
  const includeTranscripts = raw.includeTranscripts !== false;
  return { id, name, endpoint, region, bucket, prefix, forcePathStyle, accessKeyId, secretAccessKey, encryptionKey, includeTranscripts };
}

/// Validates `config.json`'s `backup` section (accounts/check.ts).
export function checkBackupConfig(raw: unknown): void {
  if (raw === undefined || raw === null) return;
  if (!isObject(raw)) throw new Error("backup must be an object");
  if (raw.stations !== undefined && raw.stations !== null && raw.stations !== "auto") {
    if (!Array.isArray(raw.stations) || raw.stations.some((s) => typeof s !== "string" || !STATION.test(s))) {
      throw new Error("backup.stations must be \"auto\" or an array of station ids");
    }
  }
  if (raw.acceptOthers !== undefined && raw.acceptOthers !== null && typeof raw.acceptOthers !== "boolean") {
    throw new Error("backup.acceptOthers must be a boolean");
  }
  if (raw.uploadMbps !== undefined && raw.uploadMbps !== null && !isMbps(raw.uploadMbps)) {
    throw new Error("backup.uploadMbps must be a non-negative number (0: no limit)");
  }
  if (raw.s3 !== undefined && raw.s3 !== null) {
    if (!Array.isArray(raw.s3)) throw new Error("backup.s3 must be an array");
    const seen = new Set<string>();
    for (let i = 0; i < raw.s3.length; i++) {
      const t = normalizeS3Target(raw.s3[i], i);
      if (seen.has(t.id)) throw new Error(`backup.s3: duplicate target id ${t.id}`);
      seen.add(t.id);
    }
  }
}

/// Reads and normalizes `backup` from a raw config object (tolerating absent or partial fields safely).
export function readBackupConfig(rawConfig: unknown): NormalizedBackupConfig {
  const b = isObject(rawConfig) && isObject(rawConfig.backup) ? rawConfig.backup : null;
  if (b === null) return { mode: "auto", stations: [], acceptOthers: true, s3: [], uploadMbps: DEFAULT_UPLOAD_MBPS };
  const isManual = Array.isArray(b.stations);
  const stations = isManual
    ? [...new Set((b.stations as unknown[]).filter((s): s is string => typeof s === "string" && STATION.test(s)))]
    : [];
  const acceptOthers = b.acceptOthers !== false;
  const s3: NormalizedS3Target[] = [];
  if (Array.isArray(b.s3)) {
    const seen = new Set<string>();
    for (let i = 0; i < b.s3.length; i++) {
      try {
        const t = normalizeS3Target(b.s3[i], i);
        if (!seen.has(t.id)) {
          seen.add(t.id);
          s3.push(t);
        }
      } catch {
        // ignore malformed persisted entry rather than crashing reads
      }
    }
  }
  const uploadMbps = isMbps(b.uploadMbps) ? b.uploadMbps : DEFAULT_UPLOAD_MBPS;
  return { mode: isManual ? "manual" : "auto", stations, acceptOthers, s3, uploadMbps };
}

/// Applies a `PUT /copies/settings` payload onto the existing backup config.
/// Existing S3 entries whose `secretAccessKey` or `encryptionKey` is omitted/empty preserve their stored secret.
/// Newly created S3 entries with no `encryptionKey` get a CSPRNG 32-byte key returned once in `generatedKeys`.
export function applyBackupUpdate(
  existingRawConfig: unknown,
  input: unknown,
): { backup: BackupConfig; generatedKeys: Record<string, string> } {
  if (!isObject(input)) throw new Error("request body must be an object");
  const cur = readBackupConfig(existingRawConfig);
  const existingS3 = new Map(cur.s3.map((t) => [t.id, t]));

  let mode: "auto" | "manual" = cur.mode;
  let stations: string[] = cur.stations;
  if (input.mode !== undefined) {
    if (input.mode !== "auto" && input.mode !== "manual") throw new Error("mode must be \"auto\" or \"manual\"");
    mode = input.mode;
  }
  if (input.stations !== undefined) {
    if (!Array.isArray(input.stations)) throw new Error("stations must be an array of station ids");
    for (const s of input.stations) {
      if (typeof s !== "string" || !STATION.test(s)) throw new Error(`invalid station id: ${String(s)}`);
    }
    stations = [...new Set(input.stations as string[])];
    if (input.mode === undefined) mode = "manual";
  }

  let acceptOthers = cur.acceptOthers;
  if (input.acceptOthers !== undefined) {
    if (typeof input.acceptOthers !== "boolean") throw new Error("acceptOthers must be a boolean");
    acceptOthers = input.acceptOthers;
  }

  let uploadMbps = cur.uploadMbps ?? DEFAULT_UPLOAD_MBPS;
  if (input.uploadMbps !== undefined) {
    if (!isMbps(input.uploadMbps)) throw new Error("uploadMbps must be a non-negative number (0: no limit)");
    uploadMbps = input.uploadMbps;
  }

  const generatedKeys: Record<string, string> = {};
  let s3: S3TargetConfig[] = cur.s3;
  if (input.s3 !== undefined) {
    if (!Array.isArray(input.s3)) throw new Error("s3 must be an array");
    const nextS3: S3TargetConfig[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < input.s3.length; i++) {
      const item = input.s3[i];
      if (!isObject(item)) throw new Error(`s3[${i}] must be an object`);
      let id = typeof item.id === "string" ? item.id.trim() : "";
      if (id === "") {
        do {
          id = randomBytes(4).toString("hex");
        } while (seen.has(id) || existingS3.has(id));
      } else if (!S3_ID.test(id)) {
        throw new Error(`s3[${i}].id must match /^[a-z0-9_-]{1,32}$/`);
      }
      if (seen.has(id)) throw new Error(`duplicate s3 target id: ${id}`);
      seen.add(id);

      const prev = existingS3.get(id);
      const rawAccessKey = typeof item.accessKeyId === "string" ? item.accessKeyId.trim() : "";
      const accessKeyId = rawAccessKey !== "" ? rawAccessKey : (prev?.accessKeyId ?? "");

      const rawSecret = typeof item.secretAccessKey === "string" ? item.secretAccessKey : "";
      const secretAccessKey = rawSecret !== "" ? rawSecret : (prev?.secretAccessKey ?? "");

      const rawKey = typeof item.encryptionKey === "string" ? item.encryptionKey.trim() : "";
      let encryptionKey = rawKey !== "" ? rawKey : (prev?.encryptionKey ?? "");
      if (encryptionKey === "" && prev === undefined) {
        encryptionKey = randomBytes(32).toString("hex");
        generatedKeys[id] = encryptionKey;
      }

      const normalized = normalizeS3Target(
        {
          id,
          name: item.name,
          endpoint: item.endpoint,
          region: item.region,
          bucket: item.bucket,
          prefix: item.prefix,
          forcePathStyle: item.forcePathStyle,
          accessKeyId,
          secretAccessKey,
          encryptionKey,
          includeTranscripts: item.includeTranscripts,
        },
        i,
      );
      nextS3.push(normalized);
    }
    s3 = nextS3;
  }

  const backup: BackupConfig = {
    stations: mode === "manual" ? stations : "auto",
    acceptOthers,
    s3,
    ...(uploadMbps !== DEFAULT_UPLOAD_MBPS ? { uploadMbps } : {}),
  };
  return { backup, generatedKeys };
}

/// Builds the sanitized view for `overview.copies.backup` and `GET /copies/settings`.
export function buildBackupView(
  config: NormalizedBackupConfig,
  peers: BackupPeerView[],
  s3Status: (id: string) => S3TargetStatus,
): BackupView {
  return {
    mode: config.mode,
    stations: config.mode === "manual" ? [...config.stations] : [],
    acceptOthers: config.acceptOthers,
    peers,
    uploadMbps: config.uploadMbps ?? DEFAULT_UPLOAD_MBPS,
    s3: config.s3.map((t) => {
      const st = s3Status(t.id);
      return {
        id: t.id,
        name: t.name,
        endpoint: t.endpoint,
        region: t.region,
        bucket: t.bucket,
        prefix: t.prefix,
        forcePathStyle: t.forcePathStyle,
        accessKeyMask: maskValue(t.accessKeyId),
        keyFingerprint: keyFingerprint(t.encryptionKey),
        includeTranscripts: t.includeTranscripts,
        to: st.to,
        at: st.at,
        error: st.error,
        reason: st.reason,
      };
    }),
  };
}
