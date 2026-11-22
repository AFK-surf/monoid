import assert from "node:assert/strict";
import test from "node:test";
import { ulid } from "ulid";
import { digest, randomSecret, type Tokens } from "../src/auth.ts";
import { harness } from "./harness.ts";

type H = Awaited<ReturnType<typeof harness>>;
type Answer = Awaited<ReturnType<H["fetch"]>>;

const APPLE_SUB = "001234.0123456789abcdef0123456789abcdef.1234";

/** Starts a browser sign-in flow at `/v1/auth/google/start` and returns helpers for the choose/code pages. */
async function startBrowser(h: H, address: string, callback = "http://127.0.0.1:32145/oauth/callback") {
  const verifier = randomSecret(),
    state = randomSecret();
  const query = new URLSearchParams({ state, redirect_uri: callback, code_challenge: await digest(verifier), code_challenge_method: "S256", name: "iPhone" });
  const start = await h.fetch("/v1/auth/google/start?" + query, { redirect: "manual", headers: { "cf-connecting-ip": address } });
  assert.equal(start.status, 200, "choosePage should be shown");
  const page = await start.text();
  const id = /action="\/v1\/auth\/login\/([A-Za-z0-9_-]{43})"/.exec(page)![1]!;
  const cookie = start.headers.get("set-cookie")!.split(";")[0]!;
  const csrf = cookie.split("=")[1]!;
  const post = (fields: Record<string, string>) =>
    h.fetch(`/v1/auth/login/${id}`, {
      method: "POST",
      redirect: "manual",
      headers: { "content-type": "application/x-www-form-urlencoded", origin: h.origin, cookie, "cf-connecting-ip": address },
      body: new URLSearchParams({ csrf, ...fields }).toString(),
    });
  const exchange = async (finished: Answer) => {
    assert.equal(finished.status, 302);
    const location = new URL(finished.headers.get("location")!);
    assert.equal(finished.headers.get("location")!.split("?")[0], callback);
    assert.equal(location.searchParams.get("state"), state);
    const answer = await h.fetch("/v1/auth/token", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: location.searchParams.get("code"), code_verifier: verifier, redirect_uri: callback }),
    });
    assert.equal(answer.status, 200);
    return (await answer.json()) as Tokens;
  };
  return { id, verifier, state, callback, page, start, cookie, csrf, post, exchange };
}

/** Completes Apple's cross-site form_post + same-site GET callback starting from a 302 authorize redirect. */
async function completeApple(
  h: H,
  authorize: URL,
  cookie: string,
  sub: string,
  opts: { email?: string; name?: { firstName: string; lastName: string }; refreshToken?: string | null; emailVerified?: boolean | string; invalid?: string; sendCookie?: boolean; address?: string } = {},
) {
  const appleCode = ulid();
  h.appleCodes.set(appleCode, {
    nonce: authorize.searchParams.get("nonce")!,
    sub,
    email: opts.email,
    refreshToken: opts.refreshToken,
    emailVerified: opts.emailVerified,
    invalid: opts.invalid,
  });
  const form = new URLSearchParams({ state: authorize.searchParams.get("state")!, code: appleCode });
  if (opts.name) form.set("user", JSON.stringify({ name: opts.name, email: opts.email }));
  if (opts.invalid === "cancel") {
    form.delete("code");
    form.set("error", "user_cancelled_authorize");
  }
  const posted = await h.fetch("/v1/auth/apple/callback", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: "https://appleid.apple.com" },
    body: form,
    redirect: "manual",
  });
  const again = posted.status === 303 ? new URL(posted.headers.get("location")!) : null;
  const back = again
    ? await h.fetch(again.pathname + again.search, {
        headers: {
          ...(opts.sendCookie === false ? {} : { cookie }),
          ...(opts.address ? { "cf-connecting-ip": opts.address } : {}),
        },
        redirect: "manual",
      })
    : null;
  return { posted, again, back, redirect: back?.status === 302 ? new URL(back.headers.get("location")!) : null };
}

