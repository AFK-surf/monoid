// Deterministic security regression tests for browser external boundaries, CDP Gate,
// PSL/WebAuthn/autofill, main-world bindings, HTTP Origin/session checks, and Farview IPC.
import assert from "node:assert/strict";
import { createServer, type Socket } from "node:net";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import vm from "node:vm";
import WebSocket, { WebSocketServer } from "ws";
import type { Cdp, CdpEvent } from "../src/browser/cdp.ts";
import { MAX_AGENT_FRAME, askTab, decodeAnswer } from "../src/browser/farview-agent.ts";
import { FarviewForm } from "../src/browser/farview-form.ts";
import { FarviewScreen, FrameLink, MAX_FRAME_BINARY_BYTES, MAX_FRAME_LINE_BYTES } from "../src/browser/farview-screen.ts";
import { Gate } from "../src/browser/gate.ts";
import { isLoopbackHost, isPublicSuffix, isSecureAutofillUrl, normalizeHost, registrableDomain, sameSiteHost } from "../src/browser/psl.ts";
import { browserDoor, sessionPath } from "../src/browser/proxy.ts";
import { ofSites } from "../src/browser/signins.ts";
import { TabForm, atomicTypeScript } from "../src/browser/signin-form.ts";
import { COPY_BINDING, HUMAN_COPY_WINDOW_MS, LOGIN_BINDING, PASSKEY_BINDING, TabView, fillScript, rpFor } from "../src/browser/view.ts";
import { CLIP_TEXT_MAX } from "../src/screens/source.ts";
import { STILLFAIL_SURFACE } from "../src/store/store.ts";
import { notFromHere, openAgentsDoor } from "../src/tools/http.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { SignIns } from "../src/vault/signin.ts";

const turn = async () => {
  for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
};

