// The scripts the station runs in a page (view.ts, signin-form.ts, farview-form.ts), each the very text the
// TypeScript sends: what hears a page's copies, its login fields and its passkey sign-ins, what fills a login form, and
// what finds a sign-in form's fields and its button.

///|
/// The binding a tab's copies call while a person driving it watches its clipboard.
pub let copy_binding : String = "__stillfailCopied"

///|
/// The longest text a clipboard carries (screens/source.ts `CLIP_TEXT_MAX`).
pub let clip_text_max : Int = 1024 * 1024

///|
let copy_hook_text : String =
  #|(() => {
  #|  if (window.__stillfailCopyHook) return;
  #|  window.__stillfailCopyHook = true;
  #|  const say = (text) => { try { if (typeof text === "string" && text !== "" && typeof window.@BINDING === "function") window.@BINDING(text.slice(0, @MOST)); } catch {} };
  #|  const selected = () => {
  #|    const el = document.activeElement;
  #|    if (el && (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && /^(text|search|url|tel|email|number)$/i.test(el.type || "text")))) {
  #|      try { if (el.selectionStart !== el.selectionEnd) return el.value.slice(el.selectionStart, el.selectionEnd); } catch {}
  #|      return "";
  #|    }
  #|    return String(window.getSelection() || "");
  #|  };
  #|  // What was selected, said once the copy's dispatch is over (a message to itself: a task after it) unless the page
  #|  // set its own by then.
  #|  let pending = null;
  #|  const after = new MessageChannel();
  #|  after.port1.onmessage = () => { if (pending) say(pending); pending = null; };
  #|  const started = () => {
  #|    pending = selected();
  #|    after.port2.postMessage(0);
  #|  };
  #|  const reached = (e) => {
  #|    let set = "";
  #|    try { set = e.clipboardData ? e.clipboardData.getData("text/plain") : ""; } catch {}
  #|    if (set) { pending = null; say(set); }
  #|  };
  #|  for (const type of ["copy", "cut"]) { window.addEventListener(type, started, true); window.addEventListener(type, reached); }
  #|  const board = navigator.clipboard;
  #|  if (board && typeof board.writeText === "function") {
  #|    const write = board.writeText.bind(board);
  #|    board.writeText = (text) => { say(String(text)); return write(text); };
  #|  }
  #|})()

///|
/// What hears a page's copies, run in it (and in each document it opens while watched): a copy's or a cut's text, as
/// the page set it or as it was selected, and what it writes with navigator.clipboard.writeText.
pub fn copy_hook() -> String {
  copy_hook_text
  .replace_all(old="@BINDING", new=copy_binding)
  .replace_all(old="@MOST", new=(clip_text_max / 4).to_string())
}

///|
/// The binding a tab's login fields call while a person driving it is offered to fill them.
pub let login_binding : String = "__stillfailLogin"

///|
let login_hook_text : String =
  #|(() => {
  #|  if (window !== window.top) return;
  #|  if (typeof window.__stillfailLoginTell === "function") {
  #|    window.__stillfailLoginTell();
  #|    return;
  #|  }
  #|  const deep = (root) => { let el = root.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; return el; };
  #|  const kind = (el) => {
  #|    if (!el || el.tagName !== "INPUT" || el.disabled || el.readOnly) return null;
  #|    const type = (el.type || "text").toLowerCase();
  #|    const auto = (el.autocomplete || "").toLowerCase();
  #|    if (type === "password") return "password";
  #|    if (!/^(text|email|tel)$/.test(type)) return null;
  #|    if (/username|email|webauthn/.test(auto)) return "username";
  #|    if (el.form && el.form.querySelector("input[type=password]")) return "username";
  #|    return /user|email|login|account|identifier/i.test((el.name || "") + " " + (el.id || "")) ? "username" : null;
  #|  };
  #|  const focused = (e) => (e && e.composedPath ? e.composedPath()[0] : deep(document));
  #|  let said = "";
  #|  const say = (el) => {
  #|    const field = kind(el);
  #|    const now = field ? JSON.stringify(el.value ? { field, filled: true } : { field }) : "null";
  #|    if (now === said) return;
  #|    said = now;
  #|    try { if (typeof window.@BINDING === "function") window.@BINDING(now); } catch {}
  #|  };
  #|  window.__stillfailLoginTell = () => {
  #|    said = "";
  #|    say(deep(document));
  #|  };
  #|  document.addEventListener("focusin", (e) => say(focused(e)), true);
  #|  // (where the focus goes: none, or one a focusin then says itself)
  #|  document.addEventListener("focusout", (e) => say(e.relatedTarget), true);
  #|  document.addEventListener("input", () => say(deep(document)), true);
  #|  document.addEventListener("change", () => say(deep(document)), true);
  #|  say(deep(document));
  #|})()

