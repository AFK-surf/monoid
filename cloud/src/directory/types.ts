import { STATIONS_PER_WORKSPACE } from "../../../client/limits.ts";
import type { Env } from "../env";
import type { Lang } from "../i18n.ts";
import { isIconUrl } from "../icons";
import type { Shows } from "../noticeText";
import { parseRelays } from "../relays";
import type { AccountEvent, FeedbackReply, RigView, Role, ViewTold, WorkspaceView } from "../types";

export type { Role };

export const ROLES: readonly Role[] = ["owner", "admin", "member"];
export const MANAGERS: readonly Role[] = ["owner", "admin"];

export const INVITATION_TTL_SEC = 7 * 24 * 60 * 60;
/** How often one email is told by mail that it was added to one workspace, at most (`#toMail`). */
export const ADDED_MAIL_EVERY_SEC = 24 * 60 * 60;
/** Who `addMembers` tells by mail, by whom and to which workspace (api.ts sends them, mail.ts `sendAdded`). */
export type AddedMail = { to: { email: string; joined: boolean }[]; inviter: string; workspace: string };
export const ENROLLMENT_TTL_SEC = 60 * 60;
/** How long a device's request to be confirmed into the lock waits before it is dropped (one long gone, a browser profile thrown away). */
export const LOCK_REQUEST_TTL_SEC = 7 * 24 * 60 * 60;
export const LIMITS = { openInvitations: 50, pushPerUser: 32 };
/**
 * What an account may create and how many people each workspace it created may hold (its creator among them). A code
 * or the admin's say makes an account standard (#standard); the admin's own go up to the old bounds.
 */
export const PLANS = {
  free: { workspaces: 1, members: 1 },
  standard: { workspaces: 5, members: 6 },
  admin: { workspaces: 32, members: 200 },
} as const;
export type Plan = keyof typeof PLANS;

/** The events socket's subprotocols (api.ts socketToken). */
export const EVENTS_PROTOCOLS = ["stillfail-events"] as const;
/** How long a revocation is kept and told: a day more than a credential lasts (grants.ts). */
export const REVOCATION_DAYS = 31;

/** How often a station sends "ping" on its presence socket (the runtime answers "pong" without waking this object). */
export const PING_SEC = 30;
/** A station socket unanswered this long is taken for dead. */
export const SILENT_MS = 3 * PING_SEC * 1000;
/** Close codes a station acts on. */
export const CLOSE = { replaced: 4000, removed: 4004, silent: 4008 } as const;

/** Reports one sender may send in a day, and how many the console lists. */
export const FEEDBACK_PER_DAY = 20;
export const FEEDBACK_LISTED = 500;
/** How many of the operators' changes are kept (recordAudit), and how many the console lists. */
export const AUDIT_KEPT = 1000;
export const AUDIT_LISTED = 500;
/** How many replies a station's agents may write on its reports a day. */
export const FEEDBACK_REPLIES_PER_DAY = 100;
/** How many reports with replies a member's device is given of a workspace (feedbackOf). */
export const FEEDBACK_SHOWN = 200;

export const LIST: AccountEvent = { type: "workspaces" };
/** How long an account that opened the console is told what it shows changed (noteOperator). */
export const OPERATOR_KEPT_S = 7 * 24 * 60 * 60;
/** The picture an account is shown with, of its row in users: the one it put up for itself (setOwnPicture), else its sign-in's. */
export const SHOWN_PICTURE = "COALESCE(own_picture, picture)";
export type Attachment = { station: string; at: number; dropped?: boolean } | { sub: string; sid?: string };

/**
 * Where devices' events sockets and stations' presence sockets open, and who says whether a station is enrolled: their
 * own objects (account.ts, station.ts), or, with DIRECTORY_SOCKETS "primary" (env.ts), this one, as before them: the
 * way back while nothing else depends on those objects. Told either way (an account's object keeps whether it is let
 * into the test channel in both). A test sets `where` to move them.
 */
export const sockets = { where: (env: Env): "objects" | "primary" => (env.DIRECTORY_SOCKETS === "primary" ? "primary" : "objects") };

