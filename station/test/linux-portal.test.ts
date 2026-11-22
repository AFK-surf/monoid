import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { LinuxDesktop } from "../src/screens/linux-desktop.ts";
import { LinuxInput } from "../src/screens/linux-input.ts";
import { LinuxNativeDesktop, type LinuxNativeStart } from "../src/screens/linux-native.ts";
import { LinuxGstDesktop } from "../src/screens/linux-portal.ts";
import { ScreenRefused, accessShown } from "../src/screens/hub.ts";
import { desktopEnvironment, graphicalSession } from "../src/screens/linux-session.ts";

const python = "/usr/bin/python3";
const options = { maxWidth: 400, maxHeight: 300, codecs: ["jpeg" as const] };

test("Linux component failures offer setup help, while a pending consent does not", () => {
  for (const reason of ["linuxNoDisplay", "linuxTools", "linuxToolsFailed", "linuxUnavailable", "linuxPortalUnavailable", "linuxX11FallbackUnavailable"] as const) {
    assert.equal(accessShown({ capture: false, control: false, reason }, "en")?.help, "linux-desktop");
  }
  assert.equal(accessShown({ capture: false, control: false, reason: "linuxPortalConsent", asking: true }, "en")?.help, undefined);
});

// A portal process without a graphical session: it speaks the same framed protocol and records the commands it gets.
// The real portal and PipeWire are also exercised on a disposable GNOME session in the integration check.
const fixture = `
import json, os, struct, sys, time
if os.environ.get("SF_TEST_PORTAL_PIDS"):
    with open(os.environ["SF_TEST_PORTAL_PIDS"], "a") as out: out.write(f"{os.getpid()}\\n")
def send(kind, data):
    if isinstance(data, dict): data = json.dumps(data).encode()
    sys.stdout.buffer.write(struct.pack(">BI", kind, len(data)) + data)
    sys.stdout.buffer.flush()
send(1, {"type": "consent"})
while not os.path.exists(os.environ["SF_TEST_PORTAL_GO"]): time.sleep(0.01)
if os.environ.get("SF_TEST_PORTAL_FAIL"):
    send(1, {"type": "error", "message": "cancelled"})
    sys.exit(1)
send(1, {"type": "ready", "width": 800, "height": 600})
for line in sys.stdin:
    item = json.loads(line)
    with open(os.environ["SF_TEST_PORTAL_LOG"], "a") as out: out.write(json.dumps(item) + "\\n")
    if item.get("op") == "start":
        send(1, {"type": "picture", "width": 400, "height": 300})
        send(2, b"\\xff\\xd8A\\xff\\xd9")
    elif item.get("op") == "input" and os.environ.get("SF_TEST_INPUT_ERROR"):
        send(1, {"type": "input_error", "code": "textUnsupported"})
`;

test("a desktop portal asks once, keeps the pending grant, and carries frames and ordered input", { skip: !existsSync(python), timeout: 15_000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-portal-"));
  const helper = join(dir, "helper.py"), log = join(dir, "input.jsonl"), go = join(dir, "go");
  await writeFile(helper, fixture);
  const desktop = new LinuxGstDesktop({ python, helper, env: { ...process.env, SF_TEST_PORTAL_LOG: log, SF_TEST_PORTAL_GO: go }, consentWaitMs: 20, changed: () => {} });
  t.after(async () => { await desktop.close(); await rm(dir, { recursive: true, force: true }); });
  await desktop.refresh();
  assert.equal(desktop.access().capture, true);
  await assert.rejects(desktop.open(options), (error: unknown) => error instanceof ScreenRefused && error.key === "station.screen.linuxPortalConsent");
  assert.equal(desktop.access().reason, "linuxPortalConsent");
  await writeFile(go, "allow");
  for (let attempt = 0; attempt < 250 && desktop.access().reason; attempt++) await sleep(20);
  assert.deepEqual(desktop.size(), { width: 800, height: 600 });
  const view = await desktop.open(options);
  const frame = await view.next();
  assert.ok(frame);
  assert.deepEqual(frame.config, { codec: "jpeg", width: 400, height: 300 });
  assert.deepEqual([...frame.data], [255, 216, 65, 255, 217]);
  view.keyframe();
  const repeated = await view.next();
  assert.ok(repeated);
  assert.deepEqual(repeated.config, frame.config);
  assert.ok(repeated.ts > frame.ts);
  await Promise.all([
    view.input({ t: "pointer", kind: "move", x: 0.25, y: 0.5, buttons: 0 }),
    view.input({ t: "key", kind: "down", key: "a", code: "KeyA", mods: 2 }),
    view.input({ t: "key", kind: "up", key: "a", code: "KeyA", mods: 0 }),
  ]);
  let commands: any[] = [];
  for (let attempt = 0; attempt < 60; attempt++) {
    try { commands = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line)); } catch {}
    if (commands.length >= 6) break;
    await sleep(20);
  }
  assert.equal(commands[0].op, "start");
  assert.equal(commands[1].event.t, "pointer");
  assert.deepEqual(commands.slice(2).map((command) => [command.event.keycode, command.event.kind]), [[29, "down"], [30, "down"], [29, "up"], [30, "up"]]);
  view.close();
  assert.equal(await view.next(), null);
});