///|
/// What tells of the login field in focus, run in a page's top document: `{"field": …}` as the focus comes to one and
/// `null` as it leaves; only when it changed.
pub fn login_hook() -> String {
  login_hook_text.replace_all(old="@BINDING", new=login_binding)
}

///|
let fill_text : String =
  #|((username, password) => {
  #|  const visible = (el) => !!el && !el.disabled && !el.readOnly && el.getClientRects().length > 0;
  #|  const deep = (root) => { let el = root.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; return el; };
  #|  const active = deep(document);
  #|  const scope = (active && active.form) || (active && active.getRootNode && active.getRootNode()) || document;
  #|  const all = [...scope.querySelectorAll("input")].filter(visible);
  #|  const pass = all.find((el) => (el.type || "").toLowerCase() === "password");
  #|  const account = all.find((el) => el !== pass && /^(text|email|tel)$/.test((el.type || "text").toLowerCase())
  #|    && (/username|email|webauthn/.test((el.autocomplete || "").toLowerCase()) || /user|email|login|account|identifier/i.test((el.name || "") + " " + (el.id || "")) || (pass && el.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING)));
  #|  const set = (el, value) => {
  #|    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
  #|    el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
  #|    el.dispatchEvent(new Event("change", { bubbles: true }));
  #|  };
  #|  const did = { username: false, password: false };
  #|  if (typeof username === "string" && account) { set(account, username); did.username = true; }
  #|  if (typeof password === "string" && pass) { set(pass, password); did.password = true; }
  #|  const first = did.username ? account : did.password ? pass : null;
  #|  if (first) first.focus();
  #|  return did;
  #|})(@ARGS)

///|
/// Fills the login form the focus is in (or the page's first): its account field and its password field, as typing
/// would leave them, the first of them focused. What was filled.
pub fn fill_script(username : String?, password : String?) -> String {
  let q = (v : String?) => match v {
    Some(s) => quote(s)
    None => "null"
  }
  fill_text.replace_all(old="@ARGS", new="\{q(username)}, \{q(password)}")
}

///|
/// The binding a tab's passkey sign-ins call while a person driving it signs them from their own device.
pub let passkey_binding : String = "__stillfailPasskey"

///|
/// The binding of one viewer (`owner`).
pub fn passkey_binding_of(owner : String) -> String {
  "\{passkey_binding}_\{owner.replace_all(old="-", new="")}"
}