class FakeCdp implements Cdp {
  sent: { method: string; params: any; sessionId?: string }[] = [];
  answers: Record<string, (params: any, sessionId?: string) => any> = {};
  #listeners = new Set<(e: CdpEvent) => void>();
  #end!: () => void;
  closed = new Promise<void>((r) => (this.#end = r));
  gone = false;

  async send(method: string, params: object = {}, sessionId?: string) {
    if (this.gone) throw new Error("closed");
    this.sent.push({ method, params, sessionId });
    return this.answers[method]?.(params, sessionId) ?? {};
  }

  on(listener: (e: CdpEvent) => void) {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  emit(method: string, params: any, sessionId?: string) {
    for (const l of [...this.#listeners]) l({ method, params, sessionId });
  }

  close() {
    this.gone = true;
    this.#end();
  }

  of(method: string) {
    return this.sent.filter((s) => s.method === method);
  }
}

test("PSL helpers: ICANN and private suffixes, registrable domains, IDN/dots, and secure autofill URLs", () => {
  assert.equal(isPublicSuffix("com"), true);
  assert.equal(isPublicSuffix("co.uk"), true);
  assert.equal(isPublicSuffix("github.io"), true);
  assert.equal(isPublicSuffix(".github.io."), true);
  assert.equal(isPublicSuffix("a.github.io"), false);
  assert.equal(isPublicSuffix("github.com"), false);
  assert.equal(isPublicSuffix("localhost"), false);
  assert.equal(isPublicSuffix("127.0.0.1"), false);

  assert.equal(registrableDomain("app.github.com."), "github.com");
  assert.equal(registrableDomain(".github.com"), "github.com");
  assert.equal(registrableDomain("sub.alice.github.io"), "alice.github.io");
  assert.equal(registrableDomain("github.io"), null);
  assert.equal(registrableDomain("localhost"), null);
  assert.equal(registrableDomain("127.0.0.1"), null);

  assert.equal(normalizeHost("Bücher.Example.Com."), "xn--bcher-kva.example.com");
  assert.equal(normalizeHost("x@victim.com"), "", "rejects userinfo delimiter");
  assert.equal(normalizeHost("victim.com/path"), "", "rejects path delimiter");
  assert.equal(normalizeHost("victim.com?q=1"), "", "rejects query delimiter");
  assert.equal(normalizeHost("victim.com#frag"), "", "rejects fragment delimiter");
  assert.equal(normalizeHost("victim.com:8080"), "", "rejects host:port");
  assert.equal(normalizeHost("victim .com"), "", "rejects whitespace");

  assert.equal(sameSiteHost("app.github.com", "github.com"), true);
  assert.equal(sameSiteHost("bucket.s3.amazonaws.com", "amazonaws.com"), false, "must not cross nested private suffix s3.amazonaws.com");
  assert.equal(sameSiteHost("bucket.s3.amazonaws.com", "s3.amazonaws.com"), false, "public suffix rejected");
  assert.equal(sameSiteHost("a.github.io", "github.io"), false);
  assert.equal(sameSiteHost("127.0.0.1", "127.0.0.1"), true);

  assert.equal(ofSites(".github.com", ["github.com"]), true);
  assert.equal(ofSites("api.github.com", ["github.com"]), true);
  assert.equal(ofSites("bucket.s3.amazonaws.com", ["amazonaws.com"]), false);
  assert.equal(isLoopbackHost("localhost"), true);
  assert.equal(isLoopbackHost("127.0.0.1"), true);
  assert.equal(isLoopbackHost("[::1]"), true);
  assert.equal(isLoopbackHost("::1"), true);
  assert.equal(isLoopbackHost("example.com"), false);

  assert.equal(isSecureAutofillUrl("https://github.com/login"), true);
  assert.equal(isSecureAutofillUrl("http://localhost:3000/login"), true);
  assert.equal(isSecureAutofillUrl("http://127.0.0.1:8080/login"), true);
  assert.equal(isSecureAutofillUrl("http://[::1]:8080/login"), true);
  assert.equal(isSecureAutofillUrl("http://example.com/login"), false);
  assert.equal(isSecureAutofillUrl("http://github.com/login"), false);
  assert.equal(isSecureAutofillUrl("javascript:alert(1)"), false);
  assert.equal(isSecureAutofillUrl("about:blank"), false);

  assert.equal(rpFor("github.io", "a.github.io"), false);
  assert.equal(rpFor("co.uk", "shop.co.uk"), false);
  assert.equal(rpFor("github.com", "app.github.com"), true);
  assert.equal(rpFor("a.github.io", "sub.a.github.io"), true);
  assert.equal(rpFor("localhost", "localhost"), true);
});

test("SignIns.ask refuses public suffixes such as github.io and co.uk", async () => {
  const db = new DatabaseSync(":memory:");
  const signIns = new SignIns({
    db,
    hub: {
      store: {
        getSession: () => ({}),
        starter: () => "pat@example.com",
        latestThread: () => ({ connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } }) as any,
        sessionThreadById: () => null,
        pendingCardHeader: () => null,
        insertMessage: () => [1],
        withdrawCard: () => true,
        restateCard: () => true,
        subscribe: () => {},
      },
      chat: () => ({ post: async () => "t1" }),
      shared: () => {},
      notify: () => {},
    },
    browser: {
      tabs: () => [{ id: "T1", url: "https://app.github.io/login" }],
      look: async () => ({ username: true, password: true, code: false, blocked: false }),
      drive: async () => ({ state: "left" }),
    },
    vault: {
      listed: () => null,
      held: () => null,
      use: async () => "",
      keep: async () => "",
    },
    screenLink: () => null,
    workspace: () => "ws",
    now: () => 1_800_000_000_000,
    after: () => () => {},
  });
  try {
    await assert.rejects(signIns.ask("s1", { site: "github.io", reason: "login" }), /public suffix/i);
    await assert.rejects(signIns.ask("s1", { site: "co.uk", reason: "login" }), /public suffix/i);
  } finally {
    await signIns.close();
    db.close();
  }
});

test("watchClipboard rejects unprompted background copies, allows copies within 5s of human action, rejects oversized payloads, and clears window on navigation", async () => {
  const cdp = new FakeCdp();
  let now = 10_000;
  const v = new TabView({ cdp, session: "S", targetId: "T", now: () => now });
  const clips: string[] = [];
  const stop = v.watchClipboard((c) => {
    if (c.type === "text") clips.push(c.text);
  });
  await turn();

  // No human input yet: background page calling __stillfailCopied is silently dropped.
  cdp.emit("Runtime.bindingCalled", { name: COPY_BINDING, payload: "unprompted" }, "S");
  assert.deepEqual(clips, []);

  // Mouse move alone is not a human copy-enabling action.
  await v.input({ t: "pointer", kind: "move", x: 0.5, y: 0.5, buttons: 0 });
  cdp.emit("Runtime.bindingCalled", { name: COPY_BINDING, payload: "after-move" }, "S");
  assert.deepEqual(clips, []);

  // Click opens a 5s window (supports async copy buttons).
  await v.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
  now += HUMAN_COPY_WINDOW_MS;
  cdp.emit("Runtime.bindingCalled", { name: COPY_BINDING, payload: "clicked-copy" }, "S");
  assert.deepEqual(clips, ["clicked-copy"]);

  // Oversized payload is dropped even inside the window.
  cdp.emit("Runtime.bindingCalled", { name: COPY_BINDING, payload: "x".repeat(CLIP_TEXT_MAX + 1) }, "S");
  assert.deepEqual(clips, ["clicked-copy"]);

  // Past 5s window: dropped.
  now += 1;
  cdp.emit("Runtime.bindingCalled", { name: COPY_BINDING, payload: "too-late" }, "S");
  assert.deepEqual(clips, ["clicked-copy"]);

  // Key down opens the window; top-frame navigation clears it immediately.
  await v.input({ t: "key", kind: "down", key: "c", code: "KeyC", mods: 4 });
  cdp.emit("Page.frameNavigated", { frame: { id: "main", url: "https://other.example/" } }, "S");
  cdp.emit("Runtime.bindingCalled", { name: COPY_BINDING, payload: "after-nav" }, "S");
  assert.deepEqual(clips, ["clicked-copy"]);

  stop();
  v.close();
});

test("watchPasskey uvpa ignores page-supplied host, enforces PSL + secure URL, rate-limits while resolving false, and replies with executionContextId", async () => {
  const cdp = new FakeCdp();
  let now = 1_000;
  let currentUrl = "https://victim.github.io/login";
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: currentUrl } });
  const queried: string[] = [];
  const v = new TabView({
    cdp,
    session: "S",
    targetId: "T",
    now: () => now,
    ownPasskey: (rp) => {
      queried.push(rp);
      return rp === "github.com" || rp === "github.io";
    },
  });
  await v.start({ maxWidth: 800, maxHeight: 600, codecs: ["jpeg"], passkeys: false }, { width: 800, height: 600 });
  const asks: any[] = [];
  const stop = v.watchPasskey((a) => asks.push(a));
  await turn();

  const bindingCall = cdp.of("Runtime.addBinding")[0]!;
  const bindingName = bindingCall.params.name as string;
  const owner = cdp
    .of("Runtime.evaluate")[0]!
    .params.expression.match(/const owner = "([^"]+)"/)![1]!;

  // 1. Page claims uvpa: "github.com" while actual tab URL is victim.github.io -> must ignore page's claim and stop before public suffix github.io!
  cdp.emit(
    "Runtime.bindingCalled",
    { name: bindingName, executionContextId: 42, payload: JSON.stringify({ owner, id: "u1", uvpa: "github.com" }) },
    "S",
  );
  await turn();
  assert.deepEqual(queried, ["victim.github.io"], "only authoritative host queried, never forged github.com or public suffix github.io");
  const uvpaReply = cdp.of("Runtime.evaluate").at(-1)!;
  assert.equal(uvpaReply.params.contextId, 42, "reply targeted to calling executionContextId");
  assert.match(uvpaReply.params.expression, /location\.origin !== "https:\/\/victim\.github\.io"/, "uvpa reply atomically checks expectedOrigin");
  assert.match(uvpaReply.params.expression, /"available":false/);

  // 2. Plaintext http://example.com -> resolves false without querying ownPasskey.
  queried.length = 0;
  currentUrl = "http://example.com/login";
  cdp.emit(
    "Runtime.bindingCalled",
    { name: bindingName, executionContextId: 43, payload: JSON.stringify({ owner, id: "u2", uvpa: "github.com" }) },
    "S",
  );
  await turn();
  assert.deepEqual(queried, []);
  assert.match(cdp.of("Runtime.evaluate").at(-1)!.params.expression, /"available":false/);

  // 3. Rate limiting (> 10 calls/sec): 11th call still resolves false immediately instead of hanging.
  currentUrl = "https://app.github.com/login";
  const beforeCount = cdp.of("Runtime.evaluate").length;
  for (let i = 0; i < 12; i++) {
    cdp.emit(
      "Runtime.bindingCalled",
      { name: bindingName, executionContextId: 50 + i, payload: JSON.stringify({ owner, id: `r${i}`, uvpa: "ignored" }) },
      "S",
    );
  }
  await turn();
  const replies = cdp.of("Runtime.evaluate").slice(beforeCount);
  assert.equal(replies.length, 12, "every uvpa call including rate-limited ones receives a reply");
  const limitedReply = replies.find((r) => r.params.expression.includes('"r11"'));
  assert.ok(limitedReply, "rate-limited call r11 still receives a reply");
  assert.match(limitedReply.params.expression, /"available":false/);
  assert.equal(limitedReply.params.contextId, 61);

  // 4. Passkey assertion answer uses recorded executionContextId.
  stop();
  const v2 = new TabView({ cdp, session: "S", targetId: "T", now: () => now });
  await v2.start({ maxWidth: 800, maxHeight: 600, codecs: ["jpeg"], passkeys: true }, { width: 800, height: 600 });
  const asks2: any[] = [];
  const stop2 = v2.watchPasskey((a) => asks2.push(a));
  await turn();
  const binding2 = cdp.of("Runtime.addBinding").at(-1)!.params.name as string;
  const owner2 = cdp
    .of("Runtime.evaluate")
    .at(-1)!
    .params.expression.match(/const owner = "([^"]+)"/)![1]!;
  currentUrl = "https://app.github.com/login";
  cdp.emit(
    "Runtime.bindingCalled",
    {
      name: binding2,
      executionContextId: 99,
      payload: JSON.stringify({ owner: owner2, id: "p1", rpId: "github.com", challenge: "AQID", allow: [], userVerification: "preferred" }),
    },
    "S",
  );
  await turn();
  assert.equal(asks2.at(-1)?.rpId, "github.com");
  await v2.passkey({ id: "p1", credential: "Y3JlZA", authenticatorData: "YQ", signature: "c2ln" });
  const passkeyReply = cdp.of("Runtime.evaluate").at(-1)!;
  assert.equal(passkeyReply.params.contextId, 99, "passkey assertion delivered strictly to calling executionContextId");
  assert.match(passkeyReply.params.expression, /location\.origin !== "https:\/\/app\.github\.com"/, "atomic origin guard prevents cross-site contextId reuse");