/**
 * What an account's or a station's object is told (#deliver): frames to send on its sockets (events, revocations, what
 * goes to all); `beta`, its account's test channel now; `state`, the station's state changed: `frame`, its state frame
 * as it is as this is sent, null in no workspace now (it lets its socket go). It answers whether it holds a socket
 * (`live`).
 */
export type Delivery = { frames?: string[]; beta?: boolean; state?: true; frame?: string | null };
/** The longest wait before a delivery that failed is tried again (from 2 s, doubling). */
export const OUTBOX_MAX_DELAY = 600;
/** How many hours of its requests the directory keeps counted (adminLoad): a week, as the console's longest chart. */
export const HOURS_KEPT = 7 * 24;

export class DirectoryError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) {
    super(code);
    this.status = status;
    this.code = code;
  }
}
export const fail = (status: number, code: string): never => {
  throw new DirectoryError(status, code);
};

export type Row = Record<string, SqlStorageValue>;

/** A device to push to, as registered (POST /v1/push). */
export type PushDevice =
  | { kind: "web"; endpoint: string; p256dh: string; auth: string }
  | { kind: "fcm"; token: string; app?: string }
  | { kind: "apns"; token: string; sandbox: boolean; app?: string };
/** A device registered, with the language its notifications are said in (Chinese for one registered before languages). */
export type PushRegistration = PushDevice & { id: string; lang: Lang; shows: Shows | null };

/** What the console shows of the directory's own load (adminLoad). */
export type DirectoryLoad = {
  at: number;
  /** Calls an hour from `start` (seconds), `step` apart, by family. */
  calls: { start: number; step: number; families: Record<string, number[]> };
  held: { devices: number; stations: number };
  live: { accounts: number; stations: number };
  waiting: number;
  bytes: number;
};

/** What each of the directory's calls serves, as its load is counted (adminLoad); "other" for one not listed. */
export const FAMILIES: Record<string, string> = {
  accountFor: "signin", upsertUser: "signin", joinBySignIn: "signin", openToSignIn: "admin",
  me: "me", invitationsFor: "me", setOwnPicture: "me", deleteAccount: "me", revokeSessions: "me",
  isBeta: "beta",
  seen: "sockets", closed: "sockets", stationConnected: "sockets", stationState: "sockets", stationLeft: "sockets", stationSaid: "sockets",
  fetch: "sockets", webSocketMessage: "sockets", webSocketClose: "sockets", webSocketError: "sockets",
  enroll: "stations", isStation: "stations", verifyProvisionKey: "stations", createProvisionedEnrollment: "stations", pushTargets: "stations", addFeedback: "stations", fixedUntold: "stations", reporterReply: "stations", toldFixed: "stations", markFixed: "stations",
  registerPush: "push", unregisterPush: "push", dropPush: "push", pushApps: "push",
  tellAll: "broadcast", tellStations: "broadcast", modelsMade: "broadcast", tellAdmins: "broadcast", alarm: "broadcast",
};
for (const name of ["workspace", "createWorkspace", "updateWorkspace", "deleteWorkspace", "invite", "previewInvitation", "acceptInvitation", "acceptById", "declineById", "revokeInvitation",
  "feedbackOf", "memberFeedbackReply", "setRole", "removeMember", "addMembers", "mailFailed", "removeAdded", "setRelays", "setWay", "manages", "createEnrollment", "createRigEnrollment", "updateStation", "setStationMode", "removeStation", "memberRole", "recordDevice", "devices",
  "lock", "appendLock", "clearLock", "requestLock", "lockRequests", "dropLockRequest", "provisionKeys", "createProvisionKey", "revokeProvisionKey"]) FAMILIES[name] = "workspaces";
for (const name of ["adminUsers", "setMayCreate", "adminPending", "setPending", "removePending", "setBlocked", "setBeta", "adminDeleteWorkspace", "adminCreateWorkspace", "adminSetLimits",
  "adminEnrollment", "adminWorkspaces", "inviteCodes", "createInviteCode", "revokeInviteCode", "adminFeedback", "setFeedbackStatus", "replyToFeedback", "adminLoad", "noteOperator", "isAdminAccount",
  "adminFeedbackItem", "adminAddOwners", "adminRemoveAdded", "recordAudit", "adminAudit", "auditName",
  "adminKeys", "createAdminKey", "revokeAdminKey", "verifyAdminKey"]) FAMILIES[name] = "admin";
