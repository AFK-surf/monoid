// The admin's console, on its own host: every user and workspace in still.fail cloud, the invite codes that let
// a new person create a workspace, the bug reports people's agents sent about still.fail, the relays and what the
// operators changed. Only the admin's account reaches it (still.fail cloud answers 404 to everyone else). The core puts
// each page together (views/admin.ts: found, filtered, sorted, counted); this draws it. Where the page is (a list's
// words, filter and sort, the item open) is in its URL, so a link shows the same. A page's own parts are beside it:
// feedback.tsx, workspace.tsx, relays.tsx; what they share, shared.tsx; what the core gives, types.ts.
import { Boxes, ChevronRight, Copy, Key, List as ListIcon, LogOut, Monitor, Plus, Said, Server, Ticket, Users } from "@stillfail/ui/icons.tsx";
import { useEffect, useState, type ReactNode } from "preact/compat";
import { Link, Redirect, Route, Switch as Routes, useLocation, useParams, useRoute, useSearchParams } from "wouter-preact";
import { Wordmark } from "../brand.tsx";
import { stamp } from "../api.ts";
import { failure, useToast } from "@stillfail/ui/toast.tsx";
import { Button, Confirm, CopyCommand, Dialog, Field, FilterPills, IconButton, Menu, MobileBack, ResizeHandle, SearchInput, Select, StatusDot, SwitchRow, Time, ICON, type Presence, Waiting, ErrorLine, TextInput } from "../ui.tsx";
import { useSignOut, type Account } from "../cloud/accounts.ts";
import { admin, useAction } from "../cloud/api.ts";
import { Avatar } from "../cloud/gate.tsx";
import * as nav from "../Sidebar.css.ts";
import * as shellCss from "../styles/shell.css.ts";
import * as css from "./console.css.ts";
import * as pagesCss from "../styles/pages.css.ts";
import { t } from "../i18n.ts";
import { NAME } from "../channel.ts";
import { Detail, Failed, Marks, narrow, PATH, PENDING, SAMPLE_OVERVIEW, SAMPLE_USER, sampleRows, useKept } from "./shared.tsx";
import { FeedbackDetail } from "./feedback.tsx";
import { NewWorkspaceDialog, WorkspaceDetail } from "./workspace.tsx";
import { RelaysPage } from "./relays.tsx";
import type { List, ListView, Overview, Row, UserPage } from "./types.ts";

export { useAdminAccount } from "./account.ts";

export function Console({ account }: { account: Account }) {
  const atIndex = useLocation()[0] === "/";
  const signOut = useSignOut();
  return (
    <div className={shellCss.shell} data-detail={!atIndex}>
      <nav className={nav.sidebar} aria-label={t("web-pages.admin.title")}>
        <ResizeHandle variable="--sidebar-w" edge="right" min={180} max={480} label={t("web-pages.workspace.resizeSidebar")} />
        <div className={`${nav.brand} ${nav.brandCompact}`}><Wordmark size={24} /></div>
        <div className={nav.navScroll}>
          <div className={nav.navHeading}>{t("web-pages.admin.title")}</div>
          <NavRow to="/overview"><Monitor {...ICON} />{t("web-pages.admin.overview")}</NavRow>
          <NavRow to="/users"><Users {...ICON} />{t("web-pages.admin.users")}</NavRow>
          <NavRow to="/workspaces"><Boxes {...ICON} />Workspace</NavRow>
          <NavRow to="/codes"><Ticket {...ICON} />{t("web-pages.cloud.inviteCode")}</NavRow>
          <NavRow to="/feedback"><Said {...ICON} />{t("web-pages.admin.feedback")}</NavRow>
          <NavRow to="/relays"><Server {...ICON} />{t("web-pages.admin.relays")}</NavRow>
          <NavRow to="/keys"><Key {...ICON} />{t("web-pages.admin.keys")}</NavRow>
          <NavRow to="/audit"><ListIcon {...ICON} />{t("web-pages.admin.audit")}</NavRow>
        </div>
        <div className={`${nav.navFootRow} ${css.adminFoot}`}>
          <span className={css.adminAccount}><Avatar account={account} size={20} /><span className={css.accountEmail}>{account.email}</span></span>
          <IconButton label={t("web-pages.admin.signOut")} icon={LogOut} busy={signOut.busy(account.sub)} onClick={() => void signOut.signOut(account.sub)} />
        </div>
      </nav>
      <main className={shellCss.main}>
        <Routes>
          <Route path="/">{narrow() ? null : <Redirect to="/overview" replace />}</Route>
          <Route path="/overview"><OverviewPage account={account} /></Route>
          <Route path="/users/:id?"><ListPage account={account} list="users" /></Route>
          <Route path="/workspaces/:id?"><ListPage account={account} list="workspaces" /></Route>
          <Route path="/codes"><ListPage account={account} list="invite-codes" /></Route>
          <Route path="/feedback/:id?"><ListPage account={account} list="feedback" /></Route>
          <Route path="/relays"><RelaysPage account={account} /></Route>
          <Route path="/keys"><ListPage account={account} list="keys" /></Route>
          <Route path="/audit"><ListPage account={account} list="audit" /></Route>
          <Route><Redirect to="/" replace /></Route>
        </Routes>
      </main>
    </div>
  );
}

