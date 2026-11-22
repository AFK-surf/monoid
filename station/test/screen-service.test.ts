// Optional Windows LocalSystem screen service management (screens/service.ts & service-module.ts):
// overview state, install/uninstall via elevated PowerShell, UAC decline/timeout, already-elevated direct apply,
// and PUT /screen-service authorization and error handling.
import assert from "node:assert/strict";
import type { ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import type { Request } from "../src/api/request.ts";
import { ASK_MS, ScreenService, type ScreenServiceProbe, askScript } from "../src/screens/service.ts";
import { screenServiceRoutes } from "../src/screens/service-module.ts";

function fakeShell() {
  const ran: { script: string; child: ChildProcess & EventEmitter; killed: boolean }[] = [];
  const run = (script: string) => {
    const child = new EventEmitter() as ChildProcess & EventEmitter;
    const one = { script, child, killed: false };
    (child as any).kill = () => ((one.killed = true), true);
    ran.push(one);
    return child;
  };
  return { ran, run };
}

function clock(start = 1_000_000) {
  let now = start;
  const timers: { at: number; f: () => void; off: boolean }[] = [];
  return {
    now: () => now,
    after: (ms: number, f: () => void) => {
      const t = { at: now + ms, f, off: false };
      timers.push(t);
      return () => void (t.off = true);
    },
    pass(ms: number) {
      const end = now + ms;
      while (now < end) {
        const next = timers.filter((t) => !t.off && t.at > now && t.at <= end).sort((a, b) => a.at - b.at)[0];
        now = next?.at ?? end;
        for (const t of timers.filter((t) => !t.off && t.at <= now)) {
          t.off = true;
          t.f();
        }
      }
    },
  };
}

async function setup(initial: Partial<ScreenServiceProbe> = {}) {
  const state: ScreenServiceProbe = {
    installed: false,
    running: false,
    connected: false,
    elevated: false,
    admin: true,
    userSid: "S-1-5-21-100-200-300-1001",
    binary: "C:\\app\\station\\stillfail-screen-svc.exe",
    ...initial,
  };
  const shell = fakeShell();
  const c = clock();
  let changes = 0;
  const s = new ScreenService({
    app: "C:\\app",
    now: c.now,
    after: c.after,
    changed: () => void changes++,
    probe: async () => ({ ...state }),
    run: shell.run,
  });
  await s.start();
  return { s, state, shell, c, changes: () => changes };
}

test("overview reports installed/running state and admin/binary availability", async () => {
  const a = await setup({ installed: true, running: true, connected: true });
  assert.deepEqual(a.s.view(true), { on: true, running: true, canChange: true, available: true, manage: true });

  const nonAdmin = await setup({ admin: false, elevated: false });
  assert.deepEqual(nonAdmin.s.view(true), { on: false, running: false, canChange: false, available: true, manage: true });
  await assert.rejects(nonAdmin.s.change(true), { key: "notAdmin" });
  assert.equal(nonAdmin.shell.ran.length, 0);

  const noBin = await setup({ binary: null });
  assert.deepEqual(noBin.s.view(true), { on: false, running: false, canChange: false, available: false, manage: true });
  await assert.rejects(noBin.s.change(true), { key: "notAvailable" });
});

test("switching on installs elevated via UAC and updates state on completion", async () => {
  const { s, state, shell } = await setup();
  await s.change(true);
  assert.equal(shell.ran.length, 1);
  assert.match(shell.ran[0]!.script, /-Verb RunAs/);
  assert.match(shell.ran[0]!.script, /'install', '--user-sid', 'S-1-5-21-100-200-300-1001'/);
  assert.deepEqual(s.view(true), {
    on: false,
    running: false,
    canChange: true,
    available: true,
    step: "asking",
    want: true,
    manage: true,
  });
  await assert.rejects(s.change(false), { key: "busy" });

  state.installed = true;
  state.running = true;
  state.connected = true;
  shell.ran[0]!.child.emit("exit", 0);
  await s.settled();
  assert.deepEqual(s.view(true), { on: true, running: true, canChange: true, available: true, manage: true });
});

test("UAC declined (exit 4) and timeout (ASK_MS) record failure without changing state", async () => {
  const declined = await setup();
  await declined.s.change(true);
  declined.shell.ran[0]!.child.emit("exit", 4);
  await declined.s.settled();
  assert.deepEqual(declined.s.view(true), {
    on: false,
    running: false,
    canChange: true,
    available: true,
    failed: "declined",
    want: true,
    manage: true,
  });

  const timedOut = await setup();
  await timedOut.s.change(true);
  timedOut.c.pass(ASK_MS);
  await timedOut.s.settled();
  assert.equal(timedOut.shell.ran[0]!.killed, true);
  assert.deepEqual(timedOut.s.view(true), {
    on: false,
    running: false,
    canChange: true,
    available: true,
    failed: "unanswered",
    want: true,
    manage: true,
  });
});

test("already-elevated station applies directly without -Verb RunAs and can uninstall", async () => {
  const { s, state, shell } = await setup({ installed: true, running: true, elevated: true });
  await s.change(false);
  assert.equal(shell.ran.length, 1);
  assert.doesNotMatch(shell.ran[0]!.script, /-Verb RunAs/);
  assert.match(shell.ran[0]!.script, /@\(\s*'uninstall'\s*\)/);
  assert.equal(s.view(true).step, "applying");

  state.installed = false;
  state.running = false;
  shell.ran[0]!.child.emit("exit", 0);
  await s.settled();
  assert.deepEqual(s.view(true), { on: false, running: false, canChange: true, available: true, manage: true });
});

test("askScript escapes single quotes and handles ERROR_CANCELLED", () => {
  const script = askScript("C:\\O'Brien\\stillfail-screen-svc.exe", true, "S-1-5-21-1-2-3-1001", true);
  assert.match(script, /C:\\O''Brien\\stillfail-screen-svc\.exe/);
  assert.match(script, /NativeErrorCode -eq 1223\) \{ exit 4 \}/);
});

test("PUT /screen-service requires station manager role and validates payload", async () => {
  const { s } = await setup();
  const [route] = screenServiceRoutes(s);
  const ask = (role: string, body: string) =>
    route!.handle(
      {
        method: "PUT",
        path: "/screen-service",
        query: [],
        headers: {},
        lang: "en",
        body: Buffer.from(body),
        viewer: { via: "mesh", role, email: "u@example.com" },
      } as unknown as Request,
      [] as unknown as RegExpExecArray,
    );

  assert.equal((await ask("member", '{"on":true}')).status, 403);
  assert.equal((await ask("owner", "{")).status, 400);
  assert.equal((await ask("owner", '{"on":"yes"}')).status, 400);

  const ok = await ask("owner", '{"on":true}');
  assert.equal(ok.status, 200);
  assert.equal(JSON.parse(String(ok.body)).step, "asking");

  const busy = await ask("admin", '{"on":false}');
  assert.equal(busy.status, 409);
  await s.stop();
});

test("non-zero installer exit or post-install mismatch records error failure", async () => {
  const failed = await setup();
  await failed.s.change(true);
  failed.shell.ran[0]!.child.emit("exit", 1);
  await failed.s.settled();
  assert.equal(failed.s.view(true).failed, "error");
  assert.equal(failed.s.view(true).on, false);

  const mismatch = await setup();
  await mismatch.s.change(true);
  // Exit 0 without actually installing leaves state false and records error.
  mismatch.shell.ran[0]!.child.emit("exit", 0);
  await mismatch.s.settled();
  assert.equal(mismatch.s.view(true).failed, "error");
  assert.equal(mismatch.s.view(true).on, false);
});
