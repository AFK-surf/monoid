// A workspace's pane and what the admin does to one: who made it, its plan, its people, stations, machines that only
// run tasks and invitations; owners put in, an email added taken back, a station's install command for each system, its
// limits (or back to its creator's plan), deleting it. And a workspace made for a company.
import { useState } from "preact/hooks";
import { Link, useLocation } from "wouter-preact";
import { ChevronRight, Close, Plus, UserPlus } from "@stillfail/ui/icons.tsx";
import { useToast } from "@stillfail/ui/toast.tsx";
import { stamp } from "../api.ts";
import type { Account } from "../cloud/accounts.ts";
import { admin, useAction } from "../cloud/api.ts";
import { Avatar } from "../cloud/gate.tsx";
import { Button, Confirm, CopyCommand, Dialog, Field, ICON, IconButton, Segmented, StatusDot, Time, ErrorLine, TextInput } from "../ui.tsx";
import * as shellCss from "../styles/shell.css.ts";
import { t } from "../i18n.ts";
import { STATIONS_PER_WORKSPACE } from "../../../client/limits.ts";
import * as css from "./console.css.ts";
import { Detail, Failed, PATH, SAMPLE_WORKSPACE, useKept } from "./shared.tsx";
import type { Machine, WorkspacePage } from "./types.ts";

export function WorkspaceDetail({ account, id, close }: { account: Account; id: string; close: string }) {
  const { value: w, error } = useKept<WorkspacePage>({ topic: "adminItem", account: account.sub, list: "workspaces", id });
  if (!w) return error ? <aside className={css.detail}><Failed error={error} /></aside> : <WorkspaceShown account={account} id={id} close={close} w={SAMPLE_WORKSPACE} bones />;
  return <WorkspaceShown account={account} id={id} close={close} w={w} />;
}

/** A station's line, or a rig's (whose it is before its version): how it last stood, its version, when it last came. */
function MachineLine({ m, owner }: { m: Machine; owner?: string }) {
  return (
    // still.fail cloud only knows when a station last came to it; whether it is up is for the devices to find out.
    <div className={css.line}>
      <StatusDot state={m.state} />
      <span className={css.grow}>{m.name}</span>
      <span className={css.lineAside}>
        {owner && <>{owner} · </>}
        <span data-off={m.outdated || undefined}>{m.version ?? t("web-pages.admin.ws.versionUnknown")}</span> · {stamp(m, "last_seen") ? <Time stamp={stamp(m, "last_seen")} fixed /> : t("web-pages.admin.ws.neverConnected")}
      </span>
    </div>
  );
}

