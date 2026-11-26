// Locate or install a Python + pyatv runtime environment under <data>/tools/airplay-venv.
import { spawn } from "node:child_process";
import { access, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { wall } from "../../ops/fibers.ts";
import { platform } from "../../platform/index.ts";
import { AirPlayError, type AirPlayEnvStatus } from "./types.ts";

const PYATV_SPEC = "pyatv>=0.16,<0.17";
const PROBE_TIMEOUT_MS = 10_000;
const INSTALL_TIMEOUT_MS = 5 * 60_000;

export function airplayVenvDir(dataDir: string): string {
  return join(dataDir, "tools", "airplay-venv");
}

export function airplayVenvPython(dataDir: string): string {
  const dir = airplayVenvDir(dataDir);
  return platform.os === "windows" ? join(dir, "Scripts", "python.exe") : join(dir, "bin", "python");
}

function runCommand(cmd: string, args: string[], timeoutMs: number): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    // timer: bound external python/uv probe or installation subprocess
    const stop = wall.after(timeoutMs, () => {
      timedOut = true;
      child.kill("SIGTERM");
    });
    child.stdout?.on("data", (chunk: Buffer) => {
      if (stdout.length < 64_000) stdout += chunk.toString("utf8");
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      if (stderr.length < 64_000) stderr += chunk.toString("utf8");
    });
    child.once("error", (err) => {
      stop();
      reject(err);
    });
    child.once("close", (code) => {
      stop();
      if (timedOut) {
        reject(new AirPlayError("install_timeout", `${cmd} timed out after ${Math.round(timeoutMs / 1000)}s`));
        return;
      }
      resolve({ code: code ?? -1, stdout: stdout.trim(), stderr: stderr.trim() });
    });
  });
}

async function probePyatv(pythonBin: string): Promise<string | null> {
  try {
    const res = await runCommand(pythonBin, ["-c", "import pyatv, pyatv.const; print(pyatv.const.__version__)"], PROBE_TIMEOUT_MS);
    return res.code === 0 && res.stdout !== "" ? res.stdout.split(/\r?\n/)[0]!.trim() : null;
  } catch {
    return null;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

export async function detectAirPlayEnv(dataDir: string): Promise<AirPlayEnvStatus> {
  const venvPy = airplayVenvPython(dataDir);
  if (await exists(venvPy)) {
    const ver = await probePyatv(venvPy);
    if (ver !== null) return { ready: true, python: venvPy, pyatvVersion: ver };
  }
  const candidates = platform.os === "windows" ? ["python", "python3"] : ["python3", "python"];
  let foundPython: string | null = null;
  for (const bin of candidates) {
    try {
      const check = await runCommand(bin, ["-c", "import sys; print(sys.executable)"], PROBE_TIMEOUT_MS);
      if (check.code === 0 && check.stdout !== "") {
        foundPython ??= check.stdout.split(/\r?\n/)[0]!.trim();
        const ver = await probePyatv(bin);
        if (ver !== null) return { ready: true, python: foundPython, pyatvVersion: ver };
      }
    } catch {
      // candidate not available
    }
  }
  return {
    ready: false,
    python: foundPython,
    pyatvVersion: null,
    error: foundPython === null
      ? "Python 3.9+ was not found on this station"
      : "pyatv is not installed on this station",
  };
}

const installing = new Map<string, Promise<{ ok: true; pyatvVersion: string; python: string }>>();

export function installAirPlayEnv(
  dataDir: string,
  opts?: { timeoutMs?: number },
): Promise<{ ok: true; pyatvVersion: string; python: string }> {
  const existing = installing.get(dataDir);
  if (existing !== undefined) return existing;
  const run = doInstall(dataDir, opts?.timeoutMs ?? INSTALL_TIMEOUT_MS).finally(() => {
    installing.delete(dataDir);
  });
  installing.set(dataDir, run);
  return run;
}

async function doInstall(dataDir: string, timeoutMs: number): Promise<{ ok: true; pyatvVersion: string; python: string }> {
  const venvDir = airplayVenvDir(dataDir);
  const venvPy = airplayVenvPython(dataDir);
  await mkdir(dirname(venvDir), { recursive: true });

  // Prefer uv when installed (much faster venv + pip install).
  let usedUv = false;
  try {
    const uvCheck = await runCommand("uv", ["--version"], PROBE_TIMEOUT_MS);
    if (uvCheck.code === 0) {
      const mk = await runCommand("uv", ["venv", venvDir], timeoutMs);
      if (mk.code !== 0) throw new AirPlayError("install_failed", `uv venv failed: ${mk.stderr || mk.stdout}`);
      const pip = await runCommand("uv", ["pip", "install", "--python", venvPy, PYATV_SPEC], timeoutMs);
      if (pip.code !== 0) throw new AirPlayError("install_failed", `uv pip install failed: ${pip.stderr || pip.stdout}`);
      usedUv = true;
    }
  } catch (err) {
    if (err instanceof AirPlayError) throw err;
    // uv not available, fall through to python3 -m venv
  }

  if (!usedUv) {
    const pyBin = platform.os === "windows" ? "python" : "python3";
    const mk = await runCommand(pyBin, ["-m", "venv", venvDir], timeoutMs);
    if (mk.code !== 0) {
      throw new AirPlayError("install_failed", `${pyBin} -m venv failed: ${mk.stderr || mk.stdout}`);
    }
    const pip = await runCommand(venvPy, ["-m", "pip", "install", "--upgrade", PYATV_SPEC], timeoutMs);
    if (pip.code !== 0) {
      throw new AirPlayError("install_failed", `pip install ${PYATV_SPEC} failed: ${pip.stderr || pip.stdout}`);
    }
  }

  const ver = await probePyatv(venvPy);
  if (ver === null) {
    throw new AirPlayError("install_failed", "pyatv installation finished but `import pyatv` failed");
  }
  return { ok: true, pyatvVersion: ver, python: venvPy };
}
