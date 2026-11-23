// A station's backups of its chats (its replica/copies.ts), as its 设置 shows them: one row, in words (the user,
// 2026-11-10: 「按最简单的交互方式做」). Backups are automatic, to two other stations of the workspace: the row says
// which are up to date and since when, one not reached or behind briefly, or that it is the only station. On a station
// with no chat of its own, a backup of each station no longer there takes the row's place, to be restored. A station
// from before says none: the page shows nothing. A station being retired from a workspace (its chats moved to another
// station of it), and a retired one's chats taken in here, are said here too, a line each, for its page's 迁移.
import * as format from "./format.ts";
import { t } from "./i18n.ts";
import type { Clock } from "./present.ts";
import { isObject } from "./util.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const arr = (v: unknown): J[] => (Array.isArray(v) ? v : []);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const ago = (at: number, c: Clock) => format.relativeTime(at, c.now, c.offsetMin);
const short = (id: string) => id.slice(0, 8);

/// Names in a list: A、B 和 C.
function listed(names: string[]): string {
  if (names.length <= 1) return names.join("");
  return names.slice(0, -1).join(t("core-views.copies.and")) + t("core-views.copies.andLast") + names[names.length - 1];
}

/// Why the backups, a restore or a station did not go, in words (what the station said exactly is in its log).
function why(reason: unknown): string {
  switch (reason) {
    case "offline": return t("core-views.copies.why.offline");
    case "old": return t("core-views.copies.why.old");
    case "gone": return t("core-views.copies.why.gone");
    case "notEmpty": return t("core-views.copies.why.notEmpty");
    case "full": return t("core-views.copies.why.full");
    default: return t("core-views.copies.why.error");
  }
}

/// What came of the restore the station was started again for; null where it went well and is said no more.
function restoredLine(o: J, c: Clock, quiet: boolean): string | null {
  if (!isObject(o)) return null;
  const name = str(o.name) || short(str(o.origin));
  const when = ago(num(o.at), c);
  if (o.pending === true) return t("core-views.copies.restored.pending", { name, n: num(o.left), why: why(o.reason), ago: when });
  if (typeof o.error === "string" && o.error !== "") return t("core-views.copies.restored.failed", { why: why(o.reason), ago: when });
  if (quiet) return null;
  const rows = isObject(o.rows) ? o.rows : {};
  const line = t("core-views.copies.restored.done", { name, chats: num(rows.threads), ago: when });
  return num(o.missing) > 0 ? `${line} · ${t("core-views.copies.restored.missing", { n: num(o.missing) })}` : line;
}

/// Format a single S3/R2 target from station backup settings with its status line and severity level.
function s3TargetOf(s: J, stationTo: number, c: Clock): J {
  const id = str(s?.id);
  const name = str(s?.name) || str(s?.bucket) || short(id);
  const sTo = num(s?.to);
  const at = typeof s?.at === "number" && Number.isFinite(s.at) ? s.at : null;
  const error = typeof s?.error === "string" && s.error !== "" ? s.error : null;
  const reason = s?.reason === "offline" || s?.reason === "old" || s?.reason === "error" ? s.reason : null;
  let statusLine: string;
  let level: "ok" | "amber" | "red";
  if (error !== null) {
    statusLine = reason === "offline" ? t("core-views.copies.s3.offline") : t("core-views.copies.s3.error");
    level = "red";
  } else if (at === null) {
    statusLine = t("core-views.copies.s3.pending");
    level = "amber";
  } else if (sTo < stationTo) {
    statusLine = t("core-views.copies.s3.behind");
    level = "amber";
  } else {
    statusLine = t("core-views.copies.s3.synced", { ago: ago(at, c) });
    level = "ok";
  }
  return {
    id,
    name,
    endpoint: str(s?.endpoint),
    region: str(s?.region) || "auto",
    bucket: str(s?.bucket),
    prefix: str(s?.prefix),
    forcePathStyle: s?.forcePathStyle === true,
    accessKeyMask: str(s?.accessKeyMask),
    keyFingerprint: str(s?.keyFingerprint),
    includeTranscripts: s?.includeTranscripts !== false,
    to: sTo,
    at,
    error,
    reason,
    statusLine,
    level,
  };
}

