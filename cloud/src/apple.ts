// Sign in with Apple (web OAuth with form_post, plus token revocation on account deletion).
//
// Apple returns `name` only on the first authorization (in the form_post `user` field, never in id_token).
// `refresh_token` is sealed with AUTH_SIGNING_KEY and stored in Directory `apple_identities` solely so
// DELETE /v1/me can revoke the user's Sign in with Apple authorization per App Store Guideline 5.1.1(v).
import { createRemoteJWKSet, EncryptJWT, importPKCS8, jwtDecrypt, jwtVerify, SignJWT } from "jose";
import { clock, nowSeconds } from "./auth";
import type { Env } from "./env";

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_AUTHORIZE_URL = `${APPLE_ISSUER}/auth/authorize`;
const APPLE_TOKEN_URL = `${APPLE_ISSUER}/auth/token`;
const APPLE_REVOKE_URL = `${APPLE_ISSUER}/auth/revoke`;
const APPLE_KEYS = createRemoteJWKSet(new URL(`${APPLE_ISSUER}/auth/keys`));
/** Apple's `sub` (typically `001234.hex.5678`); mapped by `appleAccount` to fit `verifyToken`'s `[A-Za-z0-9_-]{1,128}`. */
const APPLE_SUB = /^[A-Za-z0-9._-]{1,120}$/;
const encoder = new TextEncoder();

export type AppleVerified = {
  appleSub: string;
  email: string;
  name: string;
  refreshToken: string | null;
};

/** Whether Sign in with Apple is configured on this cloud. */
export function appleConfigured(env: Env): boolean {
  return Boolean(env.APPLE_CLIENT_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY);
}

/** The account `sub` created for an unlinked Apple identity (bijection on Apple's dotted `sub`, prefixed `apple_`). */
export function appleAccount(appleSub: string): string {
  return `apple_${appleSub.replaceAll(".", "_")}`;
}

/** Where the browser goes to sign in with Apple (`response_mode=form_post` is required by Apple whenever `name` or `email` is requested). */
export function appleAuthorizeUrl(env: Env, state: string, nonce: string, origin = env.PUBLIC_ORIGIN): string {
  const url = new URL(APPLE_AUTHORIZE_URL);
  for (const [key, value] of Object.entries({
    client_id: env.APPLE_CLIENT_ID!,
    redirect_uri: `${origin}/v1/auth/apple/callback`,
    response_type: "code",
    response_mode: "form_post",
    scope: "name email",
    state,
    nonce,
  }))
    url.searchParams.set(key, value);
  return url.toString();
}

/** Extracts a display name from Apple's one-time `user` JSON payload (`{ name: { firstName, lastName } }`). */
export function appleName(user: unknown): string {
  if (!user || typeof user !== "object") return "";
  const name = (user as { name?: unknown }).name;
  if (!name || typeof name !== "object") return "";
  const { firstName, lastName } = name as { firstName?: unknown; lastName?: unknown };
  return [firstName, lastName]
    .filter((part): part is string => typeof part === "string" && part.trim() !== "")
    .map((part) => part.trim())
    .join(" ")
    .slice(0, 120);
}

/** Short-lived ES256 client_secret JWT signed with the team's Sign in with Apple `.p8` key. */
async function appleClientSecret(env: Env): Promise<string> {
  const now = nowSeconds();
  const key = await importPKCS8(env.APPLE_PRIVATE_KEY!, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID! })
    .setIssuer(env.APPLE_TEAM_ID!)
    .setSubject(env.APPLE_CLIENT_ID!)
    .setAudience(APPLE_ISSUER)
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(key);
}

/** Exchanges an Apple authorization code and verifies the returned `id_token`. */
export async function appleIdentity(env: Env, code: string, nonce: string, name: string, origin = env.PUBLIC_ORIGIN): Promise<AppleVerified> {
  const clientSecret = await appleClientSecret(env);
  const response = await fetch(APPLE_TOKEN_URL, {
    method: "POST",
    redirect: "manual",
    signal: AbortSignal.timeout(10_000),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.APPLE_CLIENT_ID!,
      client_secret: clientSecret,
      code,
      grant_type: "authorization_code",
      redirect_uri: `${origin}/v1/auth/apple/callback`,
    }),
  });
  if (!response.ok) throw new Error("apple_exchange_failed");
  const tokens = (await response.json()) as { id_token?: unknown; refresh_token?: unknown };
  if (typeof tokens.id_token !== "string" || !tokens.id_token) throw new Error("apple_identity_missing");

  const { payload } = await jwtVerify(tokens.id_token, APPLE_KEYS, {
    algorithms: ["RS256"],
    issuer: APPLE_ISSUER,
    audience: env.APPLE_CLIENT_ID!,
    requiredClaims: ["sub", "exp", "iat", "nonce", "email", "email_verified"],
    currentDate: new Date(clock.now()),
  });

  // Apple encodes `email_verified` as either boolean `true` or string `"true"`.
  const verified = payload.email_verified === true || payload.email_verified === "true";
  const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
  if (
    payload.nonce !== nonce ||
    !verified ||
    !email ||
    !email.includes("@") ||
    typeof payload.sub !== "string" ||
    !APPLE_SUB.test(payload.sub) ||
    typeof payload.iat !== "number" ||
    payload.iat > nowSeconds() + 30
  )
    throw new Error("apple_identity_mismatch");

  return {
    appleSub: payload.sub,
    email,
    name: name.slice(0, 120),
    refreshToken: typeof tokens.refresh_token === "string" && tokens.refresh_token ? tokens.refresh_token : null,
  };
}

/** Revokes a stored Apple refresh token (called during `DELETE /v1/me`). */
export async function revokeAppleToken(env: Env, token: string): Promise<void> {
  if (!appleConfigured(env) || !token) return;
  const clientSecret = await appleClientSecret(env);
  const response = await fetch(APPLE_REVOKE_URL, {
    method: "POST",
    redirect: "manual",
    signal: AbortSignal.timeout(10_000),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.APPLE_CLIENT_ID!,
      client_secret: clientSecret,
      token,
      token_type_hint: "refresh_token",
    }),
  });
  if (!response.ok) throw new Error(`apple_revoke_failed_${response.status}`);
}

async function refreshEncryptionKey(env: Env): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(`stillfail-apple-refresh\0${env.AUTH_SIGNING_KEY}`)));
}

/** Encrypts an Apple refresh token for storage in Directory SQLite. */
export async function sealAppleToken(env: Env, token: string): Promise<string> {
  return new EncryptJWT({ token })
    .setProtectedHeader({ alg: "dir", enc: "A256GCM" })
    .encrypt(await refreshEncryptionKey(env));
}

/** Decrypts a stored Apple refresh token; returns null if unreadable. */
export async function unsealAppleToken(env: Env, sealed: string): Promise<string | null> {
  try {
    const { payload } = await jwtDecrypt(sealed, await refreshEncryptionKey(env), {
      keyManagementAlgorithms: ["dir"],
      contentEncryptionAlgorithms: ["A256GCM"],
    });
    return typeof payload.token === "string" && payload.token ? payload.token : null;
  } catch {
    return null;
  }
}
