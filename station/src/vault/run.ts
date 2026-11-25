// A command run with a grant (secret_run 三种用法): through the proxy, with the grant's SSH key in an
// agent, with the secret in its environment, or with a file kept in the vault written out for it. The station runs it, in the session's workspace, and gives back what it
// said with the secret hidden (scrub.ts) and cut to a size an agent reads, and how it ended.
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { endCommand, startCommand } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";
import { type Held, accountOf, valueOf } from "./keeper.ts";
import { type Proxy, placeholder } from "./proxy.ts";
import { Scrubber, scrub } from "./scrub.ts";
import { parseSshKey, serveAgent } from "./ssh-agent.ts";

/// What of a command's output an agent is given: its start and its end, this much of each.
const HEAD = 4 * 1024;
const TAIL = 28 * 1024;

export type RunAsk = { command: string; cwd: string; env?: string; timeoutMs: number };
export type Ran = { code: number | null; signal: string | null; output: string; cut: boolean; timedOut: boolean; used?: boolean };

/// The variable every run has the secret (or its placeholder) in, besides the one the item or the agent names.
export const SECRET_VAR = "STILLFAIL_SECRET";
/// The variable every run of a login's grant has its account in (not secret, so not hidden in the output).
export const ACCOUNT_VAR = "STILLFAIL_USERNAME";

/// Output kept as it comes: all of it while short, then its first HEAD bytes and its last TAIL.
class Kept {
  head = Buffer.alloc(0);
  tail = Buffer.alloc(0);
  cut = false;
  add(b: Buffer) {
    if (this.head.length < HEAD) {
      const take = b.subarray(0, HEAD - this.head.length);
      this.head = Buffer.concat([this.head, take]);
      b = b.subarray(take.length);
    }
    const all = Buffer.concat([this.tail, b]);
    if (all.length > TAIL) this.cut = true;
    this.tail = all.subarray(Math.max(0, all.length - TAIL));
  }
  text(): string {
    return this.cut ? `${this.head.toString("utf8")}\n…(cut)…\n${this.tail.toString("utf8")}` : Buffer.concat([this.head, this.tail]).toString("utf8");
  }
}

/// The shell a command is run by (platform.posixShell: Git's sh on Windows, which its installer leaves off PATH), found
/// by the run's environment and the station's for what that leaves out (the vault's drops CLAUDE_CODE_GIT_BASH_PATH and
/// ProgramFiles stays the station's): only to find it, the command given `env` alone. None: what to do, as an error.
async function shellFor(env: Record<string, string>): Promise<string> {
  const given = new Set(Object.keys(env).map((k) => k.toUpperCase()));
  const by: NodeJS.ProcessEnv = {};
  for (const [k, v] of Object.entries(process.env)) if (!given.has(k.toUpperCase())) by[k] = v;
  return platform.posixShellSoon({ ...by, ...env });
}

/// Runs `ask.command` (by sh -c) with grant `held`; `env`: the environment it starts from; `used` is told each use of
/// the secret (a host the proxy put it in, an SSH signature, the start of a command given it in its environment).
export async function runWith(held: Held, ask: RunAsk, proxy: Proxy, env: Record<string, string>, used: (detail: string) => void, allowed: () => boolean = () => true): Promise<Ran> {
  const value = valueOf(held.secret)!;
  const id = held.request.id;
  const vars: Record<string, string> = { ...env };
  const account = accountOf(held.secret);
  if (account !== null) vars[ACCOUNT_VAR] = account;
  const ends: (() => void | Promise<void>)[] = [];
  try {
    if (!allowed()) throw new Error("grant expired");
    if (held.grant.mode === "proxy") {
      await proxy.start();
      const admitted = proxy.admit({ hosts: held.grant.hosts, placeholder: placeholder(id), value, used: (host) => used(host), allowed });
      ends.push(admitted.end);
      const stand = placeholder(id);
      Object.assign(vars, {
        HTTPS_PROXY: admitted.url, https_proxy: admitted.url, NO_PROXY: "", no_proxy: "",
        NODE_EXTRA_CA_CERTS: proxy.bundle, SSL_CERT_FILE: proxy.bundle, REQUESTS_CA_BUNDLE: proxy.bundle, CURL_CA_BUNDLE: proxy.bundle, GIT_SSL_CAINFO: proxy.bundle,
        [SECRET_VAR]: stand,
      });
      if (ask.env) vars[ask.env] = stand;
    } else if (held.grant.mode === "ssh") {
      const key = parseSshKey(value);
      const dir = await mkdtemp(join(tmpdir(), "sf-ssh-"));
      ends.push(() => rm(dir, { recursive: true, force: true }));
      const sock = join(dir, "agent.sock");
      const server = await serveAgent(sock, key, () => {
        if (!allowed()) return false;
        used("ssh signature");
        return true;
      });
      // Closed before its directory goes (ends are taken last first); not waited for, as before: a process the command
      // left behind may hold a connection to it.
      ends.push(() => void server.close());
      vars.SSH_AUTH_SOCK = sock;
    } else if (held.grant.mode === "file") {
      // Written where only this user reads it, for this command alone: its path is what the command is given.
      used("file");
      const dir = await mkdtemp(join(tmpdir(), "sf-file-"));
      ends.push(() => rm(dir, { recursive: true, force: true }));
      await chmod(dir, 0o700);
      const path = join(dir, fileName(held.secret.fields.filename));
      const bytes = Buffer.from(value, "base64");
      await writeFile(path, bytes, { mode: 0o600 });
      vars[SECRET_VAR] = path;
      if (ask.env) vars[ask.env] = path;
      return await spawned(ask, vars, fileHidden(bytes, value));
    } else {
      used("environment");
      vars[SECRET_VAR] = value;
      if (ask.env) vars[ask.env] = value;
    }
    return await spawned(ask, vars, [value]);
  } finally {
    // Last made, first ended: an agent's socket closed before its directory is taken away. One that fails leaves
    // the rest to be ended.
    for (const end of ends.reverse()) await Promise.resolve().then(end).catch(() => undefined);
  }
}

