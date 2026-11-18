// still.fail's relays, a card each: how each stands, its numbers, what the probes from China's carriers and Hong Kong
// found of it, and its load over the range picked (in the URL); the cloud's list kept from here: a token for a relay
// (or for a way into one) to put itself on it, one not used taken back, a relay named anew or taken off.
import { useState } from "preact/hooks";
import { Fragment } from "preact/compat";
import { useSearchParams } from "wouter-preact";
import { Close, Edit, Plus, Trash } from "@stillfail/ui/icons.tsx";
import { useToast } from "@stillfail/ui/toast.tsx";
import type { Account } from "../cloud/accounts.ts";
import { admin, useAction } from "../cloud/api.ts";
import { Button, Confirm, CopyCommand, Dialog, Field, IconButton, MobileBack, Segmented, Select, StatusDot, Waiting, ErrorLine, TextInput } from "../ui.tsx";
import * as pagesCss from "../styles/pages.css.ts";
import { t } from "../i18n.ts";
import * as css from "./console.css.ts";
import { Failed, SAMPLE_RELAYS, useKept } from "./shared.tsx";
import type { Range, Relay, RelayChart, RelaysView } from "./types.ts";

export function RelaysPage({ account }: { account: Account }) {
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const [issuing, setIssuing] = useState(false);
  const [renaming, setRenaming] = useState<{ url: string; name: string; target?: string } | null>(null);
  const [removing, setRemoving] = useState<{ url: string; name: string; entry: boolean } | null>(null);
  const remove = useAction((url: string) => admin.relayRemove(account.sub, url), () => toast(t("web-pages.admin.relays.removed")));
  const revoke = useAction((id: string) => admin.relayTokenRevoke(account.sub, id), () => toast(t("web-pages.admin.relays.tokenRevoked")));
  const range = params.get("range") === "week" ? "week" : undefined;
  const { value: view, error } = useKept<RelaysView>({ topic: "adminRelays", account: account.sub, ...(range ? { range } : {}) });
  const pick = (to: Range) => setParams((p) => { const next = new URLSearchParams(p); if (to === "day") next.delete("range"); else next.set("range", to); return next; }, { replace: true });
  // A still.fail cloud from before has none.
  const none = error?.status === 404 || view?.relays.length === 0;
  // The relays a way in can be made into: each of the list (not the Directory's card).
  const targets = (view?.relays ?? []).filter((r) => r.url !== "directory").map((r) => ({ url: r.url, name: r.name }));
  return (
    <div className={`${pagesCss.page} ${css.mid}`}>
      <MobileBack to="/" label={t("web-pages.admin.title")} />
      <header className={pagesCss.pageHead}>
        <div><h1>{t("web-pages.admin.relays")}</h1></div>
        <div className={css.relaysTools}>
          {view && view.ranges.length > 1 && (
            <Segmented<Range> label={t("web-pages.admin.relays.range")} value={view.range} onChange={pick} options={view.ranges.map((r) => ({ value: r.id, label: r.label }))} />
          )}
          {view?.manage && <Button icon={Plus} variant="primary" onClick={() => setIssuing(true)}>{t("web-pages.admin.relays.issue")}</Button>}
        </div>
      </header>
      {none ? <p className={css.relaysNone}>{t("web-pages.admin.relays.none")}</p> : <Failed error={error} />}
      {view?.tokens && view.tokens.length > 0 && (
        <section className={`${pagesCss.card} ${css.relayTokens}`} aria-label={t("web-pages.admin.relays.waiting")}>
          <b>{t("web-pages.admin.relays.waiting")}</b>
          {view.tokens.map((k) => (
            <div key={k.key} className={`${css.line} ${css.switchLine}`} data-tight={k.id ? true : undefined}>
              <span className={css.grow}><span className={css.switchTitle}>{k.name}</span><span className={css.hint}>{k.line}</span></span>
              {k.id && <span className={css.switchBox}><IconButton label={t("web-pages.admin.relays.revokeToken")} icon={Close} busy={revoke.busy && revoke.arg === k.id} onClick={() => void revoke.run(k.id!)} /></span>}
            </div>
          ))}
        </section>
      )}
      {!view ? !error && <Waiting sample={<div className={css.relays}>{SAMPLE_RELAYS.map((r) => <RelayCard key={r.url} relay={r} />)}</div>} /> : !none && (
        <div className={css.relays}>{view.relays.map((r) => (
          <RelayCard key={r.url} relay={r} onRemove={(url, name, entry) => setRemoving({ url, name, entry })}
            onRename={(url, name, target) => setRenaming({ url, name, ...(target ? { target } : {}) })} />
        ))}</div>
      )}
      {issuing && <RelayTokenDialog account={account} targets={targets} onClose={() => setIssuing(false)} />}
      {renaming && <RenameRelayDialog account={account} relay={renaming} onClose={() => setRenaming(null)} />}
      <Confirm open={removing !== null} onClose={() => setRemoving(null)} onConfirm={() => { const r = removing!; setRemoving(null); void remove.run(r.url); }}
        title={t(removing?.entry ? "web-pages.admin.relays.removeEntryConfirm" : "web-pages.admin.relays.removeConfirm", { name: removing?.name ?? "" })}
        action={t("web-pages.admin.relays.remove")}
        description={t(removing?.entry ? "web-pages.admin.relays.removeEntryBody" : "web-pages.admin.relays.removeBody")} />
    </div>
  );
}

