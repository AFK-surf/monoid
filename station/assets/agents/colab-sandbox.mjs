// A Colab sandbox's task (station/src/agents/sandbox.ts, kind "colab"): what a job runs in place of its command. It
// takes a Google Colab VM of the sandbox's GPU from the station's pool, runs the task there through sandbox-bridge.mjs
// (its ssh carried by the Colab CLI's ProxyCommand) and hands the VM back, kept warm a while for the chat's next task.
// The pool is a directory of the station's (`pool`, <data>/colab):
//
//   venv/                     the Colab CLI (google-colab-cli), installed there the first time it is needed
//   accounts/<name>/home/     one Google account's sign-in: the CLI's HOME (its token in a file, never a keychain)
//   vms/<vm>.json             the CLI's record of one VM (its endpoint and proxy token)
//   state.json, lock/         the VMs: whose account, which GPU, which chat had it last, who holds it now
//   id_ed25519                the key the station's ssh uses there
//
// Colab never takes a VM back while it runs (its kernel is kept alive), and bills it by the hour: a VM no task holds
// is stopped `KEEP_WARM_MS` after its last one (`reap`, which the station runs: sessions/agents.ts). Measured
// 2026-11-21: an account gets at most 3 VMs of one GPU at a time (a 4th is refused, 412), each GPU counted apart; one
// starts in about 5 s; starting and stopping often is not limited; H100 and A100 answer 503 (Google has none free).
//
//   node colab-sandbox.mjs task '<json>'    {pool, gpu, chat, bridge, run, back?}: run and back are sandbox-bridge.mjs
//                                           host specs without `ssh`; exits with run's code
//   node colab-sandbox.mjs reap '<json>'    {pool}: stop VMs idle past KEEP_WARM_MS, forget those gone from Colab
//   node colab-sandbox.mjs login '<json>'   {pool, account}: sign an account in (the login tool runs it: a link to
//                                           open, then the code Google shows, typed in)
//   node colab-sandbox.mjs status '<json>'  {pool}: each account's balance and use, each VM, as JSON
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

/// The GPUs Colab names, and how many of one an account may hold at once.
export const GPUS = ["T4", "L4", "G4", "A100", "H100"];
export const PER_ACCOUNT = 3;
/// How long a VM no task holds is kept for the next (starting one again and setting it up costs more than this does).
export const KEEP_WARM_MS = 3 * 60_000;
/// An account that refused a VM of a GPU (its limit, or Google has none) is not asked for another this long.
export const REFUSED_MS = 60_000;
/// A task that cannot get a VM waits this long at most, then fails saying so.
export const WAIT_MS = 30 * 60_000;
/// The CLI's version the pool installs.
export const CLI = "google-colab-cli==0.8.0";
const CLI_ENV = { PYTHON_KEYRING_BACKEND: "keyrings.alt.file.PlaintextKeyring", COLAB_CLI_ASSIGN_RETRIES: "0", NO_COLOR: "1" };

const say = (s) => process.stderr.write(`[colab] ${s}\n`);
const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// ── the pool's state ──

export const accountsOf = (pool) => {
  const dir = join(pool, "accounts");
  return existsSync(dir) ? readdirSync(dir).filter((a) => !a.startsWith(".") && existsSync(join(dir, a, "home"))).sort() : [];
};

/// Runs `f` on the pool's state under its lock (a directory: made atomically; one left by a process gone is taken).
export function locked(pool, io, f) {
  mkdirSync(pool, { recursive: true });
  const lock = join(pool, "lock");
  for (;;) {
    try {
      mkdirSync(lock);
      writeFileSync(join(lock, "pid"), String(process.pid));
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let holder = 0;
      try { holder = Number(readFileSync(join(lock, "pid"), "utf8")); } catch {}
      let age = 0;
      try { age = io.now() - statSync(lock).mtimeMs; } catch {}
      if ((holder > 0 && !io.alive(holder)) || age > 60_000) rmSync(lock, { recursive: true, force: true });
      else io.sleep(50);
    }
  }
  try {
    const file = join(pool, "state.json");
    let st = {};
    try { st = JSON.parse(readFileSync(file, "utf8")); } catch {}
    st.vms ??= {};
    st.queue ??= [];
    st.refused ??= {};
    const out = f(st);
    writeFileSync(file + ".tmp", JSON.stringify(st, null, 1));
    renameSync(file + ".tmp", file);
    return out;
  } finally {
    rmSync(lock, { recursive: true, force: true });
  }
}

