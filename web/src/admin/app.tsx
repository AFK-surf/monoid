// The admin's console (main.tsx): on the core, the accounts the sign-in page signed in taken into it first.
import { followAppearance } from "../theme.ts";
import { startScrollbars } from "../scrollbars.ts";
import { Tooltip } from "radix-ui";
import { StrictMode } from "preact/compat";
import { createRoot } from "preact/compat/client";
import { I18nRoot, t, useLang } from "../i18n.ts";
import { Illustration } from "../brand.tsx";
import { useAccounts, useSignOut } from "../cloud/accounts.ts";
import { signInHere, takeSignedIn } from "../pages/core.ts";
import { addWords, type Words } from "@stillfail/ui/i18n.ts";
import zhPages from "../../../client/i18n/catalog/zh/web-pages.json" with { type: "json" };
import enPages from "../../../client/i18n/catalog/en/web-pages.json" with { type: "json" };
import { ToastProvider } from "@stillfail/ui/toast.tsx";
import { Button, WaitLine } from "../ui.tsx";
import { Console } from "./console.tsx";
import { useAdminAccount } from "./account.ts";
import * as shellCss from "../styles/shell.css.ts";
import { NAME } from "../channel.ts";

function AdminApp() {
  return (
    <ToastProvider>
      <Tooltip.Provider delayDuration={400}>
        <Home />
      </Tooltip.Provider>
    </ToastProvider>
  );
}

function Home() {
  const list = useAccounts();
  const { account, error, retry } = useAdminAccount();
  // (its tab says the product and the console, in the language now)
  useLang();
  if (typeof document !== "undefined") document.title = `${NAME} ${t("web-pages.admin.title")}`;
  if (list?.length === 0) {
    location.replace(signInHere());
    return null;
  }
  if (error !== null && !account) return <Unreachable error={error} retry={retry} />;
  if (account === undefined) return <div className={shellCss.gate}><WaitLine /></div>;
  if (account === null) return <NoPermission />;
  return <Console account={account} />;
}

/** Whether an account is the admin's could not be asked (the network, the cloud's 5xx): said so, with a way to try
 * again, never as 没有权限. */
function Unreachable({ error, retry }: { error: Error; retry(): void }) {
  const list = useAccounts() ?? [];
  const signOut = useSignOut();
  return (
    <div className={shellCss.gate}>
      <Illustration name="station-offline" />
      <h1>{t("web-pages.admin.unreachable.title", { name: NAME })}</h1>
      <p>{t("web-pages.admin.readFailed", { error: error.message })}</p>
      <Button variant="primary" onClick={retry}>{t("web-pages.admin.retry")}</Button>
      <Button variant="ghost" busy={signOut.busy()} onClick={() => { for (const a of list) void signOut.signOut(a.sub); }}>{t("web-pages.admin.signOut")}</Button>
    </div>
  );
}

/** Signed in, but with no account that is the admin's. */
function NoPermission() {
  const list = useAccounts() ?? [];
  const signOut = useSignOut();
  return (
    <div className={shellCss.gate}>
      <Illustration name="sign-in" />
      <h1>{t("web-pages.admin.noPermission.title")}</h1>
      <p>{t("web-pages.admin.noPermission.body", { emails: list.map((a) => a.email).join(t("web-pages.admin.noPermission.separator")), name: NAME })}</p>
      <Button variant="primary" busy={signOut.busy()} onClick={() => { for (const a of list) void signOut.signOut(a.sub); }}>{t("web-pages.admin.signOut")}</Button>
      <Button variant="ghost" onClick={() => location.assign(signInHere())}>{t("web-pages.admin.switchAccount")}</Button>
    </div>
  );
}

addWords({ zh: zhPages as Words, en: enPages as Words });

export async function show(root: HTMLElement): Promise<void> {
  followAppearance();
  startScrollbars();
  await takeSignedIn();
  // (in place of the splash index.html paints first)
  root.replaceChildren();
  createRoot(root).render(<StrictMode><I18nRoot><AdminApp /></I18nRoot></StrictMode>);
}