///|
let passkey_hook_text : String =
  #|(() => {
  #|  if (window !== window.top || !navigator.credentials) return;
  #|  const owner = @OWNER;
  #|  const device = @DEVICE;
  #|  if (window.__stillfailPasskeyWatch) return window.__stillfailPasskeyWatch(owner, true, device);
  #|  // A page kept across a station update may still have the old, unowned hook. Its get falls through while off.
  #|  if (window.__stillfailPasskeyOff) window.__stillfailPasskeyOff(true);
  #|  const owners = new Map();
  #|  let active = null;
  #|  let activeDevice = false;
  #|  const creds = navigator.credentials;
  #|  const get = creds.get.bind(creds);
  #|  const bytes = (v) => v instanceof ArrayBuffer ? new Uint8Array(v) : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : null;
  #|  const b64 = (v) => { const u = bytes(v); if (!u) return null; let s = ""; for (const b of u) s += String.fromCharCode(b); return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); };
  #|  const buf = (s) => { const t = atob(s.replace(/-/g, "+").replace(/_/g, "/")); const u = new Uint8Array(t.length); for (let i = 0; i < t.length; i++) u[i] = t.charCodeAt(i); return u.buffer; };
  #|  const waiting = new Map();
  #|  const uvpaWaiting = new Map();
  #|  let next = 0;
  #|  const said = (v) => { try { window[@NAME + "_" + active.replaceAll("-", "")](JSON.stringify({ ...v, owner: active })); return true; } catch { return false; } };
  #|  // New and old screen streams overlap on a resize. Only the active owner answers; an old stream ending cannot
  #|  // switch off its replacement or reject a request it handed over. Pending requests follow an active stream whose
  #|  // device signs passkeys, and settle as NotAllowedError when none does.
  #|  Object.defineProperty(window, "__stillfailPasskeyWatch", { value: (id, on, dev = true) => {
  #|    const useDevice = Boolean(dev);
  #|    if (on ? owners.has(id) && owners.get(id) === useDevice : !owners.has(id)) return;
  #|    if (on) owners.set(id, useDevice); else owners.delete(id);
  #|    const last = [...owners.entries()].at(-1);
  #|    const nextOwner = last ? last[0] : null;
  #|    const nextDevice = last ? last[1] : false;
  #|    if (nextOwner === active && nextDevice === activeDevice) return;
  #|    if (active !== null && activeDevice) { for (const wid of waiting.keys()) said({ id: wid, gone: true }); }
  #|    active = nextOwner;
  #|    activeDevice = nextDevice;
  #|    if (active !== null && activeDevice) { for (const w of waiting.values()) said(w.ask); }
  #|    else {
  #|      for (const w of waiting.values()) w.no(new DOMException("The operation either timed out or was not allowed.", "NotAllowedError"));
  #|      waiting.clear();
  #|    }
  #|    if (active === null || activeDevice) {
  #|      for (const u of uvpaWaiting.values()) u.res(Boolean(activeDevice));
  #|      uvpaWaiting.clear();
  #|    } else {
  #|      for (const [uid, u] of uvpaWaiting) { if (!said({ id: uid, uvpa: u.host })) { uvpaWaiting.delete(uid); u.res(false); } }
  #|    }
  #|  } });
  #|  window.__stillfailPasskeyWatch(owner, true, device);
  #|  Object.defineProperty(window, "__stillfailPasskeyReply", { value: (owner, id, a) => {
  #|    if (owner !== active) return;
  #|    const u = uvpaWaiting.get(id);
  #|    if (u) { uvpaWaiting.delete(id); return u.res(a.available === true); }
  #|    const w = waiting.get(id);
  #|    if (!w) return;
  #|    waiting.delete(id);
  #|    // (one of the vault's: the browser signs it, with the tab's own authenticator)
  #|    if (a.browser) return get(w.options).then(w.yes, w.no);
  #|    if (a.error) return w.no(new DOMException(a.error === "NotAllowedError" ? "The operation either timed out or was not allowed." : String(a.error), a.error === "NotAllowedError" ? "NotAllowedError" : "UnknownError"));
  #|    const response = { clientDataJSON: buf(a.clientData), authenticatorData: buf(a.authenticatorData), signature: buf(a.signature), userHandle: a.userHandle ? buf(a.userHandle) : null };
  #|    const credential = { id: a.credential, rawId: buf(a.credential), type: "public-key", authenticatorAttachment: "platform", response,
  #|      getClientExtensionResults: () => ({}),
  #|      toJSON: () => ({ id: a.credential, rawId: a.credential, type: "public-key", authenticatorAttachment: "platform", clientExtensionResults: {},
  #|        response: { clientDataJSON: b64(response.clientDataJSON), authenticatorData: a.authenticatorData, signature: a.signature, userHandle: a.userHandle || null } }) };
  #|    try { Object.setPrototypeOf(response, AuthenticatorAssertionResponse.prototype); Object.setPrototypeOf(credential, PublicKeyCredential.prototype); } catch {}
  #|    w.yes(credential);
  #|  } });
  #|  creds.get = function (options) {
  #|    const pk = options && options.publicKey;
  #|    const ch = pk && b64(pk.challenge);
  #|    if (active === null || !activeDevice || !pk || options.mediation === "conditional" || !ch || ch.length > 32768) return get(options);
  #|    const id = String(++next);
  #|    const allow = Array.isArray(pk.allowCredentials) ? pk.allowCredentials.map((c) => b64(c && c.id)).filter((x) => x) : [];
  #|    const ask = { id, rpId: typeof pk.rpId === "string" && pk.rpId !== "" ? pk.rpId : location.hostname, challenge: ch, allow, userVerification: pk.userVerification || "preferred" };
  #|    return new Promise((yes, no) => {
  #|      const signal = options.signal;
  #|      if (signal && signal.aborted) return no(signal.reason !== undefined ? signal.reason : new DOMException("The operation was aborted.", "AbortError"));
  #|      waiting.set(id, { yes, no, options, ask });
  #|      if (signal) signal.addEventListener("abort", () => {
  #|        if (!waiting.delete(id)) return;
  #|        said({ id, gone: true });
  #|        no(signal.reason !== undefined ? signal.reason : new DOMException("The operation was aborted.", "AbortError"));
  #|      });
  #|      if (!said(ask)) { waiting.delete(id); get(options).then(yes, no); }
  #|    });
  #|  };
  #|  // (a page left takes what it asked with it)
  #|  window.addEventListener("pagehide", () => { for (const id of waiting.keys()) said({ id, gone: true }); waiting.clear(); uvpaWaiting.clear(); });
  #|  if (window.PublicKeyCredential) {
  #|    const uvpa = typeof PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable === "function" ? PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable.bind(PublicKeyCredential) : () => Promise.resolve(false);
  #|    PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => {
  #|      if (active === null) return uvpa();
  #|      if (activeDevice) return Promise.resolve(true);
  #|      const id = "u" + (++next);
  #|      const host = String(location.hostname || "");
  #|      return new Promise((res) => {
  #|        uvpaWaiting.set(id, { host, res });
  #|        if (!said({ id, uvpa: host })) { uvpaWaiting.delete(id); res(false); }
  #|      });
  #|    };
  #|    PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
  #|  }
  #|})()

