// A subscription's GitHub credential stays at its host. Only the expiring Copilot API
// credential may cross the mesh. Its issuer chooses the account's regional API origin.
import { createHash } from "node:crypto";
import { profileFetch } from "../ops/agent-env.ts";

import { NoLink } from "../mesh/bus.ts";
import { PeerGone } from "../mesh/peer.ts";

export type CopilotLease = { token: string; expiresAt: number; api: string };

export function readCopilotLease(value: Partial<CopilotLease> | null, now: number): CopilotLease {
  const { token, expiresAt, api } = value ?? {};
  if (typeof token !== "string" || !token || typeof expiresAt !== "number" || !Number.isFinite(expiresAt) || expiresAt <= now ||
      typeof api !== "string" || !/^https:\/\/(?:[a-z0-9-]+\.)*githubcopilot\.com$/i.test(api)) {
    throw new Error("The host returned an invalid or expired Copilot API credential");
  }
  return { token, expiresAt, api };
}

export class CopilotLeases {
  private current = new Map<string, { identity: string; lease: Promise<CopilotLease> }>();

  async get(id: string, login: string, now: number, exchange = profileFetch, rejected?: string): Promise<CopilotLease> {
    const identity = createHash("sha256").update(login).digest("hex");
    const previous = this.current.get(id);
    if (previous?.identity === identity) {
      const lease = await previous.lease;
      if (lease.token !== rejected && lease.expiresAt > now + 60_000) return lease;
      if (this.current.get(id) !== previous) return this.get(id, login, now, exchange, rejected);
    }
    const lease = (async () => {
      const response = await exchange("https://api.github.com/copilot_internal/v2/token", {
        headers: { authorization: `Bearer ${login}`, accept: "application/json", "user-agent": "still.fail" },
        redirect: "manual", signal: AbortSignal.timeout(15_000),
      });
      if (!response.ok) throw new Error(`GitHub refused the Copilot credential exchange (HTTP ${response.status})`);
      const body = await response.json();
      return readCopilotLease({ token: body.token, expiresAt: body.expires_at * 1000, api: body.endpoints?.api }, now);
    })();
    this.current.set(id, { identity, lease });
    try { return await lease; } catch (error) {
      if (this.current.get(id)?.lease === lease) this.current.delete(id);
      throw error;
    }
  }
}

type BorrowedLease = {
  lease?: CopilotLease;
  pending?: Promise<CopilotLease>;
  rejected?: string;
};

/// Copilot access tokens have their own expiry. Keep them only in this station process.
export class BorrowedCopilotLeases {
  private entries = new Map<string, BorrowedLease>();

  forget(id: string) {
    this.entries.delete(id);
  }

  async get(id: string, now: () => number, ask: (rejected?: string) => Promise<CopilotLease>, rejected?: string): Promise<CopilotLease> {
    const entry = this.entries.get(id) ?? {};
    this.entries.set(id, entry);
    if (rejected && (entry.lease?.token === rejected || (!entry.lease && !entry.rejected))) {
      entry.rejected = rejected;
      delete entry.lease;
    }
    const kept = entry.lease;
    if (kept && kept.expiresAt - now() > 60_000) return kept;
    if (!entry.pending) {
      entry.pending = ask(entry.rejected).then((value) => {
        if (value.token === entry.rejected) throw new Error("The host returned the refused Copilot credential");
        entry.lease = value;
        delete entry.rejected;
        return value;
      }).catch((error) => {
        if (entry.lease && entry.lease.expiresAt > now() && (error instanceof NoLink || error instanceof PeerGone)) return entry.lease;
        delete entry.lease;
        throw error;
      }).finally(() => { delete entry.pending; });
    }
    const lease = await entry.pending;
    if (this.entries.get(id) !== entry || lease.token === entry.rejected || lease.expiresAt <= now()) {
      throw new Error("The borrowed Copilot credential is no longer available");
    }
    return lease;
  }
}
