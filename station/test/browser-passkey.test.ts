// A tab's real injected hook and TabView together, with a deterministic page and CDP. New screen streams open
// before old ones close on resize: the old viewer must neither turn off its replacement nor cancel its request.
import assert from "node:assert/strict";
import { test } from "node:test";
import { createContext, runInContext } from "node:vm";
import { TabView } from "../src/browser/view.ts";
import type { Cdp, CdpEvent } from "../src/browser/cdp.ts";
import type { PasskeyAsk } from "../src/screens/source.ts";

function page() {
  const context = createContext({ DOMException, AbortController, btoa, atob });
  const run = (s: string): any => runInContext(s, context);
  run(`globalThis.window = globalThis; window.top = window;
    window.location = { hostname: "example.org" };
    window.addEventListener = () => {};
    window.PublicKeyCredential = class {};
    window.AuthenticatorAssertionResponse = class {};
    window.nativeCalls = 0;
    window.navigator = { credentials: { get: async () => { nativeCalls++; return "native"; } } };
    window.ask = () => { window.result = "pending"; window.abort = new AbortController();
      navigator.credentials.get({ signal: abort.signal, publicKey: { rpId: "example.org", challenge: new Uint8Array([1, 2, 3]) } })
        .then(v => window.result = v, e => window.result = e.name); };
  `);
  const pending = new Set<Promise<unknown>>();
  const bindings = new Map<string, Set<(payload: string) => void>>();
  const scripts = new Map<string, string>();
  let next = 0;
  function viewer(opts: { passkeys?: boolean; ownPasskey?: (rpId: string) => boolean } = {}) {
    const session = `session-${++next}`;
    const listeners = new Set<(e: CdpEvent) => void>();
    const ownBindings = new Map<string, (payload: string) => void>();
    const cdp: Cdp = {
      send(method, params: any = {}, sid) {
        const promise = Promise.resolve().then(() => {
          assert.equal(sid, method === "Target.getTargetInfo" ? undefined : session);
          if (method === "Runtime.enable" || method === "Page.enable" || method === "Page.startScreencast") {
            return {};
          } else if (method === "Runtime.addBinding") {
            const heard = (payload: string) => { for (const f of listeners) f({ sessionId: session, method: "Runtime.bindingCalled", params: { name: params.name, payload } }); };
            const all = bindings.get(params.name) ?? new Set();
            bindings.set(params.name, all);
            all.add(heard);
            ownBindings.set(params.name, heard);
            context[params.name] = (payload: string) => { for (const f of [...all]) f(payload); };
          } else if (method === "Runtime.removeBinding") {
            const heard = ownBindings.get(params.name);
            if (heard) bindings.get(params.name)?.delete(heard);
          } else if (method === "Runtime.evaluate") {
            return { result: { value: run(params.expression) } };
          } else if (method === "Page.addScriptToEvaluateOnNewDocument") {
            const identifier = String(++next);
            scripts.set(identifier, params.source);
            return { identifier };
          } else if (method === "Page.removeScriptToEvaluateOnNewDocument") {
            scripts.delete(params.identifier);
          } else if (method === "Target.getTargetInfo") {
            return { targetInfo: { url: "https://example.org/login" } };
          } else assert.fail(method);
          return {};
        });
        pending.add(promise);
        void promise.finally(() => pending.delete(promise));
        return promise;
      },
      on(f) { listeners.add(f); return () => listeners.delete(f); },
      closed: new Promise(() => {}),
      close() {},
    };
    const view = new TabView({ cdp, session, targetId: "tab", now: () => 0, ownPasskey: opts.ownPasskey });
    if (opts.passkeys !== undefined) void view.start({ maxWidth: 1280, maxHeight: 720, codecs: ["jpeg"], passkeys: opts.passkeys }, { width: 1280, height: 720 });
    const heard: (PasskeyAsk | null)[] = [];
    const stop = view.watchPasskey(a => heard.push(a));
    return { view, heard, stop };
  }
  const settle = async () => {
    while (pending.size) await Promise.all([...pending]);
    // Drain the continuations of #url too: they can notify a viewer after its last CDP command resolved.
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(pending.size, 0);
  };
  return { run, viewer, settle, scripts };
}