  // Verify the atomic origin guard blocks delivery when Chromium reuses executionContextId=1 on a different origin.
  let delivered = false;
  vm.runInNewContext(passkeyReply.params.expression, {
    location: { origin: "https://evil.test" },
    window: { __stillfailPasskeyReply: () => { delivered = true; } },
  });
  assert.equal(delivered, false);

  // Invalid passkey params must still settle with NotAllowedError rather than hanging the page Promise.
  const beforeInvalid = cdp.of("Runtime.evaluate").length;
  cdp.emit(
    "Runtime.bindingCalled",
    {
      name: binding2,
      executionContextId: 100,
      payload: JSON.stringify({ owner: owner2, id: "bad1", rpId: "github.com", challenge: "not base64url!!", allow: [] }),
    },
    "S",
  );
  await turn();
  const invalidReply = cdp.of("Runtime.evaluate").slice(beforeInvalid).at(-1)!;
  assert.equal(invalidReply.params.contextId, 100);
  assert.match(invalidReply.params.expression, /"error":"NotAllowedError"/);

  stop2();
  v2.close();
  v.close();
});

test("watchLogin runs in isolated world stillfail-login, blocks plaintext http, and invalidates stale async prompts on navigation", async () => {
  const cdp = new FakeCdp();
  let resolveUrl!: (u: string) => void;
  cdp.answers["Page.getFrameTree"] = () => ({ frameTree: { frame: { id: "F1" } } });
  cdp.answers["Page.createIsolatedWorld"] = () => ({ executionContextId: 77 });
  cdp.answers["Target.getTargetInfo"] = () => new Promise((r) => (resolveUrl = (url) => r({ targetInfo: { url } })));

  const v = new TabView({ cdp, session: "S", targetId: "T", now: () => 0 });
  const heard: any[] = [];
  const stop = v.watchLogin((l) => heard.push(l));
  await turn();

  // Installed into isolated world "stillfail-login" with Runtime.enable BEFORE createIsolatedWorld (required on Chromium 156).
  assert.deepEqual(cdp.of("Runtime.addBinding")[0]!.params, { name: LOGIN_BINDING, executionContextName: "stillfail-login" });
  assert.equal(cdp.of("Page.addScriptToEvaluateOnNewDocument")[0]!.params.worldName, "stillfail-login");
  assert.deepEqual(cdp.of("Page.createIsolatedWorld")[0]!.params, { frameId: "F1", worldName: "stillfail-login" });
  assert.equal(cdp.of("Runtime.evaluate")[0]!.params.contextId, 77);
  const enableIdx = cdp.sent.findIndex((s) => s.method === "Runtime.enable");
  const createWorldIdx = cdp.sent.findIndex((s) => s.method === "Page.createIsolatedWorld");
  assert.ok(enableIdx >= 0 && enableIdx < createWorldIdx, "Runtime.enable must precede Page.createIsolatedWorld");

  // Trigger a login prompt while Target.getTargetInfo is pending, then navigate before it resolves -> stale result discarded!
  cdp.emit("Runtime.bindingCalled", { name: LOGIN_BINDING, payload: '{"field":"password"}' }, "S");
  cdp.emit("Page.frameNavigated", { frame: { id: "F1", url: "https://other.example/" } }, "S");
  assert.deepEqual(heard, [null], "navigation immediately clears login prompt");
  resolveUrl("https://github.com/login");
  await turn();
  assert.deepEqual(heard, [null], "late async URL lookup from before navigation must not re-pop old prompt");

  // Plaintext http://example.com -> must report null, not a login prompt.
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: "http://example.com/login" } });
  cdp.emit("Runtime.bindingCalled", { name: LOGIN_BINDING, payload: '{"field":"password"}' }, "S");
  await turn();
  assert.deepEqual(heard, [null, null]);

  // Loopback http://127.0.0.1:8080 locks #loginOrigin so fill() refuses same host on a different port.
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: "http://127.0.0.1:8080/login" } });
  cdp.emit("Runtime.bindingCalled", { name: LOGIN_BINDING, payload: '{"field":"password"}' }, "S");
  await turn();
  assert.deepEqual(heard.at(-1), { host: "127.0.0.1", field: "password" });

  const evalsBeforeFill = cdp.of("Runtime.evaluate").length;
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: "http://127.0.0.1:9999/login" } });
  await v.fill({ host: "127.0.0.1", username: "u", password: "p" });
  assert.equal(cdp.of("Runtime.evaluate").length, evalsBeforeFill, "same host on different port is refused by #loginOrigin");

  // Navigation clears #loginOrigin: stale fill() is refused even if host matches!
  cdp.emit("Page.frameNavigated", { frame: { id: "F1", url: "http://127.0.0.1:9999/login" } }, "S");
  await v.fill({ host: "127.0.0.1", username: "u", password: "p" });
  assert.equal(cdp.of("Runtime.evaluate").length, evalsBeforeFill, "fill() refused after navigation clears #loginOrigin while watchLogin is active");

  stop();
  v.close();
});