const vmFile = (pool, vm) => join(pool, "vms", `${vm}.json`);
const holderLive = (v, io) => v.holder != null && io.alive(v.holder);

/// The pool's io: the CLI, the clock, sleeping, whether a process lives. Tests give their own.
export function realIo(pool) {
  return {
    now: () => Date.now(),
    sleep: sleepSync,
    alive: (pid) => {
      try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
    },
    colab: (account, vm, args) => {
      mkdirSync(join(pool, "vms"), { recursive: true });
      const r = spawnSync(join(pool, "venv", "bin", "colab"), ["--config", vm === null ? join(pool, "accounts", account, "probe.json") : vmFile(pool, vm), ...args], {
        env: { ...process.env, ...CLI_ENV, HOME: join(pool, "accounts", account, "home") }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000,
      });
      return { code: r.status ?? 1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
    },
  };
}

/// A VM of `gpu` for `chat`, held by this process: the chat's own when it has one free (what its tasks left there is
/// still there), else any free one of the GPU, else a new one on the account holding fewest, else it waits its turn
/// (first come, first served, for each GPU). Returns the VM's name and account.
export function acquire(pool, gpu, chat, io, waitMs = WAIT_MS) {
  const accounts = accountsOf(pool);
  if (accounts.length === 0) throw new Error(`no Colab account is signed in on this station: sign one in first (station_list says how), then start the task again`);
  const ticket = `${process.pid}-${io.now()}`;
  const deadline = io.now() + waitMs;
  locked(pool, io, (st) => void st.queue.push({ ticket, gpu, pid: process.pid }));
  let told = 0;
  try {
    for (;;) {
      const now = io.now();
      const step = locked(pool, io, (st) => {
        st.queue = st.queue.filter((q) => io.alive(q.pid));
        for (const [k, until] of Object.entries(st.refused)) if (until <= now) delete st.refused[k];
        const waiting = st.queue.filter((q) => q.gpu === gpu);
        const position = waiting.findIndex((q) => q.ticket === ticket);
        if (position > 0) return { wait: position };
        const free = Object.entries(st.vms).filter(([, v]) => v.gpu === gpu && v.state === "ready" && !holderLive(v, io));
        free.sort(([, a], [, b]) => (b.chat === chat) - (a.chat === chat) || b.used - a.used);
        const leave = () => { st.queue = st.queue.filter((q) => q.ticket !== ticket); };
        if (free.length > 0) {
          const [vm, v] = free[0];
          Object.assign(v, { holder: process.pid, chat, used: now });
          leave();
          return { vm, account: v.account, reused: true };
        }
        const held = (a) => Object.values(st.vms).filter((v) => v.gpu === gpu && v.account === a).length;
        const open = accounts.filter((a) => held(a) < PER_ACCOUNT && !st.refused[`${a}:${gpu}`]);
        if (open.length === 0) return { wait: 0 };
        const account = open.reduce((a, b) => (held(b) < held(a) ? b : a));
        const vm = `${gpu.toLowerCase()}-${randomBytes(4).toString("hex")}`;
        st.vms[vm] = { account, gpu, state: "starting", holder: process.pid, chat, used: now, started: now };
        leave();
        return { vm, account, start: true };
      });
      if (step.vm !== undefined && !step.start) {
        say(`reusing VM ${step.vm} (${gpu}, account ${step.account})`);
        return step;
      }
      if (step.start) {
        say(`starting a ${gpu} VM on account ${step.account}`);
        const r = io.colab(step.account, step.vm, ["new", "-s", step.vm, "--gpu", gpu]);
        const ok = r.code === 0 && /READY/.test(r.out);
        const refused = /precondition|\b412\b/i.test(r.out) ? "its limit of VMs" : /Service Unavailable|\b503\b/.test(r.out) ? "no free machine at Google" : null;
        locked(pool, io, (st) => {
          if (ok) st.vms[step.vm].state = "ready";
          else {
            delete st.vms[step.vm];
            st.refused[`${step.account}:${gpu}`] = io.now() + (refused ? REFUSED_MS : 15_000);
            st.queue.unshift({ ticket, gpu, pid: process.pid });
          }
        });
        if (ok) return step;
        say(refused ? `account ${step.account} gave no ${gpu} (${refused})` : `starting a VM failed: ${r.out.trim().slice(-400)}`);
        continue;
      }
      if (io.now() > deadline) throw new Error(`no ${gpu} VM came free in ${Math.round(waitMs / 60_000)} minutes: every account is at its limit or Google has none; start the task again later, or sign in another account`);
      if (io.now() - told > 60_000) {
        say(step.wait > 0 ? `waiting for a ${gpu}: ${step.wait} task(s) ahead` : `waiting for a ${gpu}: every account holds ${PER_ACCOUNT} or was refused one`);
        told = io.now();
      }
      io.sleep(3000);
    }
  } finally {
    locked(pool, io, (st) => { st.queue = st.queue.filter((q) => q.ticket !== ticket); });
  }
}

/// Hands `vm` back: kept warm for KEEP_WARM_MS (reap stops it after).
export function release(pool, vm, io) {
  locked(pool, io, (st) => {
    const v = st.vms[vm];
    if (v && v.holder === process.pid) Object.assign(v, { holder: null, used: io.now() });
  });
}

/// Stops the VMs no live task holds whose last use is KEEP_WARM_MS past (none while a task waits for their GPU), and
/// forgets those Colab no longer has. Returns the names stopped.
export function reap(pool, io) {
  const now = io.now();
  const stop = locked(pool, io, (st) => {
    st.queue = st.queue.filter((q) => io.alive(q.pid));
    const out = [];
    for (const [vm, v] of Object.entries(st.vms)) {
      if (v.state === "starting" && !holderLive(v, io)) { delete st.vms[vm]; continue; }
      if (v.state !== "ready" || holderLive(v, io)) continue;
      if (now - v.used < KEEP_WARM_MS || st.queue.some((q) => q.gpu === v.gpu)) continue;
      v.state = "stopping";
      out.push([vm, v.account]);
    }
    return out;
  });
  for (const [vm, account] of stop) {
    io.colab(account, vm, ["stop", "-s", vm]);
    rmSync(vmFile(pool, vm), { force: true });
    locked(pool, io, (st) => void delete st.vms[vm]);
    say(`stopped VM ${vm} (idle)`);
  }
  // Those Colab took back or a person stopped: its list of the account's VMs no longer names their endpoint.
  for (const account of accountsOf(pool)) {
    const r = io.colab(account, null, ["sessions"]);
    if (r.code !== 0) continue;
    const listed = new Set([...r.out.matchAll(/\]\s+(\S+)\s+\|/g)].map((m) => m[1]));
    locked(pool, io, (st) => {
      for (const [vm, v] of Object.entries(st.vms)) {
        if (v.account !== account || v.state !== "ready" || holderLive(v, io)) continue;
        let endpoint = null;
        try { endpoint = JSON.parse(readFileSync(vmFile(pool, vm), "utf8"))[vm]?.endpoint ?? null; } catch {}
        if (endpoint !== null && !listed.has(endpoint)) {
          delete st.vms[vm];
          rmSync(vmFile(pool, vm), { force: true });
        }
      }
    });
  }
  return stop.map(([vm]) => vm);
}

