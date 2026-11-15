// What the agents spent (usage.rs `price`, `cost`): a model's key and prices, and a session's spending now, as its live
// view and the context it is told show it. The usage page's reads (GET /usage, admin/views.rs `usage`) are the MoonBit
// reader's; the TypeScript that answered them is the tests' (test/reference/usage.ts).
import { type UsageGroup } from "./store.ts";
import { facts } from "../accounts/catalog.ts";
import type { ContextCall } from "../store/usage.ts";
import { key as modelKey, splitAgyTier } from "../../../client/core-ts/src/shapes/model.ts";

// ── prices (usage.rs) ──

/// A model's API prices, in dollars per million tokens. Writing to the cache costs 1.25× input for five minutes, 2× for
/// an hour; fast mode doubles all of it.
type Price = { input: number; output: number; cacheRead: number };

/// Standard short-context API list prices, for a model the model catalog (accounts/catalog.ts) has no price for, or
/// before it has said anything. Longer names first.
export const PRICES: [string, Price][] = [
  ["gpt-6-astra", { input: 10.0, output: 50.0, cacheRead: 1.0 }],
  ["gpt-6.1-sol", { input: 2.0, output: 10.0, cacheRead: 0.1 }],
  // OpenAI's standard API prices: https://developers.openai.com/api/docs/models/gpt-6.1-terra (2026-11-01).
  ["gpt-6.1-terra", { input: 1.0, output: 5.0, cacheRead: 0.05 }],
  ["gpt-6-sol", { input: 2.0, output: 10.0, cacheRead: 0.2 }],
  ["gpt-6-luna", { input: 0.1, output: 0.5, cacheRead: 0.01 }],
  ["gpt-5.6-sol", { input: 4.0, output: 20.0, cacheRead: 0.4 }],
  ["claude-fable-5-2", { input: 8.0, output: 40.0, cacheRead: 0.2 }],
  ["claude-fable-5-1", { input: 10.0, output: 50.0, cacheRead: 0.25 }],
  ["claude-mythos-5-1", { input: 10.0, output: 50.0, cacheRead: 0.25 }],
  ["claude-fable-5", { input: 10.0, output: 50.0, cacheRead: 1.0 }],
  ["claude-mythos-5", { input: 10.0, output: 50.0, cacheRead: 1.0 }],
  ["claude-opus-5-5", { input: 4.0, output: 20.0, cacheRead: 0.2 }],
  ["claude-opus-5", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-8", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-7", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-6", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-5", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-sonnet-5-5", { input: 2.0, output: 10.0, cacheRead: 0.1 }],
  ["claude-sonnet-5", { input: 2.0, output: 10.0, cacheRead: 0.2 }],
  ["claude-sonnet-4-6", { input: 3.0, output: 15.0, cacheRead: 0.3 }],
  ["claude-sonnet-4-5", { input: 3.0, output: 15.0, cacheRead: 0.3 }],
  ["claude-haiku-4-5", { input: 1.0, output: 5.0, cacheRead: 0.1 }],
];
export { modelKey, splitAgyTier };

/// price: a model's prices, however a profile spells it (anthropic/claude-opus-5-5, claude-opus-5-5[1m],
/// gemini-4-hydrogen-high): the model catalog's, else the station's own table's; none for a model without a list price
/// in either.
export function price(model: string): Price | null {
  const told = facts(model)?.cost;
  if (told !== undefined) return { input: told.input, output: told.output, cacheRead: told.cacheRead ?? told.input };
  const name = modelKey(model);
  const listed = (candidate: string) =>
    PRICES.find(([prefix]) => candidate === prefix || (candidate.startsWith(prefix) && candidate.slice(prefix.length).startsWith("[")))?.[1] ?? null;
  const direct = listed(name);
  if (direct !== null) return direct;
  const at = name.indexOf("[");
  const bare = at >= 0 ? name.slice(0, at) : name;
  const split = splitAgyTier(bare);
  return split === null ? null : listed(at >= 0 ? `${split.model}${name.slice(at)}` : split.model);
}

/// cost: what a day's calls of one model would cost at its API prices, in dollars (in the Rust's order of operations).
export function cost(g: UsageGroup): number | null {
  if (g.model === null) return null;
  const p = price(g.model);
  if (p === null) return null;
  const tokens = g.input * p.input + g.cacheWrite * p.input * 1.25 + g.cacheWriteLong * p.input * 2.0 + g.cacheRead * p.cacheRead + g.output * p.output;
  return (tokens / 1e6) * (g.fast ? 2.0 : 1.0);
}

/// A session's calls as counted, added up by model (store `usageOfSession`), put together for its execution details:
/// the tokens as a chat shows them (input with what was read from and written to the cache) and what they would cost,
/// those of a model without a price apart.
export function sessionUsage(groups: UsageGroup[]): Counted {
  const out = { modelCalls: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0, unpricedCalls: 0 };
  for (const g of groups) {
    out.modelCalls += g.calls;
    out.inputTokens += g.input + g.cacheRead + g.cacheWrite + g.cacheWriteLong;
    out.cachedTokens += g.cacheRead;
    out.outputTokens += g.output;
    const c = cost(g);
    if (c === null) out.unpricedCalls += g.calls;
    else out.cost += c;
  }
  return out;
}

/// A session's calls added up (`sessionUsage`).
export type Counted = { modelCalls: number; inputTokens: number; cachedTokens: number; outputTokens: number; cost: number; unpricedCalls: number };

/// What a session's calls used, as its chat shows it while it works and at rest (the clients' TranscriptUsage): its
/// calls as the usage counter recorded them, added up, with what they would cost (`sessionUsage`: the same count as the
/// usage page's), and of its last main-thread call the model, the context it left and the model's window, where told;
/// when it was made and how long what it left in the cache is kept there (`cacheMs`, where its runtime tells what it
/// wrote: Claude's), and what sending its context again once that is over would cost (`rereadCost`, dollars: all of it
/// written to the cache again, where its model has a price).
export type SessionUsage = Counted & {
  model: string | null; contextTokens?: number; contextWindow: number | null; lastCallAt?: number; cacheMs?: number; rereadCost?: number;
};

/// A session's usage before a call of it is recorded.
export const noUsage = (): SessionUsage => ({ modelCalls: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0, unpricedCalls: 0, model: null, contextWindow: null });

/// What usage reads of a session's calls (store.ts `usageOfSession`, `lastContexts`, `conversationSince`).
type SessionCalls = {
  usageOfSession(session: string): UsageGroup[];
  lastContexts(session: string, limit: number): ContextCall[];
  conversationSince(session: string): number | null;
  savedCompactContext?(session: string): { model: string | null; contextWindow: number | null; lastCallAt: number;
    contextTokens?: number; cacheMs?: number; rereadCost?: number } | null;
};

/// How long a prompt cache keeps what was written to it: five minutes, or an hour where it was asked to.
const CACHE_SHORT_MS = 5 * 60_000;
const CACHE_LONG_MS = 60 * 60_000;

/// The calls looked back on for what was last written to the cache (one may write nothing: all of it read).
const CACHE_CALLS = 5;

/// A session's usage now (SessionUsage), from what is recorded of its calls; none before one is. Where its context
/// stands (what it holds, when its cache is over, what reading it again costs) is of the conversation it goes on with
/// (store.ts `conversationSince`): none once its context is cleared, until that conversation's first call.
export function usageNow(s: SessionCalls, key: string): SessionUsage | null {
  const counted = sessionUsage(s.usageOfSession(key));
  if (counted.modelCalls === 0) return null;
  const all = s.lastContexts(key, CACHE_CALLS);
  const out: SessionUsage = { ...counted, model: all.at(-1)?.model ?? null, contextWindow: all.at(-1)?.window ?? null };
  const since = s.conversationSince(key);
  const calls = since === null ? [] : all.filter((c) => c.at >= since);
  const last = calls.at(-1);
  if (last !== undefined) {
    if (last.context !== null) out.contextTokens = last.context;
    out.lastCallAt = last.at;
    // A read keeps it for as long again as it was written for: as the latest write asked.
    const wrote = calls.findLast((c) => c.cacheWrite + c.cacheWriteLong > 0);
    if (wrote !== undefined) {
      const long = wrote.cacheWriteLong > 0;
      out.cacheMs = long ? CACHE_LONG_MS : CACHE_SHORT_MS;
      const p = last.model === null ? null : price(last.model);
      if (p !== null && last.context !== null) out.rereadCost = ((last.context * p.input * (long ? 2.0 : 1.25)) / 1e6) * (last.fast ? 2.0 : 1.0);
    }
  }
  const saved = s.savedCompactContext?.(key) ?? null;
  const latest = all.at(-1);
  if (saved !== null && since !== null && saved.lastCallAt >= since && (latest === undefined || saved.lastCallAt > latest.at)) {
    out.model = saved.model;
    out.contextWindow = saved.contextWindow;
    out.lastCallAt = saved.lastCallAt;
    for (const name of ["contextTokens", "cacheMs", "rereadCost"] as const) {
      if (saved[name] !== undefined) out[name] = saved[name];
      else delete out[name];
    }
  }
  return out;
}