test("TabView.fill refuses plaintext http:// and fillScript atomically aborts when location.origin changed", async () => {
  const cdp = new FakeCdp();
  cdp.answers["Page.getFrameTree"] = () => ({ frameTree: { frame: { id: "F1" } } });
  cdp.answers["Page.createIsolatedWorld"] = () => ({ executionContextId: 10 });
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: "http://example.com/login" } });
  const v = new TabView({ cdp, session: "S", targetId: "T", now: () => 0 });
  await v.fill({ host: "example.com", username: "u", password: "p" });
  assert.equal(cdp.of("Runtime.evaluate").length, 0, "plaintext http://example.com never filled");

  // https:// fills and passes expectedOrigin into fillScript.
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: "https://example.com/login" } });
  await v.fill({ host: "example.com", username: "u", password: "p" });
  assert.equal(cdp.of("Runtime.evaluate").length, 1);
  assert.match(cdp.of("Runtime.evaluate")[0]!.params.expression, /https:\/\/example\.com/);

  // Executing fillScript when location.origin already navigated to attacker.test must not write password.
  const script = fillScript("alice", "s3cr3t", "https://example.com");
  const sandbox: any = {
    location: { origin: "https://attacker.test" },
    document: { activeElement: null, querySelectorAll: () => { throw new Error("should not even touch DOM"); } },
  };
  const did = vm.runInNewContext(script, sandbox);
  assert.deepEqual({ ...did }, { username: false, password: false });
  v.close();
});