function WorkspaceShown({ account, id, close, w, bones = false }: { account: Account; id: string; close: string; w: WorkspacePage; bones?: boolean }) {
  const toast = useToast();
  const [, navigate] = useLocation();
  const [deleting, setDeleting] = useState(false);
  const [enrolling, setEnrolling] = useState(false);
  const [limiting, setLimiting] = useState(false);
  const [owning, setOwning] = useState(false);
  const [unadding, setUnadding] = useState<string | null>(null);
  const remove = useAction(() => admin.deleteWorkspace(account.sub, id), () => toast(t("web-pages.settings.workspace.deleted")));
  const unadd = useAction((email: string) => admin.removeAdded(account.sub, id, email), () => toast(t("web-pages.admin.ws.addedRemoved")));
  const rigs = w.rigs ?? [];
  return (
    <Detail close={close} bones={bones} head={<>
      <span className={`${css.wsMark} ${css.wsMarkLarge}`}>{[...w.title][0]}</span>
      <span className={css.detailTitle}><b>{w.title}</b><span className={shellCss.mono}>{w.id}</span></span>
    </>}>
      <dl className={css.kv}>
        <dt>{t("web-pages.chat.info.created")}</dt><dd>{w.creator ? <Link className={css.link} to={`${PATH.users}/${encodeURIComponent(w.creator.id)}`}>{w.creator.title}</Link> : t("web-pages.admin.ws.gone")} · <Time stamp={stamp(w, "created_at")} /></dd>
        {w.plan && <><dt>{t("web-pages.admin.ws.plan")}</dt><dd>{w.plan}</dd></>}
        <dt>{t("web-pages.admin.ws.people")}</dt><dd>{w.people}</dd>
        {w.stationCount !== undefined && <><dt>Station</dt><dd>{w.stationCount}</dd></>}
      </dl>
      <div className={css.group}>{t("web-pages.admin.ws.members", { n: w.members.length })}</div>
      {w.members.map((m) => (
        <Link key={m.id} className={css.line} to={`${PATH.users}/${encodeURIComponent(m.id)}`}>
          <Avatar account={m.person} size={20} />
          <span className={css.grow}>{m.title}</span>
          <span className={css.lineAside}>{m.role}{stamp(m, "last_seen") && <> · <Time stamp={stamp(m, "last_seen")} fixed /></>}</span>
          <ChevronRight {...ICON} />
        </Link>
      ))}
      {w.added && w.added.length > 0 && <>
        <div className={css.group}>{t("web-pages.admin.ws.added", { n: w.added.length })}</div>
        {w.added.map((a) => (
          <div key={a.id} className={css.line} data-tight>
            <span className={css.grow}>{a.email}</span>
            <span className={css.lineAside}>{a.line}</span>
            <IconButton label={t("web-pages.admin.ws.removeAdded", { email: a.email })} icon={Close} busy={unadd.busy && unadd.arg === a.email} onClick={() => setUnadding(a.email)} />
          </div>
        ))}
      </>}
      <div className={css.group}>Station {w.stations.length}</div>
      {w.stations.length === 0 && <div className={css.line} data-quiet>{t("web-pages.admin.ws.noStations")}</div>}
      {w.stations.map((s) => <MachineLine key={s.id} m={s} />)}
      {rigs.length > 0 && <>
        <div className={css.group}>{t("web-pages.admin.ws.rigs", { n: rigs.length })}</div>
        {rigs.map((r) => <MachineLine key={r.id} m={r} owner={r.ownerTitle} />)}
      </>}
      {w.invitations.length > 0 && <>
        <div className={css.group}>{t("web-pages.admin.ws.invitations", { n: w.invitations.length })}</div>
        {w.invitations.map((i) => (
          <div key={i.id} className={css.line}>
            <span className={css.grow}>{i.email}</span>
            <span className={css.lineAside}>{i.line} · {t("web-pages.admin.expires", { until: stamp(i, "expires_at")?.until ?? "" })}</span>
          </div>
        ))}
      </>}
      <div className={css.actions}>
        {w.enrollable && <Button icon={Plus} onClick={() => setEnrolling(true)}>{t("web-pages.admin.ws.addStation")}</Button>}
        {/* (a core from before says no plan: nor would its cloud take owners put in) */}
        {w.customLimits !== undefined && <Button icon={UserPlus} onClick={() => setOwning(true)}>{t("web-pages.admin.ws.addOwners")}</Button>}
        {w.limits && <Button onClick={() => setLimiting(true)}>{t("web-pages.admin.ws.limits")}</Button>}
        <Button variant="danger" onClick={() => setDeleting(true)}>{t("web-pages.settings.workspace.delete")}</Button>
      </div>
      {enrolling && <EnrollDialog account={account} workspace={id} onClose={() => setEnrolling(false)} />}
      {owning && <AddOwnersDialog account={account} workspace={id} onClose={() => setOwning(false)} />}
      {limiting && w.limits && <LimitsDialog account={account} workspace={id} limits={w.limits} custom={w.customLimits === true} onClose={() => setLimiting(false)} />}
      <Confirm open={unadding !== null} onClose={() => setUnadding(null)} onConfirm={() => { const email = unadding!; setUnadding(null); void unadd.run(email); }}
        title={t("web-pages.admin.ws.removeAddedConfirm", { email: unadding ?? "" })} action={t("web-pages.admin.pending.remove")}
        description={t("web-pages.admin.ws.removeAddedBody")} />
      {/* Back to the list at once: it goes on by itself, a failure said by toast. */}
      <Confirm open={deleting} onClose={() => setDeleting(false)} onConfirm={() => { setDeleting(false); navigate(close, { replace: true }); void remove.run(); }}
        title={t("web-pages.settings.workspace.deleteConfirm", { name: w.title })} action={t("web-pages.settings.workspace.delete")}
        description={t("web-pages.admin.ws.deleteBody")} />
    </Detail>
  );
}

/** Emails as typed: split at commas, semicolons and spaces. */
const emailsIn = (text: string) => text.split(/[\s,，;；]+/).filter(Boolean);

/** Whole numbers from 1 to the most the cloud takes (directory.ts LIMITS_MAX), or null. */
const limit = (text: string, max: number): number | null => (/^[0-9]{1,4}$/.test(text.trim()) && Number(text) >= 1 && Number(text) <= max ? Number(text) : null);
const MAX = { members: 1000 };

