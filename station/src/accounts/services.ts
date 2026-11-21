// Service profile adapters: non-agent-runtime accounts (e.g., compute pools) that share the profile lifecycle
// (config validation, health checks, quota reads, sign-in, single-holder migration) without binding to a coding-agent
// runtime. Passed explicitly via ServiceRegistry (no mutable global singleton).
import type { Env } from "../agents/machine-logins.ts";
import type { Lang } from "../ops/i18n.ts";
import type { Profile } from "../sessions/config.ts";
import type { LoginJob } from "./login.ts";
import type { ProfileCheck, ProfileQuota } from "./profiles.ts";

export interface ServiceProfileAdapter {
  readonly id: string;
  readonly name: string;
  capabilities(): readonly string[];
  signInFiles(): string[];
  shareRefusal(): string | null;
  identity(home: string): Promise<string | null>;
  check(profile: Profile, ctx: { env: Env; lang: Lang }): Promise<ProfileCheck>;
  quota(profile: Profile, ctx: { env: Env; lang: Lang }): Promise<ProfileQuota>;
  login?(profile: { id: string; home: string; email?: string | null }, ctx: { env: Env; lang: Lang }): Promise<LoginJob>;
}

export type ServiceRegistry = ReadonlyMap<string, ServiceProfileAdapter>;

export const DEFAULT_SERVICES: ServiceRegistry = new Map();

export function serviceOf(p: { access?: unknown; service?: unknown } | null | undefined): string | undefined {
  if (!p || typeof p !== "object") return undefined;
  const a = p.access;
  if (a && typeof a === "object" && !Array.isArray(a)) {
    const rec = a as Record<string, unknown>;
    if (rec.kind === "service" && typeof rec.service === "string" && rec.service !== "") return rec.service;
  }
  return undefined;
}

export function defaultServiceShareRefusal(service?: string): string {
  return service
    ? `a ${service} service account stays on its host station and cannot be shared with other stations`
    : "a service account stays on its host station and cannot be shared with other stations";
}
