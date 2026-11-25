// A chat's Farview tab's sign-in form, filled by the station ( 登录态, "Signing in from a card"), as signin-form.ts
// fills a Chrome tab's: the same finder picks the fields, each marked with a per-call random attribute after verifying
// the locked secure origin (Farview's own typing: the page hears it as keys), the form sent with Enter, else by its
// button clicked. Over the tab's agent port (farview-agent.ts), so what is typed is on no command line and in no log.
import { randomBytes } from "node:crypto";
import { askTab, evalIn } from "./farview-agent.ts";
import { isSecureAutofillUrl, sameSiteHost } from "./psl.ts";
import { FINDER, type FormAsks, type FormField, LOOK_SCRIPT, type SignInForm } from "./signin-form.ts";
import { hostOf } from "./view.ts";

const nonce = () => randomBytes(8).toString("hex");

/// Atomically verifies `expectedOrigin` and marks the field of `kind` with a per-call random attribute; whether found.
const markScript = (kind: FormField, attr: string, expectedOrigin: string) =>
  `(() => {
  if (location.origin !== ${JSON.stringify(expectedOrigin)}) return false;
  const el = ${FINDER}[${JSON.stringify(kind)}];
  if (!el) return false;
  el.setAttribute(${JSON.stringify(attr)}, "");
  return true;
})()`;

/// Atomically verifies `expectedOrigin` and marks the button that sends the form (signin-form.ts BUTTON_SCRIPT's
/// choice) with a per-call random attribute; whether found.
const buttonMarkScript = (fieldAttr: string, buttonAttr: string, expectedOrigin: string) => `(() => {
  if (location.origin !== ${JSON.stringify(expectedOrigin)}) return false;
  const visible = (el) => !!el && !el.disabled && el.getClientRects().length > 0;
  const a = (${fieldAttr ? `document.querySelector(${JSON.stringify(`[${fieldAttr}]`)}) || ` : ""}document.activeElement);
  const scope = (a && a.form) || document;
  const all = [...scope.querySelectorAll("button, input[type=submit], [role=button]")].filter(visible);
  const said = (el) => (el.innerText || el.value || el.getAttribute("aria-label") || "").trim();
  const b = all.find((el) => (el.type || "").toLowerCase() === "submit" && el.tagName !== "DIV")
    || all.find((el) => /^(sign in|log in|login|next|continue|verify|submit|登录|登入|下一步|继续|验证|确定)$/i.test(said(el)));
  if (!b) return false;
  b.setAttribute(${JSON.stringify(buttonAttr)}, "");
  return true;
})()`;

export class FarviewForm implements SignInForm {
  readonly #port: number;
  #expectedOrigin: string | null = null;
  #lastAttr = "";
  #sentKey = "";

  constructor(port: number) {
    this.#port = port;
  }

  async url(): Promise<string> {
    const a = await askTab(this.#port, { kind: "look" }).catch(() => null);
    return a?.kind === "seen" ? a.url : "";
  }

  async host(): Promise<string> {
    return hostOf(await this.url());
  }

  async on(site: string): Promise<boolean> {
    const url = await this.url();
    if (!isSecureAutofillUrl(url) || !sameSiteHost(hostOf(url), site)) {
      this.#expectedOrigin = null;
      return false;
    }
    this.#expectedOrigin = new URL(url).origin;
    return true;
  }

  async #currentOrigin(): Promise<string | null> {
    const url = await this.url();
    if (!isSecureAutofillUrl(url)) return null;
    const origin = new URL(url).origin;
    if (this.#expectedOrigin !== null && origin !== this.#expectedOrigin) return null;
    return origin;
  }

  async look(): Promise<FormAsks> {
    const v = await evalIn(this.#port, LOOK_SCRIPT).catch(() => undefined);
    return { username: v?.username === true, password: v?.password === true, code: v?.code === true, blocked: v?.blocked === true };
  }

  async type(kind: FormField, value: string): Promise<boolean> {
    const expectedOrigin = await this.#currentOrigin();
    if (expectedOrigin === null) return false;
    const attr = `data-stillfail-signin-${nonce()}`;
    if ((await evalIn(this.#port, markScript(kind, attr, expectedOrigin))) !== true) return false;
    if ((await this.#currentOrigin()) !== expectedOrigin) return false;
    this.#lastAttr = attr;
    const a = await askTab(this.#port, { kind: "act", verb: "type", selector: `[${attr}]`, text: value });
    return a.kind === "seen";
  }

  async enter(): Promise<void> {
    if (this.#lastAttr === "") return;
    if ((await this.#currentOrigin()) === null) return;
    await askTab(this.#port, { kind: "act", verb: "key", selector: `[${this.#lastAttr}]`, text: "Enter" });
  }

  async press(): Promise<boolean> {
    const expectedOrigin = await this.#currentOrigin();
    if (expectedOrigin === null) return false;
    const buttonAttr = `data-stillfail-signin-btn-${nonce()}`;
    if ((await evalIn(this.#port, buttonMarkScript(this.#lastAttr, buttonAttr, expectedOrigin))) !== true) return false;
    if ((await this.#currentOrigin()) !== expectedOrigin) return false;
    return (await askTab(this.#port, { kind: "act", verb: "click", selector: `[${buttonAttr}]`, text: "" })).kind === "seen";
  }

  async mark(): Promise<void> {
    this.#sentKey = `__stillfailSent_${nonce()}`;
    await evalIn(this.#port, `(window[${JSON.stringify(this.#sentKey)}] = true)`);
  }

  async marked(): Promise<boolean> {
    if (this.#sentKey === "") return false;
    return (await evalIn(this.#port, `window[${JSON.stringify(this.#sentKey)}] === true`).catch(() => false)) === true;
  }

  close() {}
}
