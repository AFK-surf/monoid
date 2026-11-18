// Where a console sends someone to add a machine's station to a workspace, with no command to copy (Monoid's console:
// its cloud/DESIGN.md §3.14, "Connect"): `?return=<console>/connect/station&state=…&name=<the machine's name>`. They
// pick a workspace they manage; the core makes its enrollment as the app's 添加 station does (`workspace.enroll`: in a
// locked workspace with its lock's head as this device holds it), and the command goes back to the console as a form
// (OpenID's form_post), so the token is in no address, history or Referer. Only a console CONNECT_CONSOLES lists is
// sent anything: the web's Worker lets that one alone in the page's form-action, and answers any other with
// `?refused=1` (cloud/src/web.ts connectConsole). Cancelling posts `error=access_denied`, so the console says so.
import { render } from "preact";
import { useEffect, useMemo, useState } from "preact/hooks";
import { addWords, I18nRoot, t, type Words } from "@stillfail/ui/i18n.ts";
import zhPages from "../../../client/i18n/catalog/zh/web-pages.json" with { type: "json" };
import enPages from "../../../client/i18n/catalog/en/web-pages.json" with { type: "json" };
import { core } from "../core/react.ts";
import { NAME } from "../channel.ts";
import { accounts, signInHere, takeSignedIn } from "./core.ts";
import { Button, ButtonLink } from "@stillfail/ui/button.tsx";
import { ErrorLine, RadioChoices, TextInput } from "@stillfail/ui/fields.tsx";
import { Field } from "@stillfail/ui/parts.tsx";
import { StandActions, StandPage } from "@stillfail/ui/standPage.tsx";
import * as own from "./connect.css.ts";

addWords({ zh: zhPages as Words, en: enPages as Words });

type Workspace = { id: string; name: string; email: string };
/** What the core said of the workspaces: null until every account answered. */
type Listed = { managed: Workspace[] } | null;

const MANAGERS = ["owner", "admin"];

/** The workspaces the accounts signed in here manage, of the `workspaces` topic (sync/cloud.ts workspacesValue). */
function managedOf(value: unknown): Listed {
  if (!Array.isArray(value)) return null;
  const managed: Workspace[] = [];
  for (const entry of value as Record<string, unknown>[]) {
    if (entry.loaded !== true && entry.error === undefined) return null;
    const email = typeof (entry.account as { email?: unknown } | undefined)?.email === "string" ? (entry.account as { email: string }).email : "";
    for (const w of Array.isArray(entry.workspaces) ? (entry.workspaces as Record<string, unknown>[]) : []) {
      if (typeof w.id !== "string" || !MANAGERS.includes(String(w.role)) || managed.some((m) => m.id === w.id)) continue;
      managed.push({ id: w.id, name: typeof w.name === "string" && w.name !== "" ? w.name : w.id, email });
    }
  }
  return { managed };
}

/** Sends `fields` to the console as a form, leaving this page. */
function postBack(to: string, fields: Record<string, string>): void {
  const form = document.createElement("form");
  form.method = "post";
  form.action = to;
  for (const [name, value] of Object.entries(fields)) {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = name;
    input.value = value;
    form.append(input);
  }
  document.body.append(form);
  form.submit();
}