/** Extracts the 6-digit OTP code from the latest email sent to `to`. */
function codeFor(h: H, to: string): string {
  const mail = h.mails.filter((m) => m.to.toLowerCase() === to.toLowerCase()).at(-1);
  assert.ok(mail, `expected a mail to ${to}`);
  const match = /\b(\d{3}) (\d{3})\b/.exec(mail.text);
  assert.ok(match, `expected grouped 6-digit code in ${JSON.stringify(mail.text)}`);
  return match[1]! + match[2]!;
}

test("Sign in with Apple via choosePage: Private Relay new user, name preserved on 2nd login, CSP allows appleid", async () => {
  const h = await harness({ apple: true, mail: true });
  try {
    const health = (await (await h.fetch("/healthz")).json()) as { google_login: boolean; apple_login: boolean };
    assert.equal(health.google_login, true);
    assert.equal(health.apple_login, true);

    const b = await startBrowser(h, "10.20.0.1");
    assert.match(b.page, /name="via" value="google"/);
    assert.match(b.page, /name="via" value="apple"/);
    assert.match(b.start.headers.get("content-security-policy")!, /form-action 'self' https:\/\/accounts\.google\.com https:\/\/appleid\.apple\.com;/);

    const gone = await b.post({ via: "apple" });
    assert.equal(gone.status, 302);
    const authorize = new URL(gone.headers.get("location")!);
    assert.equal(authorize.origin + authorize.pathname, "https://appleid.apple.com/auth/authorize");
    assert.equal(authorize.searchParams.get("client_id"), "test-apple-services");
    assert.equal(authorize.searchParams.get("redirect_uri"), `${h.origin}/v1/auth/apple/callback`);
    assert.equal(authorize.searchParams.get("response_mode"), "form_post");
    assert.equal(authorize.searchParams.get("scope"), "name email");

    const first = await completeApple(h, authorize, gone.headers.get("set-cookie")!.split(";")[0]!, APPLE_SUB, {
      email: "hidden@privaterelay.appleid.com",
      name: { firstName: "Ada", lastName: "Lovelace" },
      emailVerified: true,
    });
    assert.equal(first.posted.status, 303);
    assert.equal(first.again!.searchParams.has("code"), false, "authorization code stays out of URL");
    const tokens = await b.exchange(first.back!);
    assert.equal(tokens.subject, "apple_001234_0123456789abcdef0123456789abcdef_1234");
    assert.equal(tokens.email, "hidden@privaterelay.appleid.com");
    assert.equal(tokens.name, "Ada Lovelace");

    // Second Apple sign-in sends no `user.name`: the stored name is preserved in both Account and Directory.
    const b2 = await startBrowser(h, "10.20.0.2");
    const gone2 = await b2.post({ via: "apple" });
    const secondFlow = await completeApple(h, new URL(gone2.headers.get("location")!), gone2.headers.get("set-cookie")!.split(";")[0]!, APPLE_SUB, {
      email: "hidden@privaterelay.appleid.com",
    });
    const tokens2 = await b2.exchange(secondFlow.back!);
    assert.equal(tokens2.subject, tokens.subject);
    assert.equal(tokens2.name, "Ada Lovelace");
    const me = (await (await h.as(tokens2)("GET", "/v1/me")).json()) as { user: { name: string; email: string } };
    assert.equal(me.user.name, "Ada Lovelace");
    assert.equal(me.user.email, "hidden@privaterelay.appleid.com");
  } finally {
    await h.close();
  }
});

