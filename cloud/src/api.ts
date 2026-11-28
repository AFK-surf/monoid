// The account-facing API: workspaces, members, invitations, stations and
// grants, each device's event socket and push registration; plus what
// stations do with their own key (enroll, hold their presence socket, send
// traces and notices). `api` returns null for paths it does not own. The
// admin's console has its own, `adminApi`, which only the console's host
// routes to (index.ts).
import { consoleAdmin, isAdmin } from "./admin";
import { revokeAppleToken, unsealAppleToken } from "./apple";
import { bearerToken, clock, denied, digest, limited, readJson, reply, verifyToken, type Claims } from "./auth";
import { adminOrigins, betaOrigin, header, publicOrigins, signedMessages } from "./compat";
import { guestOf, guests } from "./guests";
import { productOf } from "../../client/i18n/brand.ts";
import type { Live } from "./account";
import { EVENTS_PROTOCOLS, ROLES, sockets, type AddedMail, type Role } from "./directory";
import { PROVISION_KEY_PREFIX } from "./directory/stations";
import { cleanEmoji, cleanName, fail } from "./directory/types";
import type { Env } from "./env";
import { requestLang, tr, type Lang } from "./i18n.ts";
import { mailConfigured, sendAdded } from "./mail";
import type { AdminFeedback, FeedbackStatus } from "./types";
import { grantKeys, signCredential, validKeyHex, verifyAnySignature, verifyKeySignature } from "./grants";
import { changelog, changelogCacheSeconds, changelogFixesOf, serveChangelog, serveFixed } from "./changelog";
import { serveModels } from "./models";
import { FEEDBACK_LIMITS, receiveFeedback, receiveReply } from "./feedback";
import { pushKey, registration, stationNotify } from "./push";
import { relays } from "./relays";
import { unavailable, Unavailable } from "./releases";
import { receiveLoad, relaysLoad } from "./relay-load";
import { receiveIncidents, receiveReleased, serveStatus } from "./status";
import { onceMore, receiveLogs, receiveTraces, telemetryUnreached } from "./tracing";
import { ICON_URL_CHARS, keptIcon, serveIcon } from "./icons";
import { servePicture } from "./pictures";

/** Directory errors travel over RPC as their code; this gives each its status. */
const STATUS: Record<string, number> = {
  workspace_not_found: 404, member_not_found: 404, user_not_found: 404, station_not_found: 404, invitation_not_found: 404, enrollment_not_found: 404,
  forbidden: 403, invitation_for_other_email: 403,
  already_member: 409, invalid_name: 400, invalid_emoji: 400, invalid_icon: 400, invalid_role: 400, invalid_email: 400, invalid_relay: 400, invalid_relays: 400, invalid_way: 400, last_relay: 409,
  last_owner: 409, sole_owner: 409, locked_workspace: 409, not_before_owner: 409, rig_enrollment: 409, station_enrollment: 409, station_in_others: 409, last_station: 409,
  too_many_workspaces: 429, too_many_invitations: 429, too_many_members: 429, too_many_stations: 429,
  invite_code_required: 403, invite_code_invalid: 404, invite_code_used: 409, invite_code_expired: 410,
  invalid_note: 400, invalid_expiry: 400, invalid_limits: 400, invalid_days: 400, too_many_keys: 409, key_not_found: 404,
  feedback_not_found: 404, unauthorized: 401,
  invalid_signature: 401, wrong_relay_kind: 403, too_many_mesh_relays: 409, mesh_registry_capacity: 409, mesh_generation_exhausted: 409, mesh_relay_not_registered: 403, stale_mesh_address: 409, invalid_node: 400, mesh_relay_not_found: 404,
  invalid_target: 400, too_many_relays: 429, relay_not_found: 404, invalid_token: 403, wrong_relay: 403, unknown_relay: 400, invalid_secret: 403, not_from_relay: 403, invalid_request: 400,
  invalid_lock_entries: 400, lock_exists: 409, lock_fork: 409, lock_does_not_follow: 409, lock_refused: 409, invalid_device: 400, invalid_kind: 400,
};

/** A provisioning key as directory/stations.ts makes it: `sfpk_` and 32 bytes, base64url. */
const PROVISION_KEY = new RegExp(`^${PROVISION_KEY_PREFIX}[A-Za-z0-9_-]{43}$`);

const FEEDBACK_STATUSES: readonly FeedbackStatus[] = ["new", "triaged", "fixed", "wontfix"];

/** still.fail's station image (.github/workflows/station-docker.yml). */
const DOCKER_IMAGE = "ghcr.io/afk-surf/stillfail-station";

/**
 * An enrollment with what to run for it. A machine without still.fail installs it and joins at once; one with it joins.
 * On the test channel the installer is the test channel's, which gets its release (index.ts): from its host, or, with
 * no such host, ?channel=beta. The station joins PUBLIC_ORIGIN either way, by the command its product's installer
 * puts on the PATH (monoid's `monoid`, install.sh and install.ps1).
 */
function withCommands<T extends { token: string }>(env: Env, made: T, ofBeta: boolean): T & { install: string; installWindows: string; installDocker: string; command: string } {
  const beta = betaOrigin(env);
  const installer = (file: string) => (!ofBeta ? `${env.PUBLIC_ORIGIN}/${file}` : beta ? `${beta}/${file}` : `${env.PUBLIC_ORIGIN}/${file}?channel=beta`);
  // Quoted when it asks: zsh (macOS's shell) takes an unquoted ? for a file name to match, and stops.
  const sh = installer("install.sh").includes("?") ? `'${installer("install.sh")}'` : installer("install.sh");
  // still.fail's station container (station/docker): its entrypoint runs the installer of the cloud it is told, on the
  // channel it is told, with the same arguments after the image.
  const told = [`-e STILLFAIL_ORIGIN=${env.PUBLIC_ORIGIN}`, ...(ofBeta ? ["-e STILLFAIL_CHANNEL=beta"] : [])];
  const installDocker = ["docker run -d --restart unless-stopped -v stillfail:/home/stillfail", ...told, DOCKER_IMAGE, made.token].join(" ");
  return { ...made, install: `curl -fsSL ${sh} | sh -s -- ${made.token}`, installWindows: `& ([scriptblock]::Create((irm ${installer("install.ps1")}))) ${made.token}`, installDocker, command: `${productOf(env.PUBLIC_ORIGIN).id} station enroll ${env.PUBLIC_ORIGIN} ${made.token}` };
}

/**
 * Those `addMembers` added told so by mail (mail.ts `sendAdded`), in the language of the app that added them (the
 * receiver's is not known): the emails that could not be sent, which the app says and the Directory keeps waiting so
 * adding them again tries again. Nothing is sent by a cloud with no mail (a local one): none is said unsent then.
 */
