// A subscription's GitHub credential stays at its host. Only the expiring Copilot API
// credential may cross the mesh. Its issuer chooses the account's regional API origin.
import { createHash } from "node:crypto";
import { profileFetch } from "../ops/agent-env.ts";

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

  async get(id: string, login: string, now: number, exchange = profileFetch): Promise<CopilotLease> {
    const identity = createHash("sha256").update(login).digest("hex");
    const previous = this.current.get(id);
    if (previous?.identity === identity) {
      const lease = await previous.lease;
      if (lease.expiresAt > now + 60_000) return lease;
      if (this.current.get(id) !== previous) return this.get(id, login, now, exchange);
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
