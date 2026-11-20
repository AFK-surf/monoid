// Managing the optional Windows LocalSystem screen service (`stillfail-screen-svc.exe`) from the station's settings
// page: probes whether the service is installed/running and whether this Windows user is an administrator, and handles
// `PUT /screen-service {on}` by running `stillfail-screen-svc.exe install --user-sid <sid>` or `uninstall` elevated
// (via a hidden PowerShell UAC prompt when the station itself runs Limited). Installing or removing the service does
// not restart the station.
import { type ChildProcess, execFile, spawn } from "node:child_process";
import { access } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { log } from "../ops/log.ts";

export const SCREEN_SERVICE_BINARY = "stillfail-screen-svc.exe";

/// How long Windows' UAC prompt + service install/uninstall is waited for before giving up.
export const ASK_MS = 120_000;

export type Failure = "declined" | "unanswered" | "error";

export type ScreenServiceProbe = {
  installed: boolean;
  running: boolean;
  connected: boolean;
  elevated: boolean;
  admin: boolean;
  userSid: string | null;
  binary: string | null;
};

/// The overview's `screenService` (Windows only): whether the service is installed, whether it is running, whether the
/// binary is bundled and this Windows user can install it (Administrators group), any change under way or how the last
/// one failed, and whether the viewer may change it.
export type ScreenServiceView = {
  on: boolean;
  running: boolean;
  canChange: boolean;
  available: boolean;
  step?: "asking" | "applying";
  want?: boolean;
  failed?: Failure;
  message?: string;
  manage: boolean;
};

export type ScreenServiceDeps = {
  app: string;
  now: () => number;
  /// `f` once, `ms` from now (`wall.after`); the returned function calls it off.
  after: (ms: number, f: () => void) => () => void;
  changed: () => void;
  probe?: () => Promise<ScreenServiceProbe>;
  /// Runs `script` (PowerShell) apart: hidden, its exit code when it ends.
  run?: (script: string) => ChildProcess;
};

export class ChangeRefused extends Error {
  readonly key: "busy" | "notAdmin" | "notAvailable";
  constructor(key: "busy" | "notAdmin" | "notAvailable") {
    super(key);
    this.key = key;
  }
}

export class ScreenService {
  #probed: ScreenServiceProbe | null = null;
  #child: ChildProcess | null = null;
  #cancel: (() => void) | null = null;
  #step: { want: boolean; step: "asking" | "applying" } | null = null;
  #failed: { want: boolean; failed: Failure; message?: string } | null = null;
  #settling: Promise<void> = Promise.resolve();
  readonly #d: ScreenServiceDeps;

  constructor(d: ScreenServiceDeps) {
    this.#d = d;
  }

  /// Probes once as the station starts.
  async start(): Promise<void> {
    this.#probed = await this.#runProbe();
    this.#d.changed();
  }

  /// Ends any in-flight installer prompt as the station stops.
  async stop(): Promise<void> {
    this.#cancel?.();
    this.#cancel = null;
    this.#child?.kill();
    this.#child = null;
    await this.settled();
  }

