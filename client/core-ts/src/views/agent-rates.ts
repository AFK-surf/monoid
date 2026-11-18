// The output happening now, across the workspace's connected stations. A session's rate already includes its
// concurrently writing subagents (station/sessions/live.ts); count the session once, never each of its chat threads.
import { t } from "../i18n.ts";
import { get, arr } from "../util.ts";
import { count } from "./usage.ts";

type Source = {
  address: string;
  name: string;
  value: unknown;
  named(key: string): { title: string | null; model: string | null; chat: string | null };
};

/// All rates go in the total; cap the detailed rows so an update remains small on a large workspace.
export const RATE_ROWS = 20;
export function agentRates(sources: Source[]) {
  const present = sources.filter((s) => get(s.value, "online") === true && get(s.value, "supported") === true);
  const offline = sources.filter((s) => get(s.value, "online") !== true).length;
  const unsupported = sources.filter((s) => get(s.value, "online") === true && get(s.value, "supported") !== true).length;
  const all = present.flatMap((s) => (arr(get(s.value, "items")) ?? []).flatMap((v) => {
    const key = get(v, "key");
    const rate = get(v, "rate");
    return typeof key === "string" && typeof rate === "number" && Number.isFinite(rate) && rate > 0 ? [{ source: s, key, rate }] : [];
  }));
  const order = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
  all.sort((a, b) => b.rate - a.rate || order(a.source.address, b.source.address) || order(a.key, b.key));
  const total = all.reduce((n, r) => n + r.rate, 0);
  const rows = all.slice(0, RATE_ROWS).map(({ source, key, rate }) => {
    const named = source.named(key);
    return {
      key: `${source.address}\n${key}`,
      title: named.title || t("core-views.rates.untitled"),
      sub: [source.name, named.model].filter(Boolean).join(" · "),
      rate: t("core-views.rates.value", { n: count(rate) }),
      station: source.address,
      chat: named.chat,
    };
  });
  return {
    title: t("core-views.rates.title"),
    total: present.length === 0 && sources.length > 0 ? "—" : t("core-views.rates.value", { n: count(total) }),
    status: present.length === 0 && sources.length > 0 ? t("core-views.rates.unavailable") :
      all.length > 0 ? t("core-views.rates.active", { n: all.length }) : t("core-views.rates.empty"),
    basis: t("core-views.rates.basis"),
    rows,
    more: all.length > RATE_ROWS ? t("core-views.rates.more", { n: all.length - RATE_ROWS }) : "",
    notes: [
      ...(offline > 0 ? [t("core-views.rates.offline", { n: offline })] : []),
      ...(unsupported > 0 ? [t("core-views.rates.unsupported", { n: unsupported })] : []),
    ],
  };
}