/** A row of the sidebar, marked while its page (or one under it) is open. */
function NavRow({ to, children }: { to: string; children: ReactNode }) {
  const [open] = useRoute(`${to}/*?`);
  return <Link className={nav.navRow} to={to} aria-current={open ? "page" : undefined}>{children}</Link>;
}

// ── the overview ────────────────────────────────────────────────────────

function OverviewPage({ account }: { account: Account }) {
  const { value: view, error } = useKept<Overview>({ topic: "adminOverview", account: account.sub });
  return (
    <div className={`${pagesCss.page} ${css.mid}`}>
      <MobileBack to="/" label={t("web-pages.admin.title")} />
      <header className={pagesCss.pageHead}><div><h1>{t("web-pages.admin.overview")}</h1></div></header>
      <Failed error={error} />
      {!view ? !error && <Waiting sample={<OverviewBody view={SAMPLE_OVERVIEW} />} /> : <OverviewBody view={view} />}
    </div>
  );
}

/** The overview under its title (`view`): its numbers, each opening its list; the weeks' sign-ups; what needs doing. */
function OverviewBody({ view }: { view: Overview }) {
  const max = Math.max(1, ...view.weeks.map((w) => w.count));
  return (
    <>
    <div className={css.stats}>
      {view.stats.map((s) => (
        <Link key={s.label} className={css.stat} to={`${PATH[s.list]}?filter=${s.filter}`}>
          <span className={shellCss.muted}>{s.label}</span>
          <span className={css.statValue}>{s.value}</span>
          <span className={css.statNote}>{s.note}</span>
        </Link>
      ))}
    </div>
    <section className={css.chart} aria-label={t("web-pages.admin.weekly")}>
      <div className={css.chartHead}><b>{t("web-pages.admin.weekly")}</b><span className={shellCss.muted}>{t("web-pages.admin.last12")}</span></div>
      <div className={css.bars}>
        {view.weeks.map((w, i) => (
          <div key={i} className={css.bar} title={t("web-pages.admin.weekBar", { week: w.label, n: w.count })}>
            <span className={css.barCount}>{w.count || ""}</span>
            <span className={css.barFill} data-now={i === view.weeks.length - 1 || undefined} style={{ height: `${(w.count / max) * 100}%` }} />
            <span className={css.barLabel}>{w.label}</span>
          </div>
        ))}
      </div>
    </section>
    {view.todo.length > 0 && <>
      <h2 className={css.h2}>{t("web-pages.admin.todo")}</h2>
      <div className={css.list}>
        {view.todo.map((t) => (
          <Link key={t.text} className={css.todo} to={`${PATH[t.list]}?filter=${t.filter}`}>
            <StatusDot state={t.tone === "amber" ? "busy" : "offline"} />
            <span className={css.todoText}>{t.text}</span>
            <span className={css.todoHint}>{t.hint}</span>
            <ChevronRight {...ICON} />
          </Link>
        ))}
      </div>
    </>}
    </>
  );
}

// ── the lists ───────────────────────────────────────────────────────────

// Getters: read in the language at the time.
const TITLE: Record<List, string> = {
  get users() { return t("web-pages.admin.users"); }, workspaces: "Workspace",
  get "invite-codes"() { return t("web-pages.cloud.inviteCode"); }, get feedback() { return t("web-pages.admin.feedback"); },
  get audit() { return t("web-pages.admin.audit"); }, get keys() { return t("web-pages.admin.keys"); },
};
const PLACEHOLDER: Record<List, string> = {
  get users() { return t("web-pages.admin.search.users"); }, get workspaces() { return t("web-pages.admin.search.workspaces"); },
  get "invite-codes"() { return t("web-pages.admin.search.codes"); }, get feedback() { return t("web-pages.admin.search.feedback"); },
  get audit() { return t("web-pages.admin.search.audit"); }, get keys() { return t("web-pages.admin.search.keys"); },
};
const STEP = 50;