/** The tables that are this object's own, not moved into another cloud: its sockets' generations, the outbox to the
 * objects (made again as things change), its counts, the views as last told (`#told`: begun again by the next change,
 * at a version above any before), who opened its console (noteOperator: noted again as they open the other's), and
 * what its operators changed there (recordAudit: the console's own record, begun again in the other). */
export const MOVE_SKIPPED = new Set(["outbox", "live", "hits", "told", "operators", "admin_audit"]);
for (const name of ["moveExport", "moveImport", "moveAccounts"]) FAMILIES[name] = "admin";
// The relays' list: the operator's (a relay's counters and its enrolling are "other"); the cron's reading of it.
for (const name of ["relayList", "relayPut", "relayRemove", "relayToken", "relayTokenRevoke"]) FAMILIES[name] = "admin";
FAMILIES.relaysNow = "broadcast";
/** What it runs for itself rather than being called for. */
export const UNCOUNTED = new Set(["constructor", "handOff", "migrateStationMembers", "migrateFreePlan", "send", "settled", "sweep"]);

export function cleanName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const clean = value.trim().replace(/\s+/g, " ");
  return clean && clean.length <= 80 ? clean : null;
}

/** A reply on a report as the console has it. */
export function replyOf(r: Row): FeedbackReply {
  const team = r.author === "team";
  return {
    id: r.id as string,
    from: team ? "team" : "reporter",
    by: r.by as string,
    text: r.text as string,
    created_at: r.created_at as number,
    delivery: !team ? null : r.delivered_at !== null ? "delivered" : "pending",
    delivered_at: (r.delivered_at as number | null) ?? null,
  };
}

/** A report's columns but its logs, and whether it has any (adminFeedback's `slim`). */
export const FEEDBACK_SLIM = `f.id, f.number, f.channel, f.station, f.workspace, f.account, f.title, f.body, f.area, f.reporter, f.context, f.status, f.fixed_in, f.told_at, f.created_at, f.updated_at,
  CASE WHEN f.logs IS NOT NULL AND trim(f.logs) != '' THEN 1 ELSE 0 END AS has_logs, NULL AS logs`;

/** Emails as addMembers takes them: lowercased, each once, at least one; fails when one is no email. */
export function emailsOf(value: unknown): string[] {
  const given = Array.isArray(value) ? value : [];
  const wanted = [...new Set(given.map((e) => String(e).trim().toLowerCase()).filter(Boolean))];
  if (wanted.length === 0 || wanted.some((e) => !/^[^\s@]{1,64}@[^\s@]{1,190}$/.test(e))) fail(400, "invalid_email");
  return wanted;
}

/** The largest member limit and the largest legacy station argument accepted from older clients. */
export const LIMITS_MAX = { members: 1000, stations: 256 } as const;

/** A workspace's member limit; accept the older station argument but use the shared cap. */
export function limitsOf(input: { members?: unknown; stations?: unknown }): { members: number; stations: number } {
  const whole = (v: unknown, max: number) => (typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= max ? v : fail(400, "invalid_limits"));
  const members = whole(input.members, LIMITS_MAX.members);
  whole(input.stations, LIMITS_MAX.stations);
  return { members, stations: STATIONS_PER_WORKSPACE };
}

/**
 * A station's icon: one of still.fail's by its name (`glyph:rocket`, design/station-icons; a name a client does not know
 * falls back to the emoji), which may be given a colour (`glyph:rocket:blue`; the clients know which), or a picture put
 * up: kept in the bucket, by its address on one of `origins` (icons.ts keptIcon; any size up to ICON_FILE_BYTES, a GIF moving),
 * else (no bucket, or one put up before) a small data URL the clients made (96px, a few KB); else null.
 */