test("a refused desktop portal reports a retryable failure", { skip: !existsSync(python), timeout: 10_000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-portal-fail-"));
  const helper = join(dir, "helper.py"), go = join(dir, "go");
  await Promise.all([writeFile(helper, fixture), writeFile(go, "allow")]);
  const desktop = new LinuxGstDesktop({ python, helper, env: { ...process.env, SF_TEST_PORTAL_FAIL: "1", SF_TEST_PORTAL_GO: go }, consentWaitMs: 5_000, changed: () => {} });
  t.after(async () => { await desktop.close(); await rm(dir, { recursive: true, force: true }); });
  await assert.rejects(desktop.open(options), (error: unknown) => error instanceof ScreenRefused && error.key === "station.screen.linuxPortalUnavailable");
  assert.equal(desktop.access().reason, "linuxPortalUnavailable");
});

test("simultaneous portal openings prepare separate sessions", { skip: !existsSync(python), timeout: 10_000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-portal-views-"));
  const helper = join(dir, "helper.py"), go = join(dir, "go"), log = join(dir, "input.jsonl"), pids = join(dir, "pids");
  await Promise.all([writeFile(helper, fixture), writeFile(go, "allow")]);
  const desktop = new LinuxGstDesktop({ python, helper, env: { ...process.env, SF_TEST_PORTAL_GO: go, SF_TEST_PORTAL_LOG: log, SF_TEST_PORTAL_PIDS: pids }, consentWaitMs: 5_000, changed: () => {} });
  t.after(async () => { await desktop.close(); await rm(dir, { recursive: true, force: true }); });
  const [first, second] = await Promise.all([desktop.open(options), desktop.open(options)]);
  assert.notEqual(first, second);
  assert.deepEqual((await first.next())?.config, { codec: "jpeg", width: 400, height: 300 });
  assert.deepEqual((await second.next())?.config, { codec: "jpeg", width: 400, height: 300 });
  first.close();
  second.close();
  // The closed helpers still write their last commands; the desktop's close waits until both have exited.
  await desktop.close();
  const started = (await readFile(pids, "utf8")).trim().split("\n").map(Number);
  assert.equal(started.length, 2);
  for (const pid of started) assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
});

test("unsupported composed text ends the view with an actionable error", { skip: !existsSync(python), timeout: 10_000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-portal-text-"));
  const helper = join(dir, "helper.py"), go = join(dir, "go"), log = join(dir, "input.jsonl");
  await Promise.all([writeFile(helper, fixture), writeFile(go, "allow")]);
  const desktop = new LinuxGstDesktop({ python, helper, env: { ...process.env, SF_TEST_INPUT_ERROR: "1", SF_TEST_PORTAL_GO: go, SF_TEST_PORTAL_LOG: log }, consentWaitMs: 5_000, changed: () => {} });
  t.after(async () => { await desktop.close(); await rm(dir, { recursive: true, force: true }); });
  const view = await desktop.open(options);
  assert.ok(await view.next());
  const waiting = view.next();
  await view.input({ t: "text", text: "你好" });
  await assert.rejects(waiting, (error: unknown) => error instanceof ScreenRefused && error.key === "station.screen.linuxTextUnsupported");
});

test("logind discovery accepts only the station user's graphical sessions", () => {
  const info = "User=1000\nType=wayland\nClass=user\nActive=yes\nRemote=no\nDisplay=\n";
  assert.deepEqual(graphicalSession("7", 1000, info), { id: "7", uid: 1000, type: "wayland", active: true, remote: false, display: undefined });
  assert.equal(graphicalSession("7", 1001, info), null);
  assert.equal(graphicalSession("7", 1000, info.replace("Class=user", "Class=greeter")), null);
  assert.equal(graphicalSession("7", 1000, info.replace("Type=wayland", "Type=tty")), null);
});