function ListPage({ account, list }: { account: Account; list: List }) {
  const { id } = useParams<{ id?: string }>();
  const [params, setParams] = useSearchParams();
  const query = params.get("q") ?? "";
  const filter = params.get("filter") ?? undefined;
  const sort = params.get("sort") ?? undefined;
  const [limit, setLimit] = useState(STEP);
  useEffect(() => setLimit(STEP), [list, query, filter, sort]);
  const { value: view, error } = useKept<ListView>({ topic: "adminList", account: account.sub, list, query, ...(filter ? { filter } : {}), ...(sort ? { sort } : {}), limit });
  const set = (key: string, value: string | null) => setParams((p) => { const next = new URLSearchParams(p); if (value) next.set(key, value); else next.delete(key); return next; }, { replace: true });
  const [making, setMaking] = useState(false);
  const [makingKey, setMakingKey] = useState(false);
  const [granting, setGranting] = useState(false);
  const [creating, setCreating] = useState(false);
  const search = params.toString() ? `?${params}` : "";
  const detail = id && list !== "invite-codes" && list !== "audit" && list !== "keys";
  // A report's list is narrowed by its area too, said after its tab in the one filter (views/admin.ts: `new@android`).
  const [tab, area] = filter?.includes("@") ? [filter.slice(0, filter.indexOf("@")), filter.slice(filter.indexOf("@") + 1)] : [filter ?? "", ""];
  const setFilter = (nextTab: string, nextArea: string) => set("filter", nextArea ? `${nextTab === "all" ? "" : nextTab}@${nextArea}` : nextTab === "all" || nextTab === "" ? null : nextTab);
  return (
    <div className={css.split} data-open={detail || undefined}>
      <div className={`${pagesCss.page} ${css.listPage}`}>
        <MobileBack to="/" label={t("web-pages.admin.title")} />
        <header className={pagesCss.pageHead}>
          <div><h1>{TITLE[list]}{view && <span className={css.total}>{view.total}</span>}</h1></div>
          {list === "invite-codes" && <Button icon={Plus} variant="primary" onClick={() => setMaking(true)}>{t("web-pages.admin.code.make")}</Button>}
          {list === "keys" && <Button icon={Plus} variant="primary" onClick={() => setMakingKey(true)}>{t("web-pages.admin.key.make")}</Button>}
          {list === "users" && <Button icon={Plus} onClick={() => setGranting(true)}>{t("web-pages.admin.pending.add")}</Button>}
          {list === "workspaces" && <Button icon={Plus} onClick={() => setCreating(true)}>{t("web-pages.admin.ws.new")}</Button>}
        </header>
        <div className={css.toolbar}>
          <SearchInput className={css.search} value={query} placeholder={PLACEHOLDER[list]} label={t("web-pages.admin.search")} onChange={(v) => set("q", v)} clearable />
          {view?.areas && (
            <span className={css.sort}>
              <Select value={view.area ?? ""} onChange={(v) => setFilter(tab, v)} label={t("web-pages.admin.fb.area")}
                options={view.areas.map((a) => ({ value: a.id, label: a.id === "" ? a.label : `${a.label} ${a.count}` }))} />
            </span>
          )}
          {view && view.sorts.length > 1 && (
            <label className={css.sort}>
              <span className={`${shellCss.muted} ${css.sortBy}`}>{t("web-pages.admin.sortBy")}</span>
              <Select value={view.sort} onChange={(v) => set("sort", v === view.sorts[0]!.id ? null : v)} label={t("web-pages.admin.sort")} options={view.sorts.map((s) => ({ value: s.id, label: s.label }))} />
            </label>
          )}
        </div>
        {view && (
          <FilterPills className={css.filters} items={view.filters} value={view.filter} onChange={(id) => setFilter(id, area)} />
        )}
        {/* A still.fail cloud from before bug reports has no such list. */}
        {list === "feedback" && error?.status === 404 ? <p className={css.empty}>{t("web-pages.admin.noFeedback")}</p> : <Failed error={error} />}
        {!view ? !error && <Waiting sample={<div className={css.list}>{sampleRows(list).map((row) => list === "invite-codes"
          ? <CodeRow key={row.id} account={account} row={row} />
          : list === "keys" ? <KeyRow key={row.id} account={account} row={row} />
          : list === "audit" ? <AuditRow key={row.id} row={row} /> : <ItemRow key={row.id} list={list} row={row} open={false} to="" />)}</div>} />
          : view.rows.length === 0 ? (
          <p className={css.empty}>{query ? t("web-pages.admin.notFound") : t("web-pages.admin.empty")}</p>
        ) : (
          <div className={css.list}>
            {view.rows.map((row) => list === "invite-codes"
              ? <CodeRow key={row.id} account={account} row={row} />
              : list === "keys" ? <KeyRow key={row.id} account={account} row={row} />
              : list === "audit" ? <AuditRow key={row.id} row={row} />
              : <ItemRow key={row.id} list={list} row={row} sort={view.sort} open={row.id === id} to={`${PATH[list]}/${encodeURIComponent(row.id)}${search}`} />)}
            {view.more && <button className={css.more} onClick={() => setLimit((n) => n + STEP)}>{t("web-pages.admin.more", { n: Math.min(STEP, view.found - view.rows.length), total: view.found })}</button>}
          </div>
        )}
      </div>
      {detail && (list === "users"
        ? <UserDetail key={id} account={account} id={id} close={`${PATH.users}${search}`} search={search} />
        : list === "feedback"
          ? <FeedbackDetail key={id} account={account} id={id} close={`${PATH.feedback}${search}`} />
          : <WorkspaceDetail key={id} account={account} id={id} close={`${PATH.workspaces}${search}`} />)}
      {making && <NewCodeDialog account={account} onClose={() => setMaking(false)} />}
      {makingKey && <NewKeyDialog account={account} onClose={() => setMakingKey(false)} />}
      {granting && <PendingDialog account={account} search={search} onClose={() => setGranting(false)} />}
      {creating && <NewWorkspaceDialog account={account} search={search} onClose={() => setCreating(false)} />}
    </div>
  );
}

