// Run by spawn-emfile.test.ts in a process of its own, its file descriptors limited (`ulimit -n`): every one taken, so
// that `spawn` fails with EMFILE as it did on a station out of them (D80), its ChildProcess with no pid and no streams,
// its error told on the next tick. Says on stdout, as one line of JSON, what each start did; the parent judges it.
import { closeSync, mkdtempSync, openSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const uncaught: string[] = [];
process.on("uncaughtException", (error) => void uncaught.push(String((error as Error)?.stack ?? error)));
process.on("unhandledRejection", (error) => void uncaught.push(`unhandled rejection: ${String((error as Error)?.stack ?? error)}`));

// (all loaded before the descriptors are taken)
const { MbProcess, setMbReaderBinaryOverrideForTest } = await import("../../src/read/mb-reader.ts");
const { runRepoGit } = await import("../../src/ops/repo-branches.ts");
const { runGit } = await import("../../src/sessions/clones.ts");
const { SessionsProgram } = await import("../../src/agents/mb-program.ts");

const dir = mkdtempSync(join(tmpdir(), "emfile-"));
const held: number[] = [];
/// Takes every descriptor left; says whether the last open failed with EMFILE.
function exhaust(): boolean {
  try {
    for (;;) held.push(openSync("/dev/null", "r"));
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EMFILE";
  }
}
function release() {
  while (held.length > 0) closeSync(held.pop()!);
}
const tick = () => new Promise<void>((resolve) => setImmediate(resolve));
const thrown = (error: unknown) => `${(error as Error)?.name}: ${(error as Error)?.message}`;

const out: Record<string, unknown> = {};

// 1. MbProcess: built and posted to as its spawn fails, its error and end told.
{
  const errors: string[] = [];
  let threw: string | null = null;
  let exited: number | null = null;
  let p: InstanceType<typeof MbProcess> | null = null;
  const emfile = exhaust();
  try {
    p = new MbProcess(process.execPath, ["-e", ""], { background: false });
    p.postMessage({ asked: 1 });
    p.postLine("{}");
  } catch (error) {
    threw = thrown(error);
  }
  release();
  if (p !== null) {
    const proc = p;
    proc.on("error", (error: NodeJS.ErrnoException) => void errors.push(error.code ?? "?"));
    await new Promise<void>((resolve) => proc.once("exit", (code: number) => ((exited = code), resolve())));
    // (terminated and killed after: nothing thrown)
    try {
      proc.kill();
      await proc.terminate();
    } catch (error) {
      threw = thrown(error);
    }
  }
  await tick();
  out.mbProcess = { emfile, threw, errors, exited, live: MbProcess.live().length };
}

// 2. runRepoGit: an answer, not ok.
{
  let threw: string | null = null;
  let answer: unknown = null;
  const emfile = exhaust();
  let asked: Promise<unknown> | null = null;
  try {
    asked = runRepoGit(dir, ["status"]);
  } catch (error) {
    threw = thrown(error);
  }
  release();
  try {
    answer = await asked;
  } catch (error) {
    threw = thrown(error);
  }
  await tick();
  out.runRepoGit = { emfile, threw, answer };
}

// 3. runGit: an answer, not ok.
{
  let threw: string | null = null;
  let answer: { ok: boolean; stderr: string } | null = null;
  const emfile = exhaust();
  let run: ReturnType<typeof runGit> | null = null;
  try {
    run = runGit(["--version"], process.env);
  } catch (error) {
    threw = thrown(error);
  }
  release();
  try {
    answer = run === null ? null : await run.done;
  } catch (error) {
    threw = thrown(error);
  }
  await tick();
  out.runGit = { emfile, threw, ok: answer?.ok ?? null, said: answer?.stderr.includes("EMFILE") ?? null };
}

// 4. SessionsProgram: its program not started, its users told it ended.
{
  setMbReaderBinaryOverrideForTest(() => process.execPath);
  let threw: string | null = null;
  let exited: number | null = null;
  const emfile = exhaust();
  let program: ReturnType<typeof SessionsProgram.of> = null;
  const ended = new Promise<void>((resolve) => {
    try {
      program = SessionsProgram.of(join(dir, "data"));
      program?.use({ actors: true, said: () => {}, exited: (code) => ((exited = code), resolve()) });
      program?.post({ asked: 1 });
    } catch (error) {
      threw = thrown(error);
      resolve();
    }
  });
  release();
  if (program !== null) await ended;
  await tick();
  out.sessionsProgram = { emfile, threw, started: program !== null, exited, ended: (program as { ended?: boolean } | null)?.ended ?? null };
  setMbReaderBinaryOverrideForTest(undefined);
}

out.uncaught = uncaught;
process.stdout.write(`${JSON.stringify(out)}\n`);
