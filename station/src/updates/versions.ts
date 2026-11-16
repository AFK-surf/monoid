// What the updates go by, as plain functions: versions and how they compare, the release
// channels, what is offered, and the words the pages show while something updates.
import { readFileSync } from "node:fs";
import { open, readFile } from "node:fs/promises";
import { join } from "node:path";
import { plainText } from "../ops/command-output.ts";
import { type Lang, tr } from "../ops/i18n.ts";
import { platform as machine } from "../platform/index.ts";

export { stationVersion } from "../ops/version.ts";

/// Which releases a station is updated to: the stable ones, or the test channel's.
export type Channel = "stable" | "beta";

export function channelOfId(id: string): Channel | null {
  const t = id.trim();
  return t === "stable" || t === "beta" ? t : null;
}

/// Where still.fail cloud says its latest (scripts/release.sh, cloud/src/install.ts).
export const feed = (channel: Channel, origin: string) => `${origin}/releases/${channel === "stable" ? "station" : "station-beta"}.json`;

/// The channel the release in `app` came from, as its installer wrote it (CHANNEL); null from an installer before that.
/// Read once a process, what it says or that it says none: the release is the process's own (an update is another
/// process, and an installer writes it before), and the overview, a session's pages and the move's switch ask it each
/// time.
export function releaseChannel(app: string): Channel | null {
  const known = releases.get(app);
  if (known !== undefined) return known;
  let channel: Channel | null = null;
  try {
    channel = channelOfId(readFileSync(join(app, "CHANNEL"), "utf8")); // sync: once a process, as Updates is made, before the station serves
  } catch {}
  releases.set(app, channel);
  return channel;
}
const releases = new Map<string, Channel | null>();

/// `releaseChannel` off the station's thread (kept as it keeps it).
export async function releaseChannelSoon(app: string): Promise<Channel | null> {
  const known = releases.get(app);
  if (known !== undefined) return known;
  const channel = await readFile(join(app, "CHANNEL"), "utf8").then(channelOfId, () => null);
  releases.set(app, channel);
  return channel;
}

/// The channel a station is updated on: as its config says (`updateChannel`), else as its release came (an install from
/// before there were channels: stable).
export function channelOf(raw: any, app: string): Channel {
  return channelFrom(raw, configChannel(raw) === null ? releaseChannel(app) : null);
}

/// `channelOf` off the station's thread.
export async function channelOfSoon(raw: any, app: string): Promise<Channel> {
  return channelFrom(raw, configChannel(raw) === null ? await releaseChannelSoon(app) : null);
}

/// `channelOf` with the release's channel already read (`release`: as its CHANNEL says, null where it says none).
export function channelFrom(raw: any, release: Channel | null): Channel {
  return configChannel(raw) ?? release ?? "stable";
}

const configChannel = (raw: any): Channel | null => (typeof raw?.updateChannel === "string" ? channelOfId(raw.updateChannel) : null);

/// The station's version as `stationVersion` says it, its release's BUILD read off the station's thread.
export async function stationVersionSoon(app: string): Promise<string | undefined> {
  const build = await readFile(join(app, "BUILD"), "utf8").then((b) => b.trim(), () => "");
  return build !== "" && /^[0-9]+$/.test(build) ? `0.1.${build}` : undefined;
}

const parts = (v: string) => v.split(/[^0-9]/).filter((p) => p !== "").map((p) => (/^\d+$/.test(p) ? BigInt(p) : 0n));

/// Whether `latest` is a newer version than `current`, number by number ("2.1.10" is newer than "2.1.9"; as Rust
/// compares the lists: a longer one with the same start is newer).
export function newer(current: string, latest: string): boolean {
  const [a, b] = [parts(latest), parts(current)];
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i]! > b[i]!;
  return a.length > b.length;
}

/// The first dotted version in what a command said ("2.1.284 (Claude Code)", "codex-cli 0.46.0").
export function versionIn(text: string): string | null {
  for (const raw of text.split(/[\s(),]/)) {
    const w = raw.replace(/^v+/, "");
    if (w.includes(".") && w.split(".").every((p) => p !== "" && /^[0-9]/.test(p))) return w;
  }
  return null;
}

