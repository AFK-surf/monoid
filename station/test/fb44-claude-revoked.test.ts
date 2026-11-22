// FB-44: Anthropic answers a revoked Claude OAuth token 403 as well as 401. A check renews it and, still refused or its
// refresh token refused, says to sign in again (`login`), never `ok` or `unavailable`; asked again after a runtime was
// refused on it (`recheck`), a token whose models are still listed is renewed to find its login over. An allowance read
// refused so says the login is over (`signedOut`), an account the provider blocks staying `blocked`.
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkProfile, claudeAuthStatus, URLS } from "../src/accounts/profiles.ts";
import { claudeUsage, claudeWithRefresh } from "../src/accounts/quota.ts";
import { machine, provider, temp } from "./accounts-fakes.ts";

const base = { runtime: "claude" as const, key: "k", via: {}, env: {}, machine: false, lang: "zh" as const };

test("FB-44: 401 and 403 are a refused Claude OAuth token", () => {
  assert.ok(claudeAuthStatus(401) && claudeAuthStatus(403));
  assert.ok(!claudeAuthStatus(200) && !claudeAuthStatus(429) && !claudeAuthStatus(null));
});

test("FB-44: a Claude subscription answered 403 is renewed, and signed out when its refresh is refused or the new token refused too", async () => {
  const m = machine({ claude: `echo '{"loggedIn":true,"email":"a@x.com","subscriptionType":"max"}'` });
  const home = join(m.home, "profile");
  mkdirSync(home);
  const login = () => writeFileSync(join(home, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "tok", refreshToken: "r1", expiresAt: Date.now() + 3_600_000 } }));
  let renewal = 400;
  let renewed = "new";
  let listing = 403;
  const p = await provider((asked) => {
    if (asked.method === "POST") return renewal === 200 ? { status: 200, body: { access_token: renewed, refresh_token: "r2", expires_in: 3600 } } : { status: renewal, body: { error: "invalid_grant" } };
    return { status: listing, body: listing === 200 ? { data: [{ id: "claude-opus-5-5" }] } : { error: { type: "permission_error", message: "OAuth token revoked" } } };
  });
  const urls = { ...URLS, anthropic: p.base, claudeToken: p.base };
  const check = (recheck = false) => checkProfile({ ...base, kind: "subscription", home, env: m.env, urls, ...(recheck ? { recheck: true } : {}) });
  try {
    login();
    assert.equal((await check()).state, "login", "403, refresh refused");
    login();
    renewal = 200;
    const still = await check();
    assert.deepEqual([still.state, still.detail], ["login", "登录已过期或失效"], "403, renewed, 403 again");
    // Models still listed for a revoked token: not asked again, it stands; asked again after a refusal, its refresh
    // token refused is a login over.
    login();
    listing = 200;
    renewal = 400;
    assert.equal((await check()).state, "ok");
    login();
    assert.equal((await check(true)).state, "login");
    // The token endpoint not reached now: a listing that worked stands.
    login();
    renewal = 503;
    assert.equal((await check(true)).state, "ok");
  } finally {
    await p.close();
  }
});

test("FB-44: an allowance read refused 403 for the OAuth token is a login over; a blocked account stays blocked", async () => {
  let p = await provider(() => ({ status: 403, body: { error: { type: "permission_error", message: "OAuth token revoked" } } }));
  const revoked = await claudeUsage(p.base, "t", "zh");
  assert.deepEqual([revoked.state, revoked.detail], ["unavailable", "登录已过期或失效"]);
  await p.close();
  p = await provider(() => ({ status: 403, body: { error: { message: "This organization has been disabled." } } }));
  assert.equal((await claudeUsage(p.base, "t", "zh")).state, "blocked");
  await p.close();
  // Renewed and refused 403 again: signed out.
  const home = temp("revoked-403");
  writeFileSync(join(home, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "old", refreshToken: "r1", expiresAt: Date.now() + 3_600_000 } }));
  p = await provider((asked) => (asked.method === "POST" ? { status: 200, body: { access_token: "still-bad", refresh_token: "r2", expires_in: 3600 } } : { status: 403, body: { error: { message: "OAuth token revoked" } } }));
  const got = await claudeWithRefresh({}, home, { ...URLS, anthropic: p.base, claudeToken: p.base }, "zh");
  assert.deepEqual([got.state, got.signedOut], ["unavailable", true]);
  assert.deepEqual(p.asked.map((r) => r.method), ["GET", "POST", "GET"]);
  await p.close();
});