async function mailAdded(env: Env, lang: Lang, workspace: string, mail: AddedMail): Promise<string[]> {
  if (!mailConfigured(env) || mail.to.length === 0) return [];
  const sent = await Promise.allSettled(mail.to.map((m) => sendAdded(env, lang, m.email, m.joined, mail.inviter, mail.workspace)));
  const failed = mail.to.filter((_, i) => sent[i]!.status === "rejected").map((m) => m.email);
  for (const s of sent) if (s.status === "rejected") console.warn(`an added member's mail not sent: ${(s.reason as { code?: string })?.code ?? s.reason}`);
  await env.DIRECTORY.getByName("primary").mailFailed(workspace, failed, mail.to.filter((_, i) => sent[i]!.status === "fulfilled").map((m) => m.email));
  return failed;
}

export async function directory<T>(run: () => Promise<T> | T, status = 200): Promise<Response> {
  try {
    const value = await run();
    return reply(value ?? { ok: true }, status);
  } catch (error) {
    if (error instanceof Unavailable) return unavailable(error.file, error.cause);
    const code = error instanceof Error ? error.message : "";
    if (code in STATUS) return reply({ error: code }, STATUS[code]);
    throw error;
  }
}

/** Requests of the test channel (index.ts): its account's object says whether it is let in, as it says its session is live. */
export const onTestChannel = new WeakSet<Request>();
/** What a request's account's object said of its token, asked once a request (index.ts asks first on the test channel). */
const said = new WeakMap<Request, Promise<Live>>();
/**
 * The locks' routes (the workspace's lock, the person's own, the devices that came): kept here only for the stations
 * and devices from before the stations carried them (the root AGENTS.md, The cloud is the account system), and counted
 * apart from the account system's requests a minute (account.ts `charge`), which they are not to use up. They go with
 * what they serve.
 */
const LOCK_ROUTE = /^\/v1\/(me\/personal-lock|workspaces\/[^/]+\/(lock(\/.*)?|devices))$/;
/**
 * A member's credential: a device asks one for each endpoint of each workspace's stations, so it is counted on a minute
 * of its own (account.ts `charge`, 360), not to use up the account system's requests, as `LOCK_ROUTE`.
 */
const CREDENTIAL_ROUTE = /^\/v1\/workspaces\/[^/]+\/credential$/;
export function liveOf(request: Request, env: Env, claims: Claims): Promise<Live> {
  let live = said.get(request);
  if (!live) {
    const pathname = new URL(request.url).pathname;
    const quota = request.method === "POST" && CREDENTIAL_ROUTE.test(pathname) ? "credential" : LOCK_ROUTE.test(pathname);
    said.set(request, (live = env.ACCOUNTS.getByName(claims.sub).live(claims, onTestChannel.has(request), quota)));
  }
  return live;
}

/**
 * The test channel is for the accounts the admin let in (Directory `beta`); any call carrying the token of an account
 * not let in answers 403 not_beta, which the page takes for "go to the stable one" and an app for "this account cannot
 * use the test build" (index.ts).
 */
export const notBetaReply = (env: Env, request: Request) => reply({ error: "not_beta", message: tr(requestLang(request), "cloud.beta.notLetIn"), stable: env.PUBLIC_ORIGIN }, 403);

/**
 * The account a token signs in, or the answer to give: signed out (401), or over its requests a minute (429, tried
 * again later; it was answered as signed out before, and the apps said 登录已失效 to someone signed in).
 */
async function account(token: string | null, env: Env, request: Request): Promise<Claims | Response> {
  const claims = token ? await verifyToken(env, token, "access") : null;
  if (!claims) return denied();
  const live = await liveOf(request, env, claims);
  return live === true ? claims : live === "limited" ? limited() : live === "not_beta" ? notBetaReply(env, request) : denied();
}

const isUpgrade = (request: Request) => request.headers.get("upgrade")?.toLowerCase() === "websocket";

/**
 * The access token of an events socket, and the subprotocol the answer
 * selects. Browsers cannot set headers on a WebSocket, so it comes as a second
 * subprotocol, `stillfail-token.<token>`, next to `stillfail-events` (the one
 * the answer selects). A header, unlike a query string, stays out of URLs and so
 * out of request logs.
 */
export function socketToken(request: Request): { token: string; protocol: string } | null {
  const offered = (request.headers.get("sec-websocket-protocol") ?? "").split(",").map((p) => p.trim());
  const protocol = EVENTS_PROTOCOLS.find((p) => offered.includes(p));
  if (!protocol) return null;
  const match = offered.map((p) => /^stillfail-token\.([A-Za-z0-9._-]{1,4096})$/.exec(p)).find(Boolean);
  return match?.[1] ? { token: match[1], protocol } : null;
}

async function body(request: Request, maximum?: number): Promise<Record<string, unknown>> {
  // Bodiless calls (GET, DELETE, a bare accept or decline) carry no JSON.
  if (request.method === "GET" || request.method === "DELETE" || !request.headers.get("content-type")) return {};
  return readJson(request, maximum);
}

/** How large a change to a workspace or a station, or an account's own picture, may be: it can carry a picture put up
 * (icons.ts). */
const MARK_BODY = ICON_URL_CHARS + 8192;

