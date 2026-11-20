// The admin's console: still.fail cloud's operator lists as its pages show them, so the page only
// draws. `adminList`: one list found, filtered and sorted, with how many each filter holds; `adminItem`: one user's,
// workspace's or bug report's page; `adminOverview`: the counts and what wants a look. Times stay in seconds.
import { CoreError } from "../error.ts";
import * as format from "../format.ts";
import { t } from "../i18n.ts";
import { branded } from "../../../i18n/brand.ts";
import * as brand from "../brand.ts";
import type { Topic } from "../protocol.ts";
import type { Value } from "../store.ts";
import { arr as arrU, compareKeys, get as getU, toJson } from "../util.ts";
import { relays } from "./admin-relays.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const arr = (v: unknown): J[] => arrU(v) ?? [];
const get = (v: unknown, k: string): J => getU(v, k);

const DAY = 86_400;
const LIMIT = 50;

/// The operator lists a view of `list` is built from.
export function sources(view: Topic): Topic[] {
  const of = (account: unknown, list: string): Topic => ({ topic: "admin", account, list });
  switch (view.topic) {
    case "adminList":
      return [of(view.account, view.list as string)];
    case "adminItem":
      if (view.list === "users") return [of(view.account, "users"), of(view.account, "workspaces"), of(view.account, "invite-codes")];
      // (a report whole, its logs too, read as its page shows: the list carries none)
      if (view.list === "feedback") return [of(view.account, "feedback"), of(view.account, `feedback/${encodeURIComponent(view.id as string)}`)];
      return [of(view.account, "workspaces"), of(view.account, "users")];
    case "adminOverview":
      return [of(view.account, "users"), of(view.account, "workspaces"), of(view.account, "invite-codes"), of(view.account, "feedback")];
    case "adminRelays":
      return [of(view.account, "relays")];
  }
  return [];
}

const strOf = (v: J, key: string): string => (typeof get(v, key) === "string" ? v[key] : "");
const num = (v: J, key: string): number | null => (typeof get(v, key) === "number" && v[key] > 0 ? v[key] : null);
const items = (v: J, key: string): J[] => arr(get(v, key));
const isObj = (v: J) => v !== null && typeof v === "object" && !Array.isArray(v);
const orNull = (v: J) => (v === undefined ? null : v);

function roleLabel(role: string): string {
  return role === "owner" ? t("core-views.admin.role.owner") : role === "admin" ? t("core-views.admin.role.admin") : t("core-views.admin.role.member");
}

function admissionLabel(admission: string): string {
  return ["admin", "code", "granted", "invitation", "early", "free"].includes(admission) ? t(`core-views.admin.admission.${admission}`) : t("core-views.admin.not_in");
}

const mark = (label: string, tone: string) => ({ label, tone });

/// A version's numbers, to compare (`0.1.1212` → [1212], a station's; `2.1.9` → [2, 1, 9]).
function versionKey(v: string): number[] {
  const out: number[] = [];
  for (const p of v.split(/[.\-+]/)) {
    if (!/^[0-9]+$/.test(p)) break;
    out.push(Number(p));
  }
  // A station's 0.<m>.<n>: by n, its build, alone (m, the stable releases before it, only said: the user, 2026-11-09).
  return out.length === 3 && out[0] === 0 ? [out[2]!] : out;
}

function compareVersions(a: number[], b: number[]): number {
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}

/// A workspace's machines: its stations and those that only run tasks (rigs; none from a cloud from before them).
const machinesOf = (w: J): J[] => [...items(w, "stations"), ...items(w, "rigs")];

/// Each machine once, of every workspace: one in several workspaces is one machine.
function machinesOnce(workspaces: J[]): J[] {
  const seen = new Set<string>();
  const out: J[] = [];
  for (const m of workspaces.flatMap(machinesOf)) {
    const id = strOf(m, "id");
    if (id !== "" && seen.has(id)) continue;
    if (id !== "") seen.add(id);
    out.push(m);
  }
  return out;
}

function newestVersion(workspaces: J[]): string | null {
  let best: string | null = null;
  for (const s of workspaces.flatMap(machinesOf)) {
    const v = get(s, "version");
    if (typeof v !== "string") continue;
    if (best === null || compareVersions(versionKey(v), versionKey(best)) >= 0) best = v;
  }
  return best;
}

function stationState(lastSeen: number | null, now: number): string {
  if (lastSeen === null) return "error";
  if (now - lastSeen < DAY) return "online";
  if (now - lastSeen < 7 * DAY) return "offline";
  return "busy";
}

function latestStation(w: J): number | null {
  let out: number | null = null;
  for (const s of machinesOf(w)) {
    const at = num(s, "last_seen");
    if (at !== null) out = out === null ? at : Math.max(out, at);
  }
  return out;
}

const found = (text: string, words: string[]) => words.every((w) => text.includes(w));

function codeState(c: J, now: number): [string, string] {
  if (num(c, "used_at") !== null || isObj(get(c, "used_by"))) return ["used", "neutral"];
  if (num(c, "revoked_at") !== null) return ["revoked", "red"];
  const exp = num(c, "expires_at");
  if (exp !== null && exp <= now) return ["expired", "amber"];
  return ["open", "green"];
}

function codeLabel(state: string): string {
  return ["used", "revoked", "expired"].includes(state) ? t(`core-views.admin.code.${state}`) : t("core-views.admin.code.open");
}

function keyState(k: J, now: number): [string, string] {
  if (num(k, "revoked_at") !== null) return ["revoked", "red"];
  const exp = num(k, "expires_at");
  if (exp !== null && exp <= now) return ["expired", "amber"];
  return ["active", "green"];
}

function keyLabel(state: string): string {
  return ["revoked", "expired"].includes(state) ? t(`core-views.admin.key.${state}`) : t("core-views.admin.key.active");
}

function feedbackStatus(status: string): [string, string] {
  switch (status) {
    case "triaged":
      return [t("core-views.admin.feedback.triaged"), "blue"];
    case "fixed":
      return [t("core-views.admin.feedback.fixed"), "green"];
    case "wontfix":
      return [t("core-views.admin.feedback.wontfix"), "neutral"];
    default:
      return [t("core-views.admin.feedback.new"), "amber"];
  }
}

const FEEDBACK_STATUSES = ["new", "triaged", "fixed", "wontfix"];

const channelLabel = (channel: string) => (channel === "beta" ? t("core-views.admin.channel.beta") : t("core-views.admin.channel.stable"));

