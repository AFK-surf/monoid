// What the console's pages share: a topic kept in view while the next is read, where each list is, an error said, an
// item's pane beside its list, and the pages made up for their bones while they are read.
import { useRef } from "preact/hooks";
import type { ReactNode } from "preact/compat";
import { Link } from "wouter-preact";
import { useTopic } from "../core/react.ts";
import type { CoreError, Topic } from "../core/client.ts";
import { Close } from "@stillfail/ui/icons.tsx";
import { ICON, MobileBack, Pill, Waiting, ErrorLine } from "../ui.tsx";
import { sampleStamp, sampleWords } from "../samples.ts";
import * as css from "./console.css.ts";
import { t } from "../i18n.ts";
import type { FeedbackPage, List, Mark, Overview, Relay, Row, UserPage, WorkspacePage } from "./types.ts";

/** A topic of the core; while the next one (other words, say) is read, the last one's value stays in view. */
export function useKept<T>(topic: Topic): { value: T | undefined; error: CoreError | null } {
  const state = useTopic<T>(topic);
  const last = useRef<T | undefined>(undefined);
  if (state.value) last.current = state.value;
  return { value: state.value ?? (state.error ? undefined : last.current), error: state.error };
}

export const PATH: Record<List, string> = { users: "/users", workspaces: "/workspaces", "invite-codes": "/codes", feedback: "/feedback", audit: "/audit", keys: "/keys" };

/** On a phone the sidebar and a page take turns: "/" is the sidebar there, and the overview elsewhere. */
export const narrow = () => matchMedia("(max-width: 700px)").matches;

export function Failed({ error }: { error: Error | null }) {
  return error ? <ErrorLine>{t("web-pages.admin.readFailed", { error: error.message })}</ErrorLine> : null;
}

export function Marks({ marks }: { marks: Mark[] }) {
  return <>{marks.map((m) => <Pill key={m.label} tone={m.tone}>{m.label}</Pill>)}</>;
}

/** An item's pane beside its list: its head (`head`), closed from its end, over what it holds; `bones`: made up, while
 * the item is read, its head and all of it in their bones. */
export function Detail({ close, head, bones = false, children }: { close: string; head: ReactNode; bones?: boolean; children: ReactNode }) {
  return (
    <aside className={css.detail}>
      <MobileBack to={close} label={t("web-pages.admin.backToList")} />
      {bones ? <Waiting sample={<><div className={css.detailHead}>{head}</div>{children}</>} /> : <>
        <div className={css.detailHead}>{head}<Link className={css.close} to={close} aria-label={t("common.close")}><Close {...ICON} /></Link></div>
        {children}
      </>}
    </aside>
  );
}

/** An email given rights before anyone signed in with it is listed as `email:<address>` (views/admin.ts). */
export const PENDING = "email:";

// The console's pages made up, for what they show while they are read (in their bones).
export const SAMPLE_OVERVIEW: Overview = {
  stats: [3, 4, 3, 4].map((n, i) => ({ label: sampleWords(n), value: 100 + i, note: sampleWords(n + 3), list: "users", filter: "" })),
  weeks: [3, 5, 4, 6, 8, 5, 7, 9, 6, 8, 10, 7].map((count) => ({ count, label: sampleWords(2) })),
  todo: [14, 10].map((n) => ({ text: sampleWords(n), hint: sampleWords(6), tone: "amber", list: "users", filter: "" })),
};
export const SAMPLE_RELAYS: Relay[] = [6, 8].map((n, i) => ({
  url: String(i), name: sampleWords(n), state: "online", seen: sampleWords(5), ticks: [],
  numbers: [3, 4, 3].map((m) => ({ label: sampleWords(m), value: sampleWords(3) })),
  charts: [4, 3].map((m, j) => ({ id: String(j), label: sampleWords(m), peak: sampleWords(3), series: [{ id: "", label: "", values: [2, 3, 5, 4, 6, 5, 7, 6, 8, 6] }] })),
}));
export const sampleRows = (list: List): Row[] => [6, 8, 5, 7, 9, 6].map((n, i) => ({
  id: `sample-${i}`, title: sampleWords(n), line: sampleWords(n + 8), marks: [], number: sampleWords(4),
  ...(list === "users" ? { person: { name: sampleWords(n), email: "", picture: "" } } : {}), time: { last_seen: sampleStamp(3), created_at: sampleStamp(3) },
}));
const SAMPLE_TIME = { created_at: sampleStamp(4), last_seen: sampleStamp(4) };
export const SAMPLE_USER: UserPage = {
  id: "", title: sampleWords(5), person: { name: sampleWords(5), email: "", picture: "" }, email: sampleWords(16), admin: false, admission: sampleWords(4), code: null,
  mayCreate: false, mayCreateHint: sampleWords(14), mayCreateFixed: false, beta: false, blocked: false, time: SAMPLE_TIME,
  workspaces: [6, 4].map((n, i) => ({ id: String(i), name: sampleWords(n), line: sampleWords(n + 4) })),
};
export const SAMPLE_WORKSPACE: WorkspacePage = {
  id: sampleWords(10), title: sampleWords(5), creator: { id: "", title: sampleWords(5) }, people: sampleWords(6), invitations: [], time: SAMPLE_TIME,
  members: [5, 7].map((n, i) => ({ id: String(i), title: sampleWords(n), person: { name: sampleWords(n), email: "", picture: "" }, role: sampleWords(2), time: SAMPLE_TIME })),
  stations: [5, 3].map((n, i) => ({ id: String(i), name: sampleWords(n), version: sampleWords(4), outdated: false, state: "online", time: SAMPLE_TIME })),
};
export const SAMPLE_FEEDBACK: FeedbackPage = {
  id: "", number: sampleWords(4), title: sampleWords(12), body: [40, 26].map(sampleWords).join("\n\n"), status: "new", statuses: [{ id: "new", label: sampleWords(2) }],
  marks: [], channel: "", channelLabel: sampleWords(3), area: sampleWords(4), reporter: sampleWords(5), station: null, workspace: null, account: null,
  context: [], logs: null, text: "", time: SAMPLE_TIME,
};