/** An invite code's links, this console's product's first (the cloud lists its own first: monoid's, on still.fail's console too). */
function ownFirst<L extends { product: string }>(links: L[]): L[] {
  return [...links.filter((l) => l.product === NAME), ...links.filter((l) => l.product !== NAME)];
}

/** A user, a workspace or a bug report: two lines, what is off marked, when it was last seen (sent; by the order of
 * when each last changed, when it last did) at the end. */
function ItemRow({ list, row, sort, open, to }: { list: List; row: Row; sort?: string; open: boolean; to: string }) {
  const feedback = list === "feedback";
  return (
    <Link className={css.row} to={open ? to.replace(/\/[^/?]+(\?|$)/, "$1") : to} aria-current={open ? "page" : undefined}>
      {feedback ? null : row.person ? <Avatar account={row.person} size={28} /> : <span className={css.wsMark}>{[...row.title][0]}</span>}
      <span className={css.rowText}>
        <span className={css.rowLine1}>
          {feedback && <span className={`${shellCss.mono} ${shellCss.muted} ${css.fbNumber}`}>{row.number}</span>}
          <b className={feedback ? css.fbTitle : undefined}>{row.title}</b>
          <span className={css.rowTail}>
            <Marks marks={row.marks} />
            <span className={css.rowTime}>
              {list === "workspaces" && row.state && <StatusDot state={row.state as Presence} />}
              {feedback ? <Time stamp={(sort === "updated" ? stamp(row, "updated_at") : undefined) ?? stamp(row, "created_at")} fixed />
                : stamp(row, "last_seen") ? <Time stamp={stamp(row, "last_seen")} fixed /> : list === "users" ? t("web-pages.admin.neverSeen") : ""}
            </span>
          </span>
        </span>
        <span className={css.rowLine2}>{row.line}</span>
      </span>
    </Link>
  );
}