export async function api(request: Request, env: Env, url: URL): Promise<Response | null> {
  const path = url.pathname;
  const method = request.method;
  if (path === "/.well-known/stillfail-grant-keys" && method === "GET") return reply(grantKeys(env), 200, { "cache-control": "public, max-age=300" });

  // ── the relays on machines of their own: their counters, a minute apart (relay-load.ts) ──
  if (path === "/v1/relays/load" && method === "POST") return receiveLoad(request, env);
  // A relay putting itself on the cloud's list with a token its operator made (relay-registry.ts, relay-enroll.sh):
  // { token, url } (url where the token names none). Answers its secret, which its counters come with.
  if (path === "/v1/relays/mesh/events" && method === "POST") {
    const input = await body(request, 4096);
    return env.DIRECTORY.getByName("primary").fetch(new Request("https://directory/mesh-relays/events", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(input),
    }));
  }
  if (path === "/v1/relays/mesh" && method === "GET") {
    return directory(async () => ({ relays: await env.DIRECTORY.getByName("primary").meshRelays() }));
  }
  if ((path === "/v1/relays/mesh/enroll" || path === "/v1/relays/mesh/address") && method === "POST") {
    const input = await body(request, 20_480);
    return directory(() => env.DIRECTORY.getByName("primary").meshRelayRegister(input.body,input.signature,path.endsWith("/enroll")));
  }
  if (path === "/v1/relays/enroll" && method === "POST") {
    const input = await readJson(request).catch(() => null);
    if (!input) return reply({ error: "invalid_request" }, 400);
    return directory(() => env.DIRECTORY.getByName("primary").relayEnrolled(input.token, input.url));
  }

  // ── stations, authenticated by their own key ────────────────────────────
  // Enrolling moves the station to the token's workspace, out of any other; joining adds that
  // workspace to those it is in. The same body and proof (the token says where, the signature that the key is held);
  // a route of its own, so that a cloud from before it refuses rather than moves the station. Both answer with `home`.
  if ((path === "/v1/stations/enroll" || path === "/v1/stations/join") && method === "POST") {
    const input = await readJson(request).catch(() => null);
    if (!input || typeof input.token !== "string" || !validKeyHex(input.station) || typeof input.signature !== "string") return reply({ error: "invalid_request" }, 400);
    const messages = signedMessages("station-enroll-v1", publicOrigins(env), `${input.token}:${input.station}`);
    if (!(await verifyAnySignature(input.station, input.signature, messages))) return reply({ error: "invalid_signature" }, 401);
    const version = typeof input.version === "string" ? input.version.slice(0, 40) : null;
    return directory(async () => ({
      // `locks`: a station that pins a lock in each workspace it joins (one from before would take a locked one's
      // members on this cloud's word).
      // `rig`: it enrolls as a rig, which a rig's token alone makes (directory.ts `enroll`).
      ...(await env.DIRECTORY.getByName("primary").enroll(input.token as string, input.station as string, version, path === "/v1/stations/join", input.locks === true, input.rig === true)),
      station: input.station,
      ...relays(await env.DIRECTORY.getByName("primary").relaysNow()),
      grant_keys: grantKeys(env),
    }));
  }
  // The station's presence: a WebSocket it keeps open. Signed at connect in
  // headers: x-stillfail-station (its key), x-stillfail-ts (unix seconds,
  // within 5 minutes), x-stillfail-signature over
  // "stillfail-station-connect-v1:<origin>:<station>:<ts>", and
  // x-stillfail-version. (The origin is any of the cloud's.)
  if (path === "/v1/stations/connect" && method === "GET") {
    if (!isUpgrade(request)) return reply({ error: "websocket_required" }, 426);
    const station = header(request, "station");
    const signature = header(request, "signature") ?? "";
    const ts = Number(header(request, "ts"));
    if (!validKeyHex(station) || !Number.isSafeInteger(ts) || Math.abs(ts - clock.now() / 1000) > 300) return reply({ error: "invalid_request" }, 400);
    if (!(await verifyAnySignature(station, signature, signedMessages("station-connect-v1", publicOrigins(env), `${station}:${ts}`)))) return reply({ error: "invalid_signature" }, 401);
    const headers = new Headers({ upgrade: "websocket", "x-stillfail-station": station });
    // On a guest's origin (guests.ts): its state frames name that origin, so the station stays on it.
    if (guestOf(env, env.PUBLIC_ORIGIN)) headers.set("x-stillfail-origin", env.PUBLIC_ORIGIN);
    const version = header(request, "version");
    if (version) headers.set("x-stillfail-version", version.slice(0, 40));
    if (sockets.where(env) === "primary") return env.DIRECTORY.getByName("primary").fetch(new Request("https://directory/stations/connect", { headers }));
    return env.STATIONS.getByName(station).fetch(new Request("https://station/connect", { headers }));
  }

  // Spans from a signed-in client, or from a station signing them with its key (tracing.ts).
  // (their own budget by sender, tracing.ts: not the account's, which the account system's requests need)
  if (path === "/v1/telemetry/traces" && method === "POST") {
    const token = bearerToken(request);
    const claims = token ? await verifyToken(env, token, "access") : null;
    if (token && !claims) return denied();
    if (claims) {
      let live: boolean;
      try {
        live = await onceMore(() => env.ACCOUNTS.getByName(claims.sub).signedIn(claims));
      } catch (error) {
        return telemetryUnreached("account", error);
      }
      if (!live) return denied();
    }
    return receiveTraces(request, env, claims?.sub ?? null);
  }

  // A station's log, signed with its key (tracing.ts).
  if (path === "/v1/telemetry/logs" && method === "POST") return receiveLogs(request, env);

  // A bug report about still.fail itself, from a station's agent (signed with its key) or a signed-in account (feedback.ts).
  if (path === "/v1/feedback" && method === "POST") {
    const token = bearerToken(request);
    const claims = token ? await account(token, env, request) : null;
    if (claims instanceof Response) return claims;
    return receiveFeedback(request, env, claims?.sub ?? null);
  }

  // Which of its reports are fixed and out, for a station to tell who reported them; what changed, for anyone (changelog.ts).
  if (path === "/v1/feedback/fixed" && method === "POST") return serveFixed(request, env);
  // Its agents' answers on its reports (feedback.ts). A station reads none of the team's replies: they are the apps'.
  if (path === "/v1/feedback/reply" && method === "POST") return receiveReply(request, env);
  if (path === "/v1/changelog" && method === "GET") return serveChangelog(request, env);
  // What models can do and cost, for stations (models.ts): models.dev's, as still.fail reads it. No secret.
  if (path === "/v1/models" && method === "GET") return serveModels(request);
  // What still.fail/status shows (status.ts).
  if (path === "/v1/status" && method === "GET") return serveStatus(env);
  if (path === "/v1/status/incidents" && method === "POST") return receiveIncidents(request, env);
  // A release is out (status.ts): every device and station is told.
  if (path === "/v1/releases/out" && method === "POST") return receiveReleased(request, env);

  // Notices of a station's chats, signed with its key like its spans, pushed to the people they are for (push.ts).
  if (path === "/v1/stations/notify" && method === "POST") return stationNotify(request, env);
  if (path === "/v1/push/key" && method === "GET") return pushKey(env);
  // This device's push subscription or token, registered with the signed-in account's session, or taken off it.
  if (path === "/v1/push" && (method === "POST" || method === "DELETE")) {
    const claims = await account(bearerToken(request), env, request);
    if (claims instanceof Response) return claims;
    return registration(request, env, claims.sub, claims.sid);
  }

  if (path === "/v1/events" && method === "GET") {
    if (!isUpgrade(request)) return reply({ error: "websocket_required" }, 426);
    const socket = socketToken(request);
    if (sockets.where(env) === "primary") {
      const claims = await account(socket?.token ?? null, env, request);
      if (claims instanceof Response) return claims;
      if (!socket) return denied();
      return env.DIRECTORY.getByName("primary").fetch(new Request("https://directory/events", { headers: { upgrade: "websocket", "x-stillfail-sub": claims.sub, "x-stillfail-sid": claims.sid, "x-stillfail-protocol": socket.protocol } }));
    }
    // On the account's object, which checks the session itself (and, on the test channel, that it is let in).
    const claims = socket ? await verifyToken(env, socket.token, "access") : null;
    if (!claims || !socket) return denied();
    const headers = { upgrade: "websocket", "x-stillfail-sub": claims.sub, "x-stillfail-sid": claims.sid, "x-stillfail-protocol": socket.protocol, ...(onTestChannel.has(request) ? { "x-stillfail-channel": "beta" } : {}) };
    const answer = await env.ACCOUNTS.getByName(claims.sub).fetch(new Request("https://account/events", { headers }));
    return answer.status === 403 ? notBetaReply(env, request) : answer;
  }

  // ── the pictures put up as icons: to anyone with the address (icons.ts) ──
  if (path.startsWith("/v1/icons/") && method === "GET") return (await serveIcon(env, path.slice("/v1/icons/".length))) ?? reply({ error: "not_found" }, 404);

  // ── Slack's pictures, for the app in a browser, which may not read them from Slack (pictures.ts) ──
  if (path === "/v1/pictures" && method === "GET") return servePicture(request);

  // ── a console's provisioning key (directory/stations.ts): a station's enrollment at a time, and nothing else ──
  // Only `Authorization: Bearer sfpk_…` here, and such a key nowhere else (any other route takes it for no account's
  // token: 401). No account's token is taken here. A key not working (unknown, revoked, expired, its maker no longer
  // managing the workspace) is 401 `unauthorized`: the console asks someone to connect again.
  if (path === "/v1/provision/verify" || path === "/v1/provision/enrollments") {
    const unauthorized = () => reply({ error: "unauthorized" }, 401);
    const supplied = bearerToken(request);
    if (!supplied || !PROVISION_KEY.test(supplied)) return unauthorized();
    const dir = env.DIRECTORY.getByName("primary");
    const hash = await digest(supplied);
    if (path === "/v1/provision/verify" && method === "GET") {
      const found = await dir.verifyProvisionKey(hash);
      return found ? reply(found) : unauthorized();
    }
    if (path === "/v1/provision/enrollments" && method === "POST") {
      const input = await readJson(request, 4096).catch(() => null);
      if (!input) return reply({ error: "invalid_request" }, 400);
      return directory(async () => {
        const made = (await dir.createProvisionedEnrollment(hash, input.name)) ?? fail(401, "unauthorized");
        // As an owner's 添加 station has it: on the test channel's host the installer is the test channel's.
        const beta = betaOrigin(env);
        return { workspace: made.workspace, ...withCommands(env, { token: made.token, expires_at: made.expires_at }, (beta !== null && url.origin === beta) || header(request, "channel") === "beta") };
      });
    }
    return reply({ error: "not_found" }, 404);
  }

  // ── accounts ────────────────────────────────────────────────────────────
  const isAccountRoute = path === "/v1/me" || path === "/v1/me/personal-lock" || path === "/v1/me/picture" || path.startsWith("/v1/workspaces") || path.startsWith("/v1/invitations/");
  if (!isAccountRoute) return null;
  const claims = await account(bearerToken(request), env, request);
  if (claims instanceof Response) return claims;
  let input: Record<string, unknown>;
  try {
    input = await body(request, (method === "PATCH" && path.startsWith("/v1/workspaces/")) || path === "/v1/me/picture" ? MARK_BODY : undefined);
  } catch {
    return reply({ error: "invalid_request" }, 400);
  }
  const dir = env.DIRECTORY.getByName("primary");
  const sub = claims.sub;
  const text = (key: string) => (typeof input[key] === "string" ? (input[key] as string) : "");
  const role = (): Role => (ROLES.includes(input.role as Role) ? (input.role as Role) : "member");

  if (path === "/v1/me" && method === "GET") {
    // (`operator`: whether `/v1/admin/me` would answer this same request (on the console's host, index.ts), so that a device reads the operator's lists only
    // where it is one: every device of everyone asked it at every open of its events socket, the locks' end to end,
    // 2026-11-15). `console`: asked on the console's host, which serves no workspace's calls (index.ts CONSOLE_CALLS).
    // An operator is noted, to be told when the console's lists change (directory.ts `noteOperator`).
    const onConsole = adminOrigins(env).includes(new URL(request.url).origin);
    const operator = onConsole && (await consoleAdmin(request, env, claims.email, sub));
    return directory(async () => {
      const note = operator ? dir.noteOperator(sub, claims.email) : undefined;
      const [me, invitations] = await Promise.all([dir.me(sub), dir.invitationsFor(claims.email), note]);
      return { ...me, invitations, operator, ...(onConsole ? { console: true as const } : {}) };
    });
  }
  // The person's own lock, which the cloud keeps and carries but does not decide (personal-lock.ts).
  if (path === "/v1/me/personal-lock") {
    const lock = env.ACCOUNTS.getByName(sub);
    if (method === "GET") return reply({ entries: await lock.personalLock() });
    if (method === "POST") {
      const said = await lock.appendPersonalLock(sub, input.entries, input.keep === true);
      return "refused" in said ? reply({ error: said.refused }, STATUS[said.refused] ?? 409) : reply(said);
    }
  }
  // The picture the account puts up for itself, sent as a data URL and kept in the bucket as icons are (icons.ts), or
  // taken away (its sign-in's shown again).
  if (path === "/v1/me/picture") {
    if (method === "PUT") return directory(async () => dir.setOwnPicture(sub, typeof input.picture === "string" && input.picture.startsWith("data:") ? await keptIcon(env, input.picture) : input.picture));
    if (method === "DELETE") return directory(() => dir.setOwnPicture(sub, null));
  }
  // Deleting the account: the Directory first (it may refuse: 409 sole_owner), then its sessions, and revoke any linked Sign in with Apple tokens.
  if (path === "/v1/me" && method === "DELETE") {
    return directory(async () => {
      const { appleTokens } = await dir.deleteAccount(sub);
      await env.ACCOUNTS.getByName(sub).erase();
      for (const sealed of appleTokens) {
        const token = await unsealAppleToken(env, sealed);
        if (!token) continue;
        try {
          await revokeAppleToken(env, token);
        } catch (error) {
          console.error("deleteAccount: failed to revoke Apple token", error);
        }
      }
      return { deleted: true };
    });
  }
  const byId = /^\/v1\/invitations\/([0-9A-HJKMNP-TV-Z]{26})\/(accept|decline)$/.exec(path);
  if (byId && method === "POST") {
    if (byId[2] === "accept") return directory(() => dir.acceptById(sub, claims.email, byId[1]!));
    return directory(() => dir.declineById(claims.email, byId[1]!));
  }
  if (path === "/v1/workspaces" && method === "POST") return directory(() => dir.createWorkspace(sub, text("name"), isAdmin(env, claims.email, sub), input.invite_code));
  if (path === "/v1/invitations/preview" && method === "POST") return directory(() => dir.previewInvitation(text("token")));
  if (path === "/v1/invitations/accept" && method === "POST") return directory(() => dir.acceptInvitation(sub, claims.email, text("token")));

  const parts = path.split("/").slice(3).map(decodeURIComponent); // after /v1/workspaces/
  const [ws, kind, target, action] = parts;
  if (!ws || !/^[0-9A-HJKMNP-TV-Z]{26}$/.test(ws)) return reply({ error: "not_found" }, 404);
  // A picture sent as the icon, kept in the bucket once the caller and other fields pass checks (icons.ts).
  const icon = async (station?: string) => {
    if (typeof input.icon !== "string" || !input.icon.startsWith("data:")) return input.icon;
    await dir.manages(sub, ws, station);
    if (input.name !== undefined && cleanName(input.name) === null) fail(400, "invalid_name");
    if (input.emoji !== undefined && input.emoji !== null && input.emoji !== "" && cleanEmoji(input.emoji) === null) fail(400, "invalid_emoji");
    return keptIcon(env, input.icon);
  };
  if (!kind) {
    if (method === "GET") return directory(() => dir.workspace(sub, ws));
    if (method === "PATCH") return directory(async () => dir.updateWorkspace(sub, ws, { name: input.name, emoji: input.emoji, icon: await icon() }));
    if (method === "DELETE") return directory(() => dir.deleteWorkspace(sub, ws));
  }
  if (kind === "invitations" && !target && method === "POST") {
    const email = text("email").trim().toLowerCase() || null;
    const origin = (onTestChannel.has(request) || header(request, "channel") === "beta" ? betaOrigin(env) : null) ?? env.PUBLIC_ORIGIN;
    return directory(async () => {
      const made = await dir.invite(sub, ws, role(), email);
      return { ...made, url: `${origin}/invite#${made.token}` };
    });
  }
  // The bug reports from the workspace's chats the team replied on, with the replies, for its members' apps to show in
  // those chats; a member's answer on one: { text }.
  if (kind === "feedback" && !target && method === "GET") return directory(() => dir.feedbackOf(sub, ws));
  if (kind === "feedback" && target && action === "reply" && method === "POST") {
    const said = text("text").trim().slice(0, FEEDBACK_LIMITS.reply);
    if (!said || !/^[0-9A-Z]{26}$/.test(target)) return reply({ error: "invalid_request" }, 400);
    return directory(() => dir.memberFeedbackReply(sub, ws, target, said));
  }
  if (kind === "relays" && !target && method === "PUT") return directory(() => dir.setRelays(sub, ws, input.relays));
  if (kind === "ways" && !target && method === "PUT") return directory(() => dir.setWay(sub, ws, input.way, input.on));
  if (kind === "invitations" && target && method === "DELETE") return directory(() => dir.revokeInvitation(sub, ws, target));
  if (kind === "members" && !target && method === "POST") {
    return directory(async () => {
      const { mail, ...made } = await dir.addMembers(sub, ws, role(), input.emails, true);
      return { ...made, unmailed: await mailAdded(env, input.lang === "zh" || input.lang === "en" ? input.lang : requestLang(request), ws, mail) };
    });
  }
  if (kind === "added" && target && method === "DELETE") return directory(() => dir.removeAdded(sub, ws, target));
  if (kind === "members" && target && method === "PATCH") return directory(() => dir.setRole(sub, ws, target, role()));
  if (kind === "members" && target && method === "DELETE") return directory(() => dir.removeMember(sub, ws, target));
  if (kind === "enrollments" && !target && method === "POST") {
    return directory(async () => {
      const made = await dir.createEnrollment(sub, ws, text("name"));
      // Asked on the test channel (its host, or a beta app's x-stillfail-channel), the installer is the test channel's.
      const beta = betaOrigin(env);
      return withCommands(env, made, (beta !== null && url.origin === beta) || header(request, "channel") === "beta");
    });
  }
  // The workspace's provisioning keys (directory/stations.ts), its owners' and admins': listed, one made ({ name,
  // days? }, the key in this answer alone), one revoked.
  if (kind === "provision-keys" && !target && method === "GET") return directory(async () => ({ keys: await dir.provisionKeys(sub, ws) }));
  if (kind === "provision-keys" && !target && method === "POST") return directory(() => dir.createProvisionKey(sub, ws, input.name, input.days));
  if (kind === "provision-keys" && target && !action && method === "DELETE") return directory(() => dir.revokeProvisionKey(sub, ws, target));
  // A rig's enrollment (a station that only runs tasks): the same commands, to which the app adds that it is one with its person's own lock
  // to pin (`rig:<hash>`, `--rig <hash>`), as it adds a workspace lock's hash: the cloud never says whose lock that is.
  if (kind === "rigs" && target === "enrollments" && !action && method === "POST") {
    return directory(async () => {
      const made = await dir.createRigEnrollment(sub, ws, text("name"));
      const beta = betaOrigin(env);
      return { ...withCommands(env, made, (beta !== null && url.origin === beta) || header(request, "channel") === "beta"), rig: true };
    });
  }
  // A mstill.fail's credential for this device: what its stations take, offline, for the next 30 days (grants.ts).
  if (kind === "credential" && !target && method === "POST") {
    if (!validKeyHex(input.device)) return reply({ error: "invalid_device" }, 400);
    // A newer client names its base key and proves the endpoint is its own: kept for the
    // owner to check when the lock is turned on. An older one names only the endpoint.
    const base = validKeyHex(input.base) && typeof input.proof === "string" && (await verifyKeySignature(input.base, input.proof, `stillfail-lock-endpoint/1\0${ws}\0${input.device}`)) ? input.base : undefined;
    if (input.base !== undefined && base === undefined) return reply({ error: "invalid_proof" }, 400);
    return directory(async () => {
      // (one call of the Directory, not two: every ask of every device waits its turn there)
      const said = { base, kind: input.kind === "app" || input.kind === "web" ? input.kind : undefined, label: typeof input.label === "string" ? input.label.slice(0, 120) : undefined };
      const { role, ...told } = await dir.credentialDevice(sub, ws, input.device as string, said);
      const signed = await signCredential(env, { sub, email: claims.email, name: claims.name ?? "", ws, role, device: input.device as string, sid: claims.sid });
      return { ...signed, ...told };
    });
  }
  // The workspace lock, which the cloud keeps and carries but does not decide (directory.ts, lock.ts).
  if (kind === "lock" && !target) {
    const after = url.searchParams.has("after") ? Number(url.searchParams.get("after")) : -1;
    if (method === "GET") return directory(() => dir.lock(sub, ws, Number.isSafeInteger(after) ? after : -1));
    if (method === "POST") return directory(() => dir.appendLock(sub, ws, input.entries, input.keep === true));
    if (method === "DELETE") return directory(() => dir.clearLock(sub, ws));
  }
  if (kind === "lock" && target === "requests") {
    if (!action && method === "GET") return directory(() => dir.lockRequests(sub, ws));
    if (!action && method === "POST") return directory(() => dir.requestLock(sub, ws, input));
    if (action && method === "DELETE") return directory(() => dir.dropLockRequest(sub, ws, action));
  }
  if (kind === "devices" && !target && method === "GET") return directory(() => dir.devices(sub, ws));
  if (kind === "stations" && target && validKeyHex(target)) {
    // (what it is, a whole station or one that only runs tasks: asked alone)
    if (!action && method === "PATCH" && input.mode !== undefined) return directory(() => dir.setStationMode(sub, ws, target, input.mode));
    if (!action && method === "PATCH") return directory(async () => dir.updateStation(sub, ws, target, { name: input.name, emoji: input.emoji, icon: await icon(target) }));
    if (!action && method === "DELETE") return directory(() => dir.removeStation(sub, ws, target));
  }
  return reply({ error: "not_found" }, 404);
}