function areaLabel(area: string): string {
  const fixed: Record<string, string> = { station: "Station", web: "Web", android: "Android", slack: "Slack", cloud: branded("still.fail cloud", brand.current()) };
  if (area in fixed) return fixed[area];
  return area === "desktop" ? t("core-views.admin.area.desktop") : t("core-views.admin.area.unsure");
}

const named = (v: J, key: string): J => (isObj(get(v, key)) ? v[key] : null);
const accountTitle = (a: J) => strOf(a, "name") || strOf(a, "email");

type Kind = { filters: [string, string, (v: J) => boolean][]; sorts: [string, string][] };

function userKind(now: number): Kind {
  const seen = (u: J) => num(u, "last_seen");
  // What an account did says nothing of an email nobody signed in with yet.
  const account = (keep: (u: J) => boolean) => (u: J) => !isPending(u) && keep(u);
  return {
    filters: [
      ["all", t("core-views.admin.filter.all"), () => true],
      ["active", t("core-views.admin.filter.active"), account((u) => {
        const at = seen(u);
        return at !== null && now - at < 7 * DAY;
      })],
      ["new", t("core-views.admin.filter.new_users"), account((u) => {
        const at = num(u, "created_at");
        return at !== null && now - at < 7 * DAY;
      })],
      ["stuck", t("core-views.admin.not_in"), account((u) => get(u, "admission") === undefined || u.admission === null)],
      ["dormant", t("core-views.admin.filter.dormant"), account((u) => {
        const at = seen(u);
        return at === null || now - at > 30 * DAY;
      })],
      ["creators", t("core-views.admin.filter.creators"), (u) => get(u, "may_create") === true],
      ["beta", channelLabel("beta"), (u) => get(u, "beta") === true],
      ["blocked", t("core-views.admin.blocked"), (u) => get(u, "blocked") === true],
      ["pending", t("core-views.admin.pending"), isPending],
    ],
    sorts: [["seen", t("core-views.admin.sort.seen")], ["created", t("core-views.admin.sort.first_sign_in")], ["workspaces", t("core-views.admin.sort.workspaces")], ["name", t("core-views.admin.sort.name")]],
  };
}

function workspaceKind(now: number, newest: string | null): Kind {
  return {
    filters: [
      ["all", t("core-views.admin.filter.all"), () => true],
      ["bare", t("core-views.admin.no_station"), (w) => machinesOf(w).length === 0],
      ["stale", t("core-views.admin.filter.stale"), (w) => {
        if (machinesOf(w).length === 0) return false;
        const at = latestStation(w);
        return at === null || now - at > 7 * DAY;
      }],
      ["outdated", t("core-views.admin.filter.outdated"), (w) => newest !== null && machinesOf(w).some((s) => typeof get(s, "version") === "string" && compareVersions(versionKey(s.version), versionKey(newest)) < 0)],
      ["invited", t("core-views.admin.filter.invited"), (w) => items(w, "invitations").length > 0],
      ["full", t("core-views.admin.filter.full"), (w) => typeof get(w, "seats") === "number" && w.seats >= 0 && items(w, "members").length >= w.seats],
    ],
    sorts: [["active", t("core-views.admin.sort.station_seen")], ["created", t("core-views.admin.sort.created")], ["members", t("core-views.admin.sort.members")], ["name", t("core-views.admin.sort.name")]],
  };
}

function codeKind(now: number): Kind {
  const is = (state: string) => (c: J) => codeState(c, now)[0] === state;
  return {
    filters: [["all", t("core-views.admin.filter.all"), () => true], ["open", codeLabel("open"), is("open")], ["used", codeLabel("used"), is("used")], ["expired", codeLabel("expired"), is("expired")], ["revoked", codeLabel("revoked"), is("revoked")]],
    sorts: [["created", t("core-views.admin.sort.generated")]],
  };
}

function keyKind(now: number): Kind {
  const is = (state: string) => (k: J) => keyState(k, now)[0] === state;
  return {
    filters: [["all", t("core-views.admin.filter.all"), () => true], ["active", keyLabel("active"), is("active")], ["expired", keyLabel("expired"), is("expired")], ["revoked", keyLabel("revoked"), is("revoked")]],
    sorts: [["created", t("core-views.admin.sort.generated")], ["used", t("core-views.admin.sort.last_used")]],
  };
}

/// Whether the last word on a report is its reporter's (their agent's, or a person's in the app): one to answer.
function repliedTo(f: J): boolean {
  const r = items(f, "replies");
  return r.length > 0 && strOf(r[r.length - 1], "from") === "reporter";
}

/// The areas a report can be about, in the order the console's 范围 lists them (cloud/src/types.ts FeedbackArea).
const AREAS = ["station", "desktop", "android", "web", "slack", "cloud", "unknown"];

function feedbackKind(): Kind {
  const is = (status: string) => (f: J) => strOf(f, "status") === status || (status === "new" && (get(f, "status") === undefined || f.status === null));
  return {
    filters: [
      ["all", t("core-views.admin.filter.all"), () => true],
      ["new", feedbackStatus("new")[0], is("new")],
      ["replied", t("core-views.admin.feedback.replied"), repliedTo],
      ["triaged", feedbackStatus("triaged")[0], is("triaged")],
      ["fixed", feedbackStatus("fixed")[0], is("fixed")],
      ["wontfix", feedbackStatus("wontfix")[0], is("wontfix")],
      ["beta", channelLabel("beta"), (f) => strOf(f, "channel") === "beta"],
      ["stable", channelLabel("stable"), (f) => strOf(f, "channel") !== "beta"],
    ],
    sorts: [["created", t("core-views.admin.sort.submitted")], ["updated", t("core-views.admin.sort.updated")]],
  };
}

const AUDIT_KINDS: [string, (action: string) => boolean][] = [
  ["users", (a) => a.startsWith("user.") || a.startsWith("pending.")],
  ["workspaces", (a) => a.startsWith("workspace.")],
  ["codes", (a) => a.startsWith("code.")],
  ["feedback", (a) => a.startsWith("feedback.")],
  ["relays", (a) => a.startsWith("relay.")],
  ["keys", (a) => a.startsWith("key.")],
];

function auditKind(): Kind {
  return {
    filters: [["all", t("core-views.admin.filter.all"), () => true], ...AUDIT_KINDS.map(([id, keep]): [string, string, (v: J) => boolean] => [id, t(`core-views.admin.audit.kind.${id}`), (v) => keep(strOf(v, "action"))])],
    sorts: [["created", t("core-views.admin.sort.time")]],
  };
}