function RelayCard({ relay, onRemove, onRename }: { relay: Relay; onRemove?: (url: string, name: string, entry: boolean) => void; onRename?: (url: string, name: string, target?: string) => void }) {
  return (
    <section className={`${pagesCss.card} ${css.relay}`} aria-label={relay.name}>
      <div className={css.relayHead}>
        <StatusDot state={relay.state} />
        <b>{relay.name}</b>
        <span className={css.relaySeen}>{relay.seen}</span>
        {relay.editable && onRename && <IconButton label={t("web-pages.admin.relays.rename")} icon={Edit} onClick={() => onRename(relay.url, relay.name)} />}
        {relay.removable && onRemove && <IconButton label={t("web-pages.admin.relays.remove")} icon={Trash} onClick={() => onRemove(relay.url, relay.name, false)} />}
      </div>
      {(relay.how || (relay.entries && relay.entries.length > 0)) && (
        <div className={css.relayKept}>
          {relay.how && <span className={css.relayHow}>{relay.how.map((part, i) => <Fragment key={i}>{i > 0 && " · "}<span>{part}</span></Fragment>)}</span>}
          {relay.entries?.map((e) => (
            <div key={e.url} className={`${css.line} ${css.switchLine}`} data-tight={onRemove ? true : undefined}>
              <span className={css.grow}><span className={css.switchTitle}>{t("web-pages.admin.relays.entry", { name: e.name })}</span><span className={css.hint}>{e.host}</span></span>
              {(onRename || onRemove) && (
                <span className={css.switchBox}>
                  {onRename && <IconButton label={t("web-pages.admin.relays.renameEntry")} icon={Edit} onClick={() => onRename(e.url, e.name, e.target ?? relay.url)} />}
                  {onRemove && <IconButton label={t("web-pages.admin.relays.removeEntry")} icon={Close} onClick={() => onRemove(e.url, e.name, true)} />}
                </span>
              )}
            </div>
          ))}
        </div>
      )}
      {relay.numbers.length > 0 && (
        <dl className={css.relayNumbers}>
          {relay.numbers.map((n) => (
            <div key={n.label}><dt>{n.label}</dt><dd data-tone={n.tone}>{n.value}</dd></div>
          ))}
        </dl>
      )}
      {relay.probes && relay.probes.items.length > 0 && (
        <div className={css.probes}>
          <div className={css.probesHead}><b>{t("web-pages.admin.relays.probes")}</b><span>{relay.probes.seen}</span></div>
          <dl className={css.probeItems}>
            {relay.probes.items.map((p) => <div key={p.label}><dt>{p.label}</dt><dd data-tone={p.tone}>{p.value}</dd></div>)}
          </dl>
        </div>
      )}
      {relay.charts.slice(0, 1).map((c) => <LoadChart key={c.id} chart={c} ticks={relay.ticks} />)}
      {relay.charts.length > 1 && <div className={css.relayCharts}>{relay.charts.slice(1).map((c) => <LoadChart key={c.id} chart={c} ticks={relay.ticks} />)}</div>}
    </section>
  );
}

/** Each series' line, in a fixed order (the first blue, the second the accent): the same series the same colour in every chart. */
const SERIES = [css.seriesFirst, css.seriesSecond];

