// The accounts signed in on this device. Each keeps its own still.fail cloud session: a short access
// token and a rotating refresh token. Tokens are refreshed at most once at a time per account (every caller waits on
// the same refresh).
//
// Wire: POST /v1/auth/token {code, code_verifier, redirect_uri} (or /v1/auth/password {email, password, name}), POST /v1/auth/refresh (Bearer refresh)
// {request_id: ULID}, POST /v1/auth/logout (Bearer refresh) {all:false}; tokens answer {access_token, refresh_token,
// subject, email, name?, expires_at}. Sign-in starts at GET /v1/auth/google/start?state&code_challenge&…&name.
//
// Storage (the Rust core's, so either core reads the other's): `accounts` is a JSON array of StoredAccount
// (`access_expires` in epoch seconds), `login` the sign-in in progress.
import { Marks } from "./reactive.ts";
import { Clock, Deferred, Effect, Semaphore } from "effect";
import { CoreError, HostError, asCoreError } from "./error.ts";
import { HEDGE, type Host, type HttpResponse } from "./host.ts";
import { t } from "./i18n.ts";
import { Kind, type Tracer } from "./trace.ts";
import { base64url, isObject, parseJson, pointer, sha256, toJsonBytes, utf8 } from "./util.ts";

export const STORAGE_KEY = "accounts";
export const LOGIN_KEY = "login";
/// A refresh answers one small JSON document. Its shared flight must end even when the old HTTP exchange goes
/// silent without a network-change event. The session stays signed in; a later caller can ask again.
const REFRESH_TIMEOUT_MS = 60_000;

export type StoredAccount = {
  sub: string;
  email: string;
  name: string;
  picture: string;
  access: string;
  refresh: string;
  /// Epoch seconds.
  access_expires: number;
  /// Globally unique per-login session identifier (ULID) generated when an account signs in, preserved across token
  /// refreshes and profile updates so recovery can distinguish stale `device/choice` records across process restarts.
  session?: string;
};

/// What UIs see of an account: never its tokens.
export type AccountView = { sub: string; email: string; name: string; picture: string };

export function view(a: StoredAccount): AccountView {
  return { sub: a.sub, email: a.email, name: a.name, picture: a.picture };
}

type PendingLogin = { verifier: string; state: string; return_to: string; redirect_uri: string };

/// serde's reading of a StoredAccount: every field there, of its type (else the whole list is dropped, as
/// `unwrap_or_default` does in the Rust core).
function readStored(raw: unknown): StoredAccount[] | null {
  if (!Array.isArray(raw)) return null;
  const out: StoredAccount[] = [];
  for (const a of raw) {
    if (!isObject(a)) return null;
    const { sub, email, name, picture, access, refresh, access_expires, session } = a;
    if ([sub, email, name, picture, access, refresh].some((v) => typeof v !== "string") || typeof access_expires !== "number") return null;
    if (session !== undefined && typeof session !== "string") return null;
    const entry: StoredAccount = { sub, email, name, picture, access, refresh, access_expires } as StoredAccount;
    if (typeof session === "string" && session.length > 0) entry.session = session;
    out.push(entry);
  }
  return out;
}

function stored(a: StoredAccount): StoredAccount {
  const out: StoredAccount = { sub: a.sub, email: a.email, name: a.name, picture: a.picture, access: a.access, refresh: a.refresh, access_expires: a.access_expires };
  if (typeof a.session === "string" && a.session.length > 0) out.session = a.session;
  return out;
}

type Tokens = { access_token: string; refresh_token: string; subject: string; email: string; name?: string | null; expires_at: number };

function readTokens(raw: unknown): Tokens | null {
  if (!isObject(raw)) return null;
  const { access_token, refresh_token, subject, email, name, expires_at } = raw;
  if ([access_token, refresh_token, subject, email].some((v) => typeof v !== "string") || typeof expires_at !== "number") return null;
  if (name !== undefined && name !== null && typeof name !== "string") return null;
  return raw as unknown as Tokens;
}

/// Unwraps wrapper hosts (such as `WakingHost`) to the underlying shared `Host` so cross-Core locks bind to the
/// actual backing storage rather than each Core's wrapper instance.
export function rootHost(host: Host): object {
  let cur: unknown = host;
  while (cur !== null && typeof cur === "object" && "inner" in cur) {
    const next = (cur as { inner?: unknown }).inner;
    if (next === null || typeof next !== "object" || next === cur) break;
    cur = next;
  }
  return cur as object;
}