/// Sanitize and format optional `backup` settings from the station overview; undefined for older stations.
function backupOf(b: unknown, stationTo: number, c: Clock): J | undefined {
  if (!isObject(b)) return undefined;
  const mode = b.mode === "manual" ? "manual" : "auto";
  const stations = arr(b.stations).filter((s): s is string => typeof s === "string");
  const acceptOthers = b.acceptOthers !== false;
  const peers = arr(b.peers).map((p) => ({
    station: str(p?.station),
    name: str(p?.name) || short(str(p?.station)),
    acceptOthers: p?.acceptOthers !== false,
    online: p?.online === true,
  }));
  const s3 = arr(b.s3).map((s) => s3TargetOf(s, stationTo, c));
  const peerNames = new Map<string, string>();
  for (const p of peers) peerNames.set(p.station, p.name);
  const parts: string[] = [];
  if (mode === "auto") {
    parts.push(t("core-views.copies.summary.auto"));
  } else if (stations.length > 0) {
    const names = stations.map((id) => peerNames.get(id) || short(id));
    parts.push(t("core-views.copies.summary.manual", { places: listed(names) }));
  } else {
    parts.push(t("core-views.copies.summary.off"));
  }
  if (s3.length > 0) {
    parts.push(listed(s3.map((x) => x.name as string)));
  }
  parts.push(acceptOthers ? t("core-views.copies.summary.acceptOn") : t("core-views.copies.summary.acceptOff"));
  return {
    mode,
    stations,
    acceptOthers,
    peers,
    s3,
    settingsSummary: parts.join(" · "),
  };
}

/// The overview's `copies` as the page shows it; undefined when the station said none.
export function copiesShown(v: unknown, c: Clock): J | undefined {
  if (!isObject(v)) return undefined;
  const to = num(v.to);
  const backup = backupOf(v.backup, to, c);
  const keepers = arr(v.keepers).map((k) => ({ k, name: str(k?.name) || short(str(k?.station)) }));
  const s3List: J[] = backup ? backup.s3 : [];
  // (those as far as this station, and when the last of them was brought level; then what is wrong, briefly: what a
  // place holds counts, not whether the last try to it went, so one level a moment ago that missed a pass since is
  // still up to date; a partial head there has the chats, its transcripts still going)
  const currentKeepers = keepers.filter(({ k }) => typeof k?.at === "number" && num(k?.to) >= to);
  const currentS3 = s3List.filter((s) => s.error === null && s.at !== null && s.to >= to);
  const currentNames = [...currentKeepers.map((x) => x.name), ...currentS3.map((s) => s.name as string)];
  const last = Math.max(0, ...currentKeepers.map(({ k }) => num(k.at)), ...currentS3.map((s) => num(s.at)));
  const wrongKeepers = keepers.filter((x) => !currentKeepers.includes(x)).map(({ k, name }) =>
    str(k?.error) === ""
      ? t("core-views.copies.problem.behind", { name })
      : k?.reason === "old"
        ? t("core-views.copies.problem.old", { name })
        : k?.reason === "error"
          ? t("core-views.copies.problem.error", { name })
          : t("core-views.copies.problem.offline", { name }));
  const wrongS3 = s3List.filter((s) => !currentS3.includes(s)).map((s) =>
    s.error === null
      ? t("core-views.copies.problem.behind", { name: s.name })
      : s.reason === "old"
        ? t("core-views.copies.problem.old", { name: s.name })
        : s.reason === "offline"
          ? t("core-views.copies.problem.offline", { name: s.name })
          : t("core-views.copies.problem.error", { name: s.name }));
  const wrong = [...wrongKeepers, ...wrongS3];
  const totalTargets = keepers.length + s3List.length;
  let line: string;
  let level: "ok" | "amber" | "red";
  if (isObject(v.stopped)) {
    line = t("core-views.copies.stopped", { why: why(v.stopped.reason) });
    level = "red";
  } else if (totalTargets === 0) {
    line = backup !== undefined && backup.mode === "manual" && backup.stations.length === 0 && backup.s3.length === 0
      ? t("core-views.copies.none")
      : t("core-views.copies.alone");
    level = "amber";
  } else {
    const done = currentNames.length > 0 ? t("core-views.copies.done", { places: listed(currentNames), ago: ago(last, c) }) : t("core-views.copies.notYet");
    line = [done, ...wrong].join(" · ");
    level = wrong.length > 0 || currentNames.length === 0 ? "amber" : "ok";
  }
  // (just after a restore: what came of it, until a target is up to date with it; one that failed or left files to
  // place, until it is put right)
  const after = restoredLine(v.restored, c, currentNames.length > 0);
  if (after !== null && !isObject(v.stopped)) line = after;
  const manage = v.manage === true;
  const offers = v.empty === true ? offersOf(v) : [];
  const busy = offers.some((o) => o.busy);
  const retire = retireOf(v.retiring, manage);
  const out: J = {
    line,
    level,
    keepers: keepers.map(({ k, name }) => keeperOf(k, name, to, c)),
    offers,
    canRestore: manage && !busy,
    formerly: arr(v.formerly).filter((f) => typeof f === "string"),
    // (retiring this station from the workspace: one who manages it, while it has chats of its own and none is recorded)
    canRetire: manage && v.empty !== true && num(v.chats) > 0 && retire === null,
    retire,
    taking: arr(v.taking).map((x) => takingOf(x)),
  };
  if (backup !== undefined) out.backup = backup;
  return out;
}

