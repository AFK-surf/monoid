import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import {
  COLAB_AUTH_FILE,
  COLAB_REQUIRED_SCOPE,
  COLAB_SCOPES,
  COLAB_SERVICE_ID,
  COLAB_XSSI_PREFIX,
  type ColabUrls,
  colabAuthorizeUrl,
  colabCallbackCode,
  colabCodeOf,
  ensureColabToken,
  exchangeColabCode,
  fetchCcuInfo,
  generateColabPkce,
  makeColabServiceAdapter,
  readColabAuth,
  writeColabAuth,
} from "../src/accounts/colab.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { makeAccounts } from "../src/accounts/index.ts";
import { LoginManager } from "../src/accounts/login.ts";
import { builtInServices, defaultServiceShareRefusal } from "../src/accounts/services.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { shareRefusal, signInFiles } from "../src/share/index.ts";
import { PROFILE_SERVICES_HEADER, RUNTIMES_HEADER, runtimeCompatible } from "../src/api/runtime-compat.ts";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { json, type Request } from "../src/api/request.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Store } from "../src/store/store.ts";

type MockState = {
  tokenStatus: number;
  tokenBody: Record<string, unknown>;
  refreshStatus: number;
  refreshBody: Record<string, unknown>;
  userinfoEmail: string;
  ccuResponses: Array<{ status: number; body: string }>;
  tokenCalls: Array<Record<string, string>>;
  ccuCalls: Array<{ auth: string | undefined; agent: string | undefined }>;
};