test("TabForm enforces HTTPS/PSL in on(), atomically types in isolated world, and aborts without recreating world on navigation TOCTOU", async () => {
  const cdp = new FakeCdp();
  let currentUrl = "http://example.com/login";
  cdp.answers["Target.getTargetInfo"] = () => ({ targetInfo: { url: currentUrl } });
  cdp.answers["Page.getFrameTree"] = () => ({ frameTree: { frame: { id: "F1" } } });
  cdp.answers["Page.createIsolatedWorld"] = () => ({ executionContextId: 11 });

  const form = new TabForm(cdp, "S", "T");
  assert.equal(await form.on("example.com"), false, "plaintext http://example.com rejected");

  currentUrl = "https://a.github.io/login";
  assert.equal(await form.on("github.io"), false, "public suffix github.io rejected");
  assert.equal(await form.on("a.github.io"), true, "registrable subdomain accepted");

  currentUrl = "http://127.0.0.1:3000/login";
  assert.equal(await form.on("127.0.0.1"), true, "loopback http://127.0.0.1 accepted");

  // Atomic type via execCommand succeeds without needing Input.insertText.
  currentUrl = "https://github.com/login";
  assert.equal(await form.on("github.com"), true);
  cdp.answers["Runtime.evaluate"] = () => ({ result: { value: "done" } });
  assert.equal(await form.type("password", "s3cr3t"), true);
  assert.equal(cdp.of("Input.insertText").length, 0);

  // Navigation destroys the isolated world during type(): must abort and return false without recreating the world!
  const worldsBefore = cdp.of("Page.createIsolatedWorld").length;
  cdp.answers["Runtime.evaluate"] = () => {
    throw new Error("Execution context was destroyed.");
  };
  assert.equal(await form.type("password", "s3cr3t"), false);
  assert.equal(cdp.of("Page.createIsolatedWorld").length, worldsBefore, "must not silently recreate world on navigated page");
  assert.equal(cdp.of("Input.insertText").length, 0);

  // Verify atomicTypeScript itself rejects origin mismatch synchronously, and falls back to native setter when execCommand returns false.
  const mismatch = vm.runInNewContext(atomicTypeScript("password", "s3cr3t", "https://github.com", true), {
    location: { protocol: "https:", hostname: "evil.test", origin: "https://evil.test" },
  });
  assert.equal(mismatch, "mismatch");

  let setterVal = "";
  const events: string[] = [];
  class FakeInput {
    tagName = "INPUT";
    type = "password";
    disabled = false;
    readOnly = false;
    value = "";
    getClientRects() { return [{}]; }
    getAttribute() { return null; }
    focus() { fakeDoc.activeElement = this; }
    select() {}
    getRootNode() { return fakeDoc; }
    dispatchEvent(e: any) { events.push(e.type); }
  }
  Object.defineProperty(FakeInput.prototype, "value", {
    get() { return setterVal; },
    set(v: string) { setterVal = v; },
    configurable: true,
  });
  const input = new FakeInput();
  const fakeDoc: any = {
    activeElement: null,
    querySelectorAll: (sel: string) => (sel === "*" ? [input] : []),
    execCommand: () => false,
  };
  const fallbackRes = vm.runInNewContext(atomicTypeScript("password", "s3cr3t", "https://github.com", true), {
    location: { protocol: "https:", hostname: "github.com", origin: "https://github.com" },
    document: fakeDoc,
    getComputedStyle: () => ({ visibility: "visible" }),
    HTMLInputElement: FakeInput,
    Event: class { type: string; constructor(t: string) { this.type = t; } },
  });
  assert.equal(fallbackRes, "done");
  assert.equal(setterVal, "s3cr3t");
  assert.deepEqual(events, ["input", "change"]);
});