function LimitFields({ members, setMembers, submit }: { members: string; setMembers(v: string): void; submit(): void }) {
  const enter = (e: React.KeyboardEvent<HTMLElement>) => { if (e.key === "Enter" && !e.isComposing) submit(); };
  return (
    <>
      <Field label={t("web-pages.admin.ws.memberLimit")} htmlFor="limit-members" hint={t("web-pages.admin.ws.limitHint", { max: MAX.members })}>
        <TextInput id="limit-members" inputMode="numeric" value={members} onChange={(e) => setMembers(e.currentTarget.value)} onKeyDown={enter} />
      </Field>
      <Field label={t("web-pages.admin.ws.stationLimit")} htmlFor="limit-stations" hint={t("web-pages.admin.ws.stationFixed", { n: STATIONS_PER_WORKSPACE })}>
        <TextInput id="limit-stations" value={STATIONS_PER_WORKSPACE} readOnly />
      </Field>
    </>
  );
}

/** Makes a workspace for a company: its name, its owners by email, its limits; opens its page. */
export function NewWorkspaceDialog({ account, search, onClose }: { account: Account; search: string; onClose(): void }) {
  const toast = useToast();
  const [, navigate] = useLocation();
  const [name, setName] = useState("");
  const [owners, setOwners] = useState("");
  const [members, setMembers] = useState("20");
  const emails = emailsIn(owners);
  const cap = limit(members, MAX.members);
  const create = useAction(() => admin.createWorkspace(account.sub, { name: name.trim(), owners: emails, members: cap!, stations: STATIONS_PER_WORKSPACE }), (made) => {
    toast(t("web-pages.admin.ws.created"));
    navigate(`${PATH.workspaces}/${encodeURIComponent(made.id)}${search}`);
    onClose();
  });
  const ready = name.trim() !== "" && emails.length > 0 && cap !== null && !create.busy;
  const submit = () => { if (ready) create.run(); };
  return (
    <Dialog open onClose={onClose} title={t("web-pages.admin.ws.new")} description={t("web-pages.admin.ws.newLead")}
      footer={<>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={create.busy} disabled={!ready} onClick={submit}>{t("web-pages.admin.ws.create")}</Button>
      </>}>
      <Field label={t("web-pages.admin.ws.name")} htmlFor="ws-name">
        <TextInput id="ws-name" value={name} autoFocus maxLength={80} onChange={(e) => setName(e.currentTarget.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing) submit(); }} />
      </Field>
      <Field label={t("web-pages.admin.ws.owners")} htmlFor="ws-owners" hint={t("web-pages.admin.ws.ownersHint")}>
        <TextInput id="ws-owners" inputMode="email" autoComplete="off" spellcheck={false} value={owners} placeholder="name@example.com" onChange={(e) => setOwners(e.currentTarget.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing) submit(); }} />
      </Field>
      <LimitFields members={members} setMembers={setMembers} submit={submit} />
      {create.error && <ErrorLine>{create.error.message}</ErrorLine>}
    </Dialog>
  );
}

/** Its limits; one with limits of its own given back to its creator's plan. */
function LimitsDialog({ account, workspace, limits, custom, onClose }: { account: Account; workspace: string; limits: { members: number; stations: number | null }; custom: boolean; onClose(): void }) {
  const toast = useToast();
  const [members, setMembers] = useState(String(limits.members));
  const cap = limit(members, MAX.members);
  const save = useAction(() => admin.setLimits(account.sub, workspace, { members: cap!, stations: STATIONS_PER_WORKSPACE }), () => { toast(t("web-pages.admin.ws.limitsSaved")); onClose(); });
  const reset = useAction(() => admin.setLimits(account.sub, workspace, { reset: true }), () => { toast(t("web-pages.admin.ws.limitsReset")); onClose(); });
  const ready = cap !== null && !save.busy && !reset.busy;
  const submit = () => { if (ready) save.run(); };
  const error = save.error ?? reset.error;
  return (
    <Dialog open onClose={onClose} title={t("web-pages.admin.ws.limits")} description={t("web-pages.admin.ws.limitsLead")}
      footer={<>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={save.busy} disabled={!ready} onClick={submit}>{t("common.save")}</Button>
      </>}>
      <LimitFields members={members} setMembers={setMembers} submit={submit} />
      {/* (in the form, not the footer: the footer keeps its two, which fit a phone's width) */}
      {custom && (
        <div className={css.resetLimits}>
          <span className={css.hint}>{t("web-pages.admin.ws.resetHint")}</span>
          <Button busy={reset.busy} disabled={save.busy} onClick={() => reset.run()}>{t("web-pages.admin.ws.resetLimits")}</Button>
        </div>
      )}
      {error && <ErrorLine>{error.message}</ErrorLine>}
    </Dialog>
  );
}

