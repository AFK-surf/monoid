// Each attachment owns its copy, even when several files have the same name in one second. Claim the name as it is
// copied, so overlapping posts cannot replace each other's files either.
import { join } from "node:path";
import { cloneFile } from "../ops/clone.ts";
import { iso } from "../read/transcript.ts";

export async function copyAttachment(source: string, dir: string, name: string, now: number): Promise<string> {
  const stamp = iso(now).slice(0, 19).replace(/[:.]/g, "-");
  const safe = Array.from(name)
    .map((c) => (c === "\\" || c === "/" || c.codePointAt(0)! < 0x20 ? "_" : c))
    .join("");
  for (let n = 1; ; n++) {
    const into = join(dir, `${stamp}${n === 1 ? "" : `-${n}`}-${safe}`);
    try {
      await cloneFile(source, into, { excl: true });
      return into;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
  }
}