/** What any path nobody serves answers; the console's paths answer it to everyone but the admin. */
const notFound = () => new Response("Not found", { status: 404 });

const inviteUrl = (env: Env, code: string) => `${env.PUBLIC_ORIGIN}/?invite=${code}`;

/**
 * A code's sign-up link, and where this cloud answers as another product too (GUESTS), each product's (`links`): the
 * code is good on all of them, and whoever it is for signs up in the app they know.
 */
function inviteLinks(env: Env, code: string): { url: string; links?: { product: string; url: string }[] } {
  const url = inviteUrl(env, code);
  const others = guests(env);
  if (others.length === 0) return { url };
  return { url, links: [{ product: productOf(env.PUBLIC_ORIGIN).name, url }, ...others.map((g) => ({ product: productOf(g.origin).name, url: `${g.origin}/?invite=${code}` }))] };
}

/**
 * Runs an operator's change and notes it in the console's 操作记录 once it answered well (Directory recordAudit):
 * `target` named as it is before the change (`user:<sub>`, `workspace:<id>` and `feedback:<id>` as their email, name
 * and FB-<n>: what a deleted one was called stays).
 */
export async function audited(env: Env, actor: string, action: string, target: string, detail: string, run: () => Promise<Response>): Promise<Response> {
  const dir = env.DIRECTORY.getByName("primary");
  const named = await dir.auditName(target).catch(() => target);
  const response = await run();
  if (response.ok) await dir.recordAudit(actor, action, named, detail).catch(() => undefined);
  return response;
}

