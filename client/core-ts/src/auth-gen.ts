// Authoritative `(account, workspace)` authorization generation (`authGen`) and independent
// per-vault generation (`vaultGen`) tracking for RFC v3.1 PR-B2s.
//
// Design invariants:
// - `authGen` advances ONLY when authoritative authorization content digest changes
//   (account add/remove/switch, role downgrade, member removal, trusted device revocation,
//   safe mode state change). Identical digests never advance (preventing bump -> resub -> bump loops).
// - Routine workspace switching (A -> B) NEVER advances `authGen` and NEVER clears A's valid cache.
// - Single-vault timeout / explicit `vault.lock` advances ONLY `vaultGen` for affected vaults
//   and dependent `vaults` aggregates; non-vault workspace `authGen` and unaffected vaults (V2)
//   suffer zero false invalidations.
import { CoreError } from "./error.ts";
import { t } from "./i18n.ts";
import type { AuthBoundary, CallAuth, Topic } from "./protocol.ts";
import { DEVICE_GLOBAL_TOPIC_SET } from "./topic-policy.ts";
import { ofAddress } from "./workspace.ts";

export type TopicScope =
  | { readonly kind: "device" }
  | { readonly kind: "global" }
  | { readonly kind: "account"; readonly account: string }
  | { readonly kind: "workspace"; readonly workspace: string }
  | { readonly kind: "vaultWorkspace"; readonly workspace: string }
  | { readonly kind: "vault"; readonly workspace: string; readonly vault: string };

const ACCOUNT_PARAM_TOPICS = new Set(["loginSessions", "admin", "adminList", "adminItem", "adminOverview", "adminRelays"]);
const WORKSPACE_AGGREGATE_TOPICS = new Set(["workspaces", "lockPrompts", "downloads"]);

/// Classifies a topic into its isolation scope for `authGen` / `vaultGen` enforcement.
export function topicScopeOf(topic: Topic): TopicScope {
  const name = topic.topic;
  if (name === "vaultItems" || name === "vaultUses") {
    return { kind: "vault", workspace: String(topic.workspace ?? ""), vault: String(topic.vault ?? "") };
  }
  if (name === "vaults") {
    return { kind: "vaultWorkspace", workspace: String(topic.workspace ?? "") };
  }
  if (ACCOUNT_PARAM_TOPICS.has(name)) {
    return { kind: "account", account: String(topic.account ?? "") };
  }
  if (DEVICE_GLOBAL_TOPIC_SET.has(name)) {
    return { kind: "device" };
  }
  if (typeof topic.workspace === "string" && topic.workspace.length > 0) {
    return { kind: "workspace", workspace: topic.workspace };
  }
  if (typeof topic.scope === "string" && topic.scope.length > 0) {
    return { kind: "workspace", workspace: topic.scope };
  }
  if (typeof topic.station === "string" && topic.station.length > 0) {
    return { kind: "workspace", workspace: ofAddress(topic.station) };
  }
  return { kind: "global" };
}

export type AuthBoundaryEvent =
  | { readonly kind: "global"; readonly global: number }
  | {
      readonly kind: "workspace";
      readonly workspace: string;
      readonly authGen: number;
      readonly dependentWorkspaces?: readonly string[];
      readonly dependentVaultGens?: Readonly<Record<string, number>>;
    }
  | {
      readonly kind: "vault";
      readonly workspace: string;
      readonly vault: string;
      readonly vaultGen: number;
      readonly dependentWorkspaces: readonly string[];
    }
  | { readonly kind: "vaultAll"; readonly vaultGen: number };

/// Reconstructs the exact `workspaceAuthGen(ws)` at the time `snap` was captured.
export function snapWsAuthGen(snap: AuthBoundary, ws: string): number {
  return Math.max(snap.global ?? 1, snap.scopes?.[ws] ?? 0);
}

/// Reconstructs the exact `vaultGen(ws, vaultId)` at the time `snap` was captured.
export function snapVaultGen(snap: AuthBoundary, ws: string, vaultId: string): number {
  return Math.max(snap.vaultGlobal ?? 1, snap.vaults?.[`${ws}/${vaultId}`] ?? 0);
}

/// Monotonic generation tracker for `(account, workspace)` authorization and per-vault lock boundaries.
export class AuthGenTracker {
  #globalGen = 1;
  #aggregateAuthGen = 1;
  #accountsDigest: string | null = null;
  readonly #workspaceGens = new Map<string, number>();
  readonly #workspaceDigests = new Map<string, string>();
  readonly #vaultGens = new Map<string, number>();
  readonly #vaultWsGens = new Map<string, number>();
  #vaultGlobalGen = 1;
  readonly #listeners: ((event: AuthBoundaryEvent) => void)[] = [];

  get globalGen(): number {
    return this.#globalGen;
  }