/// The name a file is written under: its own, where it is a plain name, else "secret".
function fileName(name: string | undefined): string {
  const n = (name ?? "").trim();
  return n === "" || n === "." || n === ".." || /[/\\\0]/.test(n) ? "secret" : n;
}

/// What of a file is hidden in a command's output, as a value in the environment is: its text whole (the command
/// printing it) and its bytes' base64; a file not text, its base64 only.
function fileHidden(bytes: Buffer, b64: string): string[] {
  const text = bytes.toString("utf8");
  return Buffer.from(text, "utf8").equals(bytes) ? [text.replace(/\r?\n$/, ""), b64] : [b64];
}

async function spawned(ask: RunAsk, env: Record<string, string>, hidden: string[]): Promise<Ran> {
  let shell: string;
  try {
    shell = await shellFor(env);
  } catch (e) {
    return { code: null, signal: null, output: (e as Error).message, cut: false, timedOut: false };
  }
  return new Promise((resolve) => {
    const child = startCommand(shell, ["-c", ask.command], { cwd: ask.cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    const kept = new Kept();
    const out = new Scrubber(hidden);
    const err = new Scrubber(hidden);
    let timedOut = false;
    // The command's time, the machine's: a run left going is stopped, its whole process group.
    const stop = wall.after(ask.timeoutMs, () => {
      timedOut = true;
      endCommand(child, "SIGKILL");
    });
    child.on("error", (e) => {
      stop();
      resolve({ code: null, signal: null, output: `could not start ${shell}: ${e.message}`, cut: false, timedOut: false });
    });
    child.on("close", (code, signal) => {
      stop();
      kept.add(out.end());
      kept.add(err.end());
      resolve({ code, signal, output: kept.text(), cut: kept.cut, timedOut });
    });
    // (after its error is heard: one not started (ENFILE, EMFILE) has no streams, and its error told to none ends the station)
    child.stdout?.on("data", (b: Buffer) => kept.add(out.push(b)));
    child.stderr?.on("data", (b: Buffer) => kept.add(err.push(b)));
  });
}

/// What a command printed, for a secret an agent asks to keep (secret_save): its standard output, kept here (never
/// given to the agent), and its standard error with that output hidden in it.
/// `raw`: its standard output as printed, in base64 (a file kept as its bytes; absent from a station from before files).
export type Captured = { code: number | null; signal: string | null; out: string; raw?: string; err: string; timedOut: boolean; tooLong: boolean };

/// The most of a command's standard output taken as a secret.
const CAPTURE_MAX = 64 * 1024;

/// Runs `command` (by sh -c) in `cwd` and takes what it prints as a secret: none of it is shown, its standard error only
/// with the output hidden in it.
export async function capture(command: string, cwd: string, env: Record<string, string>, timeoutMs: number): Promise<Captured> {
  let shell: string;
  try {
    shell = await shellFor(env);
  } catch (e) {
    return { code: null, signal: null, out: "", err: (e as Error).message, timedOut: false, tooLong: false };
  }
  return new Promise((resolve) => {
    const child = startCommand(shell, ["-c", command], { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    const out: Buffer[] = [];
    let size = 0;
    let tooLong = false;
    const err = new Kept();
    let timedOut = false;
    // The command's time, the machine's: one left going is stopped, its whole process group.
    const stop = wall.after(timeoutMs, () => {
      timedOut = true;
      endCommand(child, "SIGKILL");
    });
    child.on("error", (e) => {
      stop();
      resolve({ code: null, signal: null, out: "", err: `could not start ${shell}: ${e.message}`, timedOut: false, tooLong: false });
    });
    child.on("close", (code, signal) => {
      stop();
      const bytes = Buffer.concat(out);
      const value = bytes.toString("utf8").replace(/\r?\n$/, "");
      resolve({ code, signal, out: tooLong ? "" : value, raw: tooLong ? "" : bytes.toString("base64"), err: value === "" ? err.text() : scrub(err.text(), [value]), timedOut, tooLong });
    });
    // (after its error is heard: one not started (ENFILE, EMFILE) has no streams, and its error told to none ends the station)
    child.stdout?.on("data", (b: Buffer) => {
      size += b.length;
      if (size > CAPTURE_MAX) tooLong = true;
      else out.push(b);
    });
    child.stderr?.on("data", (b: Buffer) => err.add(b));
  });
}