// ── the CLI and the VM ──

/// The Colab CLI installed in the pool, where it is not yet (Python 3.10 or newer is needed).
function ensureCli(pool) {
  if (existsSync(join(pool, "venv", "bin", "colab"))) return;
  say("installing the Colab CLI (once)");
  mkdirSync(pool, { recursive: true });
  const python = ["python3.13", "python3.12", "python3.11", "python3.10", "python3"].find((p) => spawnSync(p, ["-c", "import sys; sys.exit(sys.version_info < (3, 10))"]).status === 0);
  if (python === undefined) throw new Error("the Colab CLI needs Python 3.10 or newer on this station: install it, then start the task again");
  const run = (cmd, args) => {
    const r = spawnSync(cmd, args, { stdio: ["ignore", "inherit", "inherit"] });
    if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} failed`);
  };
  rmSync(join(pool, "venv"), { recursive: true, force: true });
  run(python, ["-m", "venv", join(pool, "venv")]);
  run(join(pool, "venv", "bin", "pip"), ["install", "-q", CLI, "keyrings.alt"]);
}

function ensureKey(pool) {
  const key = join(pool, "id_ed25519");
  if (!existsSync(key)) spawnSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "stillfail-colab", "-f", key]);
  return key;
}

/// ssh's command line to `vm`, up to the remote command: its connection carried by `colab ssh --proxy-mode`.
export function sshTo(pool, vm, account) {
  const key = join(pool, "id_ed25519");
  const env = Object.entries({ ...CLI_ENV, HOME: join(pool, "accounts", account, "home") }).map(([k, v]) => `${k}=${v}`);
  const proxy = ["env", ...env, join(pool, "venv", "bin", "colab"), "--config", vmFile(pool, vm), "ssh", "--proxy-mode", "-s", vm, "--identity", key]
    .map((w) => `'${w.replace(/'/g, `'\\''`)}'`).join(" ");
  return ["ssh", "-T", "-o", "BatchMode=yes", "-o", `ProxyCommand=${proxy}`, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-i", key, "-o", "IdentitiesOnly=yes", "root@colab-runtime"];
}