/**
 * One chart of a relay's load: a line for each series (a lone one with a faint wash under it: two washes over each
 * other only muddy), from 0 at the foot to the highest value of any of its series at the top (its peak, said above
 * it); a gap where a bucket has no value.
 */
function LoadChart({ chart, ticks }: { chart: RelayChart; ticks: Relay["ticks"] }) {
  const n = Math.max(1, ...chart.series.map((s) => s.values.length));
  const top = Math.max(0, ...chart.series.flatMap((s) => s.values.filter((v): v is number => v !== null)));
  // Drawn in a box 0–100 across (stretched to the chart's width; the lines keep their width) and 0–100 down.
  const x = (i: number) => (n === 1 ? 50 : (i / (n - 1)) * 100);
  const y = (v: number) => (top > 0 ? 100 - (v / top) * 100 : 100);
  return (
    <figure className={css.loadChart} aria-label={`${chart.label} · ${chart.peak}`}>
      <figcaption className={css.loadHead}>
        <b>{chart.label}</b>
        {chart.series.length > 1 && chart.series.map((s, i) => <span key={s.id} className={`${css.legend} ${SERIES[i % SERIES.length]}`}>{s.label}</span>)}
        <span className={css.peak}>{chart.peak}</span>
      </figcaption>
      <div className={css.plot}>
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
          <line className={css.rule} x1="0" x2="100" y1="0" y2="0" vectorEffect="non-scaling-stroke" />
          <line className={css.rule} x1="0" x2="100" y1="100" y2="100" vectorEffect="non-scaling-stroke" />
          {chart.series.map((s, i) => {
            const runs = stretches(s.values);
            return (
              <g key={s.id} className={SERIES[i % SERIES.length]}>
                {chart.series.length === 1 && <path className={css.wash} d={runs.map((r) => `M${x(r.from)} 100${r.values.map((v, k) => `L${x(r.from + k)} ${y(v)}`).join("")}L${x(r.from + r.values.length - 1)} 100Z`).join("")} />}
                <path className={css.trace} vectorEffect="non-scaling-stroke"
                  d={runs.map((r) => `M${x(r.from)} ${y(r.values[0]!)}${r.values.length === 1 ? "h0" : r.values.slice(1).map((v, k) => `L${x(r.from + k + 1)} ${y(v)}`).join("")}`).join("")} />
              </g>
            );
          })}
        </svg>
      </div>
      <div className={css.ticks} aria-hidden="true">
        {ticks.map((tk) => {
          const at = x(tk.index);
          return <span key={tk.index} style={{ left: `${at}%` }} data-edge={at < 3 ? "start" : at > 97 ? "end" : undefined}>{tk.label}</span>;
        })}
      </div>
    </figure>
  );
}

/** A series' values in the stretches between its gaps (null). */
function stretches(values: (number | null)[]): { from: number; values: number[] }[] {
  const out: { from: number; values: number[] }[] = [];
  values.forEach((v, i) => {
    if (v === null) return;
    const last = out.at(-1);
    if (last && last.from + last.values.length === i) last.values.push(v);
    else out.push({ from: i, values: [v] });
  });
  return out;
}

/** What the cloud says of a token it would not make, in words. */
const RELAY_ERRORS = (): Record<string, string> => ({
  invalid_name: t("web-pages.admin.relays.errors.name"),
  invalid_relay: t("web-pages.admin.relays.errors.url"),
  invalid_target: t("web-pages.admin.relays.errors.target"),
  too_many_relays: t("web-pages.admin.relays.errors.full"),
});

type Kind = "relay" | "entry";

/** A token for a relay to put itself on the cloud's list with, or for a way into one of its relays (an entry): what it
 * is called and, if said, the URL it must have; then the command its machine runs (cloud/relay-enroll.sh). */