/// An operator's change in words (`开通测试版`), by its action (cloud/src/api.ts `audited`); one not known as it is.
function auditAction(action: string, detail: string): string {
  const on = detail === "on";
  switch (action) {
    case "user.beta":
      return t(on ? "core-views.admin.audit.action.beta_on" : "core-views.admin.audit.action.beta_off");
    case "user.may_create":
      return t(on ? "core-views.admin.audit.action.may_create_on" : "core-views.admin.audit.action.may_create_off");
    case "user.block":
      return t(on ? "core-views.admin.audit.action.block_on" : "core-views.admin.audit.action.block_off");
    case "pending.set":
    case "pending.remove":
    case "workspace.create":
    case "workspace.limits":
    case "workspace.owners":
    case "workspace.added_remove":
    case "workspace.enroll":
    case "workspace.delete":
    case "code.create":
    case "code.revoke":
    case "feedback.status":
    case "feedback.reply":
    case "relay.put":
    case "relay.remove":
    case "relay.token":
    case "relay.token_revoke":
    case "key.create":
    case "key.revoke":
      return t(`core-views.admin.audit.action.${action.replace(".", "_")}`);
  }
  return action;
}

/// What an operator's change said besides, in words: a report's status by its label, limits given back said so.
function auditDetail(action: string, detail: string): string {
  if (action === "feedback.status") return feedbackStatus(detail)[0];
  if (action === "workspace.limits" && detail === "reset") return t("core-views.admin.audit.detail.reset");
  if (action === "workspace.limits") return detail.replace(/^members=/, t("core-views.admin.audit.detail.members"));
  if (["user.beta", "user.may_create", "user.block"].includes(action)) return "";
  // (what the cloud notes in its own words, `beta=on may_create=off`, `days=14 · beta`, said in the console's)
  if (action === "pending.set") {
    return detail.split(" ").filter(Boolean).map((part) => {
      const [k, v] = part.split("=");
      const on = v === "on";
      if (k === "beta") return on ? t("core-views.admin.audit.action.beta_on") : t("core-views.admin.audit.action.beta_off");
      if (k === "may_create") return on ? t("core-views.admin.audit.action.may_create_on") : t("core-views.admin.audit.action.may_create_off");
      return part;
    }).join(" · ");
  }
  if (action === "code.create") {
    return detail.split(" · ").map((part) => {
      const days = /^days=([0-9]+)$/.exec(part)?.[1];
      return days !== undefined ? t("core-views.admin.audit.detail.days", { n: Number(days) }) : part === "beta" ? channelLabel("beta") : part;
    }).join(" · ");
  }
  if (action === "key.create") {
    return detail.split(" · ").map((part) => {
      const days = /^days=([0-9]+)$/.exec(part)?.[1];
      return days !== undefined ? t("core-views.admin.audit.detail.days", { n: Number(days) }) : part === "never" ? t("core-views.admin.key.never_expires") : part;
    }).join(" · ");
  }
  return detail;
}

function haystack(list: string, v: J): string {
  let text: string;
  if (list === "users") text = `${strOf(v, "name")} ${strOf(v, "email")} ${strOf(v, "sub")}`;
  else if (list === "workspaces") {
    const c = get(v, "created_by");
    const creator = c !== undefined ? `${strOf(c, "name")} ${strOf(c, "email")}` : "";
    text = `${strOf(v, "name")} ${strOf(v, "id")} ${creator}`;
  } else if (list === "feedback") {
    const name = (key: string) => {
      const x = named(v, key);
      return x !== null ? `${strOf(x, "name")} ${strOf(x, "id")}` : "";
    };
    const a = named(v, "account");
    const account = a !== null ? `${strOf(a, "name")} ${strOf(a, "email")}` : "";
    const n = get(v, "number");
    const number = typeof n === "number" && Number.isInteger(n) && n >= 0 ? `fb-${n}` : "";
    const area = strOf(v, "area");
    text = `${number} ${strOf(v, "title")} ${strOf(v, "body")} ${strOf(v, "reporter")} ${name("station")} ${name("workspace")} ${account} ${area} ${areaLabel(area)} ${items(v, "replies").map((r) => strOf(r, "text")).join(" ")}`;
  } else if (list === "audit") {
    const action = strOf(v, "action");
    text = `${action} ${auditAction(action, strOf(v, "detail"))} ${strOf(v, "actor")} ${strOf(v, "target")} ${strOf(v, "detail")}`;
  } else if (list === "keys") {
    text = `${strOf(v, "name")} ${strOf(v, "prefix")} ${strOf(v, "created_by_email")} ${strOf(v, "id")}`;
  } else {
    const u = get(v, "used_by");
    const user = u !== undefined ? `${strOf(u, "name")} ${strOf(u, "email")}` : "";
    const w = get(v, "workspace");
    const workspace = w !== undefined ? strOf(w, "name") : "";
    text = `${strOf(v, "code")} ${strOf(v, "note")} ${user} ${workspace}`;
  }
  for (const [key, fields] of [["workspaces", ["name"]], ["members", ["name", "email"]], ["stations", ["name", "id"]], ["rigs", ["name", "id", "owner_name", "owner_email"]]] as [string, string[]][]) {
    for (const item of items(v, key)) for (const field of fields) text += ` ${strOf(item, field)}`;
  }
  return text.toLowerCase();
}

function order(list: string, sort: string, a: J, b: J): number {
  const desc = (x: number | null, y: number | null) => (y ?? 0) - (x ?? 0);
  const name = (v: J) => (strOf(v, "name") || strOf(v, "email")).toLowerCase();
  let o: number;
  if (sort === "created") o = desc(num(a, "created_at"), num(b, "created_at"));
  else if (sort === "updated") o = desc(num(a, "updated_at"), num(b, "updated_at"));
  else if (list === "keys" && sort === "used") o = desc(num(a, "last_used_at"), num(b, "last_used_at"));
  else if (list === "users" && sort === "workspaces") o = items(b, "workspaces").length - items(a, "workspaces").length;
  else if (list === "workspaces" && sort === "members") o = items(b, "members").length - items(a, "members").length;
  else if (list === "workspaces" && sort === "active") o = desc(latestStation(a), latestStation(b));
  else if (sort === "name") o = name(a) < name(b) ? -1 : name(a) > name(b) ? 1 : 0;
  else o = desc(num(a, "last_seen"), num(b, "last_seen"));
  return o !== 0 ? o : desc(num(a, "created_at"), num(b, "created_at"));
}

function feedbackRef(v: J): string {
  const n = get(v, "number");
  return typeof n === "number" && Number.isInteger(n) && n >= 0 ? `FB-${n}` : "";
}

