import { nowSeconds } from "../auth";
import type { Env } from "../env";
import type { MeshRelay } from "../mesh-relay-registry";
import { ownRelay, type Relays } from "../relays";
import type { AccountEvent, AdminList, InviteCodeView, LockHead, RigView, Role, StationEvent, StationView, WorkspaceView } from "../types";
import { ROLES, fail, type AddedMail, type Delivery, type Row } from "./types";

/** Shared SQLite access and read-only queries used across directory domain modules. */
export class DirectoryDb {
  readonly ctx: DurableObjectState;
  readonly env: Env;
  constructor(ctx: DurableObjectState, env: Env) {
    this.ctx = ctx;
    this.env = env;
  }

  rows(query: string, ...args: SqlStorageValue[]): Row[] {
    return this.ctx.storage.sql.exec(query, ...args).toArray() as Row[];
  }

  one(query: string, ...args: SqlStorageValue[]): Row | undefined {
    return this.rows(query, ...args)[0];
  }

  run(query: string, ...args: SqlStorageValue[]): void {
    this.ctx.storage.sql.exec(query, ...args);
  }

  /** The caller's role in a workspace; fails unless it has one of `allowed`. */
  role(sub: string, workspace: string, allowed: readonly Role[] = ROLES): Role {
    const row = this.one("SELECT role FROM members WHERE workspace = ? AND sub = ?", workspace, sub);
    if (!row) fail(404, "workspace_not_found");
    const role = row!.role as Role;
    if (!allowed.includes(role)) fail(403, "forbidden");
    return role;
  }

  members(workspace: string): string[] {
    return this.rows("SELECT sub FROM members WHERE workspace = ?", workspace).map((r) => r.sub as string);
  }

  /** The stations in a workspace, its rigs among them (each holds a presence socket and is told its state). */
  stationsIn(workspace: string): string[] {
    return this.rows("SELECT station FROM station_members WHERE workspace = ?", workspace).map((r) => r.station as string);
  }

  /** The workspaces a station is in, its home first: the earliest full workspace, or earliest rig workspace if rig-only. */
  memberships(station: string): string[] {
    return this.rows("SELECT workspace FROM station_members WHERE station = ? ORDER BY (rig IS NOT NULL), enrolled_at, rowid", station).map((r) => r.workspace as string);
  }

  /** Accounts signed in with this email (invitations are addressed by email). */
  byEmail(email: string | null): string[] {
    return email ? this.rows("SELECT sub FROM users WHERE lower(email) = lower(?)", email).map((r) => r.sub as string) : [];
  }

  /** Accounts with an open invitation to this workspace; they see its name. */
  invitees(workspace: string): string[] {
    return this.rows("SELECT u.sub FROM invitations i JOIN users u ON lower(u.email) = i.email WHERE i.workspace = ? AND i.expires_at > ?", workspace, nowSeconds()).map((r) => r.sub as string);
  }

  /**
   * The stations of a workspace (of every workspace, grouped by the caller, without one), as its views list them: named
   * there, `joined` where it is not the station's home (a station in one workspace says nothing of it).
   */
  stationViews(workspace: string | null): (StationView & { workspace: string })[] {
    return this.rows(`SELECT m.workspace, m.station AS id, m.name, m.emoji, m.icon, m.enrolled_at, m.enrolled_by, s.last_seen, s.version,
        EXISTS (SELECT 1 FROM station_members o WHERE o.station = m.station AND o.rig IS NULL AND (o.enrolled_at < m.enrolled_at OR (o.enrolled_at = m.enrolled_at AND o.rowid < m.rowid))) AS joined
      FROM station_members m LEFT JOIN stations s ON s.id = m.station WHERE (? IS NULL OR m.workspace = ?) AND m.rig IS NULL ORDER BY m.enrolled_at, m.rowid`, workspace, workspace)
      .map(({ joined, ...row }) => ({ ...row, ...(joined ? { joined: true } : {}) })) as unknown as (StationView & { workspace: string })[];
  }

  /** A workspace's rigs as its stations are told them (`rigs`); nothing said with none, as before there were any. */
  rigsTold(workspace: string): { rigs?: Pick<RigView, "id" | "name" | "owner" | "owner_email" | "owner_name" | "version">[] } {
    const rigs = this.rigViews(workspace).map(({ id, name, owner, owner_email, owner_name, version }) => ({ id, name, owner, owner_email, owner_name, version }));
    return rigs.length ? { rigs } : {};
  }