/// Node on the VM (the bridge's far side runs on it; Colab's image has none): this Node's version, from nodejs.org.
function ensureNode(ssh) {
  const v = process.version;
  const script = `command -v node >/dev/null || { curl -fsSL https://nodejs.org/dist/${v}/node-${v}-linux-x64.tar.xz | tar xJ -C /usr/local --strip-components=1; }`;
  const r = spawnSync(ssh[0], [...ssh.slice(1), script], { stdio: ["ignore", "inherit", "inherit"] });
  if (r.status !== 0) throw new Error("could not put Node on the VM");
}

const bridged = (bridge, spec) => new Promise((resolve) => {
  const child = spawn(process.execPath, [bridge, "host", JSON.stringify(spec)], { stdio: "inherit" });
  for (const s of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(s, () => child.kill(s));
  child.on("exit", (code, signal) => resolve(code ?? (signal ? 128 : 1)));
});

async function task(o) {
  if (!GPUS.includes(o.gpu)) throw new Error(`no GPU ${o.gpu} at Colab (${GPUS.join(", ")})`);
  ensureCli(o.pool);
  ensureKey(o.pool);
  const io = realIo(o.pool);
  const { vm, account } = acquire(o.pool, o.gpu, o.chat, io);
  try {
    const ssh = sshTo(o.pool, vm, account);
    ensureNode(ssh);
    const code = await bridged(o.bridge, { ...o.run, ssh });
    // What it brings back; once more when its connection failed (seen once on a VM just started: the first
    // connection after the task's own never answered).
    if (o.back && (await bridged(o.bridge, { ...o.back, ssh })) !== 0) {
      say("bringing the results back failed; once more");
      await bridged(o.bridge, { ...o.back, ssh });
    }
    return code;
  } finally {
    release(o.pool, vm, io);
  }
}

async function main() {
  const [what, json] = process.argv.slice(2);
  const o = JSON.parse(json ?? "{}");
  try {
    if (what === "task") process.exit(await task(o));
    if (what === "reap") {
      if (!existsSync(join(o.pool, "venv", "bin", "colab"))) return;
      reap(o.pool, realIo(o.pool));
      return;
    }
    if (what === "login") {
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(o.account ?? "")) throw new Error("name the account with letters, digits, ., _ and -");
      ensureCli(o.pool);
      const home = join(o.pool, "accounts", o.account, "home");
      mkdirSync(home, { recursive: true });
      const r = spawnSync(join(o.pool, "venv", "bin", "colab"), ["--config", join(o.pool, "accounts", o.account, "probe.json"), "usage"], {
        env: { ...process.env, ...CLI_ENV, HOME: home }, stdio: "inherit",
      });
      if (r.status !== 0) rmSync(join(o.pool, "accounts", o.account), { recursive: true, force: true });
      process.exit(r.status ?? 1);
    }
    if (what === "status") {
      const io = realIo(o.pool);
      const accounts = existsSync(join(o.pool, "venv", "bin", "colab"))
        ? accountsOf(o.pool).map((a) => ({ account: a, usage: io.colab(a, null, ["usage"]).out.trim() }))
        : [];
      const vms = locked(o.pool, io, (st) => st.vms);
      process.stdout.write(JSON.stringify({ accounts, vms }, null, 1) + "\n");
      return;
    }
    throw new Error("colab-sandbox.mjs task|reap|login|status '<json>'");
  } catch (e) {
    say(e.message);
    process.exit(1);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) await main();