function CodeRow({ account, row }: { account: Account; row: Row }) {
  const toast = useToast();
  const [revoking, setRevoking] = useState(false);
  const revoke = useAction(() => admin.revokeCode(account.sub, row.id), () => toast(t("web-pages.admin.code.revoked")));
  const copyUrl = (url: string) => void navigator.clipboard.writeText(url).then(() => toast(t("web-pages.admin.code.linkCopied")), (e: unknown) => toast(t("web-pages.admin.copyFailed", { error: failure(e) })));
  const at = row.state === "used" ? stamp(row, "used_at") : row.state === "revoked" ? stamp(row, "revoked_at") : stamp(row, "created_at");
  return (
    <div className={css.row} data-static>
      <span className={css.rowText}>
        <span className={css.rowLine1}>
          <b className={`${shellCss.mono} ${css.code}`}>{row.title}</b>
          <Marks marks={row.marks} />
          <span className={css.rowTime}>
            {row.state === "open" ? <>
              {/* Where the cloud answers as two products, each one's link (whoever it is for signs up in the app they know). */}
              {row.links && row.links.length > 1
                ? <Menu label={t("web-pages.admin.code.copyLink")} trigger={<IconButton label={t("web-pages.admin.code.copyLink")} icon={Copy} />}
                  items={ownFirst(row.links).map((l) => ({ label: t("web-pages.admin.code.copyProduct", { product: l.product }), icon: Copy, onSelect: () => copyUrl(l.url) }))} />
                : <IconButton label={t("web-pages.admin.code.copyLink")} icon={Copy} onClick={() => copyUrl(row.url ?? "")} />}
              <Button variant="ghost" busy={revoke.busy} onClick={() => setRevoking(true)}>{t("web-pages.settings.members.revoke")}</Button>
            </> : <Time stamp={at} fixed />}
          </span>
        </span>
        <span className={css.rowLine2}>{row.line || (row.state === "open" ? t("web-pages.admin.expires", { until: stamp(row, "expires_at")?.until ?? "" }) : "")}</span>
      </span>
      {/* Closes at once: its button turns until the cloud has it, a failure said by toast. */}
      <Confirm open={revoking} onClose={() => setRevoking(false)} onConfirm={() => { setRevoking(false); void revoke.run(); }}
        title={t("web-pages.admin.code.revokeConfirm", { code: row.title })} action={t("web-pages.admin.code.revoke")}
        description={t("web-pages.admin.code.revokeBody")} />
    </div>
  );
}

/** An Admin API key row: name, mono prefix, state pill, creator/usage/expiry line, and revoke action when active. */
function KeyRow({ account, row }: { account: Account; row: Row }) {
  const toast = useToast();
  const [revoking, setRevoking] = useState(false);
  const revoke = useAction(() => admin.revokeKey(account.sub, row.id), () => toast(t("web-pages.admin.key.revoked")));
  const at = row.state === "revoked" ? stamp(row, "revoked_at") : stamp(row, "created_at");
  const lastUsed = stamp(row, "last_used_at");
  const expires = stamp(row, "expires_at");
  const creator = row.line.split(" · ")[0] ?? "";
  const subline = [
    creator,
    lastUsed ? t("web-pages.admin.key.lastUsed", { ago: lastUsed.ago }) : t("web-pages.admin.key.neverUsed"),
    ...(row.state === "active"
      ? [expires ? t("web-pages.admin.expires", { until: expires.until }) : t("web-pages.admin.key.neverExpires")]
      : []),
  ].filter(Boolean).join(" · ");
  return (
    <div className={css.row} data-static>
      <span className={css.rowText}>
        <span className={css.rowLine1}>
          <b>{row.title}</b>
          {row.prefix && <span className={`${shellCss.mono} ${css.keyPrefix}`}>{row.prefix}…</span>}
          <span className={css.rowTail}>
            <Marks marks={row.marks} />
            <span className={css.rowTime}>
              {row.state === "active"
                ? <Button variant="ghost" busy={revoke.busy} onClick={() => setRevoking(true)}>{t("web-pages.admin.key.revokeShort")}</Button>
                : <Time stamp={at} fixed />}
            </span>
          </span>
        </span>
        <span className={css.rowLine2}>{subline}</span>
      </span>
      <Confirm open={revoking} onClose={() => setRevoking(false)} onConfirm={() => { setRevoking(false); void revoke.run(); }}
        title={t("web-pages.admin.key.revokeConfirm", { name: row.title })} action={t("web-pages.admin.key.revoke")}
        description={t("web-pages.admin.key.revokeBody")} />
    </div>
  );
}

/** An operator's change: what, to what, on its first line with when; who and what it said under it. */
function AuditRow({ row }: { row: Row }) {
  return (
    <div className={css.row} data-static>
      <span className={css.rowText}>
        <span className={css.rowLine1}>
          <b>{row.title}</b>
          <span className={css.rowTime}><Time stamp={stamp(row, "created_at")} fixed /></span>
        </span>
        <span className={css.rowLine2}>{row.line}</span>
      </span>
    </div>
  );
}

