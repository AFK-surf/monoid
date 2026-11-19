// The station in MoonBit (station/mb/src) says each of its errors as words a person reads, and opens no more sockets of
// its own. Refused, over every package's files but its tests' (`*_test.mbt`, `*_wbtest.mbt`), comments left out:
//   - a `suberror` with no `impl Show for` it in its package: one with none is shown as its constructor, with its
//     package's path (`station/<pkg>.<Type>`), wherever it is said to a person or written to a log;
//   - a `suberror` that derives Show: what that gives is the constructor's shell (`Refused("…")`), not its words;
//   - a socket opened by its shell's name (`shell("tcp.…")`, `"unix.…"`, `"listen.…"`) in any file but the host's
//     binding of them (station/mb/src/host/net.mbt, at most HOST_NET_SOCKETS times): every other one goes through that
//     binding and base/net (`Socket`, `Listener`, `pipe_duplex`).
// It reads the files' text, not the program. Prints each line that is not so, and fails then.
//   node scripts/mb-station.ts
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../station/mb/src", import.meta.url));

/// The one file that asks the shell for its sockets by name (`Host::socket_of`, `listener_of`, `tcp_open`, …), and how
/// many times at most: every other file goes through it.
const HOST_NET = "host/net.mbt";
const HOST_NET_SOCKETS = 12;
/// What a file says that this reads it for: an error, its Show, a socket opened by its shell's name.
const SAYS = ["suberror", "impl Show", '"tcp.', '"unix.', '"listen.'].map((word) => Buffer.from(word));
const RAW_SOCKET = /\bshell\s*\(\s*"(tcp|unix|listen)\.[^"]+"/g;

const wrong: string[] = [];

/// The packages under `dir` (each directory with a moon.pkg), from the program's root.
function packages(dir: string): string[] {
  const entries = readdirSync(join(ROOT, dir), { withFileTypes: true });
  const own = entries.some((entry) => entry.isFile() && entry.name === "moon.pkg") ? [dir] : [];
  return own.concat(entries.filter((entry) => entry.isDirectory() && entry.name !== "_build" && entry.name !== ".mooncakes").flatMap((entry) => packages(join(dir, entry.name))));
}

/// A line without its comment: a `//` outside a string, and the whole of a line of a multi-line string (`#|`, `$|`).
function code(line: string): string {
  const slash = line.indexOf("//");
  if (slash < 0) return /^\s*[#$]\|/.test(line) ? "" : line;
  if (/^\s*[#$]\|/.test(line)) return "";
  if (line.lastIndexOf('"', slash) < 0) return line.slice(0, slash);
  let inString = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === "/" && line[i + 1] === "/") return line.slice(0, i);
  }
  return line;
}

const seen = new Set<string>();
for (const pkg of packages("")) {
  const files = readdirSync(join(ROOT, pkg)).filter((name) => name.endsWith(".mbt") && !/_(wb)?test\.mbt$/.test(name)).map((name) => join(pkg, name));
  // Only the files that say any of it are read as lines (the program is 14 MB: decoding all of it alone takes longer
  // than this check may).
  const texts = new Map<string, string[]>();
  for (const file of files) {
    const bytes = readFileSync(join(ROOT, file));
    if (SAYS.some((word) => bytes.includes(word))) texts.set(file, bytes.toString("latin1").split("\n").map(code));
  }
  const whole = [...texts.values()].map((lines) => lines.join("\n")).join("\n");
  for (const [file, lines] of texts) {
    const text = lines.join("\n");
    // Its errors, each shown by an impl of its own.
    for (const found of text.matchAll(/\bsuberror\s+([A-Z][A-Za-z0-9_]*)/g)) {
      const name = found[1]!;
      const line = text.slice(0, found.index).split("\n").length;
      // The declaration: to its block's closing brace where it has one, else to its line's end; then what it derives.
      const after = text.slice(found.index + found[0].length);
      const open = /^[^\n{]*\{/.exec(after);
      let end = after.indexOf("\n");
      if (open !== null) {
        for (let depth = 0, i = open[0].length - 1; i < after.length; i++) {
          if (after[i] === "{") depth++;
          else if (after[i] === "}" && --depth === 0) {
            end = after.indexOf("\n", i);
            break;
          }
        }
      }
      const declared = after.slice(0, end < 0 ? after.length : end);
      const before = lines.slice(Math.max(0, line - 4), line - 1).join("\n");
      if (/\bderive\s*\([^)]*\bShow\b/.test(declared) || /#derive\s*\([^)]*\bShow\b/.test(before)) {
        wrong.push(`${file}:${line}: suberror ${name} derives Show: that shows its constructor's shell, not its words; write \`impl Show for ${name}\``);
      } else if (!new RegExp(`\\bimpl\\s+Show\\s+for\\s+${name}\\b`).test(whole)) {
        wrong.push(`${file}:${line}: suberror ${name} has no Show implementation: without one it is shown as station/${pkg}.${name}`);
      }
    }
    // The sockets it opens by its shell's name.
    const opened = text.match(RAW_SOCKET)?.length ?? 0;
    if (file === HOST_NET) {
      seen.add(file);
      if (opened > HOST_NET_SOCKETS) wrong.push(`${file}: opens ${opened} sockets by its shell's name, more than HOST_NET_SOCKETS (scripts/mb-station.ts, ${HOST_NET_SOCKETS}): say a new one through the ones there`);
    } else if (opened > 0) {
      wrong.push(`${file}: opens ${opened} socket${opened === 1 ? "" : "s"} by its shell's name: only ${HOST_NET} does; open one through it (Host::tcp_open, unix_open, tcp_listen_local, listener_of, …) and base/net (Socket, Listener, pipe_duplex)`);
    }
  }
}
if (!seen.has(HOST_NET)) wrong.push(`${HOST_NET} is not there: HOST_NET (scripts/mb-station.ts) names the host's binding of the shell's sockets`);

if (wrong.length > 0) {
  console.log(wrong.join("\n"));
  console.log(`(${relative(process.cwd(), ROOT) || "station/mb/src"}: every error is said as words, and a socket is opened through base/net)`);
  process.exit(1);
}
