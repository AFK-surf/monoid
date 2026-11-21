// Google Colab service profile adapter: pure Node HTTP implementation of Google OAuth2 PKCE + Colab
// `/tun/m/ccu-info` (zero Python/venv dependency, works on macOS/Linux/Windows and is fully unit-testable).
// Credentials are stored in `homes/<id>/colab-auth.json` (0600) in a format compatible with
// `google.oauth2.credentials.Credentials.to_json()` so PR 3 can reuse it directly.
import { createHash, randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { profileFetch } from "../ops/agent-env.ts";
import { wall } from "../ops/fibers.ts";
import { writePrivateSoon } from "../ops/files.ts";
import { type Lang, tr } from "../ops/i18n.ts";
import { postForm } from "./console.ts";
import type { ProfileCheck, ProfileQuota } from "./profiles.ts";
import { defaultServiceShareRefusal, type ServiceProfileAdapter } from "./services.ts";

export const COLAB_SERVICE_ID = "colab";
export const COLAB_AUTH_FILE = "colab-auth.json";
export const COLAB_CLIENT_ID = "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com";
export const COLAB_CLIENT_SECRET = "d-FL95Q19q7MQmFpd7hHD0Ty";
export const COLAB_REDIRECT_URI = "https://sdk.cloud.google.com/applicationdefaultauthcode.html";
export const COLAB_SCOPES = [
  "openid",
  "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/cloud-platform",
  "https://www.googleapis.com/auth/colaboratory",
  "https://www.googleapis.com/auth/drive.file",
] as const;
export const COLAB_REQUIRED_SCOPE = "https://www.googleapis.com/auth/colaboratory";
export const COLAB_XSSI_PREFIX = ")]}'\n";

const REFRESH_MARGIN_MS = 60_000;
const FETCH_TIMEOUT_MS = 20_000;

export type ColabUrls = {
  authUri: string;
  tokenUri: string;
  userinfoUri: string;
  colabDomain: string;
};

export const COLAB_URLS: ColabUrls = {
  authUri: "https://accounts.google.com/o/oauth2/auth",
  tokenUri: "https://oauth2.googleapis.com/token",
  userinfoUri: "https://www.googleapis.com/oauth2/v2/userinfo",
  colabDomain: "https://colab.research.google.com",
};

/// Compatible with `google.oauth2.credentials.Credentials.to_json()`, plus `email` for `identity()`.
export type ColabAuth = {
  token: string;
  refresh_token: string;
  token_uri: string;
  client_id: string;
  client_secret: string;
  scopes: string[];
  expiry: string | null;
  email: string | null;
};

export type CcuInfo = {
  currentBalance: number;
  consumptionRateHourly: number;
  assignmentsCount: number;
};

export type TokenResult =
  | { ok: true; token: string; auth: ColabAuth }
  | { ok: false; signedOut: true; detail: string }
  | { ok: false; signedOut: false; detail: string };

export async function readColabAuth(home: string): Promise<ColabAuth | null> {
  try {
    const raw = JSON.parse(await readFile(join(home, COLAB_AUTH_FILE), "utf8"));
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
    const token = typeof raw.token === "string" ? raw.token : "";
    const refresh_token = typeof raw.refresh_token === "string" ? raw.refresh_token : "";
    if (token === "" && refresh_token === "") return null;
    const scopes = Array.isArray(raw.scopes) ? raw.scopes.filter((s: unknown): s is string => typeof s === "string" && s !== "") : [];
    const expiry = typeof raw.expiry === "string" && raw.expiry !== "" ? raw.expiry : null;
    const email = typeof raw.email === "string" && raw.email.trim() !== "" ? raw.email.trim() : null;
    return {
      token,
      refresh_token,
      token_uri: typeof raw.token_uri === "string" && raw.token_uri !== "" ? raw.token_uri : COLAB_URLS.tokenUri,
      client_id: typeof raw.client_id === "string" && raw.client_id !== "" ? raw.client_id : COLAB_CLIENT_ID,
      client_secret: typeof raw.client_secret === "string" && raw.client_secret !== "" ? raw.client_secret : COLAB_CLIENT_SECRET,
      scopes,
      expiry,
      email,
    };
  } catch {
    return null;
  }
}

export function writeColabAuth(home: string, auth: ColabAuth): Promise<void> {
  return writePrivateSoon(join(home, COLAB_AUTH_FILE), `${JSON.stringify(auth, null, 2)}\n`);
}

export async function colabEmail(home: string): Promise<string | null> {
  return (await readColabAuth(home))?.email ?? null;
}

export function generateColabPkce(): { state: string; codeVerifier: string; codeChallenge: string } {
  const state = randomBytes(24).toString("base64url");
  const codeVerifier = randomBytes(32).toString("base64url");
  const codeChallenge = createHash("sha256").update(codeVerifier).digest("base64url");
  return { state, codeVerifier, codeChallenge };
}

export function colabAuthorizeUrl(urls: ColabUrls, state: string, codeChallenge: string, email?: string | null): string {
  const url = new URL(urls.authUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", COLAB_REDIRECT_URI);
  url.searchParams.set("client_id", COLAB_CLIENT_ID);
  url.searchParams.set("scope", COLAB_SCOPES.join(" "));
  url.searchParams.set("access_type", "offline");
  url.searchParams.set("prompt", "consent");
  url.searchParams.set("token_usage", "remote");
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", codeChallenge);
  url.searchParams.set("code_challenge_method", "S256");
  if (typeof email === "string" && email.trim() !== "") url.searchParams.set("login_hint", email.trim());
  return url.toString();
}

/// Extracts the authorization code from either a pasted raw code or the full Google callback URL.
export function colabCodeOf(rawInput: string, expectedState: string, lang: Lang): string {
  const trimmed = rawInput.trim();
  if (trimmed === "") throw new Error(tr(lang, "station.login.emptyCode"));
  if (/^https?:\/\//i.test(trimmed)) {
    let parsed: URL;
    try {
      parsed = new URL(trimmed);
    } catch {
      throw new Error(tr(lang, "station.colab.invalidCode"));
    }
    const err = parsed.searchParams.get("error")?.trim();
    if (err) throw new Error(tr(lang, "station.colab.oauthError", { error: err }));
    const code = parsed.searchParams.get("code")?.trim() ?? "";
    const state = parsed.searchParams.get("state")?.trim() ?? "";
    if (code === "") throw new Error(tr(lang, "station.colab.invalidCode"));
    if (state !== "" && expectedState !== "" && state !== expectedState) {
      throw new Error(tr(lang, "station.colab.wrongState"));
    }
    return code;
  }
  return trimmed;
}

/// Captures the authorization code automatically when the station browser lands on Google's callback URL.
export function colabCallbackCode(tabUrl: string | null, expectedState: string): string | null {
  if (tabUrl === null) return null;
  let parsed: URL;
  try {
    parsed = new URL(tabUrl);
  } catch {
    return null;
  }
  const target = new URL(COLAB_REDIRECT_URI);
  if (parsed.origin !== target.origin || parsed.pathname.replace(/\/+$/, "") !== target.pathname.replace(/\/+$/, "")) {
    return null;
  }
  const code = parsed.searchParams.get("code")?.trim() ?? "";
  if (code === "") return null;
  const state = parsed.searchParams.get("state")?.trim() ?? "";
  if (expectedState !== "" && state !== expectedState) return null;
  return code;
}

function oauthErrorText(status: number, body: unknown): string {
  if (body && typeof body === "object" && !Array.isArray(body)) {
    const rec = body as Record<string, unknown>;
    const desc = typeof rec.error_description === "string" && rec.error_description.trim() !== "" ? rec.error_description.trim() : null;
    const err = typeof rec.error === "string" && rec.error.trim() !== "" ? rec.error.trim() : null;
    if (desc && err) return `${err}: ${desc}`;
    if (desc) return desc;
    if (err) return err;
  }
  return `HTTP ${status}`;
}

function parseScopes(raw: unknown): string[] {
  if (typeof raw === "string") return raw.split(/\s+/).filter(Boolean);
  if (Array.isArray(raw)) return raw.filter((s): s is string => typeof s === "string" && s !== "");
  return [];
}

function expiryIso(expiresInSec: unknown, nowMs: number): string | null {
  if (typeof expiresInSec !== "number" || !Number.isFinite(expiresInSec) || expiresInSec <= 0) return null;
  return new Date(nowMs + expiresInSec * 1000).toISOString();
}

export async function exchangeColabCode(urls: ColabUrls, code: string, codeVerifier: string, lang: Lang, nowMs: number = wall.now()): Promise<ColabAuth> {
  const { status, body } = await postForm(
    urls.tokenUri,
    {
      code,
      client_id: COLAB_CLIENT_ID,
      client_secret: COLAB_CLIENT_SECRET,
      redirect_uri: COLAB_REDIRECT_URI,
      grant_type: "authorization_code",
      code_verifier: codeVerifier,
    },
    {},
  );
  if (status < 200 || status >= 300 || !body || typeof body !== "object") {
    throw new Error(tr(lang, "station.colab.oauthError", { error: oauthErrorText(status, body) }));
  }
  const accessToken = typeof body.access_token === "string" ? body.access_token.trim() : "";
  const refreshToken = typeof body.refresh_token === "string" ? body.refresh_token.trim() : "";
  const scopes = parseScopes(body.scope);
  if (accessToken === "" || refreshToken === "") {
    throw new Error(tr(lang, "station.colab.missingTokens"));
  }
  if (!scopes.includes(COLAB_REQUIRED_SCOPE)) {
    throw new Error(tr(lang, "station.colab.missingScope"));
  }
  let email: string | null = null;
  try {
    const infoRes = await profileFetch(urls.userinfoUri, {
      headers: { authorization: `Bearer ${accessToken}`, accept: "application/json" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (infoRes.ok) {
      const info = (await infoRes.json()) as Record<string, unknown>;
      if (typeof info?.email === "string" && info.email.trim() !== "") email = info.email.trim();
    }
  } catch {
    // Email is optional metadata; keep sign-in working if userinfo is briefly unreachable.
  }
  return {
    token: accessToken,
    refresh_token: refreshToken,
    token_uri: urls.tokenUri,
    client_id: COLAB_CLIENT_ID,
    client_secret: COLAB_CLIENT_SECRET,
    scopes,
    expiry: expiryIso(body.expires_in, nowMs),
    email,
  };
}

function tokenExpired(expiry: string | null, nowMs: number): boolean {
  if (expiry === null) return false;
  const ms = Date.parse(expiry);
  if (Number.isNaN(ms)) return true;
  return ms - nowMs <= REFRESH_MARGIN_MS;
}

export async function ensureColabToken(home: string, urls: ColabUrls = COLAB_URLS, nowMs: number = wall.now(), forceRefresh = false): Promise<TokenResult> {
  const auth = await readColabAuth(home);
  if (!auth) return { ok: false, signedOut: true, detail: "no credentials" };
  if (!forceRefresh && auth.token !== "" && !tokenExpired(auth.expiry, nowMs)) {
    return { ok: true, token: auth.token, auth };
  }
  if (auth.refresh_token === "") {
    return { ok: false, signedOut: true, detail: "missing refresh token" };
  }
  let status: number;
  let body: any;
  try {
    ({ status, body } = await postForm(
      urls.tokenUri,
      {
        client_id: auth.client_id || COLAB_CLIENT_ID,
        client_secret: auth.client_secret || COLAB_CLIENT_SECRET,
        refresh_token: auth.refresh_token,
        grant_type: "refresh_token",
      },
      {},
    ));
  } catch (e) {
    return { ok: false, signedOut: false, detail: (e as Error).message };
  }
  const errCode = typeof body?.error === "string" ? body.error : "";
  if (status === 401 || errCode === "invalid_grant") {
    return { ok: false, signedOut: true, detail: oauthErrorText(status, body) };
  }
  if (status < 200 || status >= 300 || typeof body?.access_token !== "string" || body.access_token.trim() === "") {
    return { ok: false, signedOut: false, detail: oauthErrorText(status, body) };
  }
  const granted = parseScopes(body.scope);
  const next: ColabAuth = {
    ...auth,
    token: body.access_token.trim(),
    refresh_token: typeof body.refresh_token === "string" && body.refresh_token.trim() !== "" ? body.refresh_token.trim() : auth.refresh_token,
    scopes: granted.length > 0 ? granted : auth.scopes,
    expiry: expiryIso(body.expires_in, nowMs) ?? auth.expiry,
  };
  await writeColabAuth(home, next);
  return { ok: true, token: next.token, auth: next };
}

function stripXssi(raw: string): string {
  if (raw.startsWith(COLAB_XSSI_PREFIX)) return raw.slice(COLAB_XSSI_PREFIX.length);
  if (raw.startsWith(")]}'\r\n")) return raw.slice(6);
  if (raw.startsWith(")]}'")) return raw.slice(4).trimStart();
  return raw;
}

export type CcuResult =
  | { ok: true; info: CcuInfo }
  | { ok: false; status: number | null; signedOut: boolean; detail: string };

export async function fetchCcuInfo(urls: ColabUrls, accessToken: string): Promise<CcuResult> {
  const base = urls.colabDomain.replace(/\/+$/, "");
  let response: Response;
  try {
    response = await profileFetch(`${base}/tun/m/ccu-info?authuser=0`, {
      headers: {
        authorization: `Bearer ${accessToken}`,
        accept: "application/json",
        "x-colab-client-agent": "colab-cli",
      },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, status: null, signedOut: false, detail: (e as Error).message };
  }
  if (response.status === 401 || response.status === 403) {
    return { ok: false, status: response.status, signedOut: true, detail: `HTTP ${response.status}` };
  }
  if (!response.ok) {
    return { ok: false, status: response.status, signedOut: false, detail: `HTTP ${response.status}` };
  }
  const text = await response.text();
  let parsed: any;
  try {
    parsed = JSON.parse(stripXssi(text));
  } catch (e) {
    return { ok: false, status: response.status, signedOut: false, detail: (e as Error).message };
  }
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  const assignments =
    typeof parsed?.assignmentsCount === "number" && Number.isFinite(parsed.assignmentsCount)
      ? Math.max(0, Math.trunc(parsed.assignmentsCount))
      : Array.isArray(parsed?.assignments)
        ? parsed.assignments.length
        : 0;
  return {
    ok: true,
    info: {
      currentBalance: num(parsed?.currentBalance),
      consumptionRateHourly: num(parsed?.consumptionRateHourly),
      assignmentsCount: assignments,
    },
  };
}

async function queryCcuWithRefresh(
  home: string,
  urls: ColabUrls,
): Promise<
  | { ok: true; info: CcuInfo; auth: ColabAuth }
  | { ok: false; missingScope: true }
  | { ok: false; missingScope: false; signedOut: boolean; detail: string }
> {
  const first = await ensureColabToken(home, urls);
  if (!first.ok) return { ok: false, missingScope: false, signedOut: first.signedOut, detail: first.detail };
  if (first.auth.scopes.length > 0 && !first.auth.scopes.includes(COLAB_REQUIRED_SCOPE)) {
    return { ok: false, missingScope: true };
  }
  const res = await fetchCcuInfo(urls, first.token);
  if (res.ok) return { ok: true, info: res.info, auth: first.auth };
  if (res.status === 401) {
    const refreshed = await ensureColabToken(home, urls, wall.now(), true);
    if (!refreshed.ok) return { ok: false, missingScope: false, signedOut: refreshed.signedOut, detail: refreshed.detail };
    if (refreshed.auth.scopes.length > 0 && !refreshed.auth.scopes.includes(COLAB_REQUIRED_SCOPE)) {
      return { ok: false, missingScope: true };
    }
    const retry = await fetchCcuInfo(urls, refreshed.token);
    if (retry.ok) return { ok: true, info: retry.info, auth: refreshed.auth };
    return { ok: false, missingScope: false, signedOut: retry.signedOut, detail: retry.detail };
  }
  return { ok: false, missingScope: false, signedOut: res.signedOut, detail: res.detail };
}

export function makeColabServiceAdapter(urls?: ColabUrls): ServiceProfileAdapter {
  const resolved = () => urls ?? COLAB_URLS;
  return {
    id: "colab",
    name: "Google Colab",
    capabilities: () => ["compute"],
    signInFiles: () => [COLAB_AUTH_FILE],
    shareRefusal: () => defaultServiceShareRefusal(COLAB_SERVICE_ID),
    identity: (home) => colabEmail(home),

    async check(profile, { lang }): Promise<ProfileCheck> {
      const auth = await readColabAuth(profile.home);
      if (!auth) {
        return { state: "login", detail: tr(lang, "station.profile.signedOut"), models: null, checkedAt: 0 };
      }
      if (auth.scopes.length > 0 && !auth.scopes.includes(COLAB_REQUIRED_SCOPE)) {
        return { state: "login", detail: tr(lang, "station.colab.missingScope"), models: null, checkedAt: 0 };
      }
      const res = await queryCcuWithRefresh(profile.home, resolved());
      if (!res.ok) {
        if (res.missingScope) {
          return { state: "login", detail: tr(lang, "station.colab.missingScope"), models: null, checkedAt: 0 };
        }
        if (res.signedOut) {
          return { state: "login", detail: tr(lang, "station.profile.signedOut"), models: null, checkedAt: 0 };
        }
        return { state: "failed", detail: res.detail, models: null, checkedAt: 0 };
      }
      const detail = [tr(lang, "station.profile.signedIn"), res.auth.email ?? ""].filter(Boolean).join(tr(lang, "station.list.comma"));
      return { state: "ok", detail, models: null, checkedAt: 0 };
    },

    async quota(profile, { lang }): Promise<ProfileQuota> {
      const res = await queryCcuWithRefresh(profile.home, resolved());
      if (!res.ok) {
        if (res.missingScope) {
          return { state: "unavailable", windows: [], detail: tr(lang, "station.colab.missingScope"), checkedAt: 0, signedOut: true };
        }
        if (res.signedOut) {
          return { state: "unavailable", windows: [], detail: tr(lang, "station.quota.signInExpired"), checkedAt: 0, signedOut: true };
        }
        return { state: "unavailable", windows: [], detail: res.detail, checkedAt: 0, unanswered: true };
      }
      const { currentBalance, consumptionRateHourly, assignmentsCount } = res.info;
      const detail =
        assignmentsCount > 0 || consumptionRateHourly > 0
          ? tr(lang, "station.colab.activeVms", { n: assignmentsCount, rate: consumptionRateHourly.toFixed(2) })
          : null;
      return {
        state: "ok",
        windows: [],
        credits: {
          hasCredits: currentBalance > 0,
          unlimited: false,
          balance: `${currentBalance.toFixed(2)} CU`,
        },
        detail,
        checkedAt: 0,
      };
    },

    async login(profile, { lang, logins }) {
      const { state, codeVerifier, codeChallenge } = generateColabPkce();
      const authUrl = colabAuthorizeUrl(resolved(), state, codeChallenge, profile.email);
      return logins.startOAuthCode(
        { id: profile.id, home: profile.home, service: COLAB_SERVICE_ID },
        {
          authUrl,
          callbackCode: (tabUrl) => colabCallbackCode(tabUrl, state),
          validate: (rawCode, validateLang) => colabCodeOf(rawCode, state, validateLang),
          exchange: async (code, exchangeLang) => {
            const auth = await exchangeColabCode(resolved(), code, codeVerifier, exchangeLang);
            await writeColabAuth(profile.home, auth);
          },
        },
        lang,
      );
    },
  };
}