///|
/// What takes a page's passkey sign-in (navigator.credentials.get with `publicKey`) to the person driving it, run in a
/// page's top document before its own scripts: the ask said through the viewer's binding, answered by the station with
/// `__stillfailPasskeyReply(owner, id, answer)`.
pub fn passkey_hook(owner : String, device? : Bool = true) -> String {
  passkey_hook_text
  .replace_all(old="@OWNER", new=quote(owner))
  .replace_all(old="@DEVICE", new=if device { "true" } else { "false" })
  .replace_all(old="@NAME", new=quote(passkey_binding))
}

///|
/// Finds the page's sign-in fields (the top document and its open shadow roots), run in a world of its own.
let finder_text : String =
  #|(() => {
  #|  const visible = (el) => !!el && !el.disabled && !el.readOnly && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden";
  #|  const inputs = [];
  #|  const walk = (root) => { for (const el of root.querySelectorAll("*")) { if (el.tagName === "INPUT") inputs.push(el); if (el.shadowRoot) walk(el.shadowRoot); } };
  #|  walk(document);
  #|  const words = (el) => [el.name, el.id, el.placeholder, el.getAttribute("aria-label")].filter(Boolean).join(" ");
  #|  const typeOf = (el) => (el.type || "text").toLowerCase();
  #|  const auto = (el) => (el.autocomplete || "").toLowerCase();
  #|  const isCode = (el) => /^(text|tel|number|password)$/.test(typeOf(el)) && (auto(el) === "one-time-code"
  #|    || /otp|totp|mfa|2fa|two.?factor|one.?time|verification|verify|authenticat|security.?code|^code$|[-_ ]code|code[-_ ]|pin\b|验证码|动态码/i.test(words(el))
  #|    || (el.inputMode === "numeric" && el.maxLength > 0 && el.maxLength <= 8 && typeOf(el) !== "password"));
  #|  const shown = inputs.filter(visible);
  #|  const code = shown.find(isCode);
  #|  const password = shown.find((el) => typeOf(el) === "password" && !isCode(el));
  #|  const username = shown.find((el) => el !== code && /^(text|email|tel)$/.test(typeOf(el)) && !isCode(el)
  #|    && (/username|email|webauthn/.test(auto(el)) || /user|email|e-mail|login|account|identifier|账号|邮箱|手机/i.test(words(el)) || (password && el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING)));
  #|  const blocked = [...document.querySelectorAll("iframe")].some((f) => visible(f) && /recaptcha|hcaptcha|turnstile|captcha|arkoselabs|funcaptcha/i.test(f.src || ""));
  #|  return { username, password, code, blocked };
  #|})()

