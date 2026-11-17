// The group connects on the station (an IM community of AFK-surf/group, `im/2`, joined as a member): kept as every platform's are
// (connects/connects.ts: connected as config.json and the station's workspace say, what the server calls people and
// conversations in <data>/group-names.json), with what each heard of its server in <data>/group-threads.json.
//
// A connect's part of config.json (`group`): the server's endpoint id and relays; its key (32 bytes, hex: the device it
// is on the server, made as it is added, carried with its entry wherever the connect goes, as Slack's token is); the
// code it joins by until it has (taken out once the server let it in, its hash kept as `bound`, so that the link is not
// made again for it); the name it asks to be known by; and, as the server last said, who it is there (`memberId`,
// `name`).
import { createHash, createPrivateKey, createPublicKey } from "node:crypto";
import { join } from "node:path";
import type { Clock } from "effect";
import type { Connection } from "../connects/connections.ts";
import { type ConnectsOptions, makeConnects } from "../connects/connects.ts";
import { NAMES_FILE } from "../connects/keys.ts";
import type { NameBook } from "../connects/names.ts";
import type { Endpoints } from "../mesh/endpoint.ts";
import { loadMesh } from "../mesh/native.ts";
import { GroupSurface } from "./surface.ts";
import { GroupThreads } from "./threads.ts";

type Json = any;

export type GroupConnect = {
  id: string;
  enabled: boolean;
  server: string;
  relays: string[];
  key: string;
  code: string | null;
  bound: string | null;
  botName: string | null;
  memberId: string | null;
  name: string | null;
  workspace?: string | null;
};

const nonEmpty = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);

/// A code as it is compared: its letters, without hyphens or spaces, in capitals (the server's `hashOf`).
export const codeHash = (code: string) => createHash("sha256").update(code.toUpperCase().replace(/[\s-]/g, "")).digest("hex");

export function groupConnects(raw: Json): GroupConnect[] {
  return (Array.isArray(raw?.connects) ? raw.connects : [])
    .filter((c: Json) => c?.kind === "group")
    .map((c: Json): GroupConnect => {
      const g = c?.group ?? {};
      return {
        id: String(c?.id ?? ""),
        enabled: c?.enabled !== false,
        server: typeof g.server === "string" ? g.server.trim().toLowerCase() : "",
        relays: Array.isArray(g.relays) ? g.relays.filter((r: unknown): r is string => typeof r === "string" && r.trim() !== "").map((r: string) => r.trim()) : [],
        key: typeof g.key === "string" ? g.key : "",
        code: nonEmpty(g.code),
        bound: nonEmpty(g.bound),
        botName: nonEmpty(g.botName),
        memberId: nonEmpty(g.memberId),
        name: nonEmpty(g.name),
        workspace: nonEmpty(c?.workspace),
      };
    });
}

/// The endpoint id of a key (hex): its Ed25519 public half, as iroh says it.
export function deviceOf(key: string): string | null {
  if (!/^[0-9a-f]{64}$/.test(key)) return null;
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(key, "hex")]);
  return createPublicKey(createPrivateKey({ key: der, format: "der", type: "pkcs8" })).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
}

export type GroupOptions = ConnectsOptions & {
  clock?: Clock.Clock;
  /// What binds the connects' endpoints (tests: a mesh in memory); default the station's mesh addon.
  endpoints?: () => Endpoints;
  /// How a connect's connection is made (tests); default a GroupSurface.
  create?: (connect: GroupConnect, book: NameBook, threads: GroupThreads) => Connection;
};

export type GroupParts = ReturnType<typeof makeGroup>;

export function makeGroup(options: GroupOptions) {
  const threads = new GroupThreads(join(options.data, "group-threads.json"));
  const endpoints = options.endpoints ?? loadMesh;
  const create =
    options.create ??
    ((c: GroupConnect, book: NameBook, t: GroupThreads) =>
      new GroupSurface({ connect: c.id, server: c.server, relays: c.relays, key: c.key, code: c.code, botName: c.botName, threads: t, book, endpoints: endpoints(), clock: options.clock }));
  const connects = makeConnects<GroupConnect>(options, {
    kind: "group",
    names: NAMES_FILE.group,
    connects: groupConnects,
    // A code taken out once it was used (its hash kept as `bound`) connects nothing again; a new one does.
    credentials: (c) => (c.server === "" || c.key === "" || c.relays.length === 0 || (c.code === null && c.bound === null && c.memberId === null) ? null : `${c.server}\n${c.relays.join(" ")}\n${c.key}\n${c.code !== null ? codeHash(c.code) : (c.bound ?? "")}`),
    create: (c, book) => create(c, book, threads),
    // Who it is on the server, and its code gone once it was let in.
    seen: (c, i) => {
      if (c.memberId === i.botUserId && c.name === i.botName && c.code === null) return null;
      // (let in as another member than before: what it heard of the conversations was the other's)
      if (c.memberId !== null && c.memberId !== i.botUserId) threads.drop(c.id);
      return (entry) => {
        entry.group = entry.group !== null && typeof entry.group === "object" ? entry.group : {};
        entry.group.memberId = i.botUserId;
        entry.group.name = i.botName;
        if (typeof entry.group.code === "string" && entry.group.code !== "") {
          entry.group.bound = codeHash(entry.group.code);
          delete entry.group.code;
        }
      };
    },
  });

  return {
    ...connects,
    threads,
    /// Stops as every platform's connects do, what they heard on the disk once it is.
    close: async () => {
      await connects.close();
      await threads.flushed();
    },
    /// What the overview says of a group connect besides what all connects say (its key never).
    shown: (raw: Json): Record<string, unknown> => {
      const [c] = groupConnects({ connects: [raw] });
      const live = connects.chat(String(raw?.id ?? ""))?.identity();
      return {
        name: c?.name ?? live?.botName ?? c?.botName ?? raw?.id,
        team: null,
        botImage: null,
        group: {
          server: c?.server ?? "",
          relays: c?.relays ?? [],
          botName: c?.botName ?? null,
          memberId: c?.memberId ?? null,
          device: c === undefined ? null : deviceOf(c.key),
          // Whether it waits to join by a code (one given and not used yet).
          joining: c?.code !== null && c?.code !== undefined,
        },
      };
    },
  };
}