function row(list: string, v: J, now: number): J {
  if (list === "users" && isPending(v)) {
    const email = strOf(v, "email");
    const marks = [mark(t("core-views.admin.pending"), "neutral")];
    if (get(v, "beta") === true) marks.push(mark(channelLabel("beta"), "accent"));
    return {
      id: pendingId(email),
      title: email,
      line: t("core-views.admin.pending.line", { rights: pendingRights(v).join(t("core-views.list_separator")) }),
      person: { name: "", email, picture: "" },
      marks,
      last_seen: null,
      created_at: orNull(get(v, "created_at")),
    };
  }
  if (list === "users") {
    const marks: J[] = [];
    if (get(v, "blocked") === true) marks.push(mark(t("core-views.admin.blocked"), "red"));
    const admission = get(v, "admission");
    if (typeof admission !== "string") marks.push(mark(t("core-views.admin.not_in"), "amber"));
    else if (admission === "admin") marks.push(mark(roleLabel("admin"), "accent"));
    if (get(v, "beta") === true) marks.push(mark(channelLabel("beta"), "accent"));
    const workspaces = items(v, "workspaces").map((w) => strOf(w, "name"));
    let line = strOf(v, "email");
    if (workspaces.length > 0) line = `${line} · ${workspaces.join(t("core-views.list_separator"))}`;
    const name = strOf(v, "name");
    return {
      id: strOf(v, "sub"),
      title: name || strOf(v, "email"),
      line,
      person: { name, email: strOf(v, "email"), picture: strOf(v, "picture") },
      marks,
      last_seen: orNull(get(v, "last_seen")),
      created_at: orNull(get(v, "created_at")),
    };
  }
  if (list === "workspaces") {
    const stations = machinesOf(v);
    const c = get(v, "created_by");
    const creator = isObj(c) ? strOf(c, "name") || strOf(c, "email") : t("core-views.admin.someone_gone");
    const marks: J[] = [];
    if (strOf(v, "plan") === "enterprise") marks.push(mark(t("core-views.admin.enterprise"), "accent"));
    if (stations.length === 0) marks.push(mark(t("core-views.admin.no_station"), "amber"));
    const latest = latestStation(v);
    return {
      id: strOf(v, "id"),
      title: strOf(v, "name"),
      line: [t("core-views.admin.created_by", { name: creator }), t("core-views.admin.people", { n: items(v, "members").length }), t("core-views.admin.stations", { n: stations.length })].join(" · "),
      marks,
      last_seen: latest,
      state: stations.length > 0 ? stationState(latest, now) : null,
      created_at: orNull(get(v, "created_at")),
    };
  }
  if (list === "feedback") {
    const [label, tone] = feedbackStatus(strOf(v, "status"));
    const marks = [mark(label, tone)];
    const replies = items(v, "replies");
    // Only what is off is marked: one the reporter answered last; how many replies it has is said on its second line.
    if (repliedTo(v)) marks.push(mark(t("core-views.admin.feedback.replied"), "amber"));
    if (strOf(v, "channel") === "beta") marks.push(mark(channelLabel("beta"), "accent"));
    const line = [areaLabel(strOf(v, "area"))];
    const w = named(v, "workspace");
    if (w !== null && strOf(w, "name") !== "") line.push(strOf(w, "name"));
    const s = named(v, "station");
    if (s !== null && strOf(s, "name") !== "") line.push(strOf(s, "name"));
    const by = strOf(v, "reporter");
    if (by === "") {
      const a = named(v, "account");
      if (a !== null) line.push(accountTitle(a));
    } else line.push(by);
    if (replies.length > 0 && !repliedTo(v)) line.push(t("core-views.admin.feedback.reply_count", { n: replies.length }));
    return { id: strOf(v, "id"), number: feedbackRef(v), title: strOf(v, "title"), line: line.join(" · "), state: strOf(v, "status"), marks, created_at: orNull(get(v, "created_at")), updated_at: orNull(get(v, "updated_at")) };
  }
  if (list === "audit") {
    const action = strOf(v, "action");
    const detail = auditDetail(action, strOf(v, "detail"));
    const target = strOf(v, "target");
    const kind = AUDIT_KINDS.find(([, keep]) => keep(action))?.[0] ?? "";
    return {
      id: strOf(v, "id"),
      title: target === "" ? auditAction(action, strOf(v, "detail")) : `${auditAction(action, strOf(v, "detail"))} · ${target}`,
      line: detail === "" ? strOf(v, "actor") : `${strOf(v, "actor")} · ${detail}`,
      state: kind,
      marks: [],
      created_at: orNull(get(v, "created_at")),
    };
  }
  if (list === "keys") {
    const [state, tone] = keyState(v, now);
    const parts: string[] = [];
    const by = strOf(v, "created_by_email");
    if (by !== "") parts.push(by);
    if (num(v, "last_used_at") === null) parts.push(t("core-views.admin.key.never_used"));
    if (num(v, "expires_at") === null) parts.push(t("core-views.admin.key.never_expires"));
    return {
      id: strOf(v, "id"),
      title: strOf(v, "name"),
      prefix: strOf(v, "prefix"),
      line: parts.join(" · "),
      state,
      marks: [mark(keyLabel(state), tone)],
      created_at: orNull(get(v, "created_at")),
      last_used_at: orNull(get(v, "last_used_at")),
      expires_at: orNull(get(v, "expires_at")),
      revoked_at: orNull(get(v, "revoked_at")),
    };
  }
  const [state, tone] = codeState(v, now);
  const user = isObj(get(v, "used_by")) ? v.used_by : null;
  let line: string;
  if (state === "used" && user !== null) {
    const name = strOf(user, "name") || strOf(user, "email");
    const w = get(v, "workspace");
    line = isObj(w) ? t("core-views.admin.code.made", { name, workspace: strOf(w, "name") }) : t("core-views.admin.code.made_deleted", { name });
  } else if (state === "used") line = t("core-views.admin.code.used_by_gone");
  else line = strOf(v, "note");
  return {
    id: strOf(v, "code"),
    title: strOf(v, "code"),
    note: strOf(v, "note"),
    line,
    state,
    marks: get(v, "beta") === true ? [mark(codeLabel(state), tone), mark(channelLabel("beta"), "accent")] : [mark(codeLabel(state), tone)],
    url: orNull(get(v, "url")),
    // (each product's sign-up link, where the cloud answers as two: cloud/src/api.ts inviteLinks)
    ...(Array.isArray(get(v, "links")) ? { links: items(v, "links").filter((l) => strOf(l, "url") !== "").map((l) => ({ product: strOf(l, "product"), url: strOf(l, "url") })) } : {}),
    user: user !== null ? strOf(user, "sub") : null,
    created_at: orNull(get(v, "created_at")),
    expires_at: orNull(get(v, "expires_at")),
    used_at: orNull(get(v, "used_at")),
    revoked_at: orNull(get(v, "revoked_at")),
  };
}

