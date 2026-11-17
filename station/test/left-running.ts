// The processes still running that carry a test file's mark in their environment (STILLFAIL_TEST_FILE, setup-env.mjs),
// as "<pid> <command>" lines, this process left out. Linux: read from /proc, each process's environ and cmdline, no
// process started (`ps -x` there is BSD's option, which procps refuses outside its personality: it said its usage on
// stderr at every file's end and the check found nothing, 2026-11-17); one of another user's, or gone meanwhile, is
// passed over as ps passed it. macOS: ps, whose -E adds each process's environment to its command.
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";

export function leftRunning(mark: string, { platform = process.platform as string, proc = "/proc", self = process.pid } = {}): string[] {
  const wanted = `STILLFAIL_TEST_FILE=${mark}`;
  if (platform === "linux") {
    const left: string[] = [];
    let pids: string[];
    try {
      pids = readdirSync(proc).filter((p) => /^[0-9]+$/.test(p) && Number(p) !== self);
    } catch {
      return [];
    }
    for (const pid of pids) {
      try {
        if (!readFileSync(`${proc}/${pid}/environ`, "latin1").split("\0").includes(wanted)) continue;
        const command = readFileSync(`${proc}/${pid}/cmdline`, "utf8").replace(/\0+$/, "").replaceAll("\0", " ");
        left.push(`${pid} ${command}`);
      } catch {}
    }
    return left;
  }
  let listed: string;
  try {
    listed = execFileSync("ps", ["-E", "-ww", "-x", "-o", "pid=,command="], { encoding: "utf8", maxBuffer: 64 << 20, env: { ...process.env, STILLFAIL_TEST_FILE: "" } });
  } catch {
    return [];
  }
  return listed.split("\n").filter((l) => l.includes(wanted)).map((l) => l.trim()).filter((l) => Number(l.split(" ")[0]) !== self)
    // (ps -E writes the environment after the command: only the command is said)
    .map((l) => l.replace(/ [A-Za-z_][A-Za-z0-9_]*=.*$/, ""));
}
