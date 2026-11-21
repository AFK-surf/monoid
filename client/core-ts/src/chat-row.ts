// A sidebar row as one viewer has it, made of the chat's row as its station makes it once for everyone (station/src/
// read/views.ts `sharedChats`) and what is the viewer's own: where they read to, the cards they let go, the chats they
// kept and pinned, the cards they answered, and who they are. One rule for the station (its `chats`, for devices from
// before) and the core (station/sync.ts), as titles.ts is for a chat's name: the station makes the chat list, never a
// list for one device.
import * as titles from "./titles.ts";

type J = Record<string, any>;

/// What of a row is the viewer's own.
export type Own = {
  /// Whether a person (a creator reference: id, email, via) is the viewer.
  mine: (person: unknown) => boolean;
  /// Where the viewer read each chat to, by its id (none: nothing of it).
  reads: ReadonlyMap<number, number>;
  /// The cards and needs the viewer let go, as `<thread>:<seq>`.
  dismissed: ReadonlySet<string>;
  /// The chats the viewer kept from archiving.
  kept: ReadonlySet<number>;
  /// The viewer's list visibility; absent when the station predates this mark.
  hidden?: ReadonlySet<number>;
  muted?: ReadonlySet<number>;
  /// When the viewer pinned each agent's row, by its key.
  pins: ReadonlyMap<string, number>;
};

/// The words a row says in the viewer's language.
export type Words = titles.TitleWords & { quotedOnly: string; admin?: string };

/// Whether something in the chat after where the viewer read is not theirs (`said`: its latest message, and the latest
/// one before that its author did not write).
function unread(said: J | null | undefined, read: number, mine: Own["mine"]): boolean {
  if (said === null || typeof said !== "object") return false;
  const byViewer = said.authorKind === "person" && mine({ id: said.author, email: said.author });
  const n = byViewer ? said.other : said.n;
  return typeof n === "number" && n > read;
}

/// A row in the viewer's words: its title by what names it (`named`), its last message's text when it only quotes. A
/// station gives its rows without them (views.ts `chats`): the words are the client's.
export function worded(row: J, words: Words): J {
  const { named, ...out } = row;
  if (named !== undefined) out.title = titles.chatTitle(named.thread, named.firstText ?? null, named.channelName ?? null, words);
  if (out.last && out.last.quotedOnly === true) {
    const { quotedOnly: _, ...last } = out.last;
    out.last = { ...last, text: words.quotedOnly };
  }
  // The local page's admin, whom a station names no more (station/src/read/views.ts `authorNames`).
  const last = out.last;
  if (words.admin !== undefined && last && typeof last === "object" && (last.authorName === null || last.authorName === undefined)
    && last.authorKind === "person" && last.author === "local") out.last = { ...last, authorName: words.admin };
  return out;
}

/// Minimal persisted sidecar per shared chat row: only the digest and projection inputs that cannot be recovered from
/// the projected row (no raw shared row, no `mineOf`, no `answeredBy`).
export type SharedSidecar = {
  digest: string;
  said: J | null;
  named: J | null;
  quotedOnly: boolean;
  localAdmin: boolean;
};

/// Extracts the minimal sidecar from a station's shared chat row and its digest.
export function sidecarOf(shared: J, rowDigest: string): SharedSidecar {
  const last = shared.last;
  const quotedOnly = last !== null && typeof last === "object" && last.quotedOnly === true;
  const localAdmin = last !== null && typeof last === "object"
    && (last.authorName === null || last.authorName === undefined)
    && last.authorKind === "person" && last.author === "local";
  return {
    digest: rowDigest,
    said: shared.said !== null && typeof shared.said === "object" ? shared.said : null,
    named: shared.named !== null && typeof shared.named === "object" ? shared.named : null,
    quotedOnly,
    localAdmin,
  };
}