function rowsOf(list: string, value: J): J[] {
  const key = list === "users" ? "users" : list === "workspaces" ? "workspaces" : list === "feedback" ? "feedback" : list === "audit" ? "audit" : list === "keys" ? "keys" : "codes";
  return items(value, key);
}

// Emails the admin gave rights to before anyone signed in with them (`pending` beside `users`; none from a cloud from
// before it): listed with the users, each as `email:<address>` (no account's id has a colon), added when first seen.
const PENDING = "email:";
const pendingId = (email: string) => `${PENDING}${email}`;
const isPending = (v: J) => get(v, "pending") === true;

function pendingOf(users: J): J[] {
  return items(users, "pending").filter((p) => strOf(p, "email") !== "").map((p) => ({
    pending: true, email: strOf(p, "email"), beta: get(p, "beta") === true, may_create: get(p, "may_create") === true, created_at: orNull(get(p, "added_at")),
  }));
}

function pendingRights(v: J): string[] {
  const rights: string[] = [];
  if (get(v, "beta") === true) rights.push(channelLabel("beta"));
  if (get(v, "may_create") === true) rights.push(t("core-views.admin.pending.standard"));
  return rights.length > 0 ? rights : [t("core-views.admin.pending.nothing")];
}

/// One list found by `query`, in `filter`, by `sort`: its first `limit` rows, and how many each filter holds.
export function list(name: string, value: J, query: string, filter: string | null, sort: string | null, limit: number | null, now: number): J {
  const all = name === "users" ? [...rowsOf(name, value), ...pendingOf(value)] : rowsOf(name, value);
  let kind: Kind;
  if (name === "users") kind = userKind(now);
  else if (name === "workspaces") kind = workspaceKind(now, newestVersion(all));
  else if (name === "invite-codes") kind = codeKind(now);
  else if (name === "feedback") kind = feedbackKind();
  else if (name === "audit") kind = auditKind();
  else if (name === "keys") kind = keyKind(now);
  else throw CoreError.invalid(t("core-views.admin.error.no_list"));
  const words = format.splitWhitespace(query.toLowerCase());
  const searched = all.filter((v) => words.length === 0 || found(haystack(name, v), words));
  // A report's list is narrowed by its area too, said after its tab (`new@android`): the topic's own filter, no other.
  const [tab, area] = name === "feedback" && filter !== null && filter.includes("@") ? [filter.slice(0, filter.indexOf("@")), filter.slice(filter.indexOf("@") + 1)] : [filter, null];
  const matched = area ? searched.filter((v) => strOf(v, "area") === area) : searched;
  const f = kind.filters.find((x) => x[0] === tab) ?? kind.filters[0];
  const s = (kind.sorts.find((x) => x[0] === sort) ?? kind.sorts[0])[0];
  const shown = matched.filter((v) => f[2](v)).sort((a, b) => order(name, s, a, b));
  const max = Math.max(limit ?? LIMIT, 1);
  return {
    total: all.length,
    found: shown.length,
    filter: f[0],
    filters: kind.filters.map(([id, label, keep]) => ({ id, label, count: matched.filter((v) => keep(v)).length })),
    sort: s,
    sorts: kind.sorts.map(([id, label]) => ({ id, label })),
    ...(name === "feedback" ? {
      area: area ?? "",
      areas: [{ id: "", label: t("core-views.admin.area.all"), count: searched.length }, ...AREAS.map((id) => ({ id, label: areaLabel(id), count: searched.filter((v) => strOf(v, "area") === id).length }))],
    } : {}),
    rows: shown.slice(0, max).map((v) => row(name, v, now)),
    more: shown.length > max,
  };
}

/// A user's page.
export function user(id: string, users: J, workspaces: J, codes: J, now: number): J {
  if (id.startsWith(PENDING)) return pending(id, users);
  const u = rowsOf("users", users).find((x) => strOf(x, "sub") === id);
  if (u === undefined) throw new CoreError("http_404", t("core-views.admin.error.no_user"), 404);
  const byId = new Map(rowsOf("workspaces", workspaces).map((w) => [strOf(w, "id"), w] as [string, J]));
  const theirs = items(u, "workspaces").map((m) => {
    const w = byId.get(strOf(m, "id"));
    const stations = w !== undefined ? items(w, "stations").length : 0;
    const people = w !== undefined ? items(w, "members").length : 0;
    return {
      id: strOf(m, "id"),
      name: strOf(m, "name"),
      role: roleLabel(strOf(m, "role")),
      line: [roleLabel(strOf(m, "role")), t("core-views.admin.people", { n: people }), t("core-views.admin.stations", { n: stations })].join(" · "),
    };
  });
  const admission = typeof get(u, "admission") === "string" ? (u.admission as string) : null;
  const usedCode = codes !== undefined && codes !== null ? rowsOf("invite-codes", codes).find((c) => isObj(get(c, "used_by")) && strOf(c.used_by, "sub") === id) : undefined;
  const mayCreate = typeof get(u, "may_create") === "boolean" ? u.may_create : null;
  const creator = get(u, "creator") === true;
  const name = strOf(u, "name");
  const seen = num(u, "last_seen");
  return {
    id,
    title: name || strOf(u, "email"),
    person: { name, email: strOf(u, "email"), picture: strOf(u, "picture") },
    email: strOf(u, "email"),
    admin: admission === "admin",
    admission: admissionLabel(admission ?? ""),
    code: usedCode !== undefined ? strOf(usedCode, "code") : null,
    created_at: orNull(get(u, "created_at")),
    last_seen: orNull(get(u, "last_seen")),
    mayCreate,
    mayCreateHint:
      admission === "admin"
        ? t("core-views.admin.may_create.admin")
        : creator
          ? t("core-views.admin.may_create.creator")
          : mayCreate === true
            ? t("core-views.admin.may_create.yes")
            : t("core-views.admin.may_create.no"),
    mayCreateFixed: admission === "admin" || creator,
    beta: typeof get(u, "beta") === "boolean" ? u.beta : null,
    blocked: typeof get(u, "blocked") === "boolean" ? u.blocked : null,
    workspaces: theirs,
    seen: seen !== null ? now - seen : null,
  };
}