test("a station started outside the desktop uses the active session's environment", { skip: !process.getuid }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-session-env-"));
  t.after(async () => { await rm(dir, { recursive: true, force: true }); });
  const uid = process.getuid!();
  const loginctl = join(dir, "loginctl"), systemctl = join(dir, "systemctl");
  const session = async (type: string, display: string) => writeFile(loginctl, `#!/bin/sh\nif [ "$1" = list-sessions ]; then\n  printf '7 ${uid} test seat0 tty2\\n'\nelse\n  printf 'User=${uid}\\nType=${type}\\nClass=user\\nActive=yes\\nRemote=no\\nDisplay=${display}\\n'\nfi\n`, { mode: 0o755 });
  const base = { ...process.env, PATH: dir, HOME: dir, DISPLAY: ":old", XAUTHORITY: "/stale-auth", WAYLAND_DISPLAY: "wayland-old" };
  await Promise.all([session("wayland", ""), writeFile(systemctl, "#!/bin/sh\nprintf 'WAYLAND_DISPLAY=wayland-9\\n'\n", { mode: 0o755 })]);
  const wayland = await desktopEnvironment(base);
  assert.equal(wayland.WAYLAND_DISPLAY, "wayland-9");
  assert.equal(wayland.DISPLAY, undefined);
  assert.equal(wayland.XAUTHORITY, undefined);
  await Promise.all([session("x11", ":9"), writeFile(systemctl, "#!/bin/sh\nprintf 'DISPLAY=:9\\n'\n", { mode: 0o755 })]);
  const x11 = await desktopEnvironment(base);
  assert.equal(x11.DISPLAY, ":9");
  assert.notEqual(x11.XAUTHORITY, "/stale-auth");
  assert.equal(x11.WAYLAND_DISPLAY, undefined);
});

test("the Linux desktop switches between discovered graphical session types", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-desktop-session-"));
  let env: NodeJS.ProcessEnv = { XDG_SESSION_TYPE: "wayland", WAYLAND_DISPLAY: "wayland-0" };
  const desktop = new LinuxDesktop({ data: dir, env: {}, title: () => "test-station", discover: async () => env, changed: () => {} });
  t.after(async () => { await desktop.close(); await rm(dir, { recursive: true, force: true }); });
  assert.equal(desktop.title(), "test-station");
  await desktop.refresh(true);
  assert.equal(desktop.access().capture, true);
  env = { XDG_SESSION_TYPE: "x11" };
  await desktop.refresh(true);
  assert.equal(desktop.access().reason, "linuxNoDisplay");
  env = { XDG_SESSION_TYPE: "x11", DISPLAY: ":65535", PATH: "" };
  await desktop.refresh(true);
  assert.equal(desktop.access().capture, true); // No APT or X11 tools: the GStreamer/XTest fallback is selected.
});

test("LinuxInput translates mouse, relative moves, wheel fractions, evdev keys, modifiers, text, and releases held state", () => {
  const input = new LinuxInput();
  assert.deepEqual(input.ops({ t: "pointer", kind: "move", x: 0.25, y: 0.5, buttons: 0 }), [
    { op: "mouse", type: "move", x: 0.25, y: 0.5, button: 0 },
  ]);
  assert.deepEqual(input.ops({ t: "pointer", kind: "move", x: 0.25, y: 0.5, buttons: 0, dx: 7, dy: -4, relative: true }), [
    { op: "mouse", type: "move", x: 0.25, y: 0.5, button: 0, dx: 7, dy: -4, relative: true },
  ]);
  assert.deepEqual(input.ops({ t: "pointer", kind: "down", x: 0.25, y: 0.5, buttons: 1 }), [
    { op: "mouse", type: "down", x: 0.25, y: 0.5, button: 0 },
  ]);
  // Fractional wheel accumulates until a full notch.
  assert.deepEqual(input.ops({ t: "wheel", x: 0.25, y: 0.5, dx: 0, dy: 60 }), []);
  assert.deepEqual(input.ops({ t: "wheel", x: 0.25, y: 0.5, dx: 0, dy: 60 }), [
    { op: "wheel", x: 0.25, y: 0.5, dx: 0, dy: 1 },
  ]);
  // Ctrl+A wraps with ControlLeft (29) when Control is not already held.
  assert.deepEqual(input.ops({ t: "key", kind: "down", key: "a", code: "KeyA", mods: 2 }), [
    { op: "key", evdev: 29, down: true },
    { op: "key", evdev: 30, down: true },
    { op: "key", evdev: 29, down: false },
  ]);
  assert.deepEqual(input.ops({ t: "key", kind: "down", key: "Control", code: "ControlLeft", mods: 2 }), [
    { op: "key", evdev: 29, down: true },
  ]);
  assert.deepEqual(input.ops({ t: "text", text: "你好" }), [{ op: "text", text: "你好" }]);
  assert.deepEqual(input.release(), [
    { op: "mouse", type: "up", x: 0.25, y: 0.5, button: 0 },
    { op: "key", evdev: 29, down: false },
  ]);
  assert.deepEqual(input.release(), []);
});

