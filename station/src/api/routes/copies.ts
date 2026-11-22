// The copies of this station's chats (replica/copies.ts), as its settings ask of them: on a station with no chat of its
// own, one of the lost stations' copies the overview's `copies.restorable` offers taken back (POST /copies/restore
// `{station, gen, from: {station}}`). The workspace's owners and admins.
import { type Request, error, json, param } from "../request.ts";
import type { Route } from "../admin.ts";
import { managesStation } from "../../mesh/credential.ts";
import type { ConfigFile } from "../../ops/config.ts";
import type { Copies, RestoreFrom } from "../../replica/copies.ts";
import type { Retire } from "../../replica/retire.ts";
import { applyBackupUpdate, normalizeS3Target, readBackupConfig } from "../../replica/backup-config.ts";
import { S3Client } from "../../replica/s3.ts";
import { Refused } from "../../mesh/bus.ts";
import { tr } from "../../ops/i18n.ts";

const body = (r: Request): any => {
  try {
    return JSON.parse(r.body.toString("utf8") || "{}") ?? {};
  } catch {
    return null;
  }
};

/// `starts`: whether a retirement may be started here (replica/module.ts `RETIRE_STARTS`); off, POST /retire is refused
/// in words and writes nothing, the rest answering as before.
export const routes = ({
  copies,
  retire,
  starts,
  config,
  changed,
}: {
  copies: Copies;
  retire: Retire;
  starts: boolean;
  config?: Pick<ConfigFile, "raw" | "updateSoon">;
  changed?: () => void;
}): Route[] => [
  // This station retired from the asker's workspace: its chats there go on on `to` (replica/retire.ts). The
  // workspace's owners and admins; GET /retire/preview says what it would move; DELETE calls it off (refused, in words, where it cannot be), POST /retire/again tries
  // a step that failed again now: resting at `sent` after a hand-over failed, the hand-over itself (its chats pause
  // again: the person asked it). One started here goes on from `sent` by itself (the panel said the chats would
  // pause); one an agent asked for (station_retire) waits there for its card.
  {
    method: "POST",
    pattern: /^\/retire$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins retire a station");
      if (!starts) return error(409, tr(r.lang, "station.retire.off"));
      const b = body(r);
      if (typeof b?.to !== "string") return error(400, "to is needed: the station the chats go to");
      try {
        await retire.retire(r.viewer.workspace, b.to, r.viewer.email);
      } catch (e) {
        return error(e instanceof Refused ? 409 : 500, (e as Error).message);
      }
      return json(202, JSON.stringify({ retiring: true }));
    },
  },
  // What retiring this station from the asker's workspace would move, shown before a person retires it.
  {
    method: "GET",
    pattern: /^\/retire\/preview$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins retire a station");
      try {
        return json(200, JSON.stringify(await retire.preview(r.viewer.workspace)));
      } catch (e) {
        return error(500, (e as Error).message);
      }
    },
  },
  {
    method: "DELETE",
    pattern: /^\/retire$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins retire a station");
      try {
        await retire.cancel(r.viewer.workspace);
      } catch (e) {
        return error(e instanceof Refused ? 409 : 500, (e as Error).message);
      }
      return json(200, JSON.stringify({ ok: true }));
    },
  },
  {
    method: "POST",
    pattern: /^\/retire\/again$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins retire a station");
      try {
        await retire.again(r.viewer.workspace);
      } catch (e) {
        return error(e instanceof Refused ? 409 : 500, (e as Error).message);
      }
      return json(202, JSON.stringify({ ok: true }));
    },
  },
  {
    method: "GET",
    pattern: /^\/copies\/history$/,
    handle: async (r: Request) => {
      const rawLimit = param(r, "limit");
      const parsed = rawLimit !== undefined && rawLimit !== "" ? Number.parseInt(rawLimit, 10) : 30;
      const limit = Number.isFinite(parsed) ? Math.max(1, Math.min(50, parsed)) : 30;
      return json(200, JSON.stringify({ records: copies.history(r.viewer.workspace, limit) }));
    },
  },
  {
    method: "GET",
    pattern: /^\/copies\/settings$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins manage backup settings");
      return json(200, JSON.stringify(copies.backupView(r.viewer.workspace)));
    },
  },
  {
    method: "PUT",
    pattern: /^\/copies\/settings$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins manage backup settings");
      if (config === undefined) return error(500, "config is not available");
      const b = body(r);
      if (b === null || typeof b !== "object" || Array.isArray(b)) return error(400, "invalid JSON");
      let updated: ReturnType<typeof applyBackupUpdate>;
      try {
        updated = applyBackupUpdate(config.raw(), b);
      } catch (e) {
        return error(400, (e as Error).message);
      }
      try {
        await config.updateSoon((raw) => {
          raw.backup = updated.backup;
        });
      } catch (e) {
        return error(400, (e as Error).message);
      }
      copies.configChanged();
      changed?.();
      const view = copies.backupView(r.viewer.workspace);
      return json(200, JSON.stringify({ ...view, generatedKeys: updated.generatedKeys }));
    },
  },
  {
    method: "POST",
    pattern: /^\/copies\/s3\/test$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins test backup targets");
      const b = body(r);
      if (b === null || typeof b !== "object" || Array.isArray(b)) return error(400, "invalid JSON");
      const saved = config === undefined ? [] : readBackupConfig(config.raw()).s3;
      const prev = typeof b.id === "string" && b.id !== "" ? saved.find((t) => t.id === b.id) : undefined;
      let target;
      try {
        target = normalizeS3Target(
          {
            id: typeof b.id === "string" && b.id !== "" ? b.id : "test",
            name: typeof b.name === "string" && b.name.trim() !== "" ? b.name : (prev?.name ?? "test"),
            endpoint: b.endpoint ?? prev?.endpoint,
            region: b.region ?? prev?.region,
            bucket: b.bucket ?? prev?.bucket,
            prefix: b.prefix ?? prev?.prefix,
            forcePathStyle: b.forcePathStyle ?? prev?.forcePathStyle,
            accessKeyId: typeof b.accessKeyId === "string" && b.accessKeyId.trim() !== "" ? b.accessKeyId.trim() : prev?.accessKeyId,
            secretAccessKey: typeof b.secretAccessKey === "string" && b.secretAccessKey !== "" ? b.secretAccessKey : prev?.secretAccessKey,
            // encryptionKey is not needed to test S3 connectivity; use a valid dummy 64-hex if absent.
            encryptionKey: typeof b.encryptionKey === "string" && b.encryptionKey !== "" ? b.encryptionKey : (prev?.encryptionKey ?? "0".repeat(64)),
            includeTranscripts: b.includeTranscripts ?? prev?.includeTranscripts,
          },
          0,
        );
      } catch (e) {
        return error(400, (e as Error).message);
      }
      try {
        await new S3Client(target).testConnection();
        return json(200, JSON.stringify({ ok: true }));
      } catch (e) {
        return json(200, JSON.stringify({ ok: false, error: (e as Error).message }));
      }
    },
  },
  {
    method: "POST",
    pattern: /^\/copies\/restore$/,
    handle: async (r: Request) => {
      if (!managesStation(r.viewer)) return error(403, "only the workspace's owners and admins restore a lost station's chats");
      const b = body(r);
      const from = b?.from;
      let restoreFrom: RestoreFrom | null = null;
      if (typeof from?.station === "string" && from.station !== "") restoreFrom = { station: from.station };
      else if (typeof from?.s3 === "string" && from.s3 !== "") restoreFrom = { s3: from.s3 };
      if (typeof b?.station !== "string" || typeof b?.gen !== "string" || restoreFrom === null) {
        return error(400, "station, gen and from: {station} or {s3} are needed");
      }
      try {
        // (it goes on as the copy is brought; how far it is, the station's settings show)
        copies.restore(r.viewer.workspace, b.station, b.gen, restoreFrom).catch(() => {});
      } catch (e) {
        return error(409, (e as Error).message);
      }
      return json(202, JSON.stringify({ restoring: true }));
    },
  },
];