/// An email's page, given rights before anyone signed in with it: what it has, as an account's page says it.
function pending(id: string, users: J): J {
  const p = pendingOf(users).find((x) => pendingId(x.email) === id);
  if (p === undefined) throw new CoreError("http_404", t("core-views.admin.error.no_user"), 404);
  return {
    id,
    pending: true,
    title: p.email,
    person: { name: "", email: p.email, picture: "" },
    email: p.email,
    admin: false,
    admission: t("core-views.admin.pending"),
    code: null,
    created_at: p.created_at,
    last_seen: null,
    mayCreate: p.may_create,
    mayCreateHint: p.may_create ? t("core-views.admin.may_create.yes") : t("core-views.admin.may_create.no"),
    mayCreateFixed: false,
    beta: p.beta,
    blocked: null,
    workspaces: [],
    seen: null,
  };
}

/// A workspace's page.
export function workspace(id: string, workspaces: J, users: J, now: number): J {
  const all = rowsOf("workspaces", workspaces);
  const newest = newestVersion(all);
  const w = all.find((x) => strOf(x, "id") === id);
  if (w === undefined) throw new CoreError("http_404", t("core-views.admin.error.no_workspace"), 404);
  const seen = new Map<string, J>(users !== undefined && users !== null ? rowsOf("users", users).map((u) => [strOf(u, "sub"), orNull(get(u, "last_seen"))] as [string, J]) : []);
  const members = items(w, "members").map((m) => {
    const sub = strOf(m, "sub");
    const name = strOf(m, "name");
    const own = get(m, "last_seen");
    return {
      id: sub,
      title: name || strOf(m, "email"),
      person: { name, email: strOf(m, "email"), picture: strOf(m, "picture") },
      role: roleLabel(strOf(m, "role")),
      last_seen: own !== undefined && own !== null ? own : (seen.get(sub) ?? null),
    };
  });
  const versionOf = (s: J) => (typeof get(s, "version") === "string" ? (s.version as string) : null);
  const outdatedOf = (version: string | null) => version !== null && newest !== null && compareVersions(versionKey(version), versionKey(newest)) < 0;
  const stations = items(w, "stations").map((s) => {
    const version = versionOf(s);
    return {
      id: strOf(s, "id"),
      name: strOf(s, "name"),
      version,
      outdated: outdatedOf(version),
      state: stationState(num(s, "last_seen"), now),
      last_seen: orNull(get(s, "last_seen")),
    };
  });
  // Those that only run tasks, each its member's (a cloud from before them says none).
  const rigs = items(w, "rigs").map((r) => {
    const version = versionOf(r);
    return {
      id: strOf(r, "id"),
      name: strOf(r, "name"),
      owner: strOf(r, "owner"),
      ownerTitle: strOf(r, "owner_name") || strOf(r, "owner_email"),
      version,
      outdated: outdatedOf(version),
      state: stationState(num(r, "last_seen"), now),
      last_seen: orNull(get(r, "last_seen")),
    };
  });
  const invitations = items(w, "invitations").map((i) => {
    const by = strOf(i, "inviter");
    return {
      id: strOf(i, "id"),
      email: typeof get(i, "email") === "string" ? i.email : t("core-views.admin.invitation.anyone"),
      line: `${roleLabel(strOf(i, "role"))}${by === "" ? "" : ` · ${t("core-views.admin.invitation.by", { name: by })}`}`,
      expires_at: orNull(get(i, "expires_at")),
    };
  });
  // Emails added that have not signed in yet: a company's owners, before they first do.
  const added = items(w, "added").map((a) => ({
    id: strOf(a, "email"),
    email: strOf(a, "email"),
    line: t("core-views.admin.added.line", { role: roleLabel(strOf(a, "role")) }),
    added_at: orNull(get(a, "added_at")),
  }));
  const c = isObj(get(w, "created_by")) ? w.created_by : null;
  const whole = (v: J): v is number => typeof v === "number" && Number.isInteger(v) && v >= 0;
  const seats = get(w, "seats");
  const stationSeats = get(w, "station_seats");
  const plan = strOf(w, "plan");
  return {
    id,
    title: strOf(w, "name"),
    creator: c !== null ? { id: strOf(c, "sub"), title: strOf(c, "name") || strOf(c, "email") } : null,
    created_at: orNull(get(w, "created_at")),
    // Those added count as the cloud counts them: each holds a seat.
    people: whole(seats) ? `${members.length + added.length} / ${seats}` : String(members.length),
    // (a rig holds a station's place: the cloud's cap counts both)
    stationCount: whole(stationSeats) ? `${stations.length + rigs.length} / ${stationSeats}` : String(stations.length + rigs.length),
    plan: planLabel(plan),
    // Limits of its own (made for a company): they can be given back to its creator's plan.
    customLimits: plan === "enterprise",
    // What the limits form starts from: an older cloud gives neither station_seats nor stations_unlimited.
    limits: whole(seats) && (whole(stationSeats) || get(w, "stations_unlimited") === true) ? { members: seats, stations: whole(stationSeats) ? stationSeats : null } : null,
    // The admin puts a station in only before the company's owners are in (directory.ts adminEnrollment).
    enrollable: get(w, "enrollable") === true,
    members,
    added,
    stations,
    rigs,
    invitations,
  };
}

/// A workspace's plan in words: its own limits (enterprise), or its creator's; none from a cloud from before plans.
function planLabel(plan: string): string | null {
  switch (plan) {
    case "enterprise":
      return t("core-views.admin.enterprise");
    case "admin":
      return t("core-views.admin.plan.admin");
    case "standard":
      return t("core-views.admin.plan.standard");
    case "free":
      return t("core-views.admin.plan.free");
  }
  return null;
}

const contextText = (v: J) => (typeof v === "string" ? v : toJson(v));