test("an overlapping viewer takes pending passkeys; old cleanup and replies cannot cancel it or turn forwarding off", async () => {
  const p = page();
  const old = p.viewer();
  await p.settle();
  p.run("ask()");
  await p.settle();
  const ask = old.heard.at(-1)!;
  assert.equal(ask.rpId, "example.org");
  const current = p.viewer();
  await p.settle();
  assert.equal(old.heard.at(-1), null);
  assert.equal(current.heard.at(-1)?.id, ask.id, "the request follows the new viewer without asking the site to retry");
  await old.view.passkey({ id: ask.id, error: "NotAllowedError" });
  old.stop();
  await p.settle();
  assert.equal(p.run("result"), "pending");
  assert.equal(p.scripts.size, 1, "old navigation hook removed, new one's retained");
  await current.view.passkey({ id: ask.id, error: "NotAllowedError" });
  await p.settle();
  assert.equal(p.run("result"), "NotAllowedError");
  p.run("ask()");
  await p.settle();
  assert.ok(current.heard.at(-1));
  assert.equal(p.run("nativeCalls"), 0, "old cleanup did not switch off forwarding");
  current.stop();
  await p.settle();
  assert.equal(p.run("result"), "NotAllowedError", "last viewer leaving settles the pending request");
  p.run("ask()");
  await p.settle();
  assert.equal(p.run("nativeCalls"), 1, "with no viewers it is the browser's request again");
  assert.equal(p.scripts.size, 0);
});

test("closing the newer viewer hands a request back; abort and reconnect leave no stale request", async () => {
  const p = page();
  const old = p.viewer();
  await p.settle();
  const current = p.viewer();
  await p.settle();
  p.run("ask()");
  await p.settle();
  assert.equal(old.heard.length, 0, "a binding broadcast is handled only by its owner");
  const ask = current.heard.at(-1)!;
  current.stop();
  await p.settle();
  assert.equal(old.heard.at(-1)?.id, ask.id, JSON.stringify({ old: old.heard, current: current.heard, result: p.run("result") }));
  assert.equal(p.run("result"), "pending");
  p.run("abort.abort()");
  await p.settle();
  assert.equal(old.heard.at(-1), null);
  assert.equal(p.run("result"), "AbortError");
  old.stop();
  await p.settle();
  const again = p.viewer();
  await p.settle();
  assert.equal(again.heard.length, 0);
  p.run("ask()");
  await p.settle();
  assert.ok(again.heard.at(-1));
  assert.equal(p.run("nativeCalls"), 0);
  again.stop();
  await p.settle();
});

test("a request aborted while its origin is being checked is not resurrected on the viewer", async () => {
  const p = page();
  const v = p.viewer();
  await p.settle();
  p.run("ask(); abort.abort()");
  await p.settle();
  assert.equal(p.run("result"), "AbortError");
  assert.equal(v.heard.length, 0);
  v.stop();
  await p.settle();
});

test("a page kept across an update replaces the legacy unowned hook without invoking it", async () => {
  const p = page();
  p.run(`window.legacyCalls = 0; window.legacyOff = false;
    window.__stillfailPasskeyOff = off => window.legacyOff = off;
    const original = navigator.credentials.get;
    navigator.credentials.get = options => {
      if (legacyOff) return original(options);
      legacyCalls++; return Promise.reject(new DOMException("old hook", "NotAllowedError"));
    };
  `);
  const v = p.viewer();
  await p.settle();
  p.run("ask()");
  await p.settle();
  assert.ok(v.heard.at(-1));
  assert.equal(p.run("legacyCalls"), 0);
  assert.equal(p.run("nativeCalls"), 0);
  v.stop();
  await p.settle();
  p.run("ask()");
  await p.settle();
  assert.equal(p.run("nativeCalls"), 1);
  assert.equal(p.run("legacyCalls"), 0);
});