test("Comma-style OTP linking: existing Google account requires email OTP before linking Apple, then signs in directly", async () => {
  const h = await harness({ apple: true, mail: true });
  try {
    // Existing Google user with a workspace, name and avatar.
    const google = await h.login("carol");
    assert.equal(google.subject, "carol");
    assert.equal(google.email, "carol@example.test");
    const createdWs = await h.as(google)("POST", "/v1/workspaces", { name: "Carol Studio" });
    assert.equal(createdWs.status, 200);

    // First-time Apple sign-in with the same verified email must NOT silently merge.
    const b = await startBrowser(h, "10.21.0.1", "stillfail://auth/callback");
    const gone = await b.post({ via: "apple" });
    const flow = await completeApple(h, new URL(gone.headers.get("location")!), gone.headers.get("set-cookie")!.split(";")[0]!, "009999.carol.0001", {
      email: "carol@example.test",
      name: { firstName: "Carol", lastName: "Apple" },
      refreshToken: "rt-carol-apple-1",
      address: "10.21.0.1",
    });
    assert.equal(flow.back!.status, 200, "should show email OTP linking page instead of signing in");
    const html = await flow.back!.text();
    assert.match(html, /carol@example\.test/);
    assert.match(html, /name="code"/);
    assert.match(flow.back!.headers.get("content-security-policy")!, /form-action 'self' https:\/\/accounts\.google\.com stillfail:;/);
    assert.equal(h.mails.length, 1);
    assert.equal(h.mails[0]!.to, "carol@example.test");

    // Wrong OTP is rejected and does not link.
    const otp = codeFor(h, "carol@example.test");
    const wrong = await b.post({ via: "code", code: otp === "000000" ? "111111" : "000000" });
    assert.equal(wrong.status, 200);
    assert.match(await wrong.text(), /4/);

    // Valid OTP links Apple to Carol's existing Google account and keeps her workspaces, name and avatar.
    const linked = await b.post({ via: "code", code: otp });
    const appleTokens = await b.exchange(linked);
    assert.equal(appleTokens.subject, "carol", "linked to original Google account sub");
    assert.equal(appleTokens.name, "Name of carol", "keeps original account name");
    const me = (await (await h.as(appleTokens)("GET", "/v1/me")).json()) as { user: { name: string; picture: string }; workspaces: { name: string }[] };
    assert.equal(me.user.name, "Name of carol");
    assert.equal(me.user.picture, "https://example.test/p.png");
    assert.equal(me.workspaces.length, 1);
    assert.equal(me.workspaces[0]!.name, "Carol Studio");

    // Subsequent Apple sign-in goes straight in with NO OTP email.
    const mailCountBefore = h.mails.length;
    const b2 = await startBrowser(h, "10.21.0.2");
    const gone2 = await b2.post({ via: "apple" });
    const flow2 = await completeApple(h, new URL(gone2.headers.get("location")!), gone2.headers.get("set-cookie")!.split(";")[0]!, "009999.carol.0001", {
      email: "carol@example.test",
      refreshToken: "rt-carol-apple-2",
    });
    assert.equal(flow2.back!.status, 302, "already linked: goes straight to callback");
    assert.equal(h.mails.length, mailCountBefore, "no OTP sent on subsequent Apple login");
    const tokens2 = await b2.exchange(flow2.back!);
    assert.equal(tokens2.subject, "carol");
    assert.equal(tokens2.name, "Name of carol");

    // Deleting the linked Google account also revokes its linked Apple refresh token.
    const del = await h.as(tokens2)("DELETE", "/v1/me");
    assert.equal(del.status, 200);
    assert.equal(h.appleRevoked.length, 1);
    assert.equal(h.appleRevoked[0]!.token, "rt-carol-apple-2");
  } finally {
    await h.close();
  }
});

test("DELETE /v1/me revokes stored Apple refresh token and cleans up apple_identities", async () => {
  const h = await harness({ apple: true, mail: true });
  try {
    const b = await startBrowser(h, "10.22.0.1");
    const gone = await b.post({ via: "apple" });
    const flow = await completeApple(h, new URL(gone.headers.get("location")!), gone.headers.get("set-cookie")!.split(";")[0]!, "007777.delete.0001", {
      email: "delete-me@privaterelay.appleid.com",
      name: { firstName: "Delete", lastName: "Me" },
      refreshToken: "rt-to-revoke-123",
    });
    const tokens = await b.exchange(flow.back!);

    // Delete account: must call Apple /auth/revoke with the stored refresh_token.
    const del = await h.as(tokens)("DELETE", "/v1/me");
    assert.equal(del.status, 200);
    assert.equal(h.appleRevoked.length, 1);
    assert.deepEqual(h.appleRevoked[0], {
      token: "rt-to-revoke-123",
      tokenTypeHint: "refresh_token",
      clientId: "test-apple-services",
    });
    assert.equal((await h.as(tokens)("GET", "/v1/me")).status, 401);

    // Signing in again with the same Apple sub works cleanly after deletion (fresh account, no stale link error).
    const b2 = await startBrowser(h, "10.22.0.2");
    const gone2 = await b2.post({ via: "apple" });
    const flow2 = await completeApple(h, new URL(gone2.headers.get("location")!), gone2.headers.get("set-cookie")!.split(";")[0]!, "007777.delete.0001", {
      email: "delete-me@privaterelay.appleid.com",
    });
    const tokens2 = await b2.exchange(flow2.back!);
    assert.equal(tokens2.subject, tokens.subject);
  } finally {
    await h.close();
  }
});