/// A bug report's page, and the whole of it as plain text to hand to an agent. `logsLoading`: of the list's (which
/// carries no logs), its own read with them still to come.
export function feedback(id: string, value: J, logsLoading = false): J {
  const f = rowsOf("feedback", value).find((x) => strOf(x, "id") === id);
  if (f === undefined) throw new CoreError("http_404", t("core-views.admin.error.no_feedback"), 404);
  const status = strOf(f, "status") || "new";
  const raw = get(f, "context");
  let context: [string, string][];
  if (isObj(raw)) context = Object.keys(raw).sort(compareKeys).filter((k) => raw[k] !== null).map((k) => [k, contextText(raw[k])]);
  else if (raw === null || raw === undefined) context = [];
  else context = [["context", contextText(raw)]];
  const logsRaw = get(f, "logs");
  const logs = typeof logsRaw === "string" && logsRaw.trim() !== "" ? logsRaw : null;
  const station = named(f, "station");
  const ws = named(f, "workspace");
  const account = named(f, "account");
  const place = (x: J) => (x === null ? null : strOf(x, "name") === "" ? strOf(x, "id") : `${strOf(x, "name")} (${strOf(x, "id")})`);
  const number = feedbackRef(f);
  let text = `${number} ${strOf(f, "title")}\n\n`;
  const fact = (label: string, v: string | null) => {
    if (v !== null && v !== "") text += `${label}: ${v}\n`;
  };
  const fixedIn = typeof get(f, "fixed_in") === "number" ? f.fixed_in : null;
  const told = get(f, "told_at") !== undefined && f.told_at !== null;
  const state = fixedIn !== null && status === "fixed" ? `${feedbackStatus(status)[0]} · 0.1.${fixedIn}${told ? ` · ${t("core-views.admin.feedback.told")}` : ""}` : feedbackStatus(status)[0];
  fact(t("core-views.admin.feedback.fact.status"), state);
  fact(t("core-views.admin.feedback.fact.channel"), `${channelLabel(strOf(f, "channel"))} (${strOf(f, "channel")})`);
  fact(t("core-views.admin.feedback.fact.area"), areaLabel(strOf(f, "area")));
  fact("Workspace", place(ws));
  fact("Station", place(station));
  fact(t("core-views.admin.feedback.fact.reporter"), strOf(f, "reporter"));
  fact(t("core-views.admin.feedback.fact.account"), account !== null ? (strOf(account, "name") === "" ? strOf(account, "email") : `${strOf(account, "name")} <${strOf(account, "email")}>`) : null);
  fact("ID", id);
  text += `\n## ${t("core-views.admin.feedback.body")}\n\n${strOf(f, "body").trimEnd()}\n`;
  if (context.length > 0) {
    text += `\n## ${t("core-views.admin.feedback.context")}\n\n`;
    for (const [k, v] of context) text += `${k}: ${v}\n`;
  }
  if (logs !== null) text += `\n## ${t("core-views.admin.feedback.logs")}\n\n\`\`\`\n${logs.trimEnd()}\n\`\`\`\n`;
  const replies = items(f, "replies").map((r) => {
    const team = strOf(r, "from") !== "reporter";
    const by = strOf(r, "by");
    const delivery = !team ? null : strOf(r, "delivery") === "delivered" ? "delivered" : "pending";
    return {
      id: strOf(r, "id"),
      from: team ? "team" : "reporter",
      authorLabel: team ? (by === "feedback-monitor" ? t("core-views.admin.feedback.monitor") : by || t("core-views.admin.feedback.team")) : t("core-views.admin.feedback.reporter_side"),
      delivery,
      deliveryLabel: delivery === null ? null : t(`core-views.admin.feedback.delivery.${delivery}`),
      text: strOf(r, "text"),
      created_at: orNull(get(r, "created_at")),
      delivered_at: orNull(get(r, "delivered_at")),
    };
  });
  if (replies.length > 0) {
    text += `\n## ${t("core-views.admin.feedback.replies")}\n\n`;
    for (const r of replies) text += `${r.authorLabel}: ${r.text}\n`;
  }
  // The team's reply goes to the chat it came from: a station's, which said its session (cloud/src/directory.ts replyToFeedback).
  const canReply = station !== null && isObj(raw) && typeof raw.session === "string" && raw.session !== "";
  return {
    id,
    number,
    title: strOf(f, "title"),
    body: strOf(f, "body"),
    status,
    statuses: FEEDBACK_STATUSES.map((s) => ({ id: s, label: feedbackStatus(s)[0] })),
    marks: [mark(state, feedbackStatus(status)[1])],
    channel: strOf(f, "channel"),
    channelLabel: channelLabel(strOf(f, "channel")),
    area: areaLabel(strOf(f, "area")),
    reporter: strOf(f, "reporter"),
    station: station !== null ? { id: strOf(station, "id"), name: strOf(station, "name") } : null,
    workspace: ws !== null ? { id: strOf(ws, "id"), title: strOf(ws, "name") || strOf(ws, "id") } : null,
    account: account !== null ? { id: strOf(account, "sub"), title: accountTitle(account) } : null,
    context: context.map(([key, v]) => ({ key, value: v })),
    logs,
    logsLoading,
    replies,
    canReply,
    replyHint: canReply ? t("core-views.admin.feedback.reply_hint") : t(station === null ? "core-views.admin.feedback.no_reply_account" : "core-views.admin.feedback.no_reply_session"),
    created_at: orNull(get(f, "created_at")),
    updated_at: orNull(get(f, "updated_at")),
    text,
  };
}

