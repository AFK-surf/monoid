// Where the machine's traffic leaves for the internet (出口), as its agents' requests leave it: through the proxy
// config.json's `agentEnv` names where it names one (ops/agent-env.ts profileFetch), else straight. A model's service
// refusing a station by its country (agents/runtime.ts REFUSED) refuses it by this, so its page and card say it.
// Cloudflare's trace answers with the country it saw the request come from (`loc`) and the data centre it reached
// (`colo`); still.fail's cloud is not asked, since a station may reach it through an entry elsewhere (cloud/AGENTS.md)
// and it is not what the agents' requests go out by. Looked at as the station starts and every EVERY_MS after: there
// is no telling when a network or a proxy changes.
import { wall } from "../ops/fibers.ts";
import { profileFetch } from "../ops/agent-env.ts";

export type Egress = { country: string; colo: string | null };

export const TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace";
/// How often it is looked at again.
export const EVERY_MS = 30 * 60_000;
/// How long a look is given.
export const WAIT_MS = 10_000;

/// What a trace's answer says of where it came from: its country (two letters, `XX` and `T1` (Tor) not one) and the
/// data centre (three letters); none where it says no country.
export function egressOf(trace: string): Egress | null {
  const field = (name: string) => new RegExp(`^${name}=(.*)$`, "m").exec(trace)?.[1]?.trim() ?? "";
  const country = field("loc").toUpperCase();
  if (!/^[A-Z]{2}$/.test(country) || country === "XX" || country === "T1") return null;
  const colo = field("colo").toUpperCase();
  return { country, colo: /^[A-Z]{3}$/.test(colo) ? colo : null };
}

export class EgressLook {
  #seen: Egress | null = null;
  #looking = false;
  readonly #ask: () => Promise<string>;

  /// `ask`: the trace's answer as a string (in tests, made up).
  constructor(ask: () => Promise<string> = traceNow) {
    this.#ask = ask;
  }

  /// Where it was last seen leaving; none before it was, or when the last look found none.
  now(): Egress | null {
    return this.#seen;
  }

  /// Looks now, one look at a time; a look that fails keeps what was seen before it.
  async look(): Promise<void> {
    if (this.#looking) return;
    this.#looking = true;
    try {
      this.#seen = egressOf(await this.#ask());
    } catch {
      // Unreachable now (no network, a proxy down): what was seen stands until a look answers.
    } finally {
      this.#looking = false;
    }
  }

  /// Looks now and every EVERY_MS after, until the returned function is called.
  follow(): () => void {
    void this.look();
    return wall.every(EVERY_MS, () => void this.look()); // timer: an external system without push (Cloudflare's trace)
  }
}

/// The trace, asked as the agents' requests go out.
async function traceNow(): Promise<string> {
  const stop = new AbortController();
  const cancel = wall.after(WAIT_MS, () => stop.abort());
  try {
    const res = await profileFetch(TRACE_URL, { signal: stop.signal });
    if (!res.ok) throw new Error(`trace ${res.status}`);
    return await res.text();
  } finally {
    cancel();
  }
}