// ── an item's page, beside its list ─────────────────────────────────────

function UserDetail({ account, id, close, search }: { account: Account; id: string; close: string; search: string }) {
  const { value: u, error } = useKept<UserPage>({ topic: "adminItem", account: account.sub, list: "users", id });
  if (!u) return error ? <aside className={css.detail}><Failed error={error} /></aside> : <UserShown account={account} id={id} close={close} search={search} u={SAMPLE_USER} bones />;
  return <UserShown account={account} id={id} close={close} search={search} u={u} />;
}

/** A user's pane (`u`): how they came in, when, their workspaces; what they may do, and blocking them. */
function UserShown({ account, id, close, search, u, bones = false }: { account: Account; id: string; close: string; search: string; u: UserPage; bones?: boolean }) {
  const toast = useToast();
  const [, navigate] = useLocation();
  const email = id.startsWith(PENDING) ? id.slice(PENDING.length) : null;
  const mayCreate = useAction<boolean, unknown>((on) => email !== null ? admin.setPending(account.sub, email, { may_create: on }) : admin.setMayCreate(account.sub, id, on),
    (_, on) => toast(on ? t("web-pages.admin.user.mayCreateOn") : t("web-pages.admin.user.mayCreateOff")));
  const beta = useAction<boolean, unknown>((on) => email !== null ? admin.setPending(account.sub, email, { beta: on }) : admin.setBeta(account.sub, id, on),
    (_, on) => toast(on ? t("web-pages.admin.user.betaOn") : t("web-pages.admin.user.betaOff")));
  const remove = useAction(() => admin.removePending(account.sub, email ?? ""), () => { toast(t("web-pages.admin.pending.removed")); navigate(close); });
  const [blocking, setBlocking] = useState(false);
  const block = useAction((on: boolean) => admin.block(account.sub, id, on), (_, on) => toast(on ? t("web-pages.admin.user.blocked") : t("web-pages.admin.user.unblocked")));
  return (
    <Detail close={close} bones={bones} head={<>
      <Avatar account={u.person} size={40} />
      <span className={css.detailTitle}><b>{u.title}</b><span>{u.pending ? u.admission : u.email}</span></span>
    </>}>
      {u.pending ? (
        <dl className={css.kv}>
          <dt>{t("web-pages.admin.user.admission")}</dt><dd>{u.admission}<span className={shellCss.muted}> · {t("web-pages.admin.pending.lead")}</span></dd>
          <dt>{t("web-pages.admin.pending.addedAt")}</dt><dd><Time stamp={stamp(u, "created_at")} /></dd>
        </dl>
      ) : <>
      <dl className={css.kv}>
        <dt>{t("web-pages.admin.user.admission")}</dt><dd>{u.admission}{u.code && <span className={shellCss.muted}> · <span className={shellCss.mono}>{u.code}</span></span>}</dd>
        <dt>{t("web-pages.admin.user.firstSignIn")}</dt><dd><Time stamp={stamp(u, "created_at")} /></dd>
        <dt>{t("web-pages.admin.user.lastSeen")}</dt><dd>{stamp(u, "last_seen") ? <Time stamp={stamp(u, "last_seen")} /> : t("web-pages.admin.neverSeen")}</dd>
        <dt>ID</dt><dd className={`${shellCss.mono} ${shellCss.muted}`}>{u.id}</dd>
      </dl>
      <div className={css.group}>Workspace {u.workspaces.length}</div>
      {u.workspaces.length === 0 && <div className={css.line} data-quiet>{t("web-pages.admin.user.noWorkspace")}</div>}
      {u.workspaces.map((w) => (
        <Link key={w.id} className={css.line} to={`${PATH.workspaces}/${encodeURIComponent(w.id)}${search}`}>
          <span className={css.grow}>{w.name}</span><span className={css.lineAside}>{w.line}</span><ChevronRight {...ICON} />
        </Link>
      ))}
      </>}
      {!u.admin && <>
        <div className={css.group}>{t("web-pages.admin.user.rights")}</div>
        {u.mayCreate !== null && (
          <SwitchRow compact title={t("web-pages.admin.user.mayCreate")} description={u.mayCreateHint} label={t("web-pages.admin.user.mayCreate")}
            checked={mayCreate.busy ? Boolean(mayCreate.arg) : u.mayCreate} disabled={u.mayCreateFixed || mayCreate.busy} onChange={(on) => mayCreate.run(on)} />
        )}
        {u.beta !== null && (
          <SwitchRow compact title={t("web-pages.admin.user.beta")} description={t("web-pages.admin.user.betaHint")} label={t("web-pages.admin.user.beta")}
            checked={beta.busy ? Boolean(beta.arg) : u.beta} disabled={beta.busy} onChange={(on) => beta.run(on)} />
        )}
        {/* (not one's own: the cloud refuses it, and nobody is to lock themselves out of the console) */}
        {u.blocked !== null && u.id !== account.sub && (
          <div className={css.actions}>
            {u.blocked
              ? <Button busy={block.busy} onClick={() => block.run(false)}>{t("web-pages.admin.user.unblock")}</Button>
              : <Button variant="danger" busy={block.busy} onClick={() => setBlocking(true)}>{t("web-pages.admin.user.block")}</Button>}
          </div>
        )}
        {u.pending && (
          <div className={css.actions}>
            <Button busy={remove.busy} onClick={() => remove.run()}>{t("web-pages.admin.pending.remove")}</Button>
          </div>
        )}
        {block.error && <ErrorLine>{block.error.message}</ErrorLine>}
      </>}
      {/* Closes at once: the block button turns until the cloud has it, a failure said by toast. */}
      <Confirm open={blocking} onClose={() => setBlocking(false)} onConfirm={() => { setBlocking(false); void block.run(true); }}
        title={t("web-pages.admin.user.blockConfirm", { name: u.title })} action={t("web-pages.admin.user.block")}
        description={t("web-pages.admin.user.blockBody")} />
    </Detail>
  );
}

