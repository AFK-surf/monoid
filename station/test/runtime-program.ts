// The program's reading of a runtime's process (station/mb's reader `--sessions`, mb/src/reader/agents_own.mbt) held to
// the TypeScript station's (test/reference/live.ts) on the same output, through the program itself: the cases of
// runtime-cases.ts written by a process under a real runner, a part at a time, what Node says of the session given
// between the parts as a driver gives it (`begin`, `aborting`, `acpSession`, `acpOpened`, `acpPrompt`, `acpInject`),
// and a crash's reading again of the output it left. What the program holds a while and tells as one (a step's
// deltas, mb agents.mbt DELTAS_MS) is compared joined on both sides; a turn's start and end carry the turn there, which
// is left out.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AgentsHost, HostedProcess, type Heard, type HostedKind } from "../src/agents/mb-agents.ts";
import { AcpReference, CursorReference, DshReference } from "./reference/live.ts";
import { NOW, expand, folded, replayed } from "./runtime-cases.ts";

type Json = any;

/// What writes a case's parts: each part (a file of lines) once a line comes on its stdin, then waits for the next.
const WRITER = `
const fs = require("node:fs");
const parts = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
let next = 0;
let carry = "";
process.stdin.on("data", (d) => {
  carry += d;
  while (carry.includes("\\n")) {
    carry = carry.slice(carry.indexOf("\\n") + 1);
    if (next < parts.length) process.stdout.write(parts[next++]);
  }
});
`;

/// A step's deltas one after another of one field joined, the turn a start and an end carry left out, when a call kept
/// started said alike.
function joined(events: Json[]): Json[] {
  const out: Json[] = [];
  for (const e of events) {
    const { turn: _, ...event } = e;
    // (when a call started is the program's clock's, not the case's)
    if (event.type === "kept" && typeof event.line?.startedAt === "number") event.line = { ...event.line, startedAt: 0 };
    const last = out.at(-1);
    if (event.type === "live" && event.event?.kind === "delta" && last?.type === "live" && last.event?.kind === "delta" && last.event.id === event.event.id && last.event.field === event.event.field && last.event.tokens === undefined && event.event.tokens === undefined) {
      out[out.length - 1] = { type: "live", event: { ...last.event, text: last.event.text + event.event.text } };
    } else out.push(event);
  }
  return out;
}

/// A mark between parts: a line Node reads and nothing else does.
const mark = (kind: HostedKind, n: number) => JSON.stringify(kind === "acp" ? { jsonrpc: "2.0", id: `mark-${n}`, result: {} } : { id: `mark-${n}` });

