// The sign-in pages, without the core (signin.ts): /login goes straight to still.fail cloud's sign-in, which offers
// every way to sign in; /auth/callback finishes it and goes back where it began. Taking far longer than it does, the
// callback says so and offers to load the page again or to start over: an app on the home screen has no reload of its
// own, and was stuck at 正在登录… for good (2026-10-09).
import { useEffect, useState } from "preact/hooks";
import { t } from "@stillfail/ui/i18n.ts";
import { Button } from "@stillfail/ui/button.tsx";
import { StandPage, type Illustration } from "@stillfail/ui/standPage.tsx";
import { NAME } from "../channel.ts";
import { begin, complete, deviceName, returnTo, SignInError } from "./signin.ts";

/** How long the sign-in's last step may take before the page offers a way out: it takes a second or two. */
const SIGNING_IN_MS = 8000;

export const name = () => deviceName((browser, os) => t("web-login.device", { brand: NAME, browser: browser || t("web-login.browser"), more: os ? ` · ${os}` : "" }));

export const start = (to: string) => begin(to, name());

/** The sign-in pages' picture, over each of them (the admin's console's too). */
export const SIGN_IN: Illustration = { src: "/illus-sign-in.svg", width: 360, height: 200 };

/** A sign-in page: its picture, what is happening, what to do next and its buttons. */
export function Page({ title, lead, children }: { title: string; lead?: string | undefined; children?: preact.ComponentChildren }) {
  return <StandPage illustration={SIGN_IN} title={title} lead={lead} actions={children} />;
}

/** /login: on to still.fail cloud's sign-in at once; should that fail, a way to try again. */
export function SignIn() {
  const title = t("web-login.title", { name: NAME });
  const lead = t("web-login.lead");
  const [error, setError] = useState<string | null>(null);
  const to = returnTo(location.search);
  useEffect(() => { start(to).catch((e: unknown) => setError(String(e))); }, []);
  if (error === null) return <Page title={title} lead={lead} />;
  return (
    <Page title={title} lead={t("web-login.unreachable", { name: NAME, error })}>
      <Button variant="primary" onClick={() => { setError(null); start(to).catch((e: unknown) => setError(String(e))); }}>{t("web-login.start")}</Button>
    </Page>
  );
}

/** /auth/callback: the sign-in finished, then where it began. */
export function Callback() {
  const [error, setError] = useState<string | null>(null);
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    const timer = setTimeout(() => setSlow(true), SIGNING_IN_MS);
    complete(location.search).then((next) => location.replace(next), (e: unknown) => {
      setError(e instanceof SignInError ? t(`web-login.${e.key}`) : t("web-login.unreachable", { name: NAME, error: String(e) }));
    }).finally(() => clearTimeout(timer));
    return () => clearTimeout(timer);
  }, []);
  if (error !== null) {
    return <Page title={t("web-login.failed")} lead={error}><Button variant="primary" onClick={() => void start("/")}>{t("web-login.again")}</Button></Page>;
  }
  if (!slow) return <Page title={t("web-login.signingIn")} />;
  return (
    <Page title={t("web-login.signingIn")} lead={t("web-login.slow")}>
      <Button variant="primary" onClick={() => location.reload()}>{t("web-login.reload")}</Button>
      <Button onClick={() => location.replace("/")}>{t("web-login.again")}</Button>
    </Page>
  );
}