export function cleanIcon(value: unknown, origins: string[]): string | null {
  if (typeof value !== "string") return null;
  if (/^glyph:[a-z0-9-]{1,40}(:[a-z]{1,16})?$/.test(value)) return value;
  if (origins.some((origin) => isIconUrl(origin, value))) return value;
  return value.length <= ICON_BYTES && /^data:image\/(png|webp|jpeg|gif);base64,[A-Za-z0-9+/]+={0,2}$/.test(value) ? value : null;
}

/** A picture an account puts up for itself: one kept here, by its address on one of `origins` (this cloud's and its
 * guests': the clients fetch a person's by its address); else null. */
export function cleanPicture(value: unknown, origins: string[]): string | null {
  return typeof value === "string" && origins.some((origin) => isIconUrl(origin, value)) ? value : null;
}

/** What a workspace's view says alike to every member (directory.ts `#alike`), as kept to be told against. */
export type AlikeView = Omit<WorkspaceView, "role" | "rev" | "rigs" | "lock_requests"> & { rigs: RigView[] };

/** A view's lists, each by the key of its entries (what a device patches by). */
const KEYED = { members: "sub", stations: "id", rigs: "id", invitations: "id", added: "email" } as const;

/** What changed from `before` to `now`, told so (AccountEvent `workspace`): a manager's with the invitations and the
 * added, anyone else's without, as their views are. */
export function viewTold(before: AlikeView, now: AlikeView, manager: boolean): ViewTold {
  const told: Required<ViewTold> = { set: {}, unset: [], put: {}, gone: {} };
  const was = before as unknown as Record<string, unknown>;
  const is = now as unknown as Record<string, unknown>;
  for (const key of new Set([...Object.keys(was), ...Object.keys(is)])) {
    if (key in KEYED) continue;
    if (!(key in is)) told.unset.push(key);
    else if (JSON.stringify(was[key]) !== JSON.stringify(is[key])) told.set[key] = is[key];
  }
  for (const [list, key] of Object.entries(KEYED)) {
    if (!manager && (list === "invitations" || list === "added")) continue;
    const entries = (v: unknown) => (Array.isArray(v) ? (v as Record<string, unknown>[]) : []);
    const held = new Map(entries(was[list]).map((e) => [e[key], JSON.stringify(e)]));
    const put = entries(is[list]).filter((e) => held.get(e[key]) !== JSON.stringify(e));
    const keys = new Set(entries(is[list]).map((e) => e[key]));
    const gone = [...held.keys()].filter((k) => !keys.has(k));
    if (put.length > 0) told.put[list] = put;
    if (gone.length > 0) told.gone[list] = gone;
  }
  return Object.fromEntries(Object.entries(told).filter(([, v]) => (Array.isArray(v) ? v.length > 0 : Object.keys(v).length > 0))) as ViewTold;
}

/** A workspace's emoji and icon as its views carry them: each only when set (clients from before them know neither). */
export function marks(emoji: unknown, icon: unknown): { emoji?: string; icon?: string } {
  return { ...(emoji ? { emoji: emoji as string } : {}), ...(icon ? { icon: icon as string } : {}) };
}

/** The ways a workspace turned off as its views carry them: only when some are (clients from before them know none). */
export function offOf(kept: unknown): { ways_off?: string[] } {
  const off = parseRelays(kept);
  return off.length > 0 ? { ways_off: off } : {};
}

/** How long a picture's data URL kept in the workspace may be: it goes to every member with the workspace. */
const ICON_BYTES = 48_000;

/** One emoji, as a person sees one (a flag, a family, a skin tone are one): the first, else null. */
export function cleanEmoji(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const first = [...new Intl.Segmenter().segment(value.trim())][0]?.segment;
  return first && first.length <= 32 && /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(first) ? first : null;
}

/** A report's context as the station sent it; empty when it was cut at its limit. */
export function contextOf(text: string | null): Record<string, unknown> {
  try {
    const value = JSON.parse(text ?? "{}") as unknown;
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** The session a report came from, which a reply goes to. */
export const sessionOf = (text: string | null): string | null => {
  const session = contextOf(text).session;
  return typeof session === "string" && session ? session : null;
};