  /** The rigs of a workspace (of every workspace, grouped by the caller, without one), each with its person (who added it). */
  rigViews(workspace: string | null): RigView[] {
    const rows = this.rows(`SELECT m.workspace, m.station AS id, m.name, m.enrolled_at, m.enrolled_by AS owner, COALESCE(u.email, '') AS owner_email, COALESCE(u.name, '') AS owner_name, s.last_seen, s.version
      FROM station_members m LEFT JOIN stations s ON s.id = m.station LEFT JOIN users u ON u.sub = m.enrolled_by WHERE (? IS NULL OR m.workspace = ?) AND m.rig = 1 ORDER BY m.enrolled_at, m.rowid`, workspace, workspace);
    return (workspace === null ? rows : rows.map(({ workspace: _, ...rig }) => rig)) as unknown as RigView[];
  }

  meshRelays(): MeshRelay[] {
    return this.rows("SELECT node, name, generation, revision, address FROM mesh_relays WHERE revoked = 0 ORDER BY node").map((row) => ({
      node: row.node as string, name: row.name as string, generation: row.generation as number,
      revision: row.revision as number, address: JSON.parse(row.address as string),
    }));
  }

  /** The relays as this cloud has them: its own, and its list in the order its relays were put on it. */
  relays(mesh: MeshRelay[] = this.meshRelays()): Relays {
    const listed = this.rows("SELECT url, name, target FROM relays ORDER BY added_at, rowid").map((r) => ({ url: r.url as string, name: r.name as string, target: (r.target as string | null) ?? null }));
    return { own: ownRelay(this.env), listed, mesh };
  }
}

/** Cross-domain callbacks wired by `Directory` so domain modules stay acyclic. */
export interface DirectoryHost {
  tell(subs: Iterable<string>, ...events: AccountEvent[]): void;
  tellAll(event: AccountEvent, station: StationEvent | null): void;
  tellStations(event: StationEvent): void;
  deliver(kind: "account" | "station", key: string, body: Delivery, how?: { urgent?: boolean; always?: boolean }): void;
  delivered(): Promise<void>;
  send(kind: "account" | "station", key: string, body: Delivery): Promise<{ live: boolean }>;
  opened(kind: "account" | "station", key: string): number;
  presence(station: string): WebSocket[];
  sendState(station: string, urgent?: boolean): void;
  disconnect(station: string): void;
  frame(station: string): string | null;
  said(station: string, message: string, send: (frame: string) => void): Promise<void>;
  adminChanged(...lists: AdminList[]): void;
  adminSubs(): string[];
  betaTold(sub: string): void;
  setBeta(sub: string, on: boolean): { sub: string; beta: boolean };
  setMayCreate(sub: string, on: boolean): { sub: string; may_create: boolean };
  inviteCodes(): InviteCodeView[];
  keepCounts(): void;
  changed(workspace: string, list: boolean, also?: Iterable<string>, only?: "lock" | "requests" | null): void;
  view(sub: string, id: string): WorkspaceView;
  removeWorkspace(id: string): void;
  standard(sub: string): boolean;
  memberCap(workspace: string): number;
  seats(workspace: string, invited?: boolean): number;
  addEmails(by: string, workspace: string, role: Role, wanted: string[]): { joined: string[]; added: string[]; already: string[] };
  toMail(by: string, workspace: string, joined: string[], added: string[], already: string[], reportsSent: boolean): AddedMail;
  forgetMailRetry(workspace: string, email: string): void;
  enrollment(sub: string, workspace: string, name: unknown, rig?: boolean): Promise<{ token: string; expires_at: number }>;
  left(station: string, home: string): void;
  rigsGone(workspace: string, sub: string): void;
  isStation(station: string): boolean;
  revoke(workspace: string, kind: "sub" | "sid", id: string): void;
  meshRelays(): MeshRelay[];
  lockHead(workspace: string): LockHead | null;
  locked(workspace: string): boolean;
  moved(workspace: string): boolean;
  lockRequestCount(workspace: string, sub: string, role: Role): number;
  lockTurnedOff(workspace: string, genesis: string, after: number): unknown[];
  lockAfter(workspace: string, after: number): unknown[];
  appendLockInternal(workspace: string, raw: unknown, fork?: boolean): Promise<LockHead | null>;
  resetFixesMarked(): void;
}