test("silent conditional mediation is not intercepted, while large Google-sized challenges reach the viewer", async () => {
  const p = page();
  const v = p.viewer();
  await p.settle();
  assert.equal(await p.run("PublicKeyCredential.isConditionalMediationAvailable()"), false);
  p.run(`navigator.credentials.get({ mediation: "conditional", publicKey: { rpId: "example.org", challenge: new Uint8Array([1, 2, 3]) } })`);
  await p.settle();
  assert.equal(v.heard.length, 0, "silent conditional autofill calls fall through without popping a card");
  assert.equal(p.run("nativeCalls"), 1);
  // Google's /v3/signin/challenge/pk sends a ~10 KB (~13,664 base64url chars) challenge.
  p.run(`window.bigResult = "pending";
    navigator.credentials.get({ publicKey: { rpId: "example.org", challenge: new Uint8Array(10248).fill(7) } })
      .then(x => window.bigResult = x.id, e => window.bigResult = e.name);`);
  await p.settle();
  const ask = v.heard.at(-1)!;
  assert.ok(ask && ask.clientData.length > 13_600);
  await v.view.passkey({ id: ask.id, credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln" });
  await p.settle();
  assert.equal(p.run("bigResult"), "Y3JlZA");
  v.stop();
  await p.settle();
});

test("a viewer without host passkeys never hangs credentials.get, settles pending device asks, and reports platform availability from vault passkeys alone", async () => {
  const p = page();
  p.run(`window.location = { hostname: "login.example.org" };
    window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(true);`);
  // 1. Start with a passkey-capable viewer that leaves an assertion pending, then switch to a viewer without host passkeys.
  const desktop = p.viewer({ passkeys: true });
  await p.settle();
  assert.equal(await p.run("PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()"), true);
  p.run("ask()");
  await p.settle();
  assert.equal(desktop.heard.length, 1);
  assert.equal(p.run("result"), "pending");

  const phoneNoPasskey = p.viewer({ passkeys: false });
  await p.settle();
  assert.equal(desktop.heard.at(-1), null);
  assert.equal(phoneNoPasskey.heard.length, 0, "viewer without host passkeys is never asked");
  assert.equal(p.run("result"), "NotAllowedError", "pending request from earlier viewer settles instead of hanging");

  // 2. Without a vault passkey for the site, platform availability is false (even if Chrome's empty virtual authenticator says true)
  // and credentials.get rejects with NotAllowedError without invoking headful Chrome's OS WebAuthn dialog (nativeCalls === 0).
  p.run(`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(v => window.uvpa = v)`);
  await p.settle();
  assert.equal(p.run("uvpa"), false);
  p.run("ask()");
  await p.settle();
  assert.equal(p.run("result"), "NotAllowedError");
  assert.equal(p.run("nativeCalls"), 0, "must never trigger headful Chrome's hidden OS WebAuthn dialog");
  assert.equal(phoneNoPasskey.heard.length, 0);

  phoneNoPasskey.stop();
  desktop.stop();
  await p.settle();

  // 3. With a vault passkey on the parent domain (example.org for login.example.org), platform availability is true
  // and credentials.get delegates to Chrome's virtual authenticator (`{ browser: true }`).
  const withVault = p.viewer({ passkeys: false, ownPasskey: (rp) => rp === "example.org" });
  await p.settle();
  p.run(`window.uvpa = "pending"; PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(v => window.uvpa = v)`);
  await p.settle();
  assert.equal(p.run("uvpa"), true);
  p.run("ask()");
  await p.settle();
  assert.equal(p.run("result"), "native");
  assert.equal(p.run("nativeCalls"), 1);
  withVault.stop();
  await p.settle();
});