/** Blocks an account or lets it back, in its own object (which keeps it out) and in the directory (which lists it). */
export async function blockAccount(env: Env, sub: string, on: boolean): Promise<Response> {
  const answer = await env.ACCOUNTS.getByName(sub).administer(on);
  if (answer.ok) await env.DIRECTORY.getByName("primary").setBlocked(sub, on);
  return answer;
}

/** The changelog's fixes marked on the reports (changelog.ts): the Directory does nothing when it is as last time. Admin reads may lag by up to CHANGELOG_CACHE_SECONDS unless invalidated by /v1/releases/out. */
async function markFixed(env: Env): Promise<void> {
  const ttl = changelogCacheSeconds(env);
  const fixes =
    ttl > 0 && env.SERVICE_STATUS
      ? await env.SERVICE_STATUS.getByName("primary")
          .changelogFixes(ttl)
          .catch(async (error) => {
            console.error("changelog cache unavailable:", error);
            return changelogFixesOf(await changelog(env.RELEASES));
          })
      : changelogFixesOf(await changelog(env.RELEASES));
  await env.DIRECTORY.getByName("primary").markFixed(fixes);
}

/**
 * The console's bug reports (feedback.ts), those the changelog fixes marked first. `slim`: the console's list, each
 * without its logs (`has_logs` says whether it has any); the feedback monitor's has them whole.
 */