function RelayTokenDialog({ account, targets, onClose }: { account: Account; targets: { url: string; name: string }[]; onClose(): void }) {
  const [kind, setKind] = useState<Kind>("relay");
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [target, setTarget] = useState(targets[0]?.url ?? "");
  const entry = kind === "entry";
  const make = useAction(() => admin.relayToken(account.sub, name.trim(), url.trim(), entry ? target : ""));
  const made = make.result;
  const ready = name.trim() !== "" && (!entry || target !== "") && !make.busy;
  const enter = (e: React.KeyboardEvent<HTMLElement>) => { if (e.key === "Enter" && !e.isComposing && ready) make.run(); };
  const failed = make.error && (RELAY_ERRORS()[(make.error as { code?: string }).code ?? ""] ?? make.error.message);
  return (
    <Dialog open onClose={onClose} wide title={made ? t("web-pages.admin.relays.issued") : t("web-pages.admin.relays.issue")}
      description={made ? t("web-pages.admin.relays.issuedLead") : t(entry ? "web-pages.admin.relays.issueEntryLead" : "web-pages.admin.relays.issueLead")}
      footer={made ? <Button variant="primary" onClick={onClose}>{t("common.done")}</Button> : <>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={make.busy} disabled={!ready} onClick={() => make.run()}>{t("web-pages.admin.relays.issueShort")}</Button>
      </>}>
      {made ? (
        <Field label={t("web-pages.admin.relays.run")} hint={t("web-pages.admin.relays.runHint")}><div className={css.command}><CopyCommand text={made.command} /></div></Field>
      ) : (
        <>
          {targets.length > 0 && (
            <Segmented<Kind> label={t("web-pages.admin.relays.kind")} value={kind} onChange={setKind}
              options={[{ value: "relay", label: t("web-pages.admin.relays.kindRelay") }, { value: "entry", label: t("web-pages.admin.relays.kindEntry") }]} />
          )}
          {entry && (
            <Field label={t("web-pages.admin.relays.target")} hint={t("web-pages.admin.relays.targetHint")}>
              <Select value={target} onChange={setTarget} label={t("web-pages.admin.relays.target")} options={targets.map((r) => ({ value: r.url, label: r.name }))} />
            </Field>
          )}
          <Field label={t("web-pages.admin.relays.name")} htmlFor="relay-name" hint={t("web-pages.admin.relays.nameHint")}>
            <TextInput id="relay-name" value={name} autoFocus maxLength={40} placeholder={t(entry ? "web-pages.admin.relays.entryPlaceholder" : "web-pages.admin.relays.namePlaceholder")} onChange={(e) => setName(e.currentTarget.value)} onKeyDown={enter} />
          </Field>
          <Field label={t("web-pages.admin.relays.url")} htmlFor="relay-url" hint={t("web-pages.admin.relays.urlHint")}>
            <TextInput id="relay-url" type="url" inputMode="url" autoComplete="off" spellcheck={false} value={url} placeholder="https://relay.example.com:8443" onChange={(e) => setUrl(e.currentTarget.value)} onKeyDown={enter} />
          </Field>
        </>
      )}
      {failed && <ErrorLine>{failed}</ErrorLine>}
    </Dialog>
  );
}

/** A relay (or a way into one) named anew: what people see a connection go through. */
function RenameRelayDialog({ account, relay, onClose }: { account: Account; relay: { url: string; name: string; target?: string }; onClose(): void }) {
  const toast = useToast();
  const [name, setName] = useState(relay.name);
  const save = useAction(() => admin.relayPut(account.sub, relay.url, name.trim(), relay.target), () => { toast(t("web-pages.admin.relays.renamed")); onClose(); });
  const ready = name.trim() !== "" && name.trim() !== relay.name && !save.busy;
  const submit = () => { if (ready) save.run(); };
  const failed = save.error && (RELAY_ERRORS()[(save.error as { code?: string }).code ?? ""] ?? save.error.message);
  return (
    <Dialog open onClose={onClose} title={t(relay.target ? "web-pages.admin.relays.renameEntry" : "web-pages.admin.relays.rename")} description={t("web-pages.admin.relays.renameLead")}
      footer={<>
        <Button variant="ghost" onClick={onClose}>{t("common.cancel")}</Button>
        <Button variant="primary" busy={save.busy} disabled={!ready} onClick={submit}>{t("common.save")}</Button>
      </>}>
      <Field label={t("web-pages.admin.relays.name")} htmlFor="relay-rename">
        <TextInput id="relay-rename" value={name} autoFocus maxLength={40} onChange={(e) => setName(e.currentTarget.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.isComposing) submit(); }} />
      </Field>
      {failed && <ErrorLine>{failed}</ErrorLine>}
    </Dialog>
  );
}
