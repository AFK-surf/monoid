// Shared relay budget; kept apart from the Durable Object so tests can read it.
export const LIMITS = {
  // A guard for the one relay process's memory (a lite container), not a share of anything: what costs money is the
  // bytes, below. It was 160, sized for a few teams before every device's and station's endpoint was home on every
  // relay (#2580); on 2026-10-30 the budget refused every new connection from 12:22 in Beijing. Its packets wait in it
  // 200 ms at most (still.fail's iroh-relay), so an idle connection holds little; the relay's minute line in Cloud Logging says
  // how many are open, to raise this further or size the container by.
  connections: 2000,
  // Everyone on it back within a minute after it restarts (a deploy drops them all).
  connectsPerMinute: 3000,
  // Per-client rates and frame sizes are the relay process's own (relay-entrypoint.sh); these are all clients together.
  // At 5 GiB and 20M it ran out every day, on 2026-10-25 already at 19:00 in Beijing: everyone on it dropped and refused
  // until 08:00. 15 GiB a day, bytes sent only (Containers charge egress alone), is 483 GB in 30 days and 499 GB in 31,
  // inside what Containers include outside NA/EU (500 GB a month). Counted both ways it ran out on 2026-11-20 at 16:32
  // in Beijing with 4.92 GiB sent.
  bytesPerDay: 15 * 1024 * 1024 * 1024,
  // A guard against a flood of empty frames, not what costs: frames pass between Cloudflare's edge and the container
  // without waking a Worker or an object. Since the regional relays took the heavy traffic, the connections that stay
  // here send small control and keepalive frames (130 to 160 B each): at 60M it cut everyone off on 2026-11-17 at 7.44 GiB
  // and 2026-11-18 at 9.02 GiB, the bytes not two thirds spent. At 150M the bytes above decide a normal day.
  framesPerDay: 150_000_000,
};

/** Trace batches each sender may send a minute (tracing.ts): a client or station sends one every few seconds at most. */
export const TELEMETRY_BATCHES_PER_MINUTE = 60;