/** Owners put in by the admin, not in the workspace (a company whose owner left): by email. */
function AddOwnersDialog({ account, workspace, onClose }: { account: Account; workspace: string; onClose(): void }) {
  const toast = useToast();
  const [owners, setOwners] = useState("");
  const emails = emailsIn(owners);
  const add = useAction(() => admin.addOwners(account.sub, workspace, emails), (made) => {
    toast(made.added.length > 0 ? t("web-pages.admin.ws.ownersAdded") : t("web-pages.admin.ws.ownersJoined"));
    onClose();
  });
  const ready = emails.length > 0 && !add.busy;
  const submit = () => { if (ready) add.run(); };
  return (
    <Dialog open onClose={onClose} title={t("web-pages.admin.ws.addOwners")} description={t("web-pages.admin.ws.addOwnersLead")}
      footer={<>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={add.busy} disabled={!ready} onClick={submit}>{t("web-pages.admin.pending.addShort")}</Button>
      </>}>
      <Field label={t("web-pages.admin.ws.owners")} htmlFor="ws-add-owners" hint={t("web-pages.admin.ws.ownersHint")}>
        <TextInput id="ws-add-owners" inputMode="email" autoComplete="off" spellcheck={false} autoFocus value={owners} placeholder="name@example.com"
          onChange={(e) => setOwners(e.currentTarget.value)} onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing) submit(); }} />
      </Field>
      {add.error && <ErrorLine>{add.error.message}</ErrorLine>}
    </Dialog>
  );
}

type Platform = "unix" | "windows" | "docker" | "cli";

/** A station's install command for the workspace, the admin not in it: its name first; then the command for each system. */
function EnrollDialog({ account, workspace, onClose }: { account: Account; workspace: string; onClose(): void }) {
  const [name, setName] = useState("");
  const [platform, setPlatform] = useState<Platform>("unix");
  const make = useAction(() => admin.enroll(account.sub, workspace, name.trim()));
  const made = make.result;
  const ready = name.trim() !== "" && !make.busy;
  // (a cloud from before gives the shell's alone)
  const commands: { value: Platform; label: string; text: string | undefined }[] = made ? [
    { value: "unix", label: "macOS / Linux", text: made.install },
    { value: "windows", label: "Windows", text: made.installWindows },
    { value: "docker", label: "Docker", text: made.installDocker },
    { value: "cli", label: t("web-pages.admin.ws.platformCli"), text: made.command },
  ] : [];
  const offered = commands.filter((c): c is typeof c & { text: string } => typeof c.text === "string" && c.text !== "");
  const shown = offered.find((c) => c.value === platform) ?? offered[0];
  return (
    <Dialog open onClose={onClose} wide title={t("web-pages.admin.ws.addStation")} description={made ? t("web-pages.admin.ws.commandLead") : t("web-pages.admin.ws.addStationLead")}
      footer={made ? <Button variant="primary" onClick={onClose}>{t("common.done")}</Button> : <>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={make.busy} disabled={!ready} onClick={() => make.run()}>{t("web-pages.admin.ws.makeCommand")}</Button>
      </>}>
      {made && shown ? (
        <>
          {offered.length > 1 && <Segmented<Platform> label={t("web-pages.admin.ws.platform")} value={shown.value} onChange={setPlatform} options={offered.map((c) => ({ value: c.value, label: c.label }))} />}
          <Field label={t("web-pages.settings.enroll.run")}><div className={css.command}><CopyCommand text={shown.text} /></div></Field>
        </>
      ) : (
        <Field label={t("web-pages.admin.ws.stationName")} htmlFor="station-name">
          <TextInput id="station-name" value={name} autoFocus maxLength={80} placeholder="Mac mini" onChange={(e) => setName(e.currentTarget.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing && ready) make.run(); }} />
        </Field>
      )}
      {make.error && <ErrorLine>{make.error.message}</ErrorLine>}
    </Dialog>
  );
}
