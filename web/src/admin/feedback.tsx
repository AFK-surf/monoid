// A bug report's pane: its status, copied whole for an agent; when, where and from whom; what it says, the replies
// between the team and its reporter (and one to send), its context and logs (read with the report's own page).
import { useState } from "preact/hooks";
import { Fragment } from "preact/compat";
import { Link } from "wouter-preact";
import { Copy, Send } from "@stillfail/ui/icons.tsx";
import { useToast } from "@stillfail/ui/toast.tsx";
import { stamp } from "../api.ts";
import type { Account } from "../cloud/accounts.ts";
import { admin, useAction, type FeedbackStatus } from "../cloud/api.ts";
import { Button, Pill, Select, Time, WaitLine, ErrorLine, TextArea } from "../ui.tsx";
import * as shellCss from "../styles/shell.css.ts";
import { t } from "../i18n.ts";
import * as css from "./console.css.ts";
import { Detail, Failed, PATH, SAMPLE_FEEDBACK, useKept } from "./shared.tsx";
import type { FeedbackPage, Reply } from "./types.ts";

export function FeedbackDetail({ account, id, close }: { account: Account; id: string; close: string }) {
  const { value: f, error } = useKept<FeedbackPage>({ topic: "adminItem", account: account.sub, list: "feedback", id });
  if (!f) return error ? <aside className={css.detail}><Failed error={error} /></aside> : <FeedbackShown account={account} close={close} f={SAMPLE_FEEDBACK} bones />;
  return <FeedbackShown account={account} close={close} f={f} />;
}

function FeedbackShown({ account, close, f, bones = false }: { account: Account; close: string; f: FeedbackPage; bones?: boolean }) {
  const toast = useToast();
  // (by its own id: the page's address may name it FB-n)
  const status = useAction((to: FeedbackStatus) => admin.feedbackStatus(account.sub, f.id, to), (_, to) => toast(t("web-pages.admin.fb.marked", { status: f.statuses.find((s) => s.id === to)?.label ?? to })));
  const copy = () => void navigator.clipboard.writeText(f.text).then(() => toast(t("web-pages.admin.fb.copied")), () => toast(t("web-pages.admin.fb.copyFailed")));
  return (
    <Detail close={close} bones={bones} head={
      <span className={css.detailTitle}><b>{f.title}</b><span className={shellCss.mono}>{f.number}</span></span>
    }>
      <div className={css.fbBar}>
        <Select value={status.busy ? status.arg! : f.status} disabled={status.busy} onChange={(v) => { if (v !== f.status) status.run(v as FeedbackStatus); }} label={t("web-pages.admin.fb.status")}
          options={f.statuses.map((s) => ({ value: s.id, label: s.label }))} />
        <Button icon={Copy} onClick={copy}>{t("web-pages.admin.fb.copy")}</Button>
      </div>
      <dl className={css.kv}>
        <dt>{t("web-pages.admin.fb.submitted")}</dt><dd><Time stamp={stamp(f, "created_at")} /></dd>
        <dt>{t("web-pages.admin.fb.channel")}</dt><dd>{f.channelLabel}</dd>
        <dt>{t("web-pages.admin.fb.area")}</dt><dd>{f.area}</dd>
        {f.reporter && <><dt>{t("web-pages.admin.fb.reporter")}</dt><dd>{f.reporter}</dd></>}
        {f.account && <><dt>{t("web-pages.profiles.account")}</dt><dd><Link className={css.link} to={`${PATH.users}/${encodeURIComponent(f.account.id)}`}>{f.account.title}</Link></dd></>}
        {f.workspace && <><dt>Workspace</dt><dd><Link className={css.link} to={`${PATH.workspaces}/${encodeURIComponent(f.workspace.id)}`}>{f.workspace.title}</Link></dd></>}
        {f.station && <><dt>Station</dt><dd>{f.station.name || <span className={shellCss.mono}>{f.station.id}</span>}</dd></>}
      </dl>
      <div className={css.group}>{t("web-pages.admin.fb.content")}</div>
      <div className={css.fbBody}>{f.body}</div>
      {/* (a core from before says nothing of replies) */}
      {f.replies !== undefined && <Replies account={account} f={f} />}
      {f.context.length > 0 && <>
        <div className={css.group}>{t("web-pages.admin.fb.context")}</div>
        <dl className={`${css.kv} ${css.fbContext}`}>
          {f.context.map((c) => <Fragment key={c.key}><dt>{c.key}</dt><dd className={shellCss.mono}>{c.value}</dd></Fragment>)}
        </dl>
      </>}
      {(f.logs || f.logsLoading) && <>
        <div className={css.group}>{t("web-pages.admin.fb.logs")}</div>
        {f.logs ? <pre className={`${shellCss.mono} ${css.fbLogs}`}>{f.logs}</pre> : <WaitLine />}
      </>}
    </Detail>
  );
}

/** The replies on a report, oldest first, and (where it came from a chat that can be told) one to send. */
function Replies({ account, f }: { account: Account; f: FeedbackPage }) {
  const toast = useToast();
  const [text, setText] = useState("");
  const send = useAction((said: string) => admin.feedbackReply(account.sub, f.id, said), () => { setText(""); toast(t("web-pages.admin.fb.sent")); });
  const ready = text.trim() !== "" && !send.busy;
  const submit = () => { if (ready) void send.run(text.trim()); };
  const failed = send.error && ((send.error as { code?: string }).code === "undeliverable" ? t("web-pages.admin.fb.undeliverable") : send.error.message);
  const replies = f.replies ?? [];
  return (
    <>
      <div className={css.group}>{t("web-pages.admin.fb.replies")}</div>
      {replies.length > 0 && <div className={css.replies}>{replies.map((r) => <ReplyShown key={r.id} r={r} />)}</div>}
      {f.canReply ? (
        <div className={css.replyForm}>
          <TextArea className={css.replyInput} rows={3} value={text} maxLength={4000} aria-label={t("web-pages.admin.fb.reply")}
            placeholder={t("web-pages.admin.fb.replyPlaceholder")} onInput={(e) => setText(e.currentTarget.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !e.isComposing) { e.preventDefault(); submit(); } }} />
          <span className={css.hint}>{f.replyHint}</span>
          {failed && <ErrorLine>{failed}</ErrorLine>}
          <div className={css.replySend}>
            <Button variant="primary" icon={Send} busy={send.busy} disabled={!ready} onClick={submit}>{t("web-pages.admin.fb.send")}</Button>
          </div>
        </div>
      ) : <div className={css.line} data-quiet>{f.replyHint}</div>}
    </>
  );
}

/** A reply: who, which side, whether it reached the chat yet and when on its first line; what it says under it. */
function ReplyShown({ r }: { r: Reply }) {
  return (
    <div className={css.reply} data-side={r.from}>
      <div className={css.replyHead}>
        <b>{r.authorLabel}</b>
        <Pill tone={r.from === "team" ? "accent" : "neutral"}>{r.from === "team" ? t("web-pages.admin.fb.team") : t("web-pages.admin.fb.reporterSide")}</Pill>
        {r.deliveryLabel && <span className={css.replyDelivery} data-pending={r.delivery === "pending" || undefined}>{r.deliveryLabel}</span>}
        <span className={css.replyTime}><Time stamp={stamp(r, "created_at")} fixed /></span>
      </div>
      <div className={css.replyText}>{r.text}</div>
    </div>
  );
}
