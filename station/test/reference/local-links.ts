// What a post's local links were made into without the native addon (src/sessions/local-links.ts `prepare`, now the
// Rust's own reading, native/mesh/src/local.rs), as far as this reads the Markdown (raw HTML and indented code blocks
// not told apart): kept for the tests to compare the addon with.
import { realpathSync, statSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { platform } from "../../src/platform/index.ts";
import { links, percentDecode } from "../../src/sessions/local-links.ts";

const isFile = (path: string) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

/// utf8_percent_encode(.., NON_ALPHANUMERIC): every byte but ASCII letters and digits as %XX.
function percentEncode(text: string): string {
  let out = "";
  for (const b of Buffer.from(text, "utf8")) {
    out += (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ? String.fromCharCode(b) : `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

/// Resolves only file URLs, familiar machine roots, or paths that actually name a local file. In particular, station
/// routes (/o/…, /chats/…) and protocol-relative web URLs stay web links.
function localPath(destination: string): string | null {
  const decoded = percentDecode(destination);
  let path: string;
  if (destination.startsWith("file:")) {
    try {
      path = fileURLToPath(new URL(destination));
    } catch {
      throw new Error(`invalid local file link: ${destination}; use an absolute path in files`);
    }
  } else if (platform.paths.isDrivePath(decoded)) {
    // A drive's path (`C:\…`, `C:/…`, on Windows) is a local one, as a familiar root's is on Unix.
    path = decoded;
  } else {
    if (!decoded.startsWith("/") || decoded.startsWith("//")) return null;
    const known = ["/Users/", "/home/", "/tmp/", "/private/", "/var/", "/Volumes/", "/mnt/", "/workspace/", "/etc/", "/opt/"];
    if (!known.some((root) => decoded.startsWith(root)) && !isFile(decoded)) return null;
    path = decoded;
  }
  if (isFile(path)) return path;
  // Codex commonly emits /path/file.rs:12 or /path/file.rs:12:3.
  let base = path;
  for (let i = 0; i < 2; i++) {
    const at = base.lastIndexOf(":");
    if (at < 0) break;
    const tail = base.slice(at + 1);
    if (tail === "" || !/^[0-9]+$/.test(tail)) break;
    base = base.slice(0, at);
    if (isFile(base)) return base;
  }
  throw new Error(`local file link does not name a readable file: ${destination}; correct the path or write it as code instead of a link`);
}

/// A destination with no scheme that is neither from a root nor a fragment or a query (`films/a.mp4`, `report.pdf`):
/// a path where the agent works, as `files` takes one.
const isRelative = (destination: string) => destination !== "" && !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(destination) && !/^[/\\#?]/.test(destination);

/// A relative link's file: none when it names one of the message's files (`[report](report.pdf)` beside `files`, which
/// the clients place by its name), else the one it names in the workspace. Naming neither, it is refused: no reader
/// could open it.
function inWorkspace(destination: string, paths: string[], workspace: string): string | null {
  const decoded = percentDecode(destination);
  const name = decoded.slice(decoded.lastIndexOf("/") + 1);
  if (paths.some((p) => basename(p) === name)) return null;
  const path = join(workspace, decoded);
  if (isFile(path)) return path;
  throw new Error(`local file link ${destination} names no file in the workspace (${workspace}) nor one of the message's files; give its absolute path or attach it with files, use a full URL (https://…), or write it as code`);
}

const canonical = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};

/// prepare without the addon: as far as this reads the Markdown (raw HTML and indented code blocks not told apart).
export function prepareHere(text: string, paths: string[], workspace: string): string {
  const replacements: [number, number, string][] = [];
  for (const link of links(text)) {
    const path = localPath(link.destination) ?? (isRelative(link.destination) ? inWorkspace(link.destination, paths, workspace) : null);
    if (path === null) continue;
    if (!link.inline) throw new Error(`local file link ${link.destination} must use inline Markdown: [label](path); it will be attached automatically`);
    const source = text.slice(link.start, link.end);
    let start: number | null = null;
    for (let at = source.lastIndexOf(link.destination); at >= 0; at = at === 0 ? -1 : source.lastIndexOf(link.destination, at - 1)) {
      const before = source.slice(0, at).trimEnd().replace(/<+$/, "").trimEnd();
      if (before.endsWith("](")) {
        start = at;
        break;
      }
    }
    if (start === null) throw new Error(`write local file link ${link.destination} without Markdown escapes (use <…> around paths with spaces)`);
    const real = canonical(path);
    if (real === null) throw new Error(`no such file: ${path}`);
    if (!paths.some((p) => canonical(isAbsolute(p) ? p : join(workspace, p)) === real)) paths.push(path);
    const name = percentEncode(basename(path));
    replacements.push([link.start + start, link.start + start + link.destination.length, name]);
  }
  // Both clients identify attachments by name; different files with one name must never silently overwrite.
  const names = new Map<string, string>();
  for (const p of paths) {
    const path = isAbsolute(p) ? p : join(workspace, p);
    const real = canonical(path);
    if (real === null) throw new Error(`no such file: ${path}`);
    const name = basename(path);
    if (name === "") continue;
    const previous = names.get(name);
    names.set(name, real);
    if (previous !== undefined && previous !== real) throw new Error(`attachments have the same name: ${name}; rename the files before posting`);
  }
  replacements.sort((a, b) => a[0] - b[0]);
  let result = text;
  for (const [from, to, name] of replacements.reverse()) result = result.slice(0, from) + name + result.slice(to);
  return result;
}