/// Serializes read-modify-write commits to `accounts` across every `Accounts` / `Core` sharing the same backing `Host`.
const HOST_ACCOUNTS_LOCK = new WeakMap<object, ReturnType<typeof Semaphore.makeUnsafe>>();
function hostAccountsLock(host: Host): ReturnType<typeof Semaphore.makeUnsafe> {
  const key = rootHost(host);
  let lock = HOST_ACCOUNTS_LOCK.get(key);
  if (!lock) {
    lock = Semaphore.makeUnsafe(1);
    HOST_ACCOUNTS_LOCK.set(key, lock);
  }
  return lock;
}

/// Parses persisted `STORAGE_KEY` bytes: `null` (absent key) => empty `[]`; corrupt/invalid non-null bytes => `null`.
function parseStoredDisk(bytes: Uint8Array | null): StoredAccount[] | null {
  if (bytes === null) return [];
  return readStored(parseJson(bytes));
}

export class Accounts {
  readonly #host: Host;
  #list: StoredAccount[];
  /// True when initial `storageGet("accounts")` failed or returned corrupt non-null JSON (distinct from absent/empty):
  /// recovery must never prune `pendingMe`, delete credentials as orphans, or allow ownership-dependent writes while
  /// unloaded, and any mutation must reload and merge disk accounts before persisting.
  #unloaded: boolean;
  #listeners: ((removed?: readonly string[]) => void)[] = [];
  /// What reads the list (`list`) is made again as it changes.
  readonly #seen = new Marks();
  /// The refresh under way per account session: every caller in the same session waits on the one.
  readonly #refreshing = new Map<string, Deferred.Deferred<string, CoreError>>();
  #tracer: Tracer | null = null;
  /// Since when (monotonic ms) a refresh has had no answer.
  #unanswered: number | null = null;

  private constructor(host: Host, list: StoredAccount[], unloaded = false) {
    this.#host = host;
    this.#list = list;
    this.#unloaded = unloaded;
  }

  /// Loads the stored accounts. Distinguishes a storage read failure or corrupt non-null bytes (`isUnloaded()`) from
  /// an absent key or valid empty array so startup recovery never treats unreadable/corrupt accounts as signed-out orphans.
  static load(host: Host): Effect.Effect<Accounts> {
    return Effect.map(Effect.result(host.storageGet(STORAGE_KEY)), (r) => {
      if (r._tag === "Failure") return new Accounts(host, [], true);
      const parsed = parseStoredDisk(r.success);
      if (parsed === null) return new Accounts(host, [], true);
      return new Accounts(host, parsed, false);
    });
  }

  /// Whether the initial `storageGet("accounts")` failed or returned corrupt bytes and the real signed-in list is unknown.
  isUnloaded(): boolean {
    return this.#unloaded;
  }

  /// Persistent unique session identifier of signed-in account `sub` ("" for legacy accounts without one).
  sessionId(sub: string): string {
    return this.#list.find((a) => a.sub === sub)?.session ?? "";
  }

