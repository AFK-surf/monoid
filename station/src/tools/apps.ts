// The agents' hand on their workspace's apps (apps/registry.ts): save a file as an app's new version, list them, read
// an app's versions, make one current again (a rollback), and read and write its documents. How to write an app and
// what its widget can do is skill stillfail-apps (src/skills/stillfail-apps.md). Said in English, as the station's own
// refusals to agents are.
import { readFile, stat, writeFile } from "node:fs/promises";
import { extname, isAbsolute, resolve } from "node:path";
import { AppRefused, type Apps, SOURCE_MOST } from "../apps/registry.ts";
import type { Tool } from "./mcp.ts";

/// The chat a session is: its workspace's id, the directory its files are read from.
export type AppSessions = (session: string) => { ws: string; dir: string } | null;

export const APP_TOOLS = [
  {
    name: "app_save",
    description: "Save a .mbui or .wasm file as a new current version of a station app (made if new). Skill stillfail-apps.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "[a-z0-9-], ≤40" },
        title: { type: "string" },
        file: { type: "string" },
        note: { type: "string", description: "What it changes, one line." },
        base_rev: { type: "integer", description: "The rev you changed." },
        schema: { type: "integer" },
        force: { type: "boolean" },
      },
      required: ["id", "file", "note"],
      additionalProperties: false,
    },
  },
  { name: "app_list", description: "This workspace's station apps.", inputSchema: { type: "object", properties: {}, additionalProperties: false } },
  {
    name: "app_versions",
    description: "A station app's versions and history; rev+to writes that version's file to path to.",
    inputSchema: { type: "object", properties: { id: { type: "string" }, rev: { type: "integer" }, to: { type: "string" } }, required: ["id"], additionalProperties: false },
  },
  {
    name: "app_publish",
    description: "Make a version of a station app current again (rollback).",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" }, rev: { type: "integer" }, note: { type: "string" }, force: { type: "boolean" } },
      required: ["id", "rev"],
      additionalProperties: false,
    },
  },
  {
    name: "app_data",
    description: "Read or write a station app's shared JSON documents.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        op: { enum: ["list", "get", "set", "delete"] },
        collection: { type: "string" },
        doc: { type: "string" },
        data: {},
        base: { type: "integer" },
      },
      required: ["id", "op", "collection"],
      additionalProperties: false,
    },
  },
];

const str = (v: unknown) => (typeof v === "string" ? v : "");
const int = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) ? v : null);

export function appTools(apps: Apps, sessions: AppSessions): Tool[] {
  const chat = (session: string) => {
    const s = sessions(session);
    if (s === null) throw new Error("this session is not a chat of this station's: app tools work from a chat's agent");
    return s;
  };
  const run = async (f: () => unknown | Promise<unknown>): Promise<string> => {
    try {
      return JSON.stringify(await f());
    } catch (e) {
      throw e instanceof AppRefused ? new Error(e.message) : e;
    }
  };
  const [save, list, versions, publish, data] = APP_TOOLS as [any, any, any, any, any];
  return [
    {
      ...save,
      run: (session, a) =>
        run(async () => {
          const { ws, dir } = chat(session);
          const file = str(a.file);
          if (file === "") throw new AppRefused(400, "file is required: the path of the .mbui or .wasm to save");
          const ext = extname(file).toLowerCase();
          if (ext !== ".mbui" && ext !== ".wasm") throw new AppRefused(400, "file must end in .mbui or .wasm: name it so (skill stillfail-apps)");
          const path = isAbsolute(file) ? file : resolve(dir, file);
          let size: number;
          try {
            size = (await stat(path)).size;
          } catch {
            throw new AppRefused(404, `no file at ${path}: write it first (relative paths are of your working directory)`);
          }
          if (size > SOURCE_MOST) throw new AppRefused(413, `the file is over ${SOURCE_MOST} bytes: make the app smaller (move data into its documents)`);
          const source = new Uint8Array(await readFile(path));
          const m = apps.save(ws, {
            id: str(a.id),
            title: typeof a.title === "string" ? a.title : null,
            kind: ext === ".mbui" ? "mbui" : "wasm",
            source,
            note: str(a.note),
            by: session,
            base: int(a.base_rev),
            schema: int(a.schema),
            force: a.force === true,
          });
          return { ...m, link: `[${m.title}](sf-app:${m.id})`, pinned: `sf-app:${m.id}@${m.rev}` };
        }),
    },
    { ...list, run: (session) => run(() => ({ apps: apps.list(chat(session).ws) })) },
    {
      ...versions,
      run: (session, a) =>
        run(async () => {
          const { ws, dir } = chat(session);
          const all = apps.versions(ws, str(a.id));
          const rev = int(a.rev);
          const to = str(a.to);
          if (rev === null && to === "") return all;
          if (rev === null || to === "") throw new AppRefused(400, "give both rev and to: the version to write, and the path to write its file to");
          const v = apps.get(ws, str(a.id), rev);
          const path = isAbsolute(to) ? to : resolve(dir, to);
          await writeFile(path, v.source);
          return { ...all, written: { rev, path, kind: v.kind, size: v.source.length } };
        }),
    },
    {
      ...publish,
      run: (session, a) =>
        run(() => {
          const rev = int(a.rev);
          if (rev === null) throw new AppRefused(400, "rev is required: app_versions lists them");
          return apps.publish(chat(session).ws, { id: str(a.id), rev, by: session, note: typeof a.note === "string" ? a.note : undefined, force: a.force === true });
        }),
    },
    {
      ...data,
      run: (session, a) =>
        run(() => {
          const { ws } = chat(session);
          const id = str(a.id);
          const collection = str(a.collection);
          const doc = str(a.doc);
          const needDoc = () => {
            if (doc === "") throw new AppRefused(400, `doc is required for ${a.op}: the document's id`);
          };
          switch (a.op) {
            case "list":
              return { docs: apps.docs(ws, id, collection) };
            case "get":
              needDoc();
              return { doc: apps.doc(ws, id, collection, doc) };
            case "set":
              needDoc();
              if (!("data" in a)) throw new AppRefused(400, "data is required for set: the document's JSON");
              return apps.putDoc(ws, { app: id, collection, id: doc, data: a.data, by: session, base: int(a.base) });
            case "delete":
              needDoc();
              return apps.deleteDoc(ws, { app: id, collection, id: doc });
            default:
              throw new AppRefused(400, "op: list, get, set or delete");
          }
        }),
    },
  ];
}
