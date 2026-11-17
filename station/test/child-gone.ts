// A test's child process gone before the test file's own process ends (setup-env.mjs names, kills and fails on what is
// still running then: on Linux from /proc, where a process signalled but not yet gone is still there, 2026-11-17).
import type { ChildProcess } from "node:child_process";

/// `child` gone, not only told to go: a harness program ends as its stdin does (`kill`: killed instead), killed where it
/// has not gone a while on, and waited for.
export async function childGone(child: ChildProcess | null | undefined, kill = false): Promise<void> {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  if (kill) child.kill("SIGKILL");
  else child.stdin?.end();
  // timer: a deadline on a child process ending (one that does not end on its input is killed)
  const late = setTimeout(() => child.kill("SIGKILL"), 2000);
  late.unref();
  await gone;
  clearTimeout(late);
}