/// What is offered for the station going from `version` to `latest` (as `channel`'s feed says it), its release having
/// come from `installed`: [newer, downgrade]. Back to the stable release from a beta is offered even when it is older,
/// but only so: a stable station is never offered an older version. A station's version is 0.<m>.<n>, compared by n
/// (its build) alone: m, the stable releases before it, is only said (the user, 2026-11-09).
export function offer(version: string | null | undefined, latest: string | null | undefined, channel: Channel, installed: Channel): [boolean, boolean] {
  if (!version || !latest) return [false, false];
  const [from, to] = [parts(version).at(-1) ?? 0n, parts(latest).at(-1) ?? 0n];
  if (to > from) return [true, false];
  return [false, channel === "stable" && installed === "beta" && to < from];
}

/// The last complete percentage of curl's progress bar in what the installer said (it records the bar in update.log,
/// with older clouds too); none when there is none. curl may be mid-write: a half reading is not one.
export function curlPercent(log: string): number | null {
  const lines = log.split(/[\r\n]/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]!.trimEnd();
    const at = line.search(/\s\S*$/);
    if (at < 0) continue;
    const [bar, value] = [line.slice(0, at), line.slice(at + 1)];
    if (bar === "" || !/^[#\s]*$/.test(bar) || !value.endsWith("%")) continue;
    const text = value.slice(0, -1);
    if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text)) continue;
    const n = Number(text);
    if (Number.isFinite(n) && n >= 0 && n <= 100) return Math.floor(n);
  }
  return null;
}

/// How much of the station's release the installer has downloaded, from update.log's tail (a slow download's log can
/// be large).
export async function stationDownloadPercent(log: string): Promise<number | null> {
  const fh = await open(log, "r").catch(() => null);
  if (fh === null) return null;
  try {
    const len = (await fh.stat()).size;
    const from = Math.max(0, len - 4096);
    const buf = Buffer.alloc(Math.min(4096, len));
    const { bytesRead } = await fh.read(buf, 0, buf.length, from);
    return curlPercent(buf.subarray(0, bytesRead).toString("utf8"));
  } catch {
    return null;
  } finally {
    await fh.close().catch(() => {});
  }
}

/// The last lines of what a command said, for the pages (at most four, at most 600 characters), without what it told
/// a terminal (colours, a progress bar's carriage returns).
export function tail(said: string, lang: Lang): string {
  // A line written over (a progress bar's) is what it was last.
  const shown = said.split("\n").map((l) => l.replace(/\r+$/, "").split("\r").at(-1)!).join("\n");
  const lines = plainText(shown).trim().split("\n").filter((l) => l.trim() !== "");
  const last = lines.slice(Math.max(0, lines.length - 4)).join("\n");
  if (last === "") return tr(lang, "station.updates.noOutput");
  const chars = [...last];
  return chars.slice(Math.max(0, chars.length - 600)).join("");
}

/// Words the pages show, said in whichever language they are read in: a catalog key, or text as a command said it.
export type Words = { key: string; args?: Record<string, unknown> } | { text: string };
export const say = (w: Words, lang: Lang) => ("text" in w ? w.text : tr(lang, w.key, w.args));
export const sameWords = (a: Words | null | undefined, b: Words | null | undefined) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

export const INSTALLING: Words = { key: "station.updates.installing" };

/// The step a line of an installer's output says it is at: Homebrew's, and Claude Code's installer's.
export function stepOf(line: string): Words | null {
  const l = line.trim();
  if (["==> Fetching", "==> Downloading"].some((s) => l.startsWith(s))) return { key: "station.updates.downloading" };
  if (["==> Installing", "==> Pouring", "==> Upgrading", "==> Moving", "==> Linking", "Setting up Claude Code"].some((s) => l.startsWith(s))) return INSTALLING;
  return null;
}

/// How much of a download is in, as the pages say it: a line, and the share (drawn as a bar) when its size is known.
export function downloading(version: string, got: number, total: number | null): [Words, number | null] {
  const mb = (b: number) => Math.round(b / 1_000_000);
  if (total !== null && total > 0) return [{ key: "station.updates.downloadingSized", args: { version, got: mb(Math.min(got, total)), mb: mb(total) } }, Math.floor((Math.min(got, total) * 100) / total)];
  return [{ key: "station.updates.downloadingSoFar", args: { version, mb: mb(got) } }, null];
}

/// This machine as the runtimes name their builds (`darwin-arm64`…).
export function platform(): string | null {
  const os = machine.buildOs;
  const arch = process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "x64" : null;
  return os && arch ? `${os}-${arch}` : null;
}