/// A station that keeps this one's backups, a row on its 备份 page: how far what it holds goes, in words.
function keeperOf(k: J, name: string, to: number, c: Clock): J {
  const at = typeof k?.at === "number" && Number.isFinite(k.at) ? k.at : null;
  const failing = str(k?.error) !== "";
  const current = at !== null && num(k?.to) >= to;
  let line: string;
  let level: "ok" | "amber";
  if (at === null) {
    line = failing ? t("core-views.copies.keeper.firstWhy", { why: why(k?.reason) }) : t("core-views.copies.keeper.first");
    level = "amber";
  } else if (current && k?.partial === true) {
    line = t("core-views.copies.keeper.partial", { ago: ago(at, c), n: num(k?.lacking) });
    level = "ok";
  } else if (current) {
    line = t("core-views.copies.keeper.current", { ago: ago(at, c) });
    level = "ok";
  } else {
    line = failing ? t("core-views.copies.keeper.behindWhy", { ago: ago(at, c), why: why(k?.reason) }) : t("core-views.copies.keeper.behind", { ago: ago(at, c) });
    level = "amber";
  }
  return { station: str(k?.station), name, line, level };
}

/// Bytes in a few characters (1.2 GB).
function size(n: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let x = n;
  while (x >= 1000 && i < units.length - 1) (x /= 1000, i++);
  return `${i === 0 ? x : x.toFixed(x < 10 ? 1 : 0)} ${units[i]}`;
}

/// Why moving the chats to `name` did not go, in words (what the station said exactly is in its log).
function retireWhy(reason: unknown, name: string): string {
  switch (reason) {
    case "offline": return t("core-views.copies.retire.why.offline", { name });
    case "full": return t("core-views.copies.retire.why.full", { name });
    case "old": return t("core-views.copies.retire.why.old", { name });
    case "failed": return t("core-views.copies.retire.why.failed", { name });
    default: return t("core-views.copies.why.error");
  }
}

/// The steps a station's retirement goes through, in their order (the station's replica/retire.ts `Step`), a row each;
/// `accounts` only where its accounts move with it (its home workspace). Its last, `done`, has no row: once there every
/// row is done and the page offers taking the station out of the workspace. Nor has `sent` (all of it there, the chats
/// still working, the hand-over waiting for a person's confirmation; or back there after a hand-over failed, the chats
/// working again): 传文件 done, 暂停聊天 waiting for the confirmation, or saying why the hand-over did not go, to be
/// tried again as a failed row is.
const RETIRE_STEPS = ["sending", "quiet", "handing", "accounts", "connects"] as const;