  /// Resolves once any pending post-exit re-probe has finished (for tests).
  async settled(): Promise<void> {
    for (let at = this.#settling; ; at = this.#settling) {
      await at;
      if (at === this.#settling) return;
    }
  }

  async #runProbe(): Promise<ScreenServiceProbe> {
    try {
      return await (this.#d.probe ?? (() => probe(this.#d.app)))();
    } catch {
      return { installed: false, running: false, connected: false, elevated: false, admin: false, userSid: null, binary: null };
    }
  }

  view(manage: boolean): ScreenServiceView {
    const p = this.#probed ?? { installed: false, running: false, connected: false, elevated: false, admin: false, userSid: null, binary: null };
    const available = p.binary !== null;
    const canChange = available && (p.elevated || p.admin);
    return {
      on: p.installed,
      running: p.running || p.connected,
      canChange,
      available,
      ...(this.#step !== null ? { step: this.#step.step, want: this.#step.want } : {}),
      ...(this.#step === null && this.#failed !== null
        ? { failed: this.#failed.failed, want: this.#failed.want, ...(this.#failed.message ? { message: this.#failed.message } : {}) }
        : {}),
      manage,
    };
  }

  /// Installs (`on: true`) or uninstalls (`on: false`) `StillfailScreenService`. Returns once the hidden PowerShell
  /// prompt has been launched; the overview updates as it completes.
  async change(on: boolean): Promise<void> {
    if (this.#step !== null) throw new ChangeRefused("busy");
    if (this.#probed === null) this.#probed = await this.#runProbe();
    const p = this.#probed;
    if (p.binary === null) throw new ChangeRefused("notAvailable");
    if (!p.elevated && !p.admin) throw new ChangeRefused("notAdmin");
    const elevate = !p.elevated;
    this.#step = { want: on, step: elevate ? "asking" : "applying" };
    this.#failed = null;
    this.#d.changed();

    const script = askScript(p.binary, on, p.userSid, elevate);
    const child = (this.#d.run ?? runHidden)(script);
    this.#child = child;

    const finish = (failed: Failure | null, message?: string) => {
      if (this.#child !== child) return;
      this.#cancel?.();
      this.#cancel = null;
      this.#child = null;
      const run = async () => {
        this.#probed = await this.#runProbe();
        this.#step = null;
        if (failed !== null) {
          this.#failed = { want: on, failed, ...(message ? { message } : {}) };
        } else if (this.#probed.installed !== on) {
          this.#failed = { want: on, failed: "error" };
        } else {
          this.#failed = null;
        }
        this.#d.changed();
      };
      this.#settling = this.#settling.then(run).catch((e) => {
        log.warn("screen-service", "status re-probe failed", { error: (e as Error).message });
        this.#step = null;
        this.#failed = { want: on, failed: "error" };
        this.#d.changed();
      });
    };

    this.#cancel = this.#d.after(ASK_MS, () => {
      child.kill();
      finish("unanswered");
    });
    child.on("error", (err) => finish("error", err?.message));
    child.on("exit", (code) => {
      if (code === 0) finish(null);
      else if (code === 4) finish("declined");
      else finish("error");
    });
  }
}

/// A PowerShell single-quoted string literal.
const q = (s: string) => `'${s.replaceAll("'", "''")}'`;

const run = promisify(execFile);

/// Finds `stillfail-screen-svc.exe`: STILLFAIL_SCREEN_SVC, beside the station's code in a release, or built locally.
export async function screenServiceBinary(app: string, env: NodeJS.ProcessEnv = process.env): Promise<string | null> {
  const candidates = [
    env.STILLFAIL_SCREEN_SVC,
    join(app, "station", SCREEN_SERVICE_BINARY),
    fileURLToPath(new URL(`./${SCREEN_SERVICE_BINARY}`, import.meta.url)),
    fileURLToPath(new URL(`../../native/screen/target/release/${SCREEN_SERVICE_BINARY}`, import.meta.url)),
  ];
  for (const p of candidates) {
    if (!p) continue;
    if (await access(p).then(() => true, () => false)) return p;
  }
  return null;
}

/// Probes current Windows elevation/admin/SID and, when `stillfail-screen-svc.exe` is present, queries `status`.
export async function probe(app: string): Promise<ScreenServiceProbe> {
  const binary = await screenServiceBinary(app);
  const script = [
    "$id = [Security.Principal.WindowsIdentity]::GetCurrent()",
    "$e = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
    "$a = [bool](& (Join-Path $env:SystemRoot 'System32\\whoami.exe') /groups /fo csv | Select-String -SimpleMatch 'S-1-5-32-544')",
    "$s = $id.User.Value",
    "Write-Output ([string]$e + ' ' + [string]$a + ' ' + [string]$s)",
  ].join("\r\n");
  const [{ stdout: idOut }, svc] = await Promise.all([
    run("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")], { windowsHide: true, timeout: 10_000 }),
    binary
      ? run(binary, ["status"], { windowsHide: true, timeout: 10_000 })
          .then(({ stdout }) => parseStatus(stdout))
          .catch(() => ({ installed: false, running: false, connected: false }))
      : Promise.resolve({ installed: false, running: false, connected: false }),
  ]);
  const [e, a, sid] = idOut.trim().split(/\s+/);
  return {
    installed: svc.installed,
    running: svc.running,
    connected: svc.connected,
    elevated: e === "True",
    admin: a === "True",
    userSid: sid && /^S-1-5-/.test(sid) ? sid : null,
    binary,
  };
}

function parseStatus(stdout: string): { installed: boolean; running: boolean; connected: boolean } {
  try {
    const j = JSON.parse(stdout.trim());
    return {
      installed: j?.installed === true,
      running: j?.running === true,
      connected: j?.connected === true,
    };
  } catch {
    return { installed: false, running: false, connected: false };
  }
}

function runHidden(script: string): ChildProcess {
  return spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")], {
    stdio: "ignore",
    windowsHide: true,
  });
}

/// Hidden PowerShell that runs `stillfail-screen-svc.exe install --user-sid <sid>` or `uninstall` elevated (via UAC
/// when `elevate` is true), waiting for it to finish and forwarding its exit code (4 when UAC was refused, 5 when it
/// could not be started).
export function askScript(binary: string, on: boolean, userSid: string | null, elevate: boolean): string {
  const args = on
    ? userSid
      ? `@('install', '--user-sid', ${q(userSid)})`
      : `@('install')`
    : `@('uninstall')`;
  return [
    "try {",
    `  $p = Start-Process -FilePath ${q(binary)} -ArgumentList ${args} -WindowStyle Hidden -PassThru -Wait${elevate ? " -Verb RunAs" : ""} -ErrorAction Stop`,
    "  exit $p.ExitCode",
    "} catch {",
    "  $e = $_.Exception; while ($e -and -not ($e -is [ComponentModel.Win32Exception])) { $e = $e.InnerException }",
    "  if ($e -and $e.NativeErrorCode -eq 1223) { exit 4 }",
    "  exit 5",
    "}",
  ].join("\r\n");
}