  /// Reads and validates `STORAGE_KEY` from the shared host. Treats both storage read errors and corrupt non-null
  /// bytes as retryable failures so callers never overwrite or wipe shared accounts when disk cannot be verified.
  #readDiskChecked(): Effect.Effect<{ kind: "ok"; list: StoredAccount[] } | { kind: "error"; error: CoreError }> {
    return Effect.map(Effect.result(this.#host.storageGet(STORAGE_KEY)), (r) => {
      if (r._tag === "Failure") return { kind: "error" as const, error: asCoreError(r.failure) };
      const parsed = parseStoredDisk(r.success);
      if (parsed === null) return { kind: "error" as const, error: CoreError.invalid(t("core-logic.accounts.invalid_json")) };
      return { kind: "ok" as const, list: parsed };
    });
  }

  /// Reloads persisted accounts before mutating/writing if initial `load()` failed, preventing overwrites of existing
  /// accounts on disk. Caller MUST hold `hostAccountsLock(this.#host)`. Returns true when `#unloaded` transitioned
  /// from true to false, or fails with a retryable error if storage is still unreadable.
  #ensureLoadedHeld(): Effect.Effect<boolean, CoreError> {
    return Effect.gen({ self: this }, function* () {
      if (!this.#unloaded) return false;
      const disk = yield* this.#readDiskChecked();
      if (disk.kind === "error") return yield* Effect.fail(disk.error);
      if (!this.#unloaded) return false;
      this.#list = disk.list;
      this.#unloaded = false;
      return true;
    });
  }

  #ensureLoadedLocked(): Effect.Effect<boolean, CoreError> {
    return hostAccountsLock(this.#host).withPermits(1)(this.#ensureLoadedHeld());
  }

  #notify(removed?: readonly string[]): void {
    this.#seen.touch();
    for (const listener of [...this.#listeners]) listener(removed);
  }

  setTracer(tracer: Tracer): void {
    this.#tracer = tracer;
  }

  list(): AccountView[] {
    this.#seen.read();
    return this.#list.map(view);
  }

  refreshing(): number {
    return this.#refreshing.size;
  }

  /// Called after every change to the list; `removed` lists accounts explicitly signed out by this transition.
  onChange(listener: (removed?: readonly string[]) => void): void {
    this.#listeners.push(listener);
  }

  /// Starts a sign-in: stores the PKCE verifier and state, returns the URL to open.
  beginSignIn(redirectUri: string, returnTo: string, deviceName: string): Effect.Effect<string, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const verifier = this.#secret();
      const state = this.#secret();
      const pending: PendingLogin = { verifier, state, return_to: returnTo, redirect_uri: redirectUri };
      yield* Effect.mapError(this.#host.storageSet(LOGIN_KEY, toJsonBytes(pending)), asCoreError);
      const query = (
        [
          ["state", state],
          ["code_challenge", challenge(verifier)],
          ["code_challenge_method", "S256"],
          ["redirect_uri", redirectUri],
          ["name", deviceName],
        ] as [string, string][]
      )
        .map(([k, v]) => `${k}=${encodeComponent(v)}`)
        .join("&");
      return `${this.#host.cloudOrigin()}/v1/auth/google/start?${query}`;
    });
  }

  /// Finishes a sign-in from the callback's query string. Returns the account and where to go next.
  completeSignIn(query: string): Effect.Effect<[AccountView, string], CoreError> {
    return Effect.gen({ self: this }, function* () {
      const params = parseQuery(query);
      const param = (k: string) => params.find(([n]) => n === k)?.[1];
      // A login is good for one try, whatever its outcome.
      const raw = parseJson(yield* Effect.orElseSucceed(this.#host.storageGet(LOGIN_KEY), () => null));
      const pending = isObject(raw) && ["verifier", "state", "return_to", "redirect_uri"].every((k) => typeof raw[k] === "string") ? (raw as unknown as PendingLogin) : null;
      yield* Effect.ignore(this.#host.storageDelete(LOGIN_KEY), { log: "Unhandled", message: "login removed" });
      const error = param("error");
      if (error !== undefined && error !== "") {
        return yield* Effect.fail(error === "login_cancelled" ? new CoreError("login_cancelled", t("core-logic.accounts.login.cancelled")) : new CoreError("login_failed", t("core-logic.accounts.login.failed")));
      }
      if (!pending || param("state") !== pending.state) return yield* Effect.fail(new CoreError("login_state_mismatch", t("core-logic.accounts.login.state_mismatch")));
      const expired = () => new CoreError("login_expired", t("core-logic.accounts.login.expired"));
      const body = { code: param("code") ?? null, code_verifier: pending.verifier, redirect_uri: pending.redirect_uri };
      const response = yield* Effect.mapError(this.#post("/v1/auth/token", null, body, null), expired);
      if (!ok(response)) return yield* Effect.fail(expired().withStatus(response.status));
      const tokens = readTokens(parseJson(response.body));
      if (!tokens) return yield* Effect.fail(expired());
      const account = yield* this.#signedIn(tokens);
      const returnTo = pending.return_to === "" || pending.return_to.startsWith("/auth/") ? "/" : pending.return_to;
      return [account, returnTo] as [AccountView, string];
    });
  }

  /// Signs in with an email and a password: only the accounts still.fail cloud set up for that (App Store review's).
  passwordSignIn(email: string, password: string, deviceName: string): Effect.Effect<AccountView, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const failed = () => new CoreError("login_failed", t("core-logic.accounts.login.password_failed"));
      const response = yield* Effect.mapError(this.#post("/v1/auth/password", null, { email, password, name: deviceName }, null), failed);
      if (response.status === 401) return yield* Effect.fail(new CoreError("login_wrong_password", t("core-logic.accounts.login.wrong_password")).withStatus(401));
      if (!ok(response)) return yield* Effect.fail(failed().withStatus(response.status));
      const tokens = readTokens(parseJson(response.body));
      if (!tokens) return yield* Effect.fail(failed());
      return yield* this.#signedIn(tokens);
    });
  }

  /// Keeps the account a sign-in answered with.
  #signedIn(tokens: Tokens): Effect.Effect<AccountView, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const account: StoredAccount = {
        sub: tokens.subject,
        email: tokens.email,
        name: tokens.name ?? "",
        picture: "",
        access: tokens.access_token,
        refresh: tokens.refresh_token,
        access_expires: tokens.expires_at,
        session: ulid(this.#host),
      };
      yield* this.#put(account);
      // The picture comes with the profile; fetched once, best effort (never reviving a signed-out/replaced session or clobbering rotated tokens).
      const picture = yield* this.#picture(account.access);
      if (picture !== null) {
        account.picture = picture;
        yield* Effect.ignore(this.#updateProfile(account.sub, account.session ?? "", { picture }), { log: "Unhandled", message: "account kept" });
      }
      return view(account);
    });
  }

  /// A usable access token, refreshing it when it expires within a minute (once at a time per account session/refresh).
  /// Bound to the session & refresh captured at entry across async reads, network calls, and CAS storage commits.
  accessToken(sub: string): Effect.Effect<string, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const now = this.#host.nowMs() / 1000;
      const a = this.#get(sub);
      if (!a) return yield* Effect.fail(CoreError.signedOut(t("core-logic.accounts.signed_out")));
      if (a.access_expires - 60 > now) return a.access;
      const target: StoredAccount = { ...a };
      const key = `${sub}\0${target.session ?? ""}\0${target.refresh}`;
      const existing = this.#refreshing.get(key);
      if (existing) return yield* Deferred.await(existing);
      const clock = yield* Clock.Clock;
      const done = Deferred.makeUnsafe<string, CoreError>();
      this.#refreshing.set(key, done);
      // The refresh runs to its end whoever waits (it rotates the session): a fiber of its own, on the caller's
      // clock. Ending the HTTP attempt must not interrupt keeping the rotated tokens once they arrived.
      Effect.runFork(
        this.#refresh(target).pipe(
          Effect.exit,
          Effect.flatMap((exit) =>
            Effect.sync(() => {
              this.#refreshing.delete(key);
              Deferred.doneUnsafe(done, exit);
            }),
          ),
          Effect.provideService(Clock.Clock, clock),
        ),
      );
      return yield* Deferred.await(done);
    });
  }

  signOut(sub: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const reloaded = yield* this.#ensureLoadedLocked();
      const account = this.#get(sub);
      if (!account) {
        if (reloaded) this.#notify();
        return;
      }
      yield* Effect.ignore(this.#post("/v1/auth/logout", account.refresh, { all: false }, null), { log: "Unhandled", message: "signed out at still.fail" });
      const forgot = yield* this.#forgetIfMatches(sub, account.session ?? "", account.refresh, false, reloaded);
      if (forgot.kind === "retry") return yield* Effect.fail(forgot.error);
      if (forgot.writeErr) return yield* Effect.fail(forgot.writeErr);
    });
  }

  /// Takes over the accounts a page kept before the core existed (camelCase fields). An account already here is
  /// replaced only by a newer session.
  migrate(accounts: unknown): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      let raw = accounts;
      if (typeof raw === "string") {
        const parsed = parseJson(raw);
        if (parsed === undefined) return yield* Effect.fail(CoreError.invalid(t("core-logic.accounts.invalid_json")));
        raw = parsed;
      } else if (raw === null) return;
      if (!Array.isArray(raw)) return yield* Effect.fail(CoreError.invalid(t("core-logic.accounts.not_array")));
      let shouldNotify = false;
      let writeErr: CoreError | null = null;
      yield* hostAccountsLock(this.#host).withPermits(1)(
        Effect.gen({ self: this }, function* () {
          const disk = yield* this.#readDiskChecked();
          if (disk.kind === "error") return yield* Effect.fail(disk.error);
          const reloaded = this.#unloaded;
          const nextList = [...disk.list];
          this.#unloaded = false;
          let changed = false;
          for (const item of raw) {
            if (!isObject(item)) continue;
            const { sub, email, access, refresh, accessExpires } = item;
            if (typeof sub !== "string" || typeof email !== "string" || typeof access !== "string" || typeof refresh !== "string" || typeof accessExpires !== "number") continue;
            const name = item.name === undefined ? "" : item.name;
            const picture = item.picture === undefined ? "" : item.picture;
            if (typeof name !== "string" || typeof picture !== "string") continue;
            const existing = nextList.findIndex((a) => a.sub === sub);
            if (existing < 0) {
              const account: StoredAccount = { sub, email, name, picture, access, refresh, access_expires: accessExpires, session: ulid(this.#host) };
              nextList.push(account);
            } else if (nextList[existing].access_expires < accessExpires) {
              const prevSession = nextList[existing].session;
              const account: StoredAccount = { sub, email, name, picture, access, refresh, access_expires: accessExpires };
              if (typeof prevSession === "string" && prevSession.length > 0) account.session = prevSession;
              nextList[existing] = account;
            }
            changed = true;
          }
          this.#list = nextList;
          if (changed) {
            const written = yield* Effect.result(this.#host.storageSet(STORAGE_KEY, toJsonBytes(nextList)));
            shouldNotify = true;
            if (written._tag === "Failure") writeErr = asCoreError(written.failure);
          } else if (reloaded) {
            shouldNotify = true;
          }
        }),
      );
      if (shouldNotify) this.#notify();
      if (writeErr) return yield* Effect.fail(writeErr);
    });
  }

  /// Takes the stored credentials of `target.sub` when another core wrote newer ones for the exact same session;
  /// reports `"stale"` when this instance or shared storage already signed out or replaced `target`'s session.
  #adoptStored(target: StoredAccount): Effect.Effect<{ kind: "adopted"; access: string } | { kind: "stale" } | { kind: "continue"; account: StoredAccount }> {
    return Effect.map(Effect.result(this.#host.storageGet(STORAGE_KEY)), (r) => {
      const ours = this.#get(target.sub);
      if (!ours || (ours.session ?? "") !== (target.session ?? "") || ours.refresh !== target.refresh) {
        return { kind: "stale" as const };
      }
      if (r._tag === "Success") {
        const diskList = readStored(parseJson(r.success));
        if (diskList !== null) {
          const theirs = diskList.find((a) => a.sub === target.sub);
          if (!theirs || (theirs.session ?? "") !== (target.session ?? "")) {
            return { kind: "stale" as const };
          }
          if (theirs.refresh !== target.refresh) {
            const i = this.#list.findIndex((a) => a.sub === target.sub);
            if (i >= 0 && (this.#list[i].session ?? "") === (target.session ?? "") && this.#list[i].refresh === target.refresh) {
              this.#list[i] = theirs;
            }
            const good = theirs.access_expires - 60 > this.#host.nowMs() / 1000;
            return good ? { kind: "adopted" as const, access: theirs.access } : { kind: "continue" as const, account: { ...theirs } };
          }
        }
      }
      return { kind: "continue" as const, account: target };
    });
  }

  #get(sub: string): StoredAccount | undefined {
    const a = this.#list.find((a) => a.sub === sub);
    return a ? { ...a } : undefined;
  }

  /// Tests: the stored account itself.
  stored(sub: string): StoredAccount | undefined {
    return this.#get(sub);
  }

  #refresh(target: StoredAccount): Effect.Effect<string, CoreError> {
    return Effect.gen({ self: this }, function* () {
      // Another core on the same storage may have refreshed already: its credentials are the current ones.
      const adopted = yield* this.#adoptStored(target);
      if (adopted.kind === "adopted") return adopted.access;
      if (adopted.kind === "stale") return yield* Effect.fail(CoreError.signedOut(t("core-logic.accounts.signed_out")));
      const account = adopted.account;
      const body = { request_id: ulid(this.#host) };
      // Every refresh is a trace of its own, recorded whatever the sampling.
      const span = this.#tracer?.always("auth.refresh", Kind.Client) ?? null;
      if (span && this.#unanswered !== null) span.set("stillfail.auth.unanswered_ago_ms", Math.trunc(this.#host.monotonicMs() - this.#unanswered));
      const traceparent = span ? span.context.traceparent() : null;
      this.#unanswered = this.#host.monotonicMs();
      const sent = yield* Effect.result(Effect.timeoutOrElse(
        Effect.mapError(this.#post("/v1/auth/refresh", account.refresh, body, traceparent), asCoreError),
        { duration: REFRESH_TIMEOUT_MS, orElse: () => Effect.fail(new CoreError("timeout", t("core-logic.mesh.timed_out"))) },
      ));
      if (sent._tag === "Failure") {
        if (span) {
          span.set("error.type", sent.failure.code);
          span.fail();
          span.end();
        }
        return yield* Effect.fail(sent.failure);
      }
      const response = sent.success;
      this.#unanswered = null;
      if (span) {
        span.set("http.response.status_code", response.status);
        if (!ok(response)) {
          const code = parseJson(response.body);
          span.set("error.type", isObject(code) && typeof code.error === "string" ? code.error : `http_${response.status}`);
          span.fail();
        }
        span.end();
      }
      if (response.status === 401) {
        const forgot = yield* this.#forgetIfMatches(account.sub, account.session ?? "", account.refresh, true, false);
        if (forgot.kind === "retry") return yield* Effect.fail(forgot.error);
        return yield* Effect.fail(CoreError.signedOut(t("core-logic.accounts.session_expired", { email: account.email })).withStatus(401));
      }
      if (!ok(response)) return yield* Effect.fail(new CoreError("refresh_failed", t("core-logic.accounts.refresh_failed", { status: response.status }), response.status));
      const tokens = readTokens(parseJson(response.body));
      if (!tokens) return yield* Effect.fail(new CoreError("refresh_failed", t("core-logic.accounts.refresh_unreadable")));
      const committed = yield* this.#commitRefresh(account, tokens);
      if (committed.kind === "stale") {
        return yield* Effect.fail(CoreError.signedOut(t("core-logic.accounts.signed_out")));
      }
      if (committed.kind === "retry") {
        return yield* Effect.fail(committed.error);
      }
      return committed.access;
    });
  }

  /// Takes the profile a `/v1/me` answered with (`{user: {name, picture}}`): the picture fetched at sign-in may have
  /// failed, or the account's picture changed since. A name only where it says one.
  profile(sub: string, me: unknown): Effect.Effect<void> {
    return Effect.suspend(() => {
      const account = this.#get(sub);
      const name = pointer(me, "/user/name");
      const picture = pointer(me, "/user/picture");
      if (!account || typeof picture !== "string") return Effect.void;
      const nextName = typeof name === "string" && name !== "" ? name : account.name;
      if (picture === account.picture && nextName === account.name) return Effect.void;
      return Effect.ignore(this.#updateProfile(sub, account.session ?? "", { picture, name: nextName }), { log: "Unhandled", message: "account kept" });
    });
  }

  #picture(access: string): Effect.Effect<string | null> {
    return this.#host.fetch({ method: "GET", url: `${this.#host.cloudOrigin()}/v1/me`, headers: [["authorization", `Bearer ${access}`]], body: null }).pipe(
      Effect.map((response) => {
        const picture = pointer(parseJson(response.body), "/user/picture");
        return typeof picture === "string" && picture !== "" ? picture : null;
      }),
      Effect.orElseSucceed(() => null),
    );
  }

  #post(path: string, bearer: string | null, body: unknown, traceparent: string | null): Effect.Effect<HttpResponse, HostError> {
    const headers: [string, string][] = [["content-type", "application/json"]];
    if (traceparent !== null) headers.push(["traceparent", traceparent]);
    if (bearer !== null) headers.push(["authorization", `Bearer ${bearer}`]);
    // A refresh asked twice with its one `request_id` is answered the same: it may go again beside one gone quiet.
    if (path === "/v1/auth/refresh") headers.push([HEDGE, "1"]);
    return this.#host.fetch({ method: "POST", url: `${this.#host.cloudOrigin()}${path}`, headers, body: toJsonBytes(body) });
  }

  /// Adds or replaces an account (new sign-in) inside the cross-instance host lock: reads and validates shared disk
  /// storage first, merges by `sub` (preserving accounts added by other instances), and never writes if disk is unreadable.
  #put(account: StoredAccount): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      let writeErr: CoreError | null = null;
      yield* hostAccountsLock(this.#host).withPermits(1)(
        Effect.gen({ self: this }, function* () {
          const disk = yield* this.#readDiskChecked();
          if (disk.kind === "error") return yield* Effect.fail(disk.error);
          const nextList = [...disk.list];
          const i = nextList.findIndex((a) => a.sub === account.sub);
          if (i >= 0) {
            const session = account.session ?? nextList[i].session;
            nextList[i] = stored(session ? { ...account, session } : account);
          } else {
            nextList.push(stored(account));
          }
          this.#list = nextList;
          this.#unloaded = false;
          const written = yield* Effect.result(this.#host.storageSet(STORAGE_KEY, toJsonBytes(nextList)));
          if (written._tag === "Failure") writeErr = asCoreError(written.failure);
        }),
      );
      this.#notify();
      if (writeErr) return yield* Effect.fail(writeErr);
    });
  }

  /// Cross-instance serialized CAS commit of a profile/picture update: checks both in-memory and shared disk session
  /// match `expectedSession` and aborts without writing if shared storage cannot be read/parsed.
  #updateProfile(sub: string, expectedSession: string, patch: { picture?: string; name?: string }): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      let shouldNotify = false;
      let writeErr: CoreError | null = null;
      yield* hostAccountsLock(this.#host).withPermits(1)(
        Effect.gen({ self: this }, function* () {
          const memIdx = this.#list.findIndex((a) => a.sub === sub);
          if (memIdx < 0 || (this.#list[memIdx].session ?? "") !== expectedSession) return;
          const memCur = this.#list[memIdx];
          const nextPicture = patch.picture !== undefined ? patch.picture : memCur.picture;
          const nextName = patch.name !== undefined ? patch.name : memCur.name;
          if (nextPicture === memCur.picture && nextName === memCur.name) return;
          const disk = yield* this.#readDiskChecked();
          if (disk.kind === "error") return yield* Effect.fail(disk.error);
          const diskList = [...disk.list];
          const diskIdx = diskList.findIndex((a) => a.sub === sub);
          if (diskIdx < 0 || (diskList[diskIdx].session ?? "") !== expectedSession) return;
          diskList[diskIdx] = stored({ ...diskList[diskIdx], picture: nextPicture, name: nextName });
          this.#list[memIdx] = stored({ ...memCur, picture: nextPicture, name: nextName });
          const written = yield* Effect.result(this.#host.storageSet(STORAGE_KEY, toJsonBytes(diskList)));
          shouldNotify = true;
          if (written._tag === "Failure") writeErr = asCoreError(written.failure);
        }),
      );
      if (shouldNotify) this.#notify();
      if (writeErr) return yield* Effect.fail(writeErr);
    });
  }

  /// Cross-instance serialized CAS commit of a 200 token refresh: verifies both in-memory state and shared host storage
  /// still hold the exact `(session, refresh)` that initiated the refresh, aborting without writing on read failure.
  #commitRefresh(expected: StoredAccount, tokens: Tokens): Effect.Effect<{ kind: "ok"; access: string } | { kind: "stale" } | { kind: "retry"; error: CoreError }> {
    return Effect.gen({ self: this }, function* () {
      let shouldNotify = false;
      const result = yield* hostAccountsLock(this.#host).withPermits(1)(
        Effect.gen({ self: this }, function* () {
          const memIdx = this.#list.findIndex((a) => a.sub === expected.sub);
          if (memIdx < 0) return { kind: "stale" as const };
          const memCur = this.#list[memIdx];
          if ((memCur.session ?? "") !== (expected.session ?? "") || memCur.refresh !== expected.refresh) {
            return { kind: "stale" as const };
          }
          const disk = yield* this.#readDiskChecked();
          if (disk.kind === "error") {
            return { kind: "retry" as const, error: disk.error };
          }
          const diskList = [...disk.list];
          const diskIdx = diskList.findIndex((a) => a.sub === expected.sub);
          if (diskIdx < 0 || (diskList[diskIdx].session ?? "") !== (expected.session ?? "")) {
            return { kind: "stale" as const };
          }
          if (diskList[diskIdx].refresh !== expected.refresh) {
            // Another instance rotated tokens for the same session: adopt it without regressing disk.
            this.#list[memIdx] = diskList[diskIdx];
            return { kind: "ok" as const, access: diskList[diskIdx].access };
          }
          const updated = stored({
            ...diskList[diskIdx],
            access: tokens.access_token,
            refresh: tokens.refresh_token,
            access_expires: tokens.expires_at,
            name: tokens.name ? tokens.name : diskList[diskIdx].name,
          });
          diskList[diskIdx] = updated;
          this.#list[memIdx] = updated;
          // The new tokens are good even if they cannot be written down.
          yield* Effect.ignore(this.#host.storageSet(STORAGE_KEY, toJsonBytes(diskList)), { log: "Unhandled", message: "refreshed account kept" });
          shouldNotify = true;
          return { kind: "ok" as const, access: updated.access };
        }),
      );
      if (shouldNotify) this.#notify();
      return result;
    });
  }

  /// Cross-instance serialized CAS removal of `sub` for sign-out or 401 refresh: removes only when both in-memory state
  /// and shared host storage still match `expectedSession` (and `expectedRefresh` when `matchRefresh` is true), and
  /// returns `{ kind: "retry", error }` without modifying disk whenever shared storage cannot be read/parsed.
  #forgetIfMatches(
    sub: string,
    expectedSession: string,
    expectedRefresh: string,
    matchRefresh: boolean,
    notifyIfUnchanged: boolean,
  ): Effect.Effect<{ kind: "done"; writeErr?: CoreError } | { kind: "retry"; error: CoreError }> {
    return Effect.gen({ self: this }, function* () {
      let notifyRemoved: string[] | undefined;
      let shouldNotify = false;
      const result = yield* hostAccountsLock(this.#host).withPermits(1)(
        Effect.gen({ self: this }, function* () {
          const disk = yield* this.#readDiskChecked();
          if (disk.kind === "error") return { kind: "retry" as const, error: disk.error };
          let reloaded = false;
          if (this.#unloaded) {
            this.#list = disk.list;
            this.#unloaded = false;
            reloaded = true;
          }
          const memCur = this.#list.find((a) => a.sub === sub);
          const matches = (a: StoredAccount | undefined) =>
            a !== undefined
            && (a.session ?? "") === expectedSession
            && (!matchRefresh || a.refresh === expectedRefresh);
          if (!matches(memCur)) {
            if (reloaded || notifyIfUnchanged) shouldNotify = true;
            return { kind: "done" as const };
          }
          const diskCur = disk.list.find((a) => a.sub === sub);
          if (matchRefresh) {
            if (!matches(diskCur)) {
              if (reloaded || notifyIfUnchanged) shouldNotify = true;
              return { kind: "done" as const };
            }
          } else {
            if (diskCur !== undefined && (diskCur.session ?? "") !== expectedSession) {
              if (reloaded || notifyIfUnchanged) shouldNotify = true;
              return { kind: "done" as const };
            }
            if (diskCur === undefined) {
              // Already removed from shared storage by another instance: remove locally without rewriting disk.
              this.#list = this.#list.filter((a) => a.sub !== sub);
              shouldNotify = true;
              notifyRemoved = [sub];
              return { kind: "done" as const };
            }
          }
          const nextDisk = disk.list.filter((a) => a.sub !== sub);
          this.#list = this.#list.filter((a) => a.sub !== sub);
          const written = yield* Effect.result(this.#host.storageSet(STORAGE_KEY, toJsonBytes(nextDisk)));
          shouldNotify = true;
          notifyRemoved = [sub];
          return written._tag === "Failure"
            ? { kind: "done" as const, writeErr: asCoreError(written.failure) }
            : { kind: "done" as const };
        }),
      );
      if (shouldNotify) this.#notify(notifyRemoved);
      return result;
    });
  }

  #secret(): string {
    const bytes = new Uint8Array(32);
    this.#host.randomBytes(bytes);
    return base64url(bytes);
  }
}