/// Re-projects a persisted viewer chat row using its minimal sidecar, updated viewer marks (`own`), and language
/// `words`. Preserves `mine` and `answered` (identity changes discard the baseline and refetch whole). Revokes derived
/// marks (`pinned`, `hidden`, `muted`, `archiveReminderDismissed`, `unread`, `card`/`need`/`decision` `dismissed`)
/// whenever absent from `own`.
export function reprojectChatRow(row: J, sidecar: SharedSidecar, own: Own, words: Words): J {
  const out: J = { ...row };
  if (sidecar.named !== null) {
    out.title = titles.chatTitle(sidecar.named.thread, sidecar.named.firstText ?? null, sidecar.named.channelName ?? null, words);
  }
  if (out.last && typeof out.last === "object") {
    let last: J | null = null;
    if (sidecar.quotedOnly) last = { ...(last ?? out.last), text: words.quotedOnly };
    if (sidecar.localAdmin && words.admin !== undefined) last = { ...(last ?? out.last), authorName: words.admin };
    if (last !== null) out.last = last;
  }
  const thread = typeof out.thread === "number" ? out.thread : null;
  out.unread = thread !== null && unread(sidecar.said, own.reads.get(thread) ?? 0, own.mine);
  if (thread !== null) {
    out.archiveReminderDismissed = own.kept.has(thread);
    if (own.hidden !== undefined) out.hidden = own.hidden.has(thread);
    if (own.muted !== undefined) out.muted = own.muted.has(thread);
    for (const k of ["card", "need"] as const) {
      const c = out[k];
      if (c && typeof c === "object") {
        const dismissed = own.dismissed.has(`${thread}:${c.seq}`);
        if (dismissed && c.dismissed !== true) out[k] = { ...c, dismissed: true };
        else if (!dismissed && c.dismissed !== undefined) {
          const { dismissed: _, ...rest } = c;
          out[k] = rest;
        }
      }
    }
    if (out.decision && typeof out.decision === "object") {
      const dismissed = own.dismissed.has(`${thread}:${out.decision.seq}`);
      if (dismissed && out.decision.dismissed !== true) out.decision = { ...out.decision, dismissed: true };
      else if (!dismissed && out.decision.dismissed !== undefined) {
        const { dismissed: _, ...rest } = out.decision;
        out.decision = rest;
      }
    }
  }
  out.pinned = typeof out.id === "string" ? (own.pins.get(out.id) ?? null) : null;
  return out;
}

/// The row of `shared` (a chat's row as its station made it for everyone) for a viewer, in `words` (none: what names it
/// kept, for the client to word: `worded`).
export function rowFor(shared: J, own: Own, words?: Words): J {
  const { mineOf, said, answeredBy, ws: _ws, ...kept } = shared;
  const row = words === undefined ? kept : worded(kept, words);
  const thread = typeof row.thread === "number" ? row.thread : null;
  row.unread = thread !== null && unread(said, own.reads.get(thread) ?? 0, own.mine);
  row.mine = (Array.isArray(mineOf) ? mineOf : []).some((p: unknown) => own.mine(p));
  if (thread !== null) {
    row.archiveReminderDismissed = own.kept.has(thread);
    if (own.hidden !== undefined) row.hidden = own.hidden.has(thread);
    if (own.muted !== undefined) row.muted = own.muted.has(thread);
    for (const k of ["card", "need"] as const) {
      const c = row[k];
      if (c && typeof c === "object" && own.dismissed.has(`${thread}:${c.seq}`)) row[k] = { ...c, dismissed: true };
    }
    if (row.decision && own.dismissed.has(`${thread}:${row.decision.seq}`)) row.decision = { ...row.decision, dismissed: true };
    const answered = (Array.isArray(answeredBy) ? answeredBy : []).filter((a: J) => own.mine(a.by)).map(({ by: _, ...a }: J) => a);
    if (answered.length > 0) row.answered = answered;
  }
  row.pinned = typeof row.id === "string" ? (own.pins.get(row.id) ?? null) : null;
  return row;
}