test("DELETE /v1/me still succeeds if Apple revoke endpoint temporarily fails", async () => {
  const h = await harness({ apple: true, appleRevokeFail: true });
  try {
    const b = await startBrowser(h, "10.23.0.1");
    const gone = await b.post({ via: "apple" });
    const flow = await completeApple(h, new URL(gone.headers.get("location")!), gone.headers.get("set-cookie")!.split(";")[0]!, "007777.fail.0002", {
      email: "revoke-fail@privaterelay.appleid.com",
      refreshToken: "rt-fail-1",
    });
    const tokens = await b.exchange(flow.back!);
    const del = await h.as(tokens)("DELETE", "/v1/me");
    assert.equal(del.status, 200);
    assert.equal((await h.as(tokens)("GET", "/v1/me")).status, 401);
  } finally {
    await h.close();
  }
});

test("security: cookie binding, single-use replay, invalid claims, cancel, and unlinked Apple admin rejection", async () => {
  const h = await harness({ apple: true });
  try {
    // Missing cookie on GET callback is rejected.
    const b1 = await startBrowser(h, "10.24.0.1");
    const g1 = await b1.post({ via: "apple" });
    const stolen = await completeApple(h, new URL(g1.headers.get("location")!), g1.headers.get("set-cookie")!.split(";")[0]!, APPLE_SUB, { sendCookie: false });
    assert.equal(stolen.back!.status, 400);

    // Replaying POST callback a second time is rejected.
    const b2 = await startBrowser(h, "10.24.0.2");
    const g2 = await b2.post({ via: "apple" });
    const auth2 = new URL(g2.headers.get("location")!);
    await completeApple(h, auth2, g2.headers.get("set-cookie")!.split(";")[0]!, APPLE_SUB);
    const replay = await h.fetch("/v1/auth/apple/callback", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ state: auth2.searchParams.get("state")!, code: "another" }),
      redirect: "manual",
    });
    assert.equal(replay.status, 400);

    // Cancel and invalid claims fail closed.
    const bCancel = await startBrowser(h, "10.24.0.3");
    const gCancel = await bCancel.post({ via: "apple" });
    const cancelled = await completeApple(h, new URL(gCancel.headers.get("location")!), gCancel.headers.get("set-cookie")!.split(";")[0]!, APPLE_SUB, { invalid: "cancel" });
    assert.equal(cancelled.redirect!.searchParams.get("error"), "login_cancelled");

    for (const [i, invalid] of (["nonce", "aud", "email", "noEmail"] as const).entries()) {
      const bBad = await startBrowser(h, `10.24.1.${i + 1}`);
      const gBad = await bBad.post({ via: "apple" });
      const wrong = await completeApple(h, new URL(gBad.headers.get("location")!), gBad.headers.get("set-cookie")!.split(";")[0]!, APPLE_SUB, { invalid });
      assert.equal(wrong.redirect!.searchParams.get("error"), "apple_login_failed", invalid);
      assert.equal(wrong.redirect!.searchParams.has("code"), false, invalid);
    }

    // Unlinked Apple account using ADMIN_EMAIL cannot access admin console, and does not shadow Google's admin account.
    const bAdmin = await startBrowser(h, "10.24.2.1");
    const gAdmin = await bAdmin.post({ via: "apple" });
    const adminFlow = await completeApple(h, new URL(gAdmin.headers.get("location")!), gAdmin.headers.get("set-cookie")!.split(";")[0]!, "000999.admin.0001", {
      email: "alice@example.test",
    });
    const appleAdmin = await bAdmin.exchange(adminFlow.back!);
    assert.equal(appleAdmin.email, "alice@example.test");
    assert.equal((await h.as(appleAdmin, "admin")("GET", "/v1/admin/me")).status, 404);

    // Real Google admin alice still gets admin console access.
    const googleAdmin = await h.login("alice");
    assert.equal(googleAdmin.subject, "alice");
    assert.equal((await h.as(googleAdmin, "admin")("GET", "/v1/admin/me")).status, 200);

    // Console host redirects /v1/auth/apple/start to PUBLIC_ORIGIN.
    const moved = await h.fetchAdmin("/v1/auth/apple/start?state=x", { redirect: "manual" });
    assert.equal(moved.status, 302);
    assert.equal(moved.headers.get("location"), `${h.origin}/v1/auth/apple/start?state=x`);
  } finally {
    await h.close();
  }
});

