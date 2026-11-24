// Real file systems mounted in a room, for the footprint tests (mb-footprint.test.ts, reader-contract-footprint.test.ts):
// a tmpfs on each of `MOUNTS` in a mount namespace of a user namespace's (`unshare -rm`), filled there, then measured
// there by the program (or a candidate reader) and by the reference, with the bytes a measure that stays on the room's
// file system sees. Linux only; on CI there it must be possible (the workflows let user namespaces mount), never skipped.
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { platform } from "../src/platform/index.ts";

/// Where a file system is mounted in the room: one of no name of its own, and one of each name a measure that finds
/// looks into (what is made again, the attachments, a repository's metadata).
export const MOUNTS = ["mnt", "app/node_modules", "uploads", ".git"];

/// Whether a tmpfs can be mounted here in a user namespace (one mounted once, not only the namespace made).
function mountable(): boolean {
  if (platform.os !== "linux") return false;
  const dir = mkdtempSync(join(tmpdir(), "footprint-mountable-"));
  try {
    return spawnSync("unshare", ["-rm", "sh", "-c", 'mount -t tmpfs tmpfs "$0"', dir], { stdio: "ignore" }).status === 0;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const canMount = mountable();
/// On CI's Linux it must mount: failed there, not skipped.
const mustMount = process.env.CI !== undefined && process.env.CI !== "" && platform.os === "linux";

/// Why a test of real mounts is skipped here, or false.
export const noMounts = (): string | false =>
  canMount || mustMount ? false : "mounting a tmpfs in a user namespace (unshare -rm, Linux; kernel.apparmor_restrict_unprivileged_userns=0)";

export type Measured = { bytes: number; rebuild: [string, number][]; complete: boolean; reason?: string };

/// The room `root` with a tmpfs on each of `MOUNTS` (each holding 29 000 bytes of files), measured with what is made
/// again found: by `candidate` (a reader binary asked as footprint.ts asks it) or else the station's own measure
/// (footprint.ts `measureRoom`), by the reference, and `visible`, every entry's blocks but what is in the mounts.
export function measuredMounted(root: string, candidate?: string): { got: Measured; reference: Measured; visible: number } {
  if (!canMount) throw new Error("a tmpfs cannot be mounted in a user namespace here (unshare -rm; on GitHub's Ubuntu, kernel.apparmor_restrict_unprivileged_userns=0)");
  for (const m of MOUNTS) mkdirSync(join(root, m), { recursive: true });
  const url = (p: string) => JSON.stringify(new URL(p, import.meta.url).href);
  const code = `const { MEASURE_ROOM, measureRoom } = await import(${url("../src/sessions/footprint.ts")});
    const { measureRoomReference } = await import(${url("./footprint-reference.ts")});
    const { lstatSync, mkdirSync, readdirSync, writeFileSync } = await import("node:fs");
    const { spawnSync } = await import("node:child_process");
    const { join, normalize, sep } = await import("node:path");
    const root = process.env.FOOTPRINT_ROOT;
    const mounts = ${JSON.stringify(MOUNTS)}.map((m) => join(root, m));
    for (const m of mounts) {
      mkdirSync(join(m, "node_modules/a/b"), { recursive: true });
      writeFileSync(join(m, "node_modules/x.js"), Buffer.alloc(20000, 7));
      writeFileSync(join(m, "node_modules/a/b/c"), Buffer.alloc(9000, 7));
    }
    const blocks = (p) => Number(lstatSync(p, { bigint: true }).blocks) * 512;
    const seen = (p) => blocks(p) + (mounts.includes(p) || !lstatSync(p).isDirectory() ? 0 : readdirSync(p).reduce((n, e) => n + seen(join(p, e)), 0));
    const candidate = process.env.FOOTPRINT_CANDIDATE;
    let got;
    if (candidate) {
      const ask = { path: root, base: normalize(root), finding: true, strict: false, ...MEASURE_ROOM };
      const ran = spawnSync(candidate, ["--builder", "footprint", "--sep", sep], { input: JSON.stringify(ask) + "\\n", encoding: "utf8" });
      const said = JSON.parse(ran.stdout.trim());
      got = { bytes: said.size, rebuild: said.rebuild ?? [], complete: said.complete, ...(said.reason !== undefined ? { reason: said.reason } : {}) };
    } else got = await measureRoom(root);
    writeFileSync(process.env.FOOTPRINT_OUT, JSON.stringify({ got, reference: await measureRoomReference(root), visible: seen(root) }));`;
  const out = join(mkdtempSync(join(tmpdir(), "footprint-mounted-")), "measured.json");
  try {
    const mount = MOUNTS.map((m) => `mount -t tmpfs tmpfs "$FOOTPRINT_ROOT/${m}"`).join(" && ");
    const ran = spawnSync("unshare", ["-rm", "sh", "-c", `${mount} && exec "$0" --import ./test/setup-env.mjs --input-type=module -e "$1"`, process.execPath, code], {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      env: { ...process.env, FOOTPRINT_ROOT: root, FOOTPRINT_OUT: out, FOOTPRINT_CANDIDATE: candidate ?? "" },
      encoding: "utf8",
    });
    if (ran.status !== 0) throw new Error(`the measures in a mount namespace failed (${ran.status}): ${ran.stderr}`);
    return JSON.parse(readFileSync(out, "utf8"));
  } finally {
    rmSync(join(out, ".."), { recursive: true, force: true });
  }
}