// ── a new invite code ───────────────────────────────────────────────────

const DAYS = [7, 14, 30, 90];

function NewCodeDialog({ account, onClose }: { account: Account; onClose(): void }) {
  const [note, setNote] = useState("");
  const [days, setDays] = useState("14");
  const [beta, setBeta] = useState(false);
  const make = useAction(() => admin.createCode(account.sub, note, Number(days), beta));
  const made = make.result;
  return (
    <Dialog open onClose={onClose} wide title={made ? t("web-pages.admin.code.made") : t("web-pages.admin.code.make")}
      description={made ? t("web-pages.admin.code.madeLead", { n: Number(days) }) : t("web-pages.admin.code.makeLead")}
      footer={made ? <Button variant="primary" onClick={onClose}>{t("common.done")}</Button> : <>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={make.busy} onClick={() => make.run()}>{t("web-pages.admin.code.makeShort")}</Button>
      </>}>
      {made ? (
        <>
          <Field label={t("web-pages.cloud.inviteCode")}><CopyCommand text={made.code} /></Field>
          {made.links && made.links.length > 1
            ? ownFirst(made.links).map((l, i) => (
              <Field key={l.url} label={t("web-pages.admin.code.productLink", { product: l.product })} {...(i === made.links!.length - 1 ? { hint: t("web-pages.admin.code.linkHint") } : {})}><CopyCommand text={l.url} /></Field>
            ))
            : <Field label={t("web-pages.admin.code.link")} hint={t("web-pages.admin.code.linkHint")}><CopyCommand text={made.url} /></Field>}
        </>
      ) : (
        <>
          <Field label={t("web-pages.admin.code.note")} htmlFor="code-note" hint={t("web-pages.admin.code.noteHint")}>
            <TextInput id="code-note" value={note} autoFocus maxLength={200} onChange={(e) => setNote(e.currentTarget.value)} placeholder={t("web-pages.admin.code.notePlaceholder")}
              onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing && !make.busy) make.run(); }} />
          </Field>
          <Field label={t("web-pages.admin.code.validity")}>
            <Select value={days} onChange={setDays} label={t("web-pages.admin.code.validity")} options={DAYS.map((d) => ({ value: String(d), label: t("web-pages.admin.code.days", { n: d }) }))} />
          </Field>
          <SwitchRow title={t("web-pages.admin.code.beta")} description={t("web-pages.admin.code.betaHint")} checked={beta} onChange={setBeta} />
        </>
      )}
      {make.error && <ErrorLine>{make.error.message}</ErrorLine>}
    </Dialog>
  );
}

const KEY_DAYS = [30, 90, 365];