function ok(response: HttpResponse): boolean {
  return response.status >= 200 && response.status < 300;
}

/// PKCE S256: base64url(sha256(verifier)).
export function challenge(verifier: string): string {
  return base64url(sha256(utf8(verifier)));
}

/// A ULID, which still.fail cloud wants as the id of each refresh request.
export function ulid(host: Host): string {
  const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = Math.trunc(host.nowMs());
  const out: string[] = new Array(26);
  for (let i = 9; i >= 0; i--) {
    out[i] = ALPHABET[time % 32];
    time = Math.floor(time / 32);
  }
  const random = new Uint8Array(16);
  host.randomBytes(random);
  for (let i = 0; i < 16; i++) out[10 + i] = ALPHABET[random[i] % 32];
  return out.join("");
}

/// Percent-encodes everything but RFC 3986 unreserved characters.
export function encodeComponent(text: string): string {
  let out = "";
  for (const b of utf8(text)) {
    const c = String.fromCharCode(b);
    if (/[A-Za-z0-9\-_.~]/.test(c)) out += c;
    else out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

export function decodeComponent(text: string): string {
  const bytes = utf8(text);
  const out: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b === 0x2b) out.push(0x20);
    else if (b === 0x25 && i + 2 < bytes.length) {
      const h = String.fromCharCode(bytes[i + 1], bytes[i + 2]);
      if (/^[0-9A-Fa-f]{2}$/.test(h)) {
        out.push(parseInt(h, 16));
        i += 2;
      } else out.push(0x25);
    } else out.push(b);
  }
  return new TextDecoder().decode(new Uint8Array(out));
}

/// A query string (with or without its leading `?`) as name/value pairs.
export function parseQuery(query: string): [string, string][] {
  return query
    .replace(/^\?+/, "")
    .split("&")
    .filter((p) => p !== "")
    .map((p) => {
      const at = p.indexOf("=");
      return at >= 0 ? [decodeComponent(p.slice(0, at)), decodeComponent(p.slice(at + 1))] : [decodeComponent(p), ""];
    });
}