function Connect() {
  const query = new URLSearchParams(location.search);
  const back = query.get("return") ?? "";
  const state = query.get("state") ?? "";
  const asked = (query.get("name") ?? "").trim().slice(0, 64);
  const consoleHost = useMemo(() => {
    try {
      return new URL(back).host;
    } catch {
      return "";
    }
  }, [back]);
  const [signedIn, setSignedIn] = useState<boolean | null>(null);
  const [listed, setListed] = useState<Listed>(null);
  const [workspace, setWorkspace] = useState("");
  const [name, setName] = useState(asked);
  const [busy, setBusy] = useState<"adding" | "handing" | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (query.has("refused") || !back || !state) return;
    void takeSignedIn().then(async () => setSignedIn((await accounts()).length > 0));
  }, []);
  useEffect(() => {
    if (!signedIn) return;
    return core().subscribe({ topic: "workspaces" }, (value) => {
      const now = managedOf(value);
      setListed(now);
      if (now?.managed.length === 1) setWorkspace((w) => w || now.managed[0]!.id);
    }, () => setListed({ managed: [] }));
  }, [signedIn]);

  const page = (title: string, lead: string, action?: [string, string]) => (
    <StandPage title={title} lead={lead} actions={action && <ButtonLink href={action[1]}>{action[0]}</ButtonLink>} />
  );
  const home: [string, string] = [t("web-pages.cloud.backTo", { name: NAME }), "/"];

  if (query.has("refused") || !back || !state) return page(t("web-pages.cloud.connect.refused"), t("web-pages.cloud.connect.refusedBody", { name: NAME }), home);
  if (signedIn === false) return page(t("web-pages.cloud.slackInstalled.signIn", { name: NAME }), t("web-pages.cloud.connect.signInBody", { name: NAME }), [t("web-pages.cloud.slackInstalled.signIn", { name: NAME }), signInHere()]);
  if (busy === "handing") return page(t("web-pages.cloud.connect.handing", { host: consoleHost }), "");
  if (signedIn === null || listed === null) return page(t("web-pages.cloud.connect.reading"), "");
  if (listed.managed.length === 0) return page(t("web-pages.cloud.connect.noWorkspace"), t("web-pages.cloud.connect.noWorkspaceBody", { name: NAME }), home);

  const several = new Set(listed.managed.map((w) => w.email)).size > 1;
  const join = async (e: Event) => {
    e.preventDefault();
    if (!workspace || !name.trim() || busy) return;
    setBusy("adding");
    setError(null);
    try {
      const made = (await core().call("workspace.enroll", { workspace, name: name.trim() })) as { command?: unknown };
      if (typeof made?.command !== "string") throw new Error(t("web-pages.cloud.connect.noCommand"));
      setBusy("handing");
      postBack(back, { state, command: made.command });
    } catch (err) {
      setBusy(null);
      setError((err as Error).message);
    }
  };
  return (
    <StandPage title={t("web-pages.cloud.connect.title")} lead={t("web-pages.cloud.connect.lead", { host: consoleHost, machine: asked || t("web-pages.cloud.connect.aMachine") })}>
      <form className={own.form} onSubmit={join}>
        <Field label={t("web-pages.cloud.connect.workspace")}>
          <RadioChoices name="workspace" label={t("web-pages.cloud.connect.workspace")} value={workspace} onChange={setWorkspace} disabled={busy !== null}
            options={listed.managed.map((w) => ({ value: w.id, label: w.name, ...(several ? { meta: w.email } : {}) }))} />
        </Field>
        <Field label={t("web-pages.cloud.connect.name")} htmlFor="connect-name">
          <TextInput id="connect-name" value={name} maxLength={64} disabled={busy !== null} onInput={(e) => setName(e.currentTarget.value)} />
        </Field>
        <p className={own.note}>{t("web-pages.cloud.connect.note", { host: consoleHost })}</p>
        {error && <ErrorLine>{t("web-pages.cloud.connect.failed", { error })}</ErrorLine>}
        <StandActions>
          <Button disabled={busy !== null} onClick={() => { setBusy("handing"); postBack(back, { state, error: "access_denied" }); }}>
            {t("web-pages.cloud.connect.cancel")}
          </Button>
          <Button type="submit" variant="primary" busy={busy === "adding"} disabled={!workspace || !name.trim() || busy !== null}>
            {busy === "adding" ? t("web-pages.cloud.connect.adding") : t("web-pages.cloud.connect.add")}
          </Button>
        </StandActions>
      </form>
    </StandPage>
  );
}

export function show(root: HTMLElement): void {
  // (in place of the splash index.html paints first)
  root.replaceChildren();
  render(<I18nRoot><Connect /></I18nRoot>, root);
}
