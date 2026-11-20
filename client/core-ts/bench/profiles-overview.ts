// The Profile overview's pools made in the engine the apps run (Hermes, no JIT): `profilesOverview`
// (views/profiles-overview.ts) of a workspace of 30 subscriptions, each with a week of hours kept (an allowance read each
// hour, its calls each hour), timed: the first made and then each again, made anew (`fresh`: none kept). Bundled as the core is and run by Hermes's own
// command: apps/mbui/scripts/core.sh profiles-overview.
import "../src/hosts/hermes-globals.ts";
import { profilesOverview } from "../src/views/profiles-overview.ts";

declare const print: (line: string) => void;

const H = 3_600_000;
const NOW = Date.UTC(2026, 10, 16, 6, 30);
const ACCOUNTS = 30;
const items: unknown[] = [];
const profiles: Record<string, unknown> = {};
for (let i = 0; i < ACCOUNTS; i++) {
  const id = `p${i}`;
  const week = (scope: string, used: number) => ({ label: scope ? `每周 · ${scope}` : "每周", usedPercent: used, resetsAt: NOW + (20 + i * 4) * H, minutes: 10_080, ...(scope ? { scope } : {}) });
  items.push({
    key: id, group: ["claude", "chatgpt", "agy"][i % 3], usable: true,
    profile: { id, planText: "Max 20x", quota: { state: "ok", windows: [{ label: "5 小时", usedPercent: 30, resetsAt: NOW + 2 * H, minutes: 300 }, week("", 40 + i), week("Fable", 20), week("Gemini", 20), week("Claude / GPT", 20)] } },
    members: [{ station: "ws/st", profileId: id }],
  });
  profiles[id] = {
    quotas: Array.from({ length: 168 }, (_, j) => ({ hour: Math.floor((NOW - (j + 1) * H) / H), at: NOW - (j + 1) * H, windows: [week("", Math.max(0, 40 + i - j * 0.3))] })),
    spend: Array.from({ length: 192 }, (_, j) => ({ hour: Math.floor(NOW / H) - j, scope: "", weight: 1 + (j % 5) })),
  };
}
const pace = { nowAt: NOW, profiles };
const once = () => profilesOverview(items, () => pace, NOW, 480, true);
let t0 = Date.now();
const made = once();
const first = Date.now() - t0;
t0 = Date.now();
const rounds = 10;
for (let r = 0; r < rounds; r++) once();
print(JSON.stringify({ accounts: ACCOUNTS, pools: made.pools.length, firstMs: first, againMs: Math.round(((Date.now() - t0) / rounds) * 10) / 10 }));
