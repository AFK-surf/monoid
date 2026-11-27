// Client-side tracking of `{ id: 0, auth }` boundaries pushed by Core (PR-B2s) so Node hosts,
// e2e drivers, and harnesses attach matching `CallAuth` envelopes to protected write RPCs.
import type { AuthBoundary, CallAuth } from "./protocol.ts";

const AUTH_EXEMPT_CALLS = new Set(["auth.begin", "auth.complete", "auth.password"]);

export class ClientAuthTracker {
  #conn = 0;
  #global = 1;
  #vaultGlobal = 1;
  readonly #scopes = new Map<string, number>();
  readonly #vaults = new Map<string, number>();
  readonly #waiters: (() => void)[] = [];

  get conn(): number {
    return this.#conn;
  }

  get ready(): boolean {
    return this.#conn > 0;
  }

  /// Resolves once the initial `{ id: 0, auth }` handshake snapshot has arrived.
  whenReady(): Promise<void> {
    if (this.#conn > 0) return Promise.resolve();
    return new Promise((resolve) => this.#waiters.push(resolve));
  }

  /// Whether a call name should wait for handshake and carry a `CallAuth` envelope.
  needsAuth(name: string): boolean {
    if (name.startsWith("client.") || name.startsWith("prefs.") || name.startsWith("changelog.")) return false;
    if (AUTH_EXEMPT_CALLS.has(name)) return false;
    return name.includes(".");
  }

  /// Ingests an incoming wire message from Core. Returns true if it was an `{ id: 0, auth }` boundary.
  takeMessage(message: unknown): boolean {
    if (typeof message !== "object" || message === null) return false;
    const m = message as Record<string, unknown>;
    if (m.id !== 0 || typeof m.auth !== "object" || m.auth === null) return false;
    this.take(m.auth as AuthBoundary);
    return true;
  }

  /// Applies a full handshake snapshot or incremental `AuthBoundary` update monotonically within a connection.
  take(auth: AuthBoundary): void {
    const conn = typeof auth.conn === "number" ? auth.conn : 0;
    if (conn <= 0 || conn < this.#conn) return;
    const hasSnapshot =
      typeof auth.scopes === "object" &&
      auth.scopes !== null &&
      typeof auth.vaults === "object" &&
      auth.vaults !== null;
    if (hasSnapshot) {
      const sameConn = conn === this.#conn;
      this.#conn = conn;
      const snapGlobal = typeof auth.global === "number" && auth.global > 0 ? auth.global : 1;
      const snapVaultGlobal = typeof auth.vaultGlobal === "number" && auth.vaultGlobal > 0 ? auth.vaultGlobal : 1;
      if (sameConn) {
        if (snapGlobal > this.#global) this.#global = snapGlobal;
        if (snapVaultGlobal > this.#vaultGlobal) this.#vaultGlobal = snapVaultGlobal;
        for (const [k, v] of Object.entries(auth.scopes!)) {
          if (typeof v === "number" && v > (this.#scopes.get(k) ?? 0)) this.#scopes.set(k, v);
        }
        for (const [k, v] of Object.entries(auth.vaults!)) {
          if (typeof v === "number" && v > (this.#vaults.get(k) ?? 0)) this.#vaults.set(k, v);
        }
      } else {
        this.#global = snapGlobal;
        this.#vaultGlobal = snapVaultGlobal;
        this.#scopes.clear();
        for (const [k, v] of Object.entries(auth.scopes!)) {
          if (typeof v === "number") this.#scopes.set(k, v);
        }
        this.#vaults.clear();
        for (const [k, v] of Object.entries(auth.vaults!)) {
          if (typeof v === "number") this.#vaults.set(k, v);
        }
      }
      if (this.#waiters.length > 0) {
        const waiters = this.#waiters.splice(0);
        for (const resolve of waiters) resolve();
      }
      return;
    }
    if (this.#conn === 0) return;
    this.#conn = conn;
    if (typeof auth.global === "number" && auth.global > this.#global) {
      this.#global = auth.global;
    }
    if (typeof auth.workspace === "string" && typeof auth.authGen === "number") {
      if (auth.authGen > (this.#scopes.get(auth.workspace) ?? 0)) {
        this.#scopes.set(auth.workspace, auth.authGen);
      }
      if (typeof auth.dependentVaultGens === "object" && auth.dependentVaultGens !== null) {
        for (const [dep, vg] of Object.entries(auth.dependentVaultGens)) {
          if (typeof vg === "number" && vg > (this.#vaults.get(dep) ?? 0)) {
            this.#vaults.set(dep, vg);
          }
        }
      }
    }
    if (auth.vaultAll === true && typeof auth.vaultGen === "number") {
      if (auth.vaultGen > this.#vaultGlobal) this.#vaultGlobal = auth.vaultGen;
    } else if (
      typeof auth.workspace === "string" &&
      typeof auth.vault === "string" &&
      typeof auth.vaultGen === "number"
    ) {
      const k = `${auth.workspace}/${auth.vault}`;
      if (auth.vaultGen > (this.#vaults.get(k) ?? 0)) this.#vaults.set(k, auth.vaultGen);
      if (auth.vaultGen > (this.#vaults.get(auth.workspace) ?? 0)) this.#vaults.set(auth.workspace, auth.vaultGen);
      if (Array.isArray(auth.dependentWorkspaces)) {
        for (const dep of auth.dependentWorkspaces) {
          if (typeof dep === "string" && auth.vaultGen > (this.#vaults.get(dep) ?? 0)) {
            this.#vaults.set(dep, auth.vaultGen);
          }
        }
      }
    }
  }

  /// Builds the `CallAuth` envelope for a call, or `undefined` if not yet handshaked or exempt.
  callAuth(name: string, params: unknown): CallAuth | undefined {
    if (this.#conn <= 0 || !this.needsAuth(name)) return undefined;
    const p = typeof params === "object" && params !== null ? (params as Record<string, unknown>) : null;
    let ws: string | undefined;
    if (p) {
      if (name.startsWith("composer.") && typeof p.key === "string") {
        if (p.key.startsWith("new:") && p.key.length > 4) ws = p.key.slice(4);
        else if (p.key.includes("/")) ws = p.key.slice(0, p.key.indexOf("/"));
      }
      if (ws === undefined) {
        if (typeof p.workspace === "string" && p.workspace !== "") ws = p.workspace;
        else if (typeof p.scope === "string" && p.scope !== "") ws = p.scope;
        else if (typeof p.station === "string" && p.station.includes("/")) {
          ws = p.station.slice(0, p.station.indexOf("/"));
        }
      }
    }
    const authGen = ws !== undefined ? Math.max(this.#global, this.#scopes.get(ws) ?? 0) : this.#global;
    const auth: CallAuth = { conn: this.#conn, authGen };
    if (ws !== undefined) auth.workspace = ws;
    if (p && typeof p.account === "string" && p.account !== "") auth.account = p.account;
    const isVault =
      name.startsWith("vault.") && name !== "vault.lock" && name !== "vault.state" && name !== "vault.prompts";
    if (isVault) {
      const vault = p && typeof p.vault === "string" && p.vault !== "" ? p.vault : undefined;
      if (vault !== undefined) auth.vault = vault;
      const vKey = ws !== undefined && vault !== undefined ? `${ws}/${vault}` : ws;
      auth.vaultGen = Math.max(this.#vaultGlobal, vKey !== undefined ? (this.#vaults.get(vKey) ?? 0) : 0);
    }
    return auth;
  }
}