export async function feedbackList(env: Env, slim = false): Promise<AdminFeedback[]> {
  await markFixed(env);
  return env.DIRECTORY.getByName("primary").adminFeedback(slim);
}

/** Where a report's status is marked: the console's admin's, and the feedback monitor's with its token (index.ts). */
export const FEEDBACK_STATUS_PATH = /^\/v1\/admin\/feedback\/([0-9A-Z]{26})\/status$/;

/**
 * Marks where a report is. Only its status: a station is told of a fix only once the changelog marks it (markFixed,
 * fixedUntold), and a report marked otherwise is not told of until it is marked fixed again.
 */
export async function setFeedbackStatus(env: Env, id: string, status: unknown): Promise<Response> {
  if (!FEEDBACK_STATUSES.includes(status as FeedbackStatus)) return reply({ error: "invalid_request" }, 400);
  return directory(() => env.DIRECTORY.getByName("primary").setFeedbackStatus(id, status as FeedbackStatus));
}

/** Where the team replies to a report: the console's admin, and the feedback monitor with its token (index.ts). */
export const FEEDBACK_REPLY_PATH = /^\/v1\/admin\/feedback\/([0-9A-Z]{26})\/reply$/;

/**
 * The team's reply on a report, `by` the admin's email or the feedback monitor: { text } → 201 { id, delivery:
 * "pending" }, shown to the people of the chat it came from in their apps, never to a station or its agents; 409 {
 * error: "undeliverable", reason } where there is no such chat (`no_station`: an account's report; `no_chat`: one
 * whose chat or its workspace cannot be told, or the station left it), not kept.
 */
export async function replyToFeedback(env: Env, id: string, by: string, text: unknown): Promise<Response> {
  const said = typeof text === "string" ? text.trim().slice(0, FEEDBACK_LIMITS.reply) : "";
  if (!said) return reply({ error: "invalid_request" }, 400);
  try {
    const made = await env.DIRECTORY.getByName("primary").replyToFeedback(id, by, said);
    if ("undeliverable" in made) return reply({ error: "undeliverable", reason: made.undeliverable }, 409);
    return reply(made, 201);
  } catch (error) {
    if (error instanceof Error && error.message === "feedback_not_found") return reply({ error: "feedback_not_found" }, 404);
    throw error;
  }
}

/**
 * The cloud's list of relays, its operator's (relay-registry.ts): on the console (adminApi) and with ADMIN_TOKEN
 * (index.ts), `by` who asked. POST /v1/admin/relays/list: the list and the tokens not used yet; /put { url, name,
 * target? }: one put on it (or named anew); /remove { url }: one taken off; /token { name, url?, target? }: a token
 * for a relay to put itself on it with, and the command its machine runs (relay-enroll.sh). Null: not one of these.
 */
export async function relayAdmin(env: Env, by: string, path: string, method: string, input: Record<string, unknown>): Promise<Response | null> {
  if (method !== "POST" || !path.startsWith("/v1/admin/relays/")) return null;
  const dir = env.DIRECTORY.getByName("primary");
  const call = path.slice("/v1/admin/relays/".length);
  const said = (v: unknown) => (typeof v === "string" ? v : "");
  if (call === "list") return directory(async () => {
    const [relays, mesh] = await Promise.all([dir.relayList(), dir.meshRelays()]);
    return { ...relays, mesh };
  });
  if (call === "put") return audited(env, by, "relay.put", said(input.name) || said(input.url), said(input.url), () => directory(() => dir.relayPut(by, input)));
  if (call === "remove") return audited(env, by, "relay.remove", said(input.url), "", () => directory(async () => (await dir.relayRemove(input.url), { removed: true })));
  if (call === "mesh-remove") return audited(env, by, "relay.remove", said(input.node), "", () => directory(async () => (await dir.meshRelayRemove(input.node), { removed: true })));
  if (call === "mesh-token") {
    return audited(env, by, "relay.token", said(input.name), "", () => directory(async () => {
      if (input.url !== undefined || input.target !== undefined) throw new Error("invalid_request");
      const made = await dir.relayToken(by, { name: input.name });
      const listed = relays(await dir.relaysNow());
      return { name: made.name, expires_at: made.expires_at,
        invitation: { origin: env.PUBLIC_ORIGIN, token: made.token, relays: listed.relay_urls },
        command: "mesh-relay --global DATA_DIRECTORY INVITATION_JSON_FILE" };
    }));
  }
  if (call === "token") {
    return audited(env, by, "relay.token", said(input.name), said(input.url) || said(input.target), () => directory(async () => {
      const made = await dir.relayToken(by, input);
      return { ...made, command: `sh relay-enroll.sh ${env.PUBLIC_ORIGIN} ${made.token}${made.url ? "" : " <https://this relay's URL>"}` };
    }));
  }
  // A token not used yet taken back: { id } (relayList's).
  if (call === "token/revoke") return audited(env, by, "relay.token_revoke", said(input.id), "", () => directory(() => dir.relayTokenRevoke(input.id)));
  return null;
}