test("LinuxNativeDesktop and LinuxDesktop prefer native helper when capture is available and fall back otherwise", async (t) => {
  const frame = (kind: number, payload: Buffer = Buffer.alloc(0)) => {
    const head = Buffer.alloc(5);
    head[0] = kind;
    head.writeUInt32BE(payload.length, 1);
    return Buffer.concat([head, payload]);
  };
  let statusReply: any = { ok: true, backend: "x11", display: { id: 0, width: 1280, height: 720 }, capture: true };
  let receivedEnv: NodeJS.ProcessEnv | null = null;
  const written: Buffer[] = [];
  const fakeStart: LinuxNativeStart = (_binary, args, env) => {
    receivedEnv = env;
    const child = new EventEmitter() as any;
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    child.exitCode = null;
    child.signalCode = null;
    child.kill = () => {
      child.exitCode = 0;
      child.stdout.end();
      child.emit("close", 0, null);
    };
    if (args[0] === "status") {
      queueMicrotask(() => {
        child.stdout.write(JSON.stringify(statusReply) + "\n");
        child.stdout.end();
        child.exitCode = 0;
        child.emit("close", 0, null);
      });
    } else if (args[0] === "view") {
      child.stdin.on("data", (chunk: Buffer) => {
        written.push(chunk);
        if (written.length === 1) {
          child.stdout.write(frame(1, Buffer.from(JSON.stringify({ width: 1280, height: 720, encoder: "OpenH264 (software)", codec: "h264", regions: true }))));
        } else {
          const cfg = Buffer.alloc(12);
          cfg.writeUInt32BE(1280, 0);
          cfg.writeUInt32BE(720, 4);
          cfg[8] = 1;
          const pkt = Buffer.alloc(12);
          pkt[0] = 1;
          pkt.writeBigUInt64BE(1000n, 1);
          pkt[9] = 0x65;
          child.stdout.write(Buffer.concat([frame(2, cfg), frame(3, pkt)]));
        }
      });
    }
    return child;
  };

  const dir = await mkdtemp(join(tmpdir(), "stillfail-native-route-"));
  let env: NodeJS.ProcessEnv = { XDG_SESSION_TYPE: "x11", DISPLAY: ":42" };
  const desktop = new LinuxDesktop({
    data: dir,
    env: {},
    discover: async () => env,
    changed: () => {},
    nativeBinary: "/fake/stillfail-screen-linux",
    nativeStart: fakeStart,
  });
  t.after(async () => { await desktop.close(); await rm(dir, { recursive: true, force: true }); });

  await desktop.refresh(true);
  assert.equal((receivedEnv as NodeJS.ProcessEnv | null)?.DISPLAY, ":42");
  assert.deepEqual(desktop.size(), { width: 1280, height: 720 });
  assert.equal(desktop.access().capture, true);

  const view = await desktop.open({ maxWidth: 1280, maxHeight: 720, codecs: ["h264", "jpeg"], bitrate: 2_000_000 });
  assert.equal(view.regions?.(), true);
  assert.equal(view.video?.().encoder, "OpenH264 (software)");
  const f1 = await view.next();
  assert.ok(f1?.key);
  assert.equal(f1?.config?.codec, "h264");
  assert.equal(f1?.config?.width, 1280);
  view.close();

  // Wayland without wlr-screencopy falls back to LinuxGstDesktop (portal).
  env = { XDG_SESSION_TYPE: "wayland", WAYLAND_DISPLAY: "wayland-0" };
  statusReply = { ok: false, capture: false, unsupported: "waylandNoWlr", error: "no wlr" };
  await desktop.refresh(true);
  assert.equal(desktop.access().capture, true);
  assert.deepEqual(desktop.size(), { width: 0, height: 0 });

  // Direct LinuxNativeDesktop reports unavailable when status says capture: false.
  const nativeOnly = new LinuxNativeDesktop({ binary: "/fake/stillfail-screen-linux", env, changed: () => {}, start: fakeStart });
  await nativeOnly.refresh(true);
  assert.equal(nativeOnly.available(), false);
  assert.equal(nativeOnly.access().reason, "linuxUnavailable");
});