///|
pub fn finder() -> String {
  finder_text
}

///|
/// What the page asks for now.
pub fn look_script() -> String {
  "(() => { const f = \{finder_text}; return { username: !!f.username, password: !!f.password, code: !!f.code, blocked: f.blocked }; })()"
}

///|
/// Focuses the field of `kind`, its text selected; whether there is one.
pub fn pick_script(kind : String) -> String {
  "(() => { const el = \{finder_text}[\{quote(kind)}]; if (!el) return false; el.focus(); try { el.select(); } catch {} return document.activeElement === el || el.getRootNode().activeElement === el; })()"
}

///|
/// The button that sends the form the focus is in (or the page's only one): its middle, in CSS pixels; null for none.
pub let button_script : String =
  #|(() => {
  #|  const visible = (el) => !!el && !el.disabled && el.getClientRects().length > 0;
  #|  const a = document.activeElement;
  #|  const scope = (a && a.form) || document;
  #|  const all = [...scope.querySelectorAll("button, input[type=submit], [role=button]")].filter(visible);
  #|  const said = (el) => (el.innerText || el.value || el.getAttribute("aria-label") || "").trim();
  #|  const b = all.find((el) => (el.type || "").toLowerCase() === "submit" && el.tagName !== "DIV")
  #|    || all.find((el) => /^(sign in|log in|login|next|continue|verify|submit|登录|登入|下一步|继续|验证|确定)$/i.test(said(el)));
  #|  if (!b) return null;
  #|  const r = b.getBoundingClientRect();
  #|  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  #|})()

///|
/// What marks a Farview tab's sign-in fields and its button (farview-form.ts).
pub let farview_mark : String = "data-stillfail-signin"

///|
/// Marks the field of `kind` (and only it); whether there is one.
pub fn mark_script(kind : String) -> String {
  "(() => { for (const el of document.querySelectorAll(\"[\{farview_mark}]\")) el.removeAttribute(\"\{farview_mark}\"); const el = \{finder_text}[\{quote(kind)}]; if (!el) return false; el.setAttribute(\"\{farview_mark}\", \"\"); return true; })()"
}

///|
let button_mark_text : String =
  #|(() => {
  #|  for (const el of document.querySelectorAll("[@MARK-button]")) el.removeAttribute("@MARK-button");
  #|  const visible = (el) => !!el && !el.disabled && el.getClientRects().length > 0;
  #|  const a = document.querySelector("[@MARK]") || document.activeElement;
  #|  const scope = (a && a.form) || document;
  #|  const all = [...scope.querySelectorAll("button, input[type=submit], [role=button]")].filter(visible);
  #|  const said = (el) => (el.innerText || el.value || el.getAttribute("aria-label") || "").trim();
  #|  const b = all.find((el) => (el.type || "").toLowerCase() === "submit" && el.tagName !== "DIV")
  #|    || all.find((el) => /^(sign in|log in|login|next|continue|verify|submit|登录|登入|下一步|继续|验证|确定)$/i.test(said(el)));
  #|  if (!b) return false;
  #|  b.setAttribute("@MARK-button", "");
  #|  return true;
  #|})()

///|
/// Marks the button that sends the form (signin-form.ts BUTTON_SCRIPT's choice); whether there is one.
pub fn button_mark() -> String {
  button_mark_text.replace_all(old="@MARK", new=farview_mark)
}