/// This station being retired from the workspace (the station's replica/retire.ts): its steps, a row each, done, under
/// way (with how far it is, where it says), failed (why, in words) or not yet; the accounts that could not go with it;
/// and what the viewer may do of it now: let it go (`cancellable`, the station's word), try a failed one again
/// (`retriable`); once `done` (every row done), take the station out of the workspace.
function retireOf(r: J, manage: boolean): J | null {
  if (!isObject(r)) return null;
  const to = str(r.toName) || short(str(r.to));
  const step = str(r.step);
  const failed = typeof r.error === "string" && r.error !== "";
  const left = arr(r.accountsLeft).map((a) => str(a?.name) || short(str(a?.id))).filter((n) => n !== "");
  // (its accounts' step where they move: its home workspace, or once the station is at it or past it with some left)
  const accounts = r.home === true || step === "accounts" || left.length > 0;
  const keys = RETIRE_STEPS.filter((k) => k !== "accounts" || accounts);
  // (at `sent` it stands before 暂停聊天: its row is the one that waits)
  const at = keys.indexOf((step === "sent" ? "quiet" : step) as (typeof RETIRE_STEPS)[number]);
  const steps = keys.map((key, i) => {
    // (at `sent` nothing runs: 暂停聊天 waits, not under way, for the hand-over's confirmation; after one failed, why,
    // and that the chats work again, which is what a person needs to know first)
    const waits = step === "sent" && i === at;
    const state = step === "done" || (at >= 0 && i < at) ? "done" : i === at ? (failed ? "failed" : waits ? "todo" : "now") : "todo";
    const note = state === "failed"
      ? (step === "sent" ? t("core-views.copies.retire.resumed", { why: retireWhy(r.reason, to) }) : retireWhy(r.reason, to))
      : waits
        ? t("core-views.copies.retire.waiting")
        : state === "now" && key === "sending" && num(r.total) > 0
          ? t("core-views.copies.retire.sent", { done: size(num(r.done)), total: size(num(r.total)) })
          : "";
    return { key, label: t(`core-views.copies.retire.step.${key}`, { name: to }), state, note };
  });
  return {
    steps,
    left: left.length === 0 ? null : {
      label: t("core-views.copies.retire.left", { n: left.length }),
      note: t("core-views.copies.retire.leftNote", { names: listed(left), name: to }),
    },
    done: step === "done" && !failed,
    // (its chats stopped: from here it goes on until they are there)
    stopped: step !== "sending" && step !== "sent" && step !== "done",
    to: str(r.to),
    toName: to,
    cancellable: manage && r.cancellable === true,
    retriable: manage && r.retriable === true,
  };
}

/// Another station's chats being taken in here as it is retired: whose, and where it stands, in words.
function takingOf(x: J): J {
  const origin = str(x?.origin);
  const name = str(x?.name) || short(origin);
  const step = str(x?.step);
  const failed = step === "failed" || (typeof x?.error === "string" && x.error !== "");
  const line = failed
    ? t("core-views.copies.taking.failed", { why: t("core-views.copies.why.error") })
    : step === "placing" || step === "gits" || step === "copy" || step === "restart"
      ? t(`core-views.copies.taking.${step}`)
      : t("core-views.copies.taking.coming");
  return { origin, name, line, level: failed ? "amber" : "ok" };
}

/// On a station with no chat of its own: a backup of each station no longer there it could restore, and how the one
/// being restored goes.
function offersOf(v: J): J[] {
  const looked = isObject(v.restorable) ? v.restorable : null;
  const r = isObject(v.restoring) ? v.restoring : null;
  const going = (x: J) => {
    if (typeof x.error === "string" && x.error !== "") return t("core-views.copies.restoring.failed", { why: why(x.reason) });
    if (x.restart === true) return t("core-views.copies.restoring.restart");
    if (num(x.total) > 0 && num(x.done) >= num(x.total)) return t("core-views.copies.restoring.starting");
    return t("core-views.copies.restoring.going", { done: num(x.done), total: num(x.total) });
  };
  const running = r !== null && !(typeof r.error === "string" && r.error !== "");
  const offers = arr(looked?.copies).map((x) => {
    const name = str(x?.name) || short(str(x?.station));
    const first = arr(x?.from)[0] ?? null;
    const fromStation = typeof first?.station === "string" && first.station !== "" ? first.station : null;
    const fromS3 = typeof first?.s3 === "string" && first.s3 !== "" ? first.s3 : null;
    const fromName = typeof first?.name === "string" && first.name !== "" ? first.name : null;
    const mine = r !== null && str(r.origin) === str(x?.station) && str(r.gen) === str(x?.gen);
    const offerLine = fromS3 !== null && fromName !== null
      ? t("core-views.copies.offerFrom", { name, n: num(x?.chats), from: fromName })
      : t("core-views.copies.offer", { name, n: num(x?.chats) });
    return {
      station: str(x?.station),
      gen: str(x?.gen),
      name,
      line: mine ? going(r) : offerLine,
      fromStation,
      fromS3,
      fromName,
      busy: mine && running,
    };
  });
  // (one being restored whose backup is not among those found any more: its row still says how it goes)
  if (r !== null && !offers.some((o) => o.station === str(r.origin) && o.gen === str(r.gen))) {
    offers.push({ station: str(r.origin), gen: str(r.gen), name: str(r.name) || short(str(r.origin)), line: going(r), fromStation: str(r.from) || null, fromS3: null, fromName: null, busy: running });
  }
  return offers;
}