  get aggregateAuthGen(): number {
    return this.#aggregateAuthGen;
  }

  get vaultGlobalGen(): number {
    return this.#vaultGlobalGen;
  }

  onBoundary(listener: (event: AuthBoundaryEvent) => void): () => void {
    this.#listeners.push(listener);
    return () => {
      const idx = this.#listeners.indexOf(listener);
      if (idx >= 0) this.#listeners.splice(idx, 1);
    };
  }

  #notify(event: AuthBoundaryEvent): void {
    for (const l of [...this.#listeners]) l(event);
  }

  workspaceAuthGen(workspace: string): number {
    return Math.max(this.#globalGen, this.#workspaceGens.get(workspace) ?? 0);
  }

  vaultGen(workspace: string, vault: string): number {
    return Math.max(this.#vaultGlobalGen, this.#vaultGens.get(`${workspace}/${vault}`) ?? 0);
  }

  vaultWorkspaceGen(workspace: string): number {
    return Math.max(this.#vaultGlobalGen, this.#vaultWsGens.get(workspace) ?? 0);
  }

  /// Effective `authGen` for a topic. Device-global preferences return 0.
  authGenOf(topic: Topic): number {
    if (WORKSPACE_AGGREGATE_TOPICS.has(topic.topic)) {
      return this.#aggregateAuthGen;
    }
    const scope = topicScopeOf(topic);
    switch (scope.kind) {
      case "device":
        return 0;
      case "global":
      case "account":
        return this.#globalGen;
      case "workspace":
      case "vaultWorkspace":
      case "vault":
        return this.workspaceAuthGen(scope.workspace);
    }
  }

  /// Effective `vaultGen` for a topic. Non-vault topics return 0.
  vaultGenOf(topic: Topic): number {
    const scope = topicScopeOf(topic);
    switch (scope.kind) {
      case "vault":
        return this.vaultGen(scope.workspace, scope.vault);
      case "vaultWorkspace":
        return this.vaultWorkspaceGen(scope.workspace);
      default:
        return 0;
    }
  }

  /// Whether `topic` is affected by `event`.
  matches(topic: Topic, event: AuthBoundaryEvent): boolean {
    const scope = topicScopeOf(topic);
    switch (event.kind) {
      case "global":
        return scope.kind !== "device";
      case "workspace":
        if (topic.topic === "workspaces" || topic.topic === "lockPrompts" || topic.topic === "downloads") {
          return true;
        }
        if (scope.kind === "vaultWorkspace" && event.dependentWorkspaces?.includes(scope.workspace)) {
          return true;
        }
        return (
          (scope.kind === "workspace" || scope.kind === "vaultWorkspace" || scope.kind === "vault") &&
          scope.workspace === event.workspace
        );
      case "vault":
        if (scope.kind === "vault") {
          return scope.workspace === event.workspace && scope.vault === event.vault;
        }
        if (scope.kind === "vaultWorkspace") {
          return scope.workspace === event.workspace || event.dependentWorkspaces.includes(scope.workspace);
        }
        return false;
      case "vaultAll":
        return scope.kind === "vault" || scope.kind === "vaultWorkspace";
    }
  }

  /// Synchronizes the signed-in account set. Advances `globalGen` ONLY when the canonical
  /// account set changes (never on token refresh or identical re-emission).
  syncAccounts(subs: readonly string[]): boolean {
    const digest = [...new Set(subs)].sort().join("\u0001");
    if (this.#accountsDigest === null) {
      this.#accountsDigest = digest;
      return false;
    }
    if (this.#accountsDigest === digest) return false;
    this.#accountsDigest = digest;
    let maxSeen = Math.max(this.#globalGen, this.#aggregateAuthGen);
    for (const g of this.#workspaceGens.values()) if (g > maxSeen) maxSeen = g;
    this.#globalGen = maxSeen + 1;
    this.#aggregateAuthGen = this.#globalGen;
    this.#notify({ kind: "global", global: this.#globalGen });
    return true;
  }

  hasWorkspaceDigest(workspace: string): boolean {
    return this.#workspaceDigests.has(workspace);
  }

  workspaceDigest(workspace: string): string | undefined {
    return this.#workspaceDigests.get(workspace);
  }

  #bumpDependentVaultWs(dependentWorkspaces: readonly string[]): Record<string, number> | undefined {
    if (dependentWorkspaces.length === 0) return undefined;
    const out: Record<string, number> = {};
    for (const dep of dependentWorkspaces) {
      const next = Math.max(this.#vaultGlobalGen, this.#vaultWsGens.get(dep) ?? 0) + 1;
      this.#vaultWsGens.set(dep, next);
      out[dep] = next;
    }
    return out;
  }

  /// Synchronizes authoritative authorization summary for a workspace (owner, role, membership,
  /// safe mode, trusted device status). Advances `authGen(workspace)` ONLY when digest changes.
  syncWorkspace(workspace: string, digest: string, dependentWorkspaces: readonly string[] = []): boolean {
    const prev = this.#workspaceDigests.get(workspace);
    if (prev === undefined) {
      this.#workspaceDigests.set(workspace, digest);
      return false;
    }
    if (prev === digest) return false;
    this.#workspaceDigests.set(workspace, digest);
    const next = Math.max(this.#globalGen, this.#workspaceGens.get(workspace) ?? 0) + 1;
    this.#workspaceGens.set(workspace, next);
    this.#aggregateAuthGen = Math.max(this.#aggregateAuthGen + 1, next);
    const depVaultGens = this.#bumpDependentVaultWs(dependentWorkspaces);
    this.#notify({
      kind: "workspace",
      workspace,
      authGen: next,
      ...(dependentWorkspaces.length > 0 ? { dependentWorkspaces } : {}),
      ...(depVaultGens ? { dependentVaultGens: depVaultGens } : {}),
    });
    return true;
  }

  /// Explicitly advances `authGen` for one workspace (used by tests or direct revocation events).
  bumpWorkspace(workspace: string, dependentWorkspaces: readonly string[] = []): number {
    const next = Math.max(this.#globalGen, this.#workspaceGens.get(workspace) ?? 0) + 1;
    this.#workspaceGens.set(workspace, next);
    this.#aggregateAuthGen = Math.max(this.#aggregateAuthGen + 1, next);
    const depVaultGens = this.#bumpDependentVaultWs(dependentWorkspaces);
    this.#notify({
      kind: "workspace",
      workspace,
      authGen: next,
      ...(dependentWorkspaces.length > 0 ? { dependentWorkspaces } : {}),
      ...(depVaultGens ? { dependentVaultGens: depVaultGens } : {}),
    });
    return next;
  }

  /// Advances `vaultGen` for a single vault (`workspace/vault`) and its dependent `vaults` aggregates
  /// without advancing non-vault workspace `authGen` or touching other vaults (V2).
  bumpVault(workspace: string, vault: string, dependentWorkspaces: readonly string[] = []): number {
    const key = `${workspace}/${vault}`;
    let maxSeen = Math.max(this.#vaultGlobalGen, this.#vaultGens.get(key) ?? 0, this.#vaultWsGens.get(workspace) ?? 0);
    for (const dep of dependentWorkspaces) {
      const g = this.#vaultWsGens.get(dep) ?? 0;
      if (g > maxSeen) maxSeen = g;
    }
    const next = maxSeen + 1;
    this.#vaultGens.set(key, next);
    this.#vaultWsGens.set(workspace, next);
    for (const dep of dependentWorkspaces) {
      this.#vaultWsGens.set(dep, next);
    }
    this.#notify({ kind: "vault", workspace, vault, vaultGen: next, dependentWorkspaces });
    return next;
  }

  /// Advances `vaultGen` for all vaults (explicit `vault.lock`), without advancing non-vault `authGen`.
  bumpAllVaults(): number {
    let maxSeen = this.#vaultGlobalGen;
    for (const g of this.#vaultGens.values()) if (g > maxSeen) maxSeen = g;
    for (const g of this.#vaultWsGens.values()) if (g > maxSeen) maxSeen = g;
    const next = maxSeen + 1;
    this.#vaultGlobalGen = next;
    for (const k of this.#vaultGens.keys()) this.#vaultGens.set(k, next);
    for (const k of this.#vaultWsGens.keys()) this.#vaultWsGens.set(k, next);
    this.#notify({ kind: "vaultAll", vaultGen: next });
    return next;
  }

  /// Builds an authoritative snapshot for a newly connected / restarted client.
  snapshot(conn: number): AuthBoundary {
    const scopes: Record<string, number> = {};
    for (const [ws, g] of this.#workspaceGens) scopes[ws] = Math.max(this.#globalGen, g);
    const vaults: Record<string, number> = {};
    for (const [k, g] of this.#vaultGens) vaults[k] = Math.max(this.#vaultGlobalGen, g);
    for (const [ws, g] of this.#vaultWsGens) vaults[ws] = Math.max(this.#vaultGlobalGen, g);
    return {
      conn,
      global: this.#globalGen,
      aggregate: this.#aggregateAuthGen,
      vaultGlobal: this.#vaultGlobalGen,
      scopes,
      vaults,
    };
  }

  /// Builds a targeted boundary message for an incremental event.
  toBoundaryMessage(conn: number, event: AuthBoundaryEvent): AuthBoundary {
    switch (event.kind) {
      case "global":
        return { conn, global: event.global, aggregate: this.#aggregateAuthGen };
      case "workspace":
        return {
          conn,
          global: this.#globalGen,
          aggregate: this.#aggregateAuthGen,
          workspace: event.workspace,
          authGen: event.authGen,
          ...(event.dependentWorkspaces && event.dependentWorkspaces.length > 0
            ? { dependentWorkspaces: [...event.dependentWorkspaces] }
            : {}),
          ...(event.dependentVaultGens ? { dependentVaultGens: { ...event.dependentVaultGens } } : {}),
        };
      case "vault":
        return {
          conn,
          global: this.#globalGen,
          workspace: event.workspace,
          vault: event.vault,
          vaultGen: event.vaultGen,
          ...(event.dependentWorkspaces.length > 0 ? { dependentWorkspaces: [...event.dependentWorkspaces] } : {}),
        };
      case "vaultAll":
        return { conn, global: this.#globalGen, vaultAll: true, vaultGen: event.vaultGen };
    }
  }

  /// Verifies a delayed write call's original authorization context against current authoritative state
  /// and the parsed call's resolved target (`account`, `workspace`, `vault`).
  /// For protected write calls on a handshaked connection (`conn > 0`), missing `auth` is rejected,
  /// declared targets must match resolved targets, and generations must match exactly.
  verifyCallAuth(
    auth: CallAuth | undefined,
    conn: number,
    ownerOf: (workspace: string) => string | null,
    signedInSubs: ReadonlySet<string>,
    target?: { account?: string; workspace?: string; vault?: string; isVault?: boolean; viewAuthGen?: number },
    protectedWrite = false,
  ): CoreError | null {
    if (!auth) {
      if (protectedWrite && conn > 0) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
      return null;
    }
    if (conn > 0 && (auth.conn === undefined || auth.conn !== conn)) {
      return new CoreError("auth_stale", t("core-misc.auth.stale"));
    }
    if (auth.account !== undefined && !signedInSubs.has(auth.account)) {
      return new CoreError("auth_stale", t("core-misc.auth.stale"));
    }
    if (target?.account !== undefined) {
      if (auth.account !== undefined && auth.account !== target.account) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
      if (!signedInSubs.has(target.account)) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
    }
    const resolvedWs = target?.workspace ?? auth.workspace;
    if (target?.workspace !== undefined && auth.workspace !== undefined && auth.workspace !== target.workspace) {
      return new CoreError("auth_stale", t("core-misc.auth.stale"));
    }
    if (resolvedWs !== undefined) {
      if (auth.account !== undefined && ownerOf(resolvedWs) !== auth.account) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
      const curAuthGen = this.workspaceAuthGen(resolvedWs);
      if (target?.viewAuthGen !== undefined) {
        // View-bound calls (`terminal.*` / `screen.*` / `farview.send`): ALWAYS verify the bound view was
        // opened in the workspace's current generation, regardless of whether `auth.workspace` was supplied.
        if (target.viewAuthGen !== curAuthGen) {
          return new CoreError("auth_stale", t("core-misc.auth.stale"));
        }
        if (protectedWrite && conn > 0 && auth.authGen === undefined) {
          return new CoreError("auth_stale", t("core-misc.auth.stale"));
        }
        if (auth.authGen !== undefined) {
          if (auth.workspace !== undefined) {
            if (auth.authGen !== curAuthGen) return new CoreError("auth_stale", t("core-misc.auth.stale"));
          } else if (auth.authGen !== this.#globalGen && auth.authGen !== curAuthGen) {
            return new CoreError("auth_stale", t("core-misc.auth.stale"));
          }
        }
      } else {
        if (protectedWrite && conn > 0 && auth.authGen === undefined) {
          return new CoreError("auth_stale", t("core-misc.auth.stale"));
        }
        if (auth.authGen !== undefined && auth.authGen !== curAuthGen) {
          return new CoreError("auth_stale", t("core-misc.auth.stale"));
        }
      }
    } else {
      if (protectedWrite && conn > 0 && auth.authGen === undefined) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
      if (auth.authGen !== undefined && auth.authGen !== this.#globalGen) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
    }
    const resolvedVault = target?.vault ?? auth.vault;
    if (target?.vault !== undefined && auth.vault !== undefined && auth.vault !== target.vault) {
      return new CoreError("auth_stale", t("core-misc.auth.stale"));
    }
    if (target?.isVault || auth.vaultGen !== undefined) {
      const curVaultGen =
        resolvedWs !== undefined && resolvedVault !== undefined
          ? this.vaultGen(resolvedWs, resolvedVault)
          : resolvedWs !== undefined
            ? this.vaultWorkspaceGen(resolvedWs)
            : this.#vaultGlobalGen;
      if (target?.isVault && protectedWrite && conn > 0 && auth.vaultGen === undefined) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
      if (auth.vaultGen !== undefined && auth.vaultGen !== curVaultGen) {
        return new CoreError("auth_stale", t("core-misc.auth.stale"));
      }
    }
    return null;
  }
}