type AdminActor = {
  sub: string;
  email: string;
  auditBy: string;
  key?: { id: string; name: string; prefix: string };
};

export async function adminApi(request: Request, env: Env, path: string): Promise<Response> {
  const method = request.method;
  const claims = await account(bearerToken(request), env, request);
  if (claims instanceof Response || !(await consoleAdmin(request, env, claims.email, claims.sub))) return notFound();
  const dir = env.DIRECTORY.getByName("primary");
  await dir.noteOperator(claims.sub, claims.email);
  if (path === "/v1/admin/keys" && method === "GET") {
    return directory(async () => ({ keys: await dir.adminKeys() }));
  }
  if (path === "/v1/admin/keys" && method === "POST") {
    let input: Record<string, unknown>;
    try {
      input = await body(request);
    } catch {
      return reply({ error: "invalid_request" }, 400);
    }
    let made: { name: string; prefix: string } | undefined;
    const response = await directory(async () => {
      const created = await dir.createAdminKey(claims.sub, claims.email, input.name, input.days);
      made = { name: created.name, prefix: created.prefix };
      return { ...created, origin: env.PUBLIC_ORIGIN, host: new URL(env.PUBLIC_ORIGIN).hostname };
    }, 201);
    const createdMeta = made as { name: string; prefix: string } | undefined;
    if (response.ok && createdMeta) {
      const detail = [createdMeta.prefix, typeof input.days === "number" ? `days=${input.days}` : "never"].join(" · ");
      await dir.recordAudit(claims.email, "key.create", createdMeta.name, detail).catch(() => undefined);
    }
    return response;
  }
  const revokeKey = /^\/v1\/admin\/keys\/([A-Za-z0-9_-]{1,64})\/revoke$/.exec(path);
  if (revokeKey && method === "POST") {
    let revoked: { name: string; prefix: string } | undefined;
    const response = await directory(async () => {
      const done = await dir.revokeAdminKey(revokeKey[1]!);
      revoked = { name: done.name, prefix: done.prefix };
      return { ok: true };
    });
    const revokedMeta = revoked as { name: string; prefix: string } | undefined;
    if (response.ok && revokedMeta) {
      await dir.recordAudit(claims.email, "key.revoke", revokedMeta.name, revokedMeta.prefix).catch(() => undefined);
    }
    return response;
  }
  return handleAdmin(request, env, path, { sub: claims.sub, email: claims.email, auditBy: claims.email });
}

export async function adminKeyApi(request: Request, env: Env, path: string, supplied: string): Promise<Response> {
  const dir = env.DIRECTORY.getByName("primary");
  const found = await dir.verifyAdminKey(await digest(supplied));
  if (!found) return denied();
  if (path === "/v1/admin/keys" || path.startsWith("/v1/admin/keys/")) return reply({ error: "forbidden" }, 403);
  return handleAdmin(request, env, path, {
    sub: found.created_by,
    email: found.created_by_email,
    auditBy: `${found.created_by_email} (key:${found.name})`,
    key: { id: found.id, name: found.name, prefix: found.prefix },
  });
}