test("device login with Apple works end-to-end and without Apple configured returns 503", async () => {
  const h = await harness({ apple: true, mail: true });
  try {
    const id = randomSecret(),
      verifier = randomSecret();
    const started = await h.fetch("/v1/auth/device", {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "10.25.0.1" },
      body: JSON.stringify({ id, code_challenge: await digest(verifier), name: "MacBook" }),
    });
    assert.equal(started.status, 200);
    const { verification_uri } = (await started.json()) as { verification_uri: string };
    const page = await h.fetch(new URL(verification_uri).pathname, { headers: { "cf-connecting-ip": "10.25.0.1" } });
    const html = await page.text();
    assert.match(html, /name="via" value="apple"/);
    const cookie = page.headers.get("set-cookie")!.split(";")[0]!;
    const gone = await h.fetch(`/v1/auth/login/${id}`, {
      method: "POST",
      redirect: "manual",
      headers: { "content-type": "application/x-www-form-urlencoded", origin: h.origin, cookie, "cf-connecting-ip": "10.25.0.1" },
      body: new URLSearchParams({ csrf: cookie.split("=")[1]!, via: "apple" }).toString(),
    });
    assert.equal(gone.status, 302);
    const done = await completeApple(h, new URL(gone.headers.get("location")!), gone.headers.get("set-cookie")!.split(";")[0]!, "005555.device.0001", {
      email: "device@privaterelay.appleid.com",
    });
    assert.equal(done.redirect!.pathname, "/v1/auth/device/complete");
    const polled = await h.fetch("/v1/auth/device/token", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id, code_verifier: verifier }),
    });
    assert.equal(polled.status, 200);
    const tokens = (await polled.json()) as Tokens;
    assert.equal(tokens.email, "device@privaterelay.appleid.com");
  } finally {
    await h.close();
  }

  // Without Apple configured: /healthz reports apple_login: false and direct Apple routes answer 503.
  const plain = await harness();
  try {
    const health = (await (await plain.fetch("/healthz")).json()) as { apple_login: boolean };
    assert.equal(health.apple_login, false);
    assert.equal((await plain.fetch("/v1/auth/apple/start?state=x")).status, 503);
    assert.equal((await plain.fetch("/v1/auth/apple/callback", { method: "POST" })).status, 503);
    assert.equal((await plain.fetch("/v1/auth/apple/callback?state=x")).status, 503);
  } finally {
    await plain.close();
  }

  // Apple-only cloud (no Google, no email): choosePage offers Apple alone and signs in cleanly.
  const appleOnly = await harness({ apple: true, noGoogle: true });
  try {
    const b = await startBrowser(appleOnly, "10.26.0.1");
    assert.doesNotMatch(b.page, /name="via" value="google"/);
    assert.doesNotMatch(b.page, /type="email"/);
    assert.match(b.page, /name="via" value="apple"/);
    const gone = await b.post({ via: "apple" });
    const done = await completeApple(appleOnly, new URL(gone.headers.get("location")!), gone.headers.get("set-cookie")!.split(";")[0]!, "006666.only.0001", {
      email: "only-apple@privaterelay.appleid.com",
    });
    const tokens = await b.exchange(done.back!);
    assert.equal(tokens.email, "only-apple@privaterelay.appleid.com");
  } finally {
    await appleOnly.close();
  }
});