test("FarviewForm enforces HTTPS/PSL, uses random nonces, and refuses typing after origin navigation", async () => {
  const seenScripts: string[] = [];
  const seenActs: any[] = [];
  let currentUrl = "http://example.com/login";
  const encodeStr = (s: string) => {
    const b = Buffer.from(s, "utf8");
    const out: number[] = [];
    let u = b.length * 2;
    while (u >= 0x80) {
      out.push((u & 0x7f) | 0x80);
      u >>>= 7;
    }
    out.push(u);
    return Buffer.concat([Buffer.from(out), b]);
  };
  const frameOf = (body: Buffer) => {
    const head = Buffer.alloc(4);
    head.writeUInt32BE(body.length);
    return Buffer.concat([head, body]);
  };
  const formSockets: Socket[] = [];
  const server = createServer((s) => {
    formSockets.push(s);
    let buf = Buffer.alloc(0);
    s.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      while (buf.length >= 4 && buf.length >= 4 + buf.readUInt32BE(0)) {
        const body = buf.subarray(4, 4 + buf.readUInt32BE(0));
        buf = buf.subarray(4 + body.length);
        let i = 0;
        const int = () => {
          let shift = 0, u = 0;
          for (;;) {
            const c = body[i++]!;
            u |= (c & 0x7f) << shift;
            shift += 7;
            if (c < 0x80) break;
          }
          u >>>= 0;
          return (u >>> 1) ^ -(u & 1);
        };
        const str = () => {
          const n = int();
          const v = body.subarray(i, i + n).toString("utf8");
          i += n;
          return v;
        };
        const kind = int();
        if (kind === 19) {
          // look -> seen
          s.write(frameOf(Buffer.concat([Buffer.from([20 * 2]), encodeStr(currentUrl), encodeStr("T"), encodeStr("")])));
        } else if (kind === 32) {
          const script = str();
          seenScripts.push(script);
          s.write(frameOf(Buffer.concat([Buffer.from([33 * 2]), encodeStr("true")])));
        } else if (kind === 18) {
          seenActs.push({ verb: str(), selector: str(), text: str() });
          s.write(frameOf(Buffer.concat([Buffer.from([20 * 2]), encodeStr(currentUrl), encodeStr("T"), encodeStr("")])));
        }
      }
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  try {
    const form = new FarviewForm(port);
    assert.equal(await form.on("example.com"), false, "plaintext http://example.com rejected");
    currentUrl = "https://a.github.io/login";
    assert.equal(await form.on("github.io"), false, "public suffix rejected");
    assert.equal(await form.on("a.github.io"), true);

    assert.equal(await form.type("username", "alice"), true);
    assert.match(seenActs[0]!.selector, /^\[data-stillfail-signin-[0-9a-f]{16}\]$/, "random nonce attribute used");
    assert.match(seenScripts.at(-1)!, /location\.origin !== "https:\/\/a\.github\.io"/);

    // Origin changes before next type() -> must refuse and not send act:type.
    currentUrl = "https://evil.test/phish";
    assert.equal(await form.type("password", "s3cr3t"), false);
    assert.equal(seenActs.length, 1, "password never typed after origin changed");

    // mark() uses random window property instead of fixed __stillfailSent.
    await form.mark();
    assert.match(seenScripts.at(-1)!, /__stillfailSent_[0-9a-f]{16}/);
  } finally {
    for (const s of formSockets) s.destroy();
    server.close();
  }
});

test("CDP Gate hardens dangerous methods, flatten, windowId whitelist, WebAuthn.*, and O(1) wants() over 1 MiB", () => {
  const g = new Gate({ context: "C1", contextOf: (id) => (id === "A" ? "C1" : id === "X" ? "C2" : undefined) });
  const client = (m: object) => {
    const r = g.fromClient(JSON.stringify(m));
    return { up: r.up.map((x) => JSON.parse(x)), down: r.down.map((x) => JSON.parse(x)) };
  };
  const chrome = (m: object) => {
    const text = JSON.stringify(m);
    const r = g.wants(text) ? g.fromChrome(text) : { up: [], down: [text] };
    return { up: r.up.map((x) => JSON.parse(x)), down: r.down.map((x) => JSON.parse(x)) };
  };

  // 1. Removed dangerous browser methods refused.
  for (const method of ["Target.exposeDevToolsProtocol", "Target.setRemoteLocations", "Target.sendMessageToTarget", "WebAuthn.enable"]) {
    const r = client({ id: 1, method, params: { targetId: "A", sessionId: "SA" } });
    assert.equal(r.up.length, 0, method);
    assert.ok(r.down[0].error, method);
  }

  // 2. Target.attachToTarget requires flatten: true.
  assert.ok(client({ id: 2, method: "Target.attachToTarget", params: { targetId: "A" } }).down[0].error);
  assert.ok(client({ id: 3, method: "Target.attachToTarget", params: { targetId: "A", flatten: false } }).down[0].error);
  assert.equal(client({ id: 4, method: "Target.attachToTarget", params: { targetId: "A", flatten: true } }).up.length, 1);
  chrome({ id: 4, result: { sessionId: "SA" } });

  // 3. Playwright root-level Target.setAutoAttach with waitForDebuggerOnStart: true is allowed.
  assert.equal(
    client({ id: 5, method: "Target.setAutoAttach", params: { autoAttach: true, waitForDebuggerOnStart: true, flatten: true } }).up.length,
    1,
  );

  // 4. WebAuthn.* on target session is refused (both getCredentials and disable).
  for (const method of ["WebAuthn.getCredentials", "WebAuthn.disable", "WebAuthn.removeVirtualAuthenticator"]) {
    const r = client({ id: 6, sessionId: "SA", method, params: {} });
    assert.equal(r.up.length, 0, method);
    assert.ok(r.down[0].error, method);
  }

  // 5. Window bounds require windowId previously granted via Browser.getWindowForTarget (both browser-level & page-session without targetId).
  assert.ok(client({ id: 7, method: "Browser.getWindowBounds", params: { windowId: 99 } }).down[0].error);
  assert.ok(client({ id: 8, method: "Browser.setWindowBounds", params: { windowId: 99, bounds: { width: 800 } } }).down[0].error);
  assert.ok(client({ id: 9, method: "Browser.getWindowForTarget", params: {} }).down[0].error, "browser-level without targetId refused");

  // Browser-level with own targetId records windowId 11.
  assert.equal(client({ id: 10, method: "Browser.getWindowForTarget", params: { targetId: "A" } }).up.length, 1);
  chrome({ id: 10, result: { windowId: 11, bounds: { width: 1200, height: 800 } } });
  assert.equal(client({ id: 11, method: "Browser.getWindowBounds", params: { windowId: 11 } }).up.length, 1);

  // Page-session call omitting targetId records windowId 12.
  assert.equal(client({ id: 12, sessionId: "SA", method: "Browser.getWindowForTarget", params: {} }).up.length, 1);
  chrome({ id: 12, sessionId: "SA", result: { windowId: 12, bounds: { width: 1200, height: 800 } } });
  assert.equal(client({ id: 13, sessionId: "SA", method: "Browser.setWindowBounds", params: { windowId: 12, bounds: { width: 1000 } } }).up.length, 1);

  // 6. > 1 MiB Target.getTargets response IS inspected and filtered, while > 1 MiB screenshot skips wants() in O(1).
  client({ id: 20, method: "Target.getTargets", params: {} });
  const bigPad = "a".repeat(1_200_000);
  const bigTargets = JSON.stringify({
    id: 20,
    result: {
      targetInfos: [
        { targetId: "A", browserContextId: "C1", title: bigPad },
        { targetId: "X", browserContextId: "C2", title: "secret" },
      ],
    },
  });
  assert.ok(bigTargets.length > 1 << 20);
  assert.equal(g.wants(bigTargets), true, "> 1 MiB pending Target.getTargets must still be filtered");
  const filtered = JSON.parse(g.fromChrome(bigTargets).down[0]!);
  assert.deepEqual(
    filtered.result.targetInfos.map((t: any) => t.targetId),
    ["A"],
  );

  // Even while another request is pending in #asked, an unrelated > 1 MiB screenshot returns wants() === false in O(1).
  client({ id: 21, method: "Target.getTargets", params: {} });
  const bigScreenshot = JSON.stringify({ id: 999, result: { data: bigPad }, sessionId: "SA" });
  assert.equal(g.wants(bigScreenshot), false, "> 1 MiB screenshot bypasses JSON.parse() in O(1)");

  // > 1 MiB Target.attachedToTarget for a foreign target is still inspected and detached at once.
  const bigForeignAttach = JSON.stringify({
    method: "Target.attachedToTarget",
    params: { sessionId: "SX", targetInfo: { targetId: "X", browserContextId: "C2", title: bigPad } },
  });
  assert.equal(g.wants(bigForeignAttach), true);
  const detached = g.fromChrome(bigForeignAttach);
  assert.equal(detached.down.length, 0);
  assert.equal(JSON.parse(detached.up[0]!).method, "Target.detachFromTarget");

  // 7. Non-Target events on a #foreign session are intercepted and dropped.
  const foreignNonTarget = JSON.stringify({ method: "Runtime.consoleAPICalled", params: { type: "log" }, sessionId: "SX" });
  assert.equal(g.wants(foreignNonTarget), true);
  assert.equal(g.fromChrome(foreignNonTarget).down.length, 0);

  // 8. Negative id > 1 MiB Target.getTargets is still inspected and filtered (no bypass).
  client({ id: -5, method: "Target.getTargets", params: {} });
  const negBigTargets = JSON.stringify({
    id: -5,
    result: {
      targetInfos: [
        { targetId: "A", browserContextId: "C1", title: bigPad },
        { targetId: "X", browserContextId: "C2", title: "secret" },
      ],
    },
  });
  assert.equal(g.wants(negBigTargets), true);
  const negFiltered = JSON.parse(g.fromChrome(negBigTargets).down[0]!);
  assert.deepEqual(
    negFiltered.result.targetInfos.map((t: any) => t.targetId),
    ["A"],
  );

  // 9. Page-session Target.attachToTarget response with inner result.sessionId AND outer sessionId must match outer sessionId.
  assert.equal(client({ id: 30, sessionId: "SA", method: "Target.attachToTarget", params: { targetId: "A", flatten: true } }).up.length, 1);
  const nestedSessionReply = JSON.stringify({ id: 30, result: { sessionId: "SN" }, sessionId: "SA" });
  assert.equal(g.wants(nestedSessionReply), true, "outer sessionId SA matches #asked instead of inner result.sessionId SN");
  g.fromChrome(nestedSessionReply);
  assert.equal(client({ id: 31, sessionId: "SN", method: "Runtime.evaluate", params: { expression: "1" } }).up.length, 1, "new session SN registered in #sessions");

  // 10. Invalid client message id is refused, and duplicate in-flight / reserved #own ids are refused.
  assert.ok(client({ id: 1.5, method: "Browser.getVersion", params: {} }).down[0].error);
  // id: 21 is still pending in #asked (from step 6): reusing id: 21 must be rejected instead of overwriting the filter.
  assert.ok(client({ id: 21, method: "Browser.getVersion", params: {} }).down[0].error, "duplicate in-flight id refused");
  // The detach sent for foreign SX used internal #own id (2_000_000_000): client sending that id while pending is refused.
  const ownId = JSON.parse(detached.up[0]!).id;
  assert.ok(client({ id: ownId, method: "Browser.getVersion", params: {} }).down[0].error, "collision with in-flight internal #own id refused");
});

test("notFromHere rejects Origin: null and browserDoor returns 404 for unknown sessions without calling browser.open", async () => {
  assert.ok(notFromHere({ host: "127.0.0.1:4000", origin: "null" }, [4000]) !== null);
  assert.ok(notFromHere({ host: "127.0.0.1:4000", origin: "null", "sec-fetch-site": "none" }, [4000]) !== null);
  assert.equal(notFromHere({ host: "127.0.0.1:4000" }, [4000]), null);

  const opened: string[] = [];
  const chrome = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>((r) => chrome.once("listening", () => r()));
  const route = browserDoor(
    {
      open: async (session) => {
        opened.push(session);
        return { ws: `ws://127.0.0.1:${(chrome.address() as any).port}/devtools/browser/x`, gate: { context: "C1", contextOf: () => undefined } };
      },
    },
    { hasSession: (s) => s === "CHAT/known" },
  );
  const door = await openAgentsDoor({ port: 0 }, new McpEndpoint(() => undefined, []), () => ({ status: 404, body: {} }), () => null, () => [route]);
  try {
    const unknown = new WebSocket(`ws://127.0.0.1:${door.port}${sessionPath("CHAT/unknown")}`);
    const status = await new Promise<number>((r) => unknown.once("unexpected-response", (_q, res) => r(res.statusCode ?? 0)));
    assert.equal(status, 404);
    assert.deepEqual(opened, [], "browser.open must not be called for unknown session");

    const known = new WebSocket(`ws://127.0.0.1:${door.port}${sessionPath("CHAT/known")}`);
    await new Promise<void>((r, j) => (known.once("open", () => r()), known.once("error", j)));
    assert.deepEqual(opened, ["CHAT/known"]);
    known.close();
  } finally {
    await door.close(0);
    await new Promise<void>((r) => chrome.close(() => r()));
  }
});

test("Farview IPC rejects truncated/overflow varints, negative/out-of-bounds strings, oversized frames, and oversized FrameLink lines/frames", async () => {
  // 1. decodeAnswer malformed inputs throw RangeError immediately (no infinite loop).
  assert.throws(() => decodeAnswer(Buffer.alloc(0)), RangeError);
  assert.throws(() => decodeAnswer(Buffer.from([0x80])), RangeError, "truncated varint");
  assert.throws(() => decodeAnswer(Buffer.from([0x80, 0x80, 0x80, 0x80, 0x80, 0x01])), RangeError, "6-byte overflow varint");
  assert.throws(() => decodeAnswer(Buffer.from([0x80, 0x80, 0x80, 0x80, 0x10])), RangeError, "5th byte upper nibble overflow");
  // KIND.value (33 -> zigzag 66) followed by negative string length (-1 -> zigzag 1)
  assert.throws(() => decodeAnswer(Buffer.from([66, 1])), RangeError, "negative string length");
  // KIND.value followed by string length 100 with only 2 bytes left
  assert.throws(() => decodeAnswer(Buffer.from([66, 0xc8, 0x01, 0x41, 0x42])), RangeError, "out-of-bounds string length");

  // 2. askTab rejects immediately on oversized frame header and on malformed varint frame.
  const sockets: Socket[] = [];
  let mode: "oversize" | "truncated" = "oversize";
  const agentServer = createServer((s) => {
    sockets.push(s);
    s.once("data", () => {
      if (mode === "oversize") {
        const head = Buffer.alloc(4);
        head.writeUInt32BE(MAX_AGENT_FRAME + 1);
        s.write(head);
      } else {
        const head = Buffer.alloc(4);
        head.writeUInt32BE(1);
        s.write(Buffer.concat([head, Buffer.from([0x80])]));
      }
    });
  });
  await new Promise<void>((r) => agentServer.listen(0, "127.0.0.1", r));
  const agentPort = (agentServer.address() as { port: number }).port;
  try {
    mode = "oversize";
    await assert.rejects(askTab(agentPort, { kind: "look" }), RangeError);
    mode = "truncated";
    await assert.rejects(askTab(agentPort, { kind: "look" }), RangeError);
  } finally {
    for (const s of sockets) s.destroy();
    agentServer.close();
  }

  // 3. FrameLink closes immediately on oversized binary frame length, non-number/non-integer length, or oversized line without newline.
  const frameSockets: Socket[] = [];
  let frameMode: "huge-bytes" | "bad-bytes" | "string-bytes" | "huge-line" = "huge-bytes";
  const frameServer = createServer((s) => {
    frameSockets.push(s);
    s.once("data", () => {
      if (frameMode === "huge-bytes") {
        s.write(`${JSON.stringify({ frame: { seq: 1, width: 1, height: 1, format: "jpeg", bytes: MAX_FRAME_BINARY_BYTES + 1 } })}\n`);
      } else if (frameMode === "bad-bytes") {
        s.write(`${JSON.stringify({ frame: { seq: 1, width: 1, height: 1, format: "jpeg", bytes: 1.5 } })}\n`);
      } else if (frameMode === "string-bytes") {
        s.write(`${JSON.stringify({ frame: { seq: 1, width: 1, height: 1, format: "jpeg", bytes: "10" } })}\n`);
      } else {
        s.write(Buffer.alloc(MAX_FRAME_LINE_BYTES + 16, 0x61));
      }
    });
  });
  await new Promise<void>((r) => frameServer.listen(0, "127.0.0.1", r));
  const framePort = (frameServer.address() as { port: number }).port;
  try {
    for (const m of ["huge-bytes", "bad-bytes", "string-bytes", "huge-line"] as const) {
      frameMode = m;
      const link = new FrameLink(framePort);
      const got = await link.picture();
      assert.equal(got, null, `FrameLink must close and resolve null on ${m}`);
      link.close();
    }
  } finally {
    for (const s of frameSockets) s.destroy();
    frameServer.close();
  }

  // 4. FarviewView gates copied clipboard events on a 5s human gesture window and clears it on navigation.
  const fvSockets: Socket[] = [];
  const fvServer = createServer((s) => {
    fvSockets.push(s);
  });
  await new Promise<void>((r) => fvServer.listen(0, "127.0.0.1", r));
  const fvPort = (fvServer.address() as { port: number }).port;
  let now = 10_000;
  const fvScreen = new FarviewScreen({ session: "chat:fv-sec", port: fvPort, now: () => now });
  try {
    const view = await fvScreen.open({ maxWidth: 800, maxHeight: 600, codecs: ["jpeg"] });
    const clips: string[] = [];
    view.watchClipboard!((c) => { if (c.type === "text") clips.push(c.text); });
    for (let i = 0; i < 200 && fvSockets.length === 0; i++) await new Promise((r) => setImmediate(r));
    assert.equal(fvSockets.length, 1);
    const sock = fvSockets[0]!;
    // Unprompted copy dropped
    sock.write(`${JSON.stringify({ copied: "unprompted" })}\n`);
    await turn();
    assert.deepEqual(clips, []);
    // Within 5s of human click -> accepted
    await view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
    now += 4_000;
    sock.write(`${JSON.stringify({ copied: "allowed" })}\n`);
    for (let i = 0; i < 200 && clips.length === 0; i++) await new Promise((r) => setImmediate(r));
    assert.deepEqual(clips, ["allowed"]);
    // Navigation clears gesture window
    sock.write(`${JSON.stringify({ page: { url: "https://other.example/", title: "Other" } })}\n`);
    sock.write(`${JSON.stringify({ copied: "after-nav" })}\n`);
    await turn();
    assert.deepEqual(clips, ["allowed"]);
    view.close();
  } finally {
    fvScreen.close();
    for (const s of fvSockets) s.destroy();
    fvServer.close();
  }
});