async function handleAdmin(request: Request, env: Env, path: string, actor: AdminActor): Promise<Response> {
  const method = request.method;
  let input: Record<string, unknown>;
  try {
    input = await body(request);
  } catch {
    return reply({ error: "invalid_request" }, 400);
  }
  const dir = env.DIRECTORY.getByName("primary");
  if (path === "/v1/admin/me" && method === "GET") return reply({ email: actor.email, ...(actor.key ? { key: actor.key } : {}) });
  // With the emails given rights before anyone signed in with them (`pending`; a console from before reads no such list).
  if (path === "/v1/admin/users" && method === "GET") return directory(async () => {
    const [users, pending] = await Promise.all([dir.adminUsers(), dir.adminPending()]);
    return { users, pending };
  });
  // Gives an email the test channel or the standard plan, signed in with or not: { email, beta?: boolean, may_create?: boolean }.
  const by = actor.auditBy;
  const text = (v: unknown) => (typeof v === "string" ? v : "");
  const onOff = (v: unknown) => (v === true ? "on" : v === false ? "off" : "");
  if (path === "/v1/admin/pending" && method === "POST") {
    const right = (v: unknown) => v === undefined || v === null || typeof v === "boolean";
    if (!right(input.beta) || !right(input.may_create)) return reply({ error: "invalid_request" }, 400);
    const rights = [input.beta !== undefined && input.beta !== null ? `beta=${onOff(input.beta)}` : "", input.may_create !== undefined && input.may_create !== null ? `may_create=${onOff(input.may_create)}` : ""].filter(Boolean).join(" ");
    return audited(env, by, "pending.set", text(input.email).trim().toLowerCase(), rights, () => directory(() => dir.setPending(actor.sub, input.email, input.beta as boolean | null | undefined, input.may_create as boolean | null | undefined)));
  }
  if (path === "/v1/admin/pending/remove" && method === "POST") return audited(env, by, "pending.remove", text(input.email).trim().toLowerCase(), "", () => directory(() => dir.removePending(input.email)));
  // What the operators changed here, the newest first (the console's 操作记录).
  if (path === "/v1/admin/audit" && method === "GET") return directory(async () => ({ audit: await dir.adminAudit() }));
  // Lets an account into the test channel (BETA_ORIGIN) or out of it: { on: boolean }.
  const beta = /^\/v1\/admin\/users\/([A-Za-z0-9_-]{1,128})\/beta$/.exec(path);
  if (beta && method === "POST") {
    if (typeof input.on !== "boolean") return reply({ error: "invalid_request" }, 400);
    return audited(env, by, "user.beta", `user:${beta[1]!}`, onOff(input.on), () => directory(() => dir.setBeta(beta[1]!, input.on as boolean)));
  }
  // Gives an account the right to create workspaces, as a code would, or takes it back: { on: boolean }.
  const mayCreate = /^\/v1\/admin\/users\/([A-Za-z0-9_-]{1,128})\/may-create$/.exec(path);
  if (mayCreate && method === "POST") {
    if (typeof input.on !== "boolean") return reply({ error: "invalid_request" }, 400);
    return audited(env, by, "user.may_create", `user:${mayCreate[1]!}`, onOff(input.on), () => directory(() => dir.setMayCreate(mayCreate[1]!, input.on as boolean)));
  }
  // Blocks an account (signs it out everywhere) or lets it back: { on: boolean }. Not the operator's own, nor ADMIN_EMAIL's
  // (with Access, others of the team operate the console too).
  const block = /^\/v1\/admin\/users\/([A-Za-z0-9_-]{1,128})\/block$/.exec(path);
  if (block && method === "POST") {
    if (typeof input.on !== "boolean") return reply({ error: "invalid_request" }, 400);
    if (block[1] === actor.sub || (await dir.isAdminAccount(block[1]!))) return reply({ error: "forbidden" }, 403);
    return audited(env, by, "user.block", `user:${block[1]!}`, onOff(input.on), () => blockAccount(env, block[1]!, input.on as boolean));
  }
  if (path === "/v1/admin/workspaces" && method === "GET") return directory(async () => ({ workspaces: await dir.adminWorkspaces() }));
  // A workspace made for a company (「企业 workspace」): { name, owners: [email], members, stations }.
  if (path === "/v1/admin/workspaces" && method === "POST") {
    const owners = Array.isArray(input.owners) ? input.owners.map(String).join(", ") : "";
    return audited(env, by, "workspace.create", text(input.name).trim(), owners, () => directory(() => dir.adminCreateWorkspace(actor.sub, input)));
  }
  // Its limits: { members, stations }; { reset: true } back to its creator's plan.
  const limits = /^\/v1\/admin\/workspaces\/([A-Za-z0-9_-]{1,64})\/limits$/.exec(path);
  if (limits && method === "POST") return audited(env, by, "workspace.limits", `workspace:${limits[1]!}`, input.reset === true || input.members === null ? "reset" : `members=${String(input.members)}`, () => directory(() => dir.adminSetLimits(limits[1]!, input)));
  // Owners put in by the admin, not in it: { emails } (a company whose owner left); told by mail as members added are.
  const owners = /^\/v1\/admin\/workspaces\/([A-Za-z0-9_-]{1,64})\/owners$/.exec(path);
  if (owners && method === "POST") {
    const emails = Array.isArray(input.emails) ? input.emails.map(String).join(", ") : "";
    return audited(env, by, "workspace.owners", `workspace:${owners[1]!}`, emails, () => directory(async () => {
      const { mail, ...made } = await dir.adminAddOwners(actor.sub, owners[1]!, input.emails);
      return { ...made, unmailed: await mailAdded(env, input.lang === "zh" || input.lang === "en" ? input.lang : requestLang(request), owners[1]!, mail) };
    }));
  }
  // An email added that has not signed in yet, taken back: { email }.
  const addedRemove = /^\/v1\/admin\/workspaces\/([A-Za-z0-9_-]{1,64})\/added\/remove$/.exec(path);
  if (addedRemove && method === "POST") return audited(env, by, "workspace.added_remove", `workspace:${addedRemove[1]!}`, text(input.email).trim().toLowerCase(), () => directory(() => dir.adminRemoveAdded(addedRemove[1]!, input.email)));
  // A station's enrollment for a company's workspace before any owner is in it, the admin not in it: { name }. The
  // stable channel's installer.
  const enroll = /^\/v1\/admin\/workspaces\/([A-Za-z0-9_-]{1,64})\/enrollments$/.exec(path);
  if (enroll && method === "POST") return audited(env, by, "workspace.enroll", `workspace:${enroll[1]!}`, text(input.name).trim(), () => directory(async () => withCommands(env, await dir.adminEnrollment(actor.sub, enroll[1]!, input.name), false)));
  // Deletes a workspace as its owner would: its stations are let go, its people told.
  const remove = /^\/v1\/admin\/workspaces\/([A-Za-z0-9_-]{1,64})\/delete$/.exec(path);
  if (remove && method === "POST") return audited(env, by, "workspace.delete", `workspace:${remove[1]!}`, "", () => directory(() => dir.adminDeleteWorkspace(remove[1]!)));
  // Each with its sign-up link: that is the web app's, on the other origin (each product's, `links`, where it is two).
  if (path === "/v1/admin/invite-codes" && method === "GET") return directory(async () => ({ codes: (await dir.inviteCodes()).map((c) => ({ ...c, ...inviteLinks(env, c.code) })) }));
  // { note?, days?, beta?: boolean }: with beta, whoever redeems it is let into the test channel too.
  if (path === "/v1/admin/invite-codes" && method === "POST") {
    if (input.beta !== undefined && input.beta !== null && typeof input.beta !== "boolean") return reply({ error: "invalid_request" }, 400);
    const detail = [text(input.note).trim(), typeof input.days === "number" ? `days=${input.days}` : "", input.beta === true ? "beta" : ""].filter(Boolean).join(" · ");
    let made = "";
    const response = await directory(async () => {
      const code = await dir.createInviteCode(actor.sub, input.note, input.days, input.beta === true);
      made = code.code;
      return { ...code, ...inviteLinks(env, code.code) };
    });
    if (response.ok) await dir.recordAudit(by, "code.create", made, detail).catch(() => undefined);
    return response;
  }
  // Bug reports about still.fail (feedback.ts), and marking where each is: { status }.
  // Those the changelog fixes marked first (changelog.ts).
  if (path === "/v1/admin/feedback" && method === "GET") {
    return directory(async () => ({ feedback: await feedbackList(env, true) }));
  }
  const status = FEEDBACK_STATUS_PATH.exec(path);
  if (status && method === "POST") return audited(env, by, "feedback.status", `feedback:${status[1]!}`, text(input.status), () => setFeedbackStatus(env, status[1]!, input.status));
  // A reply to the session that reported it: { text }.
  const replied = FEEDBACK_REPLY_PATH.exec(path);
  if (replied && method === "POST") return audited(env, by, "feedback.reply", `feedback:${replied[1]!}`, "", () => replyToFeedback(env, replied[1]!, actor.email, input.text));
  // One report whole, its logs too, by its id or its number (FB-12): any of them, not only those the list holds.
  const item = /^\/v1\/admin\/feedback\/([A-Za-z0-9_-]{1,32})$/.exec(path);
  if (item && method === "GET") {
    await markFixed(env);
    return directory(async () => ({ item: await dir.adminFeedbackItem(item[1]!) }));
  }
  // How loaded the relays are (relay-load.ts).
  if (path === "/v1/admin/relays" && method === "GET") return reply(await relaysLoad(env));
  const relayCall = await relayAdmin(env, by, path, method, input);
  if (relayCall) return relayCall;
  const revoke = /^\/v1\/admin\/invite-codes\/([A-Za-z0-9-]{1,32})\/revoke$/.exec(path);
  if (revoke && method === "POST") return audited(env, by, "code.revoke", revoke[1]!, "", () => directory(() => dir.revokeInviteCode(revoke[1]!)));
  return notFound();
}
