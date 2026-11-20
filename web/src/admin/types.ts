// What the core gives the console's pages (client/core-ts/src/views/admin.ts, admin-relays.ts), as they draw it.
import type { Stamp } from "../api.ts";
import type { Presence, Tone } from "../ui.tsx";
import type { FeedbackStatus } from "../cloud/api.ts";

export type List = "users" | "workspaces" | "invite-codes" | "feedback" | "audit" | "keys";
export type Timed = { time?: Record<string, Stamp> };
export type Mark = { label: string; tone: Tone };
export type PersonLike = { name: string; email: string; picture: string };
export type Row = Timed & {
  id: string; title: string; line: string; marks: Mark[]; person?: PersonLike;
  /** A workspace's: how its stations last stood. A code's: open, used, expired, revoked. An operator's change: its kind. A key's: active, expired, revoked. */
  state?: Presence | string | null; url?: string | null; note?: string;
  /** An Admin API key's prefix (`sfa_…`). */
  prefix?: string;
  /** A code's sign-up link for each product, where the cloud answers as two. */
  links?: { product: string; url: string }[];
  /** A bug report's: FB-<number>. */
  number?: string;
};
export type ListView = {
  total: number; found: number; filter: string; filters: { id: string; label: string; count: number }[]; sort: string; sorts: { id: string; label: string }[]; rows: Row[]; more: boolean;
  /** The reports' list: the area it is narrowed to ("" all), and how many each holds. */
  area?: string; areas?: { id: string; label: string; count: number }[];
};
export type UserPage = Timed & {
  /** An email given rights before anyone signed in with it (id `email:<address>`). */
  pending?: boolean;
  id: string; title: string; person: PersonLike; email: string; admin: boolean; admission: string; code: string | null;
  mayCreate: boolean | null; mayCreateHint: string; mayCreateFixed: boolean; beta: boolean | null; blocked: boolean | null;
  workspaces: { id: string; name: string; line: string }[];
};
export type Machine = Timed & { id: string; name: string; version: string | null; outdated: boolean; state: Presence };
export type WorkspacePage = Timed & {
  id: string; title: string; creator: { id: string; title: string } | null; people: string;
  /** Missing from a core from before. */
  stationCount?: string; plan?: string | null; limits?: { members: number; stations: number | null } | null; enrollable?: boolean;
  /** Limits of its own (made for a company), which can be given back to its creator's plan. */
  customLimits?: boolean;
  members: (Timed & { id: string; title: string; person: PersonLike; role: string })[];
  /** Emails added that have not signed in yet. */
  added?: (Timed & { id: string; email: string; line: string })[];
  stations: Machine[];
  /** Its machines that only run tasks, each its member's. */
  rigs?: (Machine & { owner: string; ownerTitle: string })[];
  invitations: (Timed & { id: string; email: string; line: string })[];
};
export type Reply = Timed & {
  id: string; from: "team" | "reporter"; authorLabel: string; delivery: "pending" | "delivered" | null; deliveryLabel: string | null; text: string;
};
export type FeedbackPage = Timed & {
  id: string; number: string; title: string; body: string; status: FeedbackStatus; statuses: { id: FeedbackStatus; label: string }[];
  marks: Mark[]; channel: string; channelLabel: string; area: string; reporter: string;
  station: { id: string; name: string } | null; workspace: { id: string; title: string } | null; account: { id: string; title: string } | null;
  context: { key: string; value: string }[]; logs: string | null;
  /** Its logs still to come (the list's row shown till its own read is here). */
  logsLoading?: boolean;
  /** The team's and the reporter's replies, oldest first; whether the team can reply, and what a reply does or why not. */
  replies?: Reply[]; canReply?: boolean; replyHint?: string;
  /** All of it as plain text, to hand to an agent. */
  text: string;
};
export type Range = "day" | "week";
export type RelaysView = {
  range: Range;
  ranges: { id: Range; label: string }[];
  relays: Relay[];
  /** Whether the cloud's list can be kept from here (a still.fail cloud from before says none; a core from before neither). */
  manage?: boolean;
  /** The tokens made for relays not used yet (`id`: to take one back by). */
  tokens?: { key: string; id?: string | null; name: string; line: string }[];
};
export type Relay = {
  url: string; name: string;
  /** Whether it can be taken off the list (the cloud's own cannot) or named anew, how it came onto it, the ways into it. */
  removable?: boolean; editable?: boolean; how?: string[] | null; entries?: { url: string; name: string; host: string; target?: string }[];
  state: "online" | "offline" | "error";
  /** When it was last heard from, said for people ("1 分钟前更新"). */
  seen: string;
  numbers: { label: string; value: string; tone?: "amber" | "red" }[];
  charts: RelayChart[];
  /** Where times are marked along the charts: `index` a bucket's. */
  ticks: { index: number; label: string }[];
  /** What the probes from China's carriers and Hong Kong found of it last, and when. */
  probes?: { seen: string; items: { label: string; value: string; tone?: "amber" | "red" }[] };
};
export type RelayChart = { id: string; label: string; peak: string; series: { id: string; label: string; values: (number | null)[] }[] };
export type Overview = {
  stats: { label: string; value: number; note: string; list: List; filter: string }[];
  weeks: { count: number; label: string }[];
  todo: { text: string; hint: string; tone: string; list: List; filter: string }[];
};