/// The console's first page: counts, new people by week, and what wants a look.
export function overview(usersV: J, workspacesV: J, codesV: J, feedbackV: J, now: number, offsetMin: number): J {
  const users = rowsOf("users", usersV);
  const workspaces = rowsOf("workspaces", workspacesV);
  const codes = rowsOf("invite-codes", codesV);
  const within = (v: J, key: string, days: number) => {
    const at = num(v, key);
    return at !== null && now - at < days * DAY;
  };
  const count = (list: J[], keep: (v: J) => boolean) => list.filter(keep).length;
  const active = count(users, (u) => within(u, "last_seen", 7));
  // (a machine in several workspaces is one: it is counted once)
  const stations = machinesOnce(workspaces);
  const newest = newestVersion(workspaces);
  const outdated = stations.filter((s) => typeof get(s, "version") === "string" && newest !== null && compareVersions(versionKey(s.version), versionKey(newest)) < 0).length;
  const stale = stations.filter((s) => {
    const at = num(s, "last_seen");
    return at === null || now - at > 7 * DAY;
  }).length;
  const weeks: J[] = [];
  for (let ago = 11; ago >= 0; ago--) {
    const end = now - ago * 7 * DAY;
    const start = end - 7 * DAY;
    const n = users.filter((u) => {
      const at = num(u, "created_at");
      return at !== null && at > start && at <= end;
    }).length;
    weeks.push({ count: n, label: ago === 0 ? t("core-views.admin.overview.this_week") : format.dayLabel(start * 1000, now * 1000, offsetMin) });
  }
  const stuck = count(users, (u) => get(u, "admission") === undefined || u.admission === null);
  const bare = count(workspaces, (w) => machinesOf(w).length === 0);
  const expiring = count(codes, (c) => {
    const at = num(c, "expires_at");
    return codeState(c, now)[0] === "open" && at !== null && at - now < 3 * DAY;
  });
  const todo: J[] = [];
  const want = (n: number, text: string, hint: string, tone: string, list: string, filter: string) => {
    if (n > 0) todo.push({ text, hint, tone, list, filter });
  };
  const reports = feedbackV !== undefined && feedbackV !== null ? rowsOf("feedback", feedbackV) : [];
  const fresh = count(reports, (f) => get(f, "status") === "new" || get(f, "status") === undefined || f.status === null);
  want(fresh, t("core-views.admin.todo.fresh", { n: fresh }), t("core-views.admin.todo.fresh_hint"), "amber", "feedback", "new");
  const replied = count(reports, repliedTo);
  want(replied, t("core-views.admin.todo.replied", { n: replied }), t("core-views.admin.todo.replied_hint"), "amber", "feedback", "replied");
  want(stuck, t("core-views.admin.todo.stuck", { n: stuck }), t("core-views.admin.todo.stuck_hint"), "amber", "users", "stuck");
  want(bare, t("core-views.admin.todo.bare", { n: bare }), t("core-views.admin.todo.bare_hint"), "amber", "workspaces", "bare");
  want(stale, t("core-views.admin.todo.stale", { n: stale }), t("core-views.admin.todo.stale_hint"), "neutral", "workspaces", "stale");
  want(outdated, t("core-views.admin.todo.outdated", { n: outdated }), newest !== null ? t("core-views.admin.todo.outdated_hint", { version: newest }) : "", "neutral", "workspaces", "outdated");
  want(expiring, t("core-views.admin.todo.expiring", { n: expiring }), t("core-views.admin.todo.expiring_hint"), "neutral", "invite-codes", "open");
  const pct = users.length === 0 ? 0 : Math.trunc((active * 100) / users.length);
  const usedWs = count(workspaces, (w) => {
    const at = latestStation(w);
    return at !== null && now - at < 7 * DAY;
  });
  const today = stations.filter((s) => {
    const at = num(s, "last_seen");
    return at !== null && now - at < DAY;
  }).length;
  return {
    stats: [
      { label: t("core-views.admin.stat.users"), value: users.length, note: t("core-views.admin.stat.users_note", { n: count(users, (u) => within(u, "created_at", 7)) }), list: "users", filter: "all" },
      { label: t("core-views.admin.stat.active"), value: active, note: t("core-views.admin.stat.active_note", { percent: pct }), list: "users", filter: "active" },
      { label: "Workspace", value: workspaces.length, note: t("core-views.admin.stat.workspaces_note", { n: usedWs }), list: "workspaces", filter: "all" },
      { label: "Station", value: stations.length, note: t("core-views.admin.stat.stations_note", { n: today }), list: "workspaces", filter: "all" },
    ],
    weeks,
    todo,
  };
}

/// The console's views, from the operator lists they rest on; an error of one is theirs.
export function admin(view: Topic, read: (account: string, list: string) => Value | undefined, nowMs: number, offsetMin: number): Value | undefined {
  const now = nowMs / 1000;
  const account = view.account as string;
  const attempt = (f: () => J): Value => {
    try {
      return { ok: f() };
    } catch (e) {
      if (!(e instanceof CoreError)) throw e;
      return { err: e };
    }
  };
  const both = (a: Value | undefined, b: Value | undefined, f: (x: J, y: J) => J): Value | undefined => {
    if (a === undefined || b === undefined) return undefined;
    if ("err" in a) return a;
    if ("err" in b) return b;
    return attempt(() => f(a.ok, b.ok));
  };
  const okOr = (v: Value | undefined) => (v !== undefined && "ok" in v ? v.ok : undefined);
  switch (view.topic) {
    case "adminList": {
      const v = read(account, view.list as string);
      if (v === undefined || "err" in v) return v;
      return attempt(() => list(view.list as string, v.ok, (view.query as string) ?? "", (view.filter as string) ?? null, (view.sort as string) ?? null, (view.limit as number) ?? null, now));
    }
    case "adminItem": {
      const id = view.id as string;
      if (view.list === "users") {
        const codes = okOr(read(account, "invite-codes"));
        return both(read(account, "users"), read(account, "workspaces"), (u, w) => user(id, u, w, codes, now));
      }
      if (view.list === "feedback") {
        // Its own read (any report, by its id or FB-n, its logs too) where it came; the list's row till then, or
        // where a cloud from before has no such read.
        const itemV = read(account, `feedback/${encodeURIComponent(id)}`);
        const whole: J = itemV !== undefined && "ok" in itemV ? get(itemV.ok, "item") : undefined;
        if (isObj(whole)) {
          const item = whole;
          return attempt(() => feedback(strOf(item, "id"), { feedback: [item] }));
        }
        const listV = read(account, "feedback");
        if (listV === undefined) return itemV !== undefined && "err" in itemV && itemV.err.status !== 404 ? itemV : undefined;
        if ("err" in listV) return listV;
        const ref = /^fb-([0-9]+)$/i.exec(id)?.[1];
        const found = rowsOf("feedback", listV.ok).find((x) => strOf(x, "id") === id || (ref !== undefined && get(x, "number") === Number(ref)));
        if (found === undefined && itemV === undefined) return undefined;
        if (found === undefined && itemV !== undefined && "err" in itemV && itemV.err.status !== 404) return itemV;
        return attempt(() => feedback(found !== undefined ? strOf(found, "id") : id, listV.ok, found !== undefined && get(found, "has_logs") === true && itemV === undefined));
      }
      const w = read(account, "workspaces");
      if (w === undefined || "err" in w) return w;
      const users = okOr(read(account, "users"));
      return attempt(() => workspace(id, w.ok, users, now));
    }
    case "adminRelays": {
      const v = read(account, "relays");
      if (v === undefined || "err" in v) return v;
      return attempt(() => relays(v.ok, (view.range as string) ?? null, now, offsetMin));
    }
    case "adminOverview": {
      const users = read(account, "users");
      const workspaces = read(account, "workspaces");
      const codes = read(account, "invite-codes");
      if (users === undefined || workspaces === undefined || codes === undefined) return undefined;
      for (const v of [users, workspaces, codes]) if ("err" in v) return v;
      const fb = okOr(read(account, "feedback"));
      return attempt(() => overview(okOr(users), okOr(workspaces), okOr(codes), fb, now, offsetMin));
    }
  }
  return undefined;
}