function NewKeyDialog({ account, onClose }: { account: Account; onClose(): void }) {
  const [name, setName] = useState("");
  const [days, setDays] = useState("90");
  const make = useAction(() => admin.createKey(account.sub, name.trim(), days ? Number(days) : undefined));
  const made = make.result;
  const ready = name.trim() !== "" && !make.busy;
  return (
    <Dialog open onClose={onClose} wide title={made ? t("web-pages.admin.key.made") : t("web-pages.admin.key.make")}
      description={made ? t("web-pages.admin.key.madeLead") : t("web-pages.admin.key.makeLead")}
      footer={made ? <Button variant="primary" onClick={onClose}>{t("common.done")}</Button> : <>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={make.busy} disabled={!ready} onClick={() => make.run()}>{t("web-pages.admin.key.makeShort")}</Button>
      </>}>
      {made ? (
        <>
          <Field label={t("web-pages.admin.key.secret")}><div className={css.command}><CopyCommand text={made.key} /></div></Field>
          <div className={css.vaultTip}>
            <b>{t("web-pages.admin.key.vaultTitle")}</b>
            <span>{t("web-pages.admin.key.vaultHint")}</span>
            <ul>
              <li>{t("web-pages.admin.key.vaultKind")}</li>
              <li>{t("web-pages.admin.key.vaultHost", { host: made.host })}</li>
              <li>{t("web-pages.admin.key.vaultEnv")}</li>
            </ul>
          </div>
          <Field label={t("web-pages.admin.key.cliExample")}><div className={css.command}><CopyCommand text={`STILLFAIL_ADMIN_ORIGIN=${made.origin} stillfail admin whoami`} /></div></Field>
        </>
      ) : (
        <>
          <Field label={t("web-pages.admin.key.name")} htmlFor="key-name">
            <TextInput id="key-name" value={name} autoFocus maxLength={80} onChange={(e) => setName(e.currentTarget.value)} placeholder={t("web-pages.admin.key.namePlaceholder")}
              onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing && ready) make.run(); }} />
          </Field>
          <Field label={t("web-pages.admin.key.validity")}>
            <Select value={days} onChange={setDays} label={t("web-pages.admin.key.validity")} options={[
              ...KEY_DAYS.map((d) => ({ value: String(d), label: t("web-pages.admin.code.days", { n: d }) })),
              { value: "", label: t("web-pages.admin.key.never") },
            ]} />
          </Field>
        </>
      )}
      {make.error && <ErrorLine>{make.error.message}</ErrorLine>}
    </Dialog>
  );
}

/** Gives an email rights before anyone signed in with it; opens its page (an account's, if one has signed in with it). */
function PendingDialog({ account, search, onClose }: { account: Account; search: string; onClose(): void }) {
  const toast = useToast();
  const [, navigate] = useLocation();
  const [email, setEmail] = useState("");
  const [beta, setBeta] = useState(true);
  const [mayCreate, setMayCreate] = useState(false);
  // Only what is switched on: an account already signed in with the email keeps what it has besides.
  const add = useAction(() => admin.setPending(account.sub, email, { ...(beta ? { beta } : {}), ...(mayCreate ? { may_create: mayCreate } : {}) }), (made) => {
    toast(made.sub !== null ? t("web-pages.admin.pending.known") : t("web-pages.admin.pending.added"));
    navigate(`${PATH.users}/${encodeURIComponent(made.sub ?? `${PENDING}${made.email}`)}${search}`);
    onClose();
  });
  const ready = email.trim() !== "" && (beta || mayCreate) && !add.busy;
  return (
    <Dialog open onClose={onClose} title={t("web-pages.admin.pending.add")} description={t("web-pages.admin.pending.addLead")}
      footer={<>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={add.busy} disabled={!ready} onClick={() => add.run()}>{t("web-pages.admin.pending.addShort")}</Button>
      </>}>
      <Field label={t("web-pages.admin.pending.email")} htmlFor="pending-email">
        <TextInput id="pending-email" type="email" value={email} autoFocus maxLength={255} placeholder="name@example.com" onChange={(e) => setEmail(e.currentTarget.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing && ready) add.run(); }} />
      </Field>
      <SwitchRow title={t("web-pages.admin.user.beta")} description={t("web-pages.admin.user.betaHint")} checked={beta} onChange={setBeta} />
      <SwitchRow title={t("web-pages.admin.user.mayCreate")} description={t("web-pages.admin.pending.mayCreateHint")} checked={mayCreate} onChange={setMayCreate} />
      {add.error && <ErrorLine>{add.error.message}</ErrorLine>}
    </Dialog>
  );
}