/// Each session of `cases` (from one `$new` to the next) through the program and through the TypeScript: the events and
/// the lines Node is given, alike.
export async function throughProgram(kind: HostedKind, cases: Json[]) {
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "rp-") : "/tmp/rp-");
  const host = AgentsHost.where(data);
  const owner = {};
  host.use(owner);
  try {
    const sessions: Json[][] = [];
    for (const step of cases) {
      if (step?.$new !== undefined) sessions.push([step]);
      else if (step?.$cut === undefined) sessions.at(-1)!.push(step);
    }
    for (const [n, steps] of sessions.entries()) {
      const flavor = steps[0].$new;
      // The parts the process writes, each ended by a mark, and what Node says before each next part.
      const parts: string[] = [];
      const ops: Json[] = [];
      let part: string[] = [];
      const reference = kind === "dsh" ? new DshReference() : kind === "cursor" ? new CursorReference() : new AcpReference(flavor.flavor, flavor.kept, () => NOW);
      const want: { events: Json[]; lines: string[] } = { events: [], lines: [] };
      const close = () => {
        const m = mark(kind, parts.length);
        part.push(m);
        want.lines.push(m);
        parts.push(part.map((l) => `${l}\n`).join(""));
        part = [];
      };
      for (const raw of steps.slice(1)) {
        const step = expand(raw);
        if (step !== null && typeof step === "object" && Object.keys(step).some((k) => k.startsWith("$"))) {
          close();
          ops.push(step);
          if (step.$prompt !== undefined) want.events.push(...(reference instanceof AcpReference ? reference.prompted(step.$prompt.owner, step.$prompt.text) : reference.prompted()));
          else if (step.$resend !== undefined) want.events.push(...(reference as AcpReference).resent(step.$resend.owner));
          else if (step.$inject !== undefined) want.events.push(...(reference as AcpReference).injected(step.$inject.id, step.$inject.takeOver, step.$inject.text));
          else if (step.$session !== undefined) (reference as AcpReference).session = step.$session;
          else if (step.$opened !== undefined) (reference as AcpReference).opened(step.$opened?.resumed === true);
          else if (step.$aborting !== undefined) reference.turn.aborting = true;
          continue;
        }
        const line = JSON.stringify(step);
        part.push(line);
        const said = reference.line(step);
        want.events.push(...said.events);
        if (said.node) want.lines.push(line);
      }
      close();
      const file = join(data, `parts-${n}.json`);
      writeFileSync(file, JSON.stringify(parts));
      const got: { events: Json[]; lines: string[] } = { events: [], lines: [] };
      /// The marks come, each as the program gives Node its line.
      const marks = new Map<string, () => void>();
      const heard = (h: Heard) => {
        for (const l of h.lines ?? []) {
          got.lines.push(l.text);
          marks.get(l.text)?.();
        }
        got.events.push(...h.events);
      };
      const proc = await HostedProcess.start(host, data, `${kind}-${n}`, process.execPath, ["-e", WRITER, file], process.env as Record<string, string>, data, { label: `${kind} ${n}`, kind, ...(kind === "acp" ? { flavor: flavor.flavor, kept: flavor.kept } : {}), heard, exit: () => {} }, { ...reference.turn });
      try {
        for (let i = 0; i < parts.length; i++) {
          if (i > 0) {
            const op = ops[i - 1];
            if (op.$prompt !== undefined) {
              if (kind === "acp") proc.say("acpPrompt", { owner: op.$prompt.owner, text: op.$prompt.text });
              else proc.tell("begin");
            } else if (op.$resend !== undefined) proc.say("acpPrompt", { owner: op.$resend.owner, resend: true });
            else if (op.$inject !== undefined) proc.say("acpInject", { id: op.$inject.id, takeOver: op.$inject.takeOver, text: op.$inject.text });
            else if (op.$session !== undefined) proc.say("acpSession", { id: op.$session });
            else if (op.$opened !== undefined) proc.say("acpOpened", op.$opened?.resumed === true ? { resumed: true } : {});
            else if (op.$aborting !== undefined) proc.tell("aborting");
          }
          // (the part's mark is the last of it the program tells: all before it has come)
          const come = new Promise<void>((r) => marks.set(mark(kind, i), r));
          proc.write("go");
          await come;
        }
        const at = `${kind} session ${n} (${JSON.stringify(flavor)})`;
        assert.deepEqual(folded(joined(got.events)), folded(joined(want.events)), `${at}: its events`);
        assert.deepEqual(got.lines, want.lines, `${at}: the lines Node reads`);
      } finally {
        await proc.kill(1000);
      }
    }
  } finally {
    await host.close(owner);
    rmSync(data, { recursive: true, force: true });
  }
}

/// What the program reads again of an output a crash left (`replayOwn`), as the TypeScript read it: each case's lines
/// written to a runner's file, read up to `at` (all of it but a line not ended), the first part given back to the disk
/// (zeros, as a runner punches it: process.ts `bytesWithin` skipped them, with the line they cut).
export async function replayedByProgram(kind: HostedKind, cases: Json[][]) {
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "rr-") : "/tmp/rr-");
  const host = AgentsHost.where(data);
  const owner = {};
  host.use(owner);
  try {
    for (const [n, raw] of cases.entries()) {
      const [runtime, ...lines] = kind === "acp" ? raw : [null, ...raw];
      const text = lines.map((l: Json) => `${JSON.stringify(expand(l))}\n`).join("");
      // (a line given back before it, cut where the zeros end; a line not ended after it, past `at`)
      const punched = Buffer.concat([Buffer.alloc(4096), Buffer.from('of a line given back"}\n'), Buffer.from(text), Buffer.from('{"not":"ended"')]);
      const file = join(data, `out-${n}`);
      writeFileSync(file, punched);
      const at = statSync(file).size - Buffer.byteLength('{"not":"ended"');
      const extra = kind === "acp" ? { flavor: runtime[0], kept: runtime[1], resume: runtime[2] } : {};
      const said = await host.replayOwn(kind, file, at, extra);
      const { ownReplayed: _, ...result } = said;
      // (when a call started is the program's clock's, not the case's)
      for (const call of result.live?.calls ?? []) if (typeof call[1]?.startedAt === "number") call[1].startedAt = NOW;
      const [, want] = replayed(kind as "dsh" | "cursor" | "acp", raw);
      assert.deepEqual(folded(result), JSON.parse(want), `${kind} replay ${n}`);
    }
  } finally {
    await host.close(owner);
    rmSync(data, { recursive: true, force: true });
  }
}