async function startMockColabServer(state: MockState): Promise<{ urls: ColabUrls; close: () => Promise<void> }> {
  const readBody = (req: IncomingMessage) =>
    new Promise<string>((resolve) => {
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    });

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (req.method === "POST" && url.pathname === "/token") {
      const form = Object.fromEntries(new URLSearchParams(await readBody(req)).entries());
      state.tokenCalls.push(form);
      if (form.grant_type === "refresh_token") {
        res.writeHead(state.refreshStatus, { "content-type": "application/json" });
        res.end(JSON.stringify(state.refreshBody));
        return;
      }
      res.writeHead(state.tokenStatus, { "content-type": "application/json" });
      res.end(JSON.stringify(state.tokenBody));
      return;
    }
    if (req.method === "GET" && url.pathname === "/userinfo") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ email: state.userinfoEmail }));
      return;
    }
    if (req.method === "GET" && url.pathname === "/tun/m/ccu-info") {
      state.ccuCalls.push({
        auth: req.headers.authorization,
        agent: typeof req.headers["x-colab-client-agent"] === "string" ? req.headers["x-colab-client-agent"] : undefined,
      });
      const next = state.ccuResponses.length > 1 ? state.ccuResponses.shift()! : state.ccuResponses[0]!;
      res.writeHead(next.status, { "content-type": "application/json" });
      res.end(next.body);
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const addr = server.address();
  assert.ok(addr && typeof addr === "object");
  const base = `http://127.0.0.1:${addr.port}`;
  return {
    urls: {
      authUri: `${base}/oauth2/auth`,
      tokenUri: `${base}/token`,
      userinfoUri: `${base}/userinfo`,
      colabDomain: base,
    },
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

function defaultMockState(): MockState {
  return {
    tokenStatus: 200,
    tokenBody: {
      access_token: "ya29.initial-token",
      refresh_token: "1//refresh-token",
      expires_in: 3600,
      scope: COLAB_SCOPES.join(" "),
    },
    refreshStatus: 200,
    refreshBody: {
      access_token: "ya29.refreshed-token",
      expires_in: 3600,
      scope: COLAB_SCOPES.join(" "),
    },
    userinfoEmail: "colab-user@example.com",
    ccuResponses: [
      {
        status: 200,
        body: `${COLAB_XSSI_PREFIX}${JSON.stringify({
          currentBalance: 2500.0,
          consumptionRateHourly: 10.05,
          assignmentsCount: 1,
        })}`,
      },
    ],
    tokenCalls: [],
    ccuCalls: [],
  };
}

describe("Google Colab service profile adapter", () => {
  test("PKCE authorize URL, code extraction, and station-browser callback capture", () => {
    const pkce = generateColabPkce();
    assert.ok(pkce.state.length >= 24);
    assert.ok(pkce.codeVerifier.length >= 32);
    assert.ok(pkce.codeChallenge.length >= 32);

    const authUrl = colabAuthorizeUrl(
      { authUri: "https://accounts.google.com/o/oauth2/auth", tokenUri: "", userinfoUri: "", colabDomain: "" },
      pkce.state,
      pkce.codeChallenge,
      "gpu@example.com",
    );
    const parsed = new URL(authUrl);
    assert.equal(parsed.searchParams.get("response_type"), "code");
    assert.equal(parsed.searchParams.get("access_type"), "offline");
    assert.equal(parsed.searchParams.get("prompt"), "consent");
    assert.equal(parsed.searchParams.get("token_usage"), "remote");
    assert.equal(parsed.searchParams.get("code_challenge_method"), "S256");
    assert.equal(parsed.searchParams.get("code_challenge"), pkce.codeChallenge);
    assert.equal(parsed.searchParams.get("state"), pkce.state);
    assert.equal(parsed.searchParams.get("login_hint"), "gpu@example.com");
    assert.ok((parsed.searchParams.get("scope") ?? "").includes(COLAB_REQUIRED_SCOPE));

    // Direct code & full callback URL extraction
    assert.equal(colabCodeOf("4/0A-direct-code", pkce.state, "en"), "4/0A-direct-code");
    assert.equal(
      colabCodeOf(`https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-url-code&state=${encodeURIComponent(pkce.state)}`, pkce.state, "en"),
      "4/0A-url-code",
    );
    assert.throws(
      () => colabCodeOf("https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-url-code&state=wrong", pkce.state, "en"),
      /match/i,
    );

    // Station browser callback capture
    assert.equal(
      colabCallbackCode(`https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-auto&state=${encodeURIComponent(pkce.state)}`, pkce.state),
      "4/0A-auto",
    );
    assert.equal(colabCallbackCode("https://accounts.google.com/signin", pkce.state), null);
    assert.equal(colabCallbackCode("https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-auto&state=other", pkce.state), null);
  });

  test("exchangeColabCode rejects partial scope missing colaboratory", async () => {
    const state = defaultMockState();
    state.tokenBody.scope = "openid https://www.googleapis.com/auth/userinfo.email";
    const mock = await startMockColabServer(state);
    try {
      await assert.rejects(
        () => exchangeColabCode(mock.urls, "code-1", "verifier-1", "en", 1_700_000_000_000),
        /Google Colab permission was not granted/i,
      );
    } finally {
      await mock.close();
    }
  });

  test("token refresh, invalid_grant signedOut, and ccu-info XSSI stripping + 401 retry", async () => {
    const dir = await mkdtemp(join(tmpdir(), "stillfail-colab-"));
    const state = defaultMockState();
    const mock = await startMockColabServer(state);
    try {
      const auth = await exchangeColabCode(mock.urls, "code-ok", "verifier-ok", "zh", 1_700_000_000_000);
      assert.equal(auth.email, "colab-user@example.com");
      await writeColabAuth(dir, auth);
      const st = await stat(join(dir, COLAB_AUTH_FILE));
      if (process.platform !== "win32") assert.equal(st.mode & 0o777, 0o600);

      // Near expiry triggers refresh and persists new token
      const refreshed = await ensureColabToken(dir, mock.urls, 1_700_003_590_000);
      assert.equal(refreshed.ok, true);
      if (refreshed.ok) assert.equal(refreshed.token, "ya29.refreshed-token");
      const saved = await readColabAuth(dir);
      assert.equal(saved?.token, "ya29.refreshed-token");

      // Direct ccu-info call strips XSSI prefix and sends X-Colab-Client-Agent
      const ccu = await fetchCcuInfo(mock.urls, "ya29.refreshed-token");
      assert.equal(ccu.ok, true);
      if (ccu.ok) {
        assert.equal(ccu.info.currentBalance, 2500);
        assert.equal(ccu.info.consumptionRateHourly, 10.05);
        assert.equal(ccu.info.assignmentsCount, 1);
      }
      assert.equal(state.ccuCalls[0]?.agent, "colab-cli");

      // Adapter quota retries once on 401 then succeeds
      state.ccuResponses = [
        { status: 401, body: "unauthorized" },
        {
          status: 200,
          body: `${COLAB_XSSI_PREFIX}${JSON.stringify({
            currentBalance: 2489.95,
            consumptionRateHourly: 10.05,
            assignmentsCount: 1,
          })}`,
        },
      ];
      const adapter = makeColabServiceAdapter(mock.urls);
      const profile = hubConfig(
        { profiles: [{ id: "colab-1", home: dir, access: { kind: "service", service: COLAB_SERVICE_ID } }] },
        dir,
      ).profiles[0]!;
      const q = await adapter.quota(profile, { env: {}, lang: "zh" });
      assert.equal(q.state, "ok");
      assert.deepEqual(q.windows, []);
      assert.deepEqual(q.credits, { hasCredits: true, unlimited: false, balance: "2489.95 CU" });
      assert.equal(q.detail, "1 台运行中 · 10.05 CU/h");

      // invalid_grant marks signedOut
      state.refreshStatus = 400;
      state.refreshBody = { error: "invalid_grant", error_description: "Token has been expired or revoked." };
      state.ccuResponses = [{ status: 401, body: "unauthorized" }];
      const expired = await adapter.quota(profile, { env: {}, lang: "en" });
      assert.equal(expired.state, "unavailable");
      assert.equal(expired.signedOut, true);
      const checkedExpired = await adapter.check(profile, { env: {}, lang: "en" });
      assert.equal(checkedExpired.state, "login");
    } finally {
      await mock.close();
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("Accounts.newLogin({ service: 'colab' }) end-to-end creates profile, checks, and reads quota", async () => {
    const dir = await mkdtemp(join(tmpdir(), "stillfail-colab-acct-"));
    const state = defaultMockState();
    const mock = await startMockColabServer(state);
    const services = builtInServices({ colab: mock.urls });
    const store = Store.open(join(dir, "stillfail.db"));
    const config = new ConfigFile(dir);
    await config.updateSoon((raw) => {
      raw.profiles = [];
      raw.connects = [];
    });
    const accounts = makeAccounts({
      data: dir,
      store,
      config,
      services,
      machine: null,
      checkOnStart: false,
    });
    accounts.start();
    const viewer = { sub: "u1", email: "owner@example.com", name: "Owner", role: "owner" as const, workspace: "ws1", device: "d1" };
    try {
      assert.deepEqual(accounts.profileServices(), ["colab"]);
      const started = await accounts.newLogin({ service: "colab" }, viewer, "en");
      assert.equal(started.job.service, "colab");
      assert.equal(started.job.state, "needs_code");
      assert.ok(started.job.url?.startsWith(`${mock.urls.authUri}?`));

      const loginState = new URL(started.job.url!).searchParams.get("state")!;
      // Submitting a callback URL with mismatched state fails synchronously without aborting the login job.
      await assert.rejects(
        () =>
          accounts.logins.submitCode(
            started.id,
            "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-e2e&state=wrong-state",
            "en",
          ),
        /does not match/,
      );
      assert.equal(accounts.logins.get(started.id)?.state, "needs_code");

      // Event-driven wait for pendingSettled to create the profile (no sleep polling).
      const createdPromise = new Promise<string>((resolve) => {
        const check = () => {
          const entry = accounts.loginsView(viewer).find((l) => l.id === started.id);
          if (entry?.created) {
            stop();
            resolve(entry.created);
          }
        };
        const stop = accounts.onChange(check);
        check();
      });

      await accounts.logins.submitCode(
        started.id,
        `https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-e2e&state=${encodeURIComponent(loginState)}`,
        "en",
      );

      const createdId = await createdPromise;
      assert.ok(createdId, "service login should create a profile");
      const created = accounts.profiles().find((p) => p.id === createdId)!;
      assert.equal(created.runtime, undefined);
      assert.equal(created.service, "colab");
      assert.deepEqual(created.runtimes, []);
      assert.equal(created.name, "colab-user@example.com");

      // Check signInFiles & shareRefusal
      assert.deepEqual(signInFiles(created, services), [COLAB_AUTH_FILE]);
      assert.equal(shareRefusal(created, services), defaultServiceShareRefusal("colab"));

      // Credential file persisted with 0600 permissions
      const saved = JSON.parse(await readFile(join(created.home, COLAB_AUTH_FILE), "utf8"));
      assert.equal(saved.email, "colab-user@example.com");
      assert.equal(saved.refresh_token, "1//refresh-token");

      // Explicit check & quota
      const chk = await accounts.check(createdId, "en");
      assert.equal(chk.state, "ok");
      assert.equal(chk.models, null);
      assert.match(chk.detail, /colab-user@example\.com/);

      const q = await accounts.askedQuota(createdId);
      assert.equal(q?.state, "ok");
      assert.equal(q?.credits?.balance, "2500.00 CU");

      // Legacy clients without stillfail-profile-services omit colab profile
      const overview = { profiles: accounts.profilesView(viewer), logins: accounts.loginsView(viewer) };
      const req = (headers: Record<string, string>): Request => ({ path: "/overview", headers, method: "GET", query: [], body: Buffer.alloc(0), viewer, lang: "en" });
      const oldOut = JSON.parse(String(runtimeCompatible(req({ [RUNTIMES_HEADER]: RUNTIME_KINDS.join(",") }), json(200, JSON.stringify(overview))).body));
      assert.equal(oldOut.profiles.length, 0);
      const newOut = JSON.parse(String(runtimeCompatible(req({ [RUNTIMES_HEADER]: RUNTIME_KINDS.join(","), [PROFILE_SERVICES_HEADER]: "1" }), json(200, JSON.stringify(overview))).body));
      assert.equal(newOut.profiles.length, 1);
      assert.equal(newOut.profiles[0].service, "colab");
    } finally {
      await accounts.close();
      store.close();
      await mock.close();
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("LoginManager.attach auto-captures callback code from station browser tab", async () => {
    const dir = await mkdtemp(join(tmpdir(), "stillfail-colab-browser-"));
    const logins = new LoginManager(dir);
    let capturedCode: string | null = null;
    let tabUrl: string | null = null;
    let closedKey: string | null = null;
    let listener: ((key: string) => void) | null = null;
    logins.attach({
      can: () => true,
      changes: (fn: (key: string) => void) => {
        listener = fn;
        return () => {};
      },
      screenOf: () => "tab-1",
      urlOf: () => tabUrl,
      open: async () => "tab-1",
      close: (key: string) => {
        closedKey = key;
      },
    } as never);
    try {
      await logins.startOAuthCode(
        { id: "p-colab", home: join(dir, "h"), service: "colab" },
        {
          authUrl: "https://accounts.google.com/o/oauth2/auth?state=st-123",
          callbackCode: (u) => colabCallbackCode(u, "st-123"),
          exchange: async (code) => {
            capturedCode = code;
          },
        },
        "en",
      );
      const donePromise = new Promise<void>((resolve) => {
        const check = (id?: string) => {
          if (id && id !== "p-colab") return;
          if (logins.get("p-colab")?.state === "done") {
            stop();
            resolve();
          }
        };
        const stop = logins.changes(check);
        check();
      });
      tabUrl = "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/0A-tab-code&state=st-123";
      listener!("profile:p-colab");
      await donePromise;
      assert.equal(capturedCode, "4/0A-tab-code");
      assert.equal(closedKey, "profile:p-colab");
      assert.equal(logins.get("p-colab")?.state, "done");
    } finally {
      await logins.close();
      await rm(dir, { recursive: true, force: true });
    }
  });
});
