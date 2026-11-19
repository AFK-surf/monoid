// The station in MoonBit (station/mb/src) says each of its errors as words a person reads, and opens no more sockets of
// its own. Refused, over every package's files but its tests' (`*_test.mbt`, `*_wbtest.mbt`), comments left out:
//   - a `suberror` with no `impl Show for` it in its package: one with none is shown as its constructor, with its
//     package's path (`station/<pkg>.<Type>`), wherever it is said to a person or written to a log;
//   - a `suberror` that derives Show: what that gives is the constructor's shell (`Refused("…")`), not its words;
//   - a socket opened by its shell's name (`shell("tcp.…")`, `"unix.…"`, `"listen.…"`) in any file but the host's
//     binding of them (station/mb/src/host/net.mbt, at most HOST_NET_SOCKETS times): every other one goes through that
//     binding and base/net (`Socket`, `Listener`, `pipe_duplex`);
//   - outside harnesses (`*harness*.mbt`) too, a fiber forked and its handle let go (`ignore(….fork(…))`): its failure
//     is the runtime's `on_defect`, which marks the whole program failed (host.mbt `run`: exit code 1 at its next
//     handover). One a part starts and forgets is `fork_quiet` (best effort, its failure its own) or `fork_daemon`
//     (a loop or a handler, its failure given to its `on_error`);
//   - outside harnesses, a `wall` clock made of the monotonic one (`@host.now`, a runtime's `rt.now`), which counts from
//     the machine's start: the world's time is `@host.epoch_ms()`, a time shared with other programs `@host.wall_ms()`;
//   - outside harnesses, a file written beside under a name another write of it takes too (L13): one named by the pid
//     alone (`"\{path}.\{@drive.pid()}.tmp"`) or by nothing (`let tmp = "\{path}.tmp"`), where two fibers writing the
//     same file at once rename each other's away (ENOENT). `@host.Host::write_atomic` / `write_private` (`unique_tmp`)
//     name each their own;
//   - outside harnesses, more of the program's thread's waits on the disk in a whole station's slice
//     (`station_main/live_*.mbt`: `@drive.read_all`, `stat`, … and `shell_sync("fs.…")`) than MAIN_THREAD_SYNC_FS lets
//     it, which only falls: a count lower than the table's is refused too, until the table is lowered with it;
//   - a JavaScript value made MoonBit's JSON, or back, by writing it out and reading it again
//     (`@json.parse(@jsjson.stringify(v))`, `@jsjson.parse(j.stringify())`): `@jsjson.JValue::to_json` / `of_json` give
//     the same with nothing written;
//   - a SHA-256 of its own: its first round constant or first initial word as a 32-bit literal (`0x428a2f98`,
//     `0x6a09e667`, of either case; SHA-512's 64-bit ones, which begin so, are not): hash with base/hash
//     (`@hash.{Sha256, sha256, sha256_hex, sha256_utf8_hex, hmac_sha256, hex_encode}`);
//   - a fetch asked of its shell by name (`shell("fetch", …)`) in any file but the host's binding of it
//     (station/mb/src/host/http.mbt, at most HOST_HTTP_FETCHES times): every other one is `@host.Host::fetch`, which
//     cancels it on failure (`errdefer` `fetch.cancel`) and says its timeout, headers and body one way;
//   - a SHA-1 of its own (its first initial word, `0x67452301`): base/hash (`@hash.{Sha1, sha1, sha1_hex,
//     sha1_utf8_hex}`);
//   - a CRC-32 of its own (its reversed polynomial, `0xedb88320`): base/codec (`@codec.{crc32, crc32_update}`);
//   - a base64 of its own (its alphabet as a string, `"ABC…789`): base/codec (`@codec.{base64_encode,
//     base64url_encode, base64_decode, base64_decode_strict, base64url_decode}`);
//   - a civil calendar of its own (the days from 0000-03-01 to 1970-01-01, `719468`, or in 400 years, `146097`):
//     base/time (`@time.{civil_from_days, days_from_civil, utc_parts, utc_ms, format_iso_ms, format_iso_sec,
//     format_ymd, parse_iso_ms}`);
//   - a deflate or Adler-32 of its own (Adler's modulus `65521`, a dynamic block's `0x190 +`, `clen_order`):
//     base/flate (`@flate.{deflate, inflate, inflate_at, Deflater, adler32, adler32_update, zlib_compress,
//     zlib_decompress, gzip, gunzip}`).
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
/// The one file that asks the shell for a fetch by name (`Host::fetch`), and how many times at most.
const HOST_HTTP = "host/http.mbt";
const HOST_HTTP_FETCHES = 1;
/// What a file says that this reads it for: an error, its Show, a socket or a fetch asked of its shell by name, a fork, a
/// wall clock, a hash, codec, calendar or deflate of its own.
const SAYS = ["suberror", "impl Show", '"tcp.', '"unix.', '"listen.', ".fork(", "wall", ".tmp", "@drive.", "shell_sync", "@json.parse", "@jsjson.parse", "0x428a2f98", "0x428A2F98", "0x6a09e667", "0x6A09E667", '"fetch"', "0x67452301", "0xedb88320", "0xEDB88320", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "719468", "146097", "65521", "clen_order", "0x190 +", "0x190+"].map((word) => Buffer.from(word));
const RAW_SOCKET = /\bshell\s*\(\s*"(tcp|unix|listen)\.[^"]+"/g;
const RAW_FETCH = /\bshell\s*\(\s*"fetch"/g;
/// A fiber forked and its handle let go (`ignore(host.rt.fork(…))`, its `(` on the next line too).
const BARE_FORK = /\bignore\s*\(\s*[A-Za-z0-9_.()]*\.fork\s*\(/g;
/// A `wall` (a field, a parameter's default, a `let`) made of the monotonic clock: `wall: () => @host.now()`,
/// `wall? : () -> Double = fn() { @host.now().to_double() }`, `let wall = wall.unwrap_or(() => rt.now())`.
const MONOTONIC_WALL =
  /\bwall\s*\??\s*[:=~]\s*(?:\(\s*\)\s*->\s*[A-Za-z0-9_]+\s*=\s*)?(?:[A-Za-z0-9_.]*\.unwrap_or\s*\(\s*)?(?:fn\s*\(\s*\)\s*\{\s*|\(\s*\)\s*=>\s*)?(?:@host\.now|(?<![A-Za-z0-9_])(?:[A-Za-z0-9_]+\.)*rt\.now)\b/g;

/// A name beside a file that another write of it takes too (L13): the pid's alone (`"\{path}.\{@drive.pid()}.tmp"`,
/// `"\{path}.\{js_text(pid)}.tmp"`), or none of its own (`let tmp = "\{path}.tmp"`, `(fs.rename)("\{path}.tmp", …)`).
const SHARED_TMP = [
  /\.\s*\\?\{[^}\n]*\bpid\b[^}\n]*\}\.tmp\b/g,
  /\blet\s+(?:tmp|temp)\s*=\s*"\\\{[^}\n]+\}\.tmp"/g,
  /\b(?:write_text|write|rename)\s*\)?\s*\(\s*"\\\{[^}\n]+\}\.tmp"/g,
];
/// A wait on the disk on the program's thread: `@drive`'s calls, and the shell's `fs.*` asked synchronously.
const SYNC_FS =
  /(?<![A-Za-z0-9_])@drive\.(?:read_all|read_text|write_text|write_private|write_private_bytes|stat|readdir|mkdir|remove|rename|exists|is_dir|lstat|read_bytes|copy|names|rm_force)\s*\(|\bshell_sync\s*\(\s*"fs\.[^"]+"/g;
/// How many of them each whole station's slice (`station_main/live_*.mbt`, its harnesses' aside) has at most; only
/// falls. A new one reads or writes through `@host.Host::{read_bytes, read_text, file_sha256, write_atomic,
/// write_private}` or the shell's `fs.*` asked by `host.shell`, off the program's thread.
const MAIN_THREAD_SYNC_FS: Record<string, number> = {
  "station_main/live_p5_1_admin.mbt": 2,
  "station_main/live_p5_1_events.mbt": 5,
  "station_main/live_p5_1_tools.mbt": 1,
  "station_main/live_p5_2_chats.mbt": 1,
  "station_main/live_p5_2_ctx.mbt": 3,
  "station_main/live_p5_2_drivers.mbt": 2,
  "station_main/live_p5_2_home.mbt": 1,
  "station_main/live_p5_2_hubops.mbt": 1,
  "station_main/live_p5_2_io.mbt": 15,
  "station_main/live_p5_2_main.mbt": 4,
  "station_main/live_p5_2_own.mbt": 3,
  "station_main/live_p5_2_program.mbt": 8,
  "station_main/live_p5_2_world.mbt": 4,
  "station_main/live_p5_3_accounts_io.mbt": 2,
  "station_main/live_p5_3_jobs.mbt": 2,
  "station_main/live_p5_4.mbt": 1,
  "station_main/live_p5_4_browser.mbt": 1,
  "station_main/live_p5_4_devices.mbt": 10,
  "station_main/live_p5_4_drive.mbt": 2,
  "station_main/live_p5_4_helperfs.mbt": 1,
  "station_main/live_p5_4_screens.mbt": 1,
  "station_main/live_p5_4_terms.mbt": 6,
  "station_main/live_p5_4_util.mbt": 1,
  "station_main/live_p5_4_vault.mbt": 7,
  "station_main/live_p5_5_connects.mbt": 8,
  "station_main/live_p5_5_copies.mbt": 2,
  "station_main/live_p5_5_moves.mbt": 2,
};
/// A JavaScript value made MoonBit's JSON, or back, by writing it out and reading it again.
const REPARSED = [/@json\.parse\s*\(\s*@jsjson\.stringify\s*\(/g, /@jsjson\.parse\s*\(\s*[A-Za-z0-9_.]+\.stringify\s*\(\s*\)\s*\)/g];

/// The line `index` is on in `text`, from 1.
// A SHA-256's first round constant or initial word, 32 bits (not the start of SHA-512's 64-bit ones).
const OWN_SHA256 = /\b0x(428a2f98|6a09e667)(?![0-9a-f])/gi;
/// What base's packages each do once, made again: its constant or table, and what to use instead.
const OWN_BASE: [RegExp, string][] = [
  // SHA-1's first initial word.
  [/\b0x67452301(?![0-9a-f])/gi, "a SHA-1 of its own: hash with base/hash (`@hash.{Sha1, sha1, sha1_hex, sha1_utf8_hex}`)"],
  // CRC-32's reversed polynomial.
  [/\b0xedb88320(?![0-9a-f])/gi, "a CRC-32 of its own: use base/codec (`@codec.{crc32, crc32_update}`)"],
  // Base64's alphabet.
  [/"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/g, "a base64 of its own: use base/codec (`@codec.{base64_encode, base64url_encode, base64_decode, base64_decode_strict, base64url_decode}`)"],
  // The civil calendar's days from 0000-03-01 to 1970-01-01, and in 400 years.
  [/\b(?:719468|146097)L?\b/g, "a civil calendar of its own: use base/time (`@time.{civil_from_days, days_from_civil, utc_parts, utc_ms, format_iso_ms, format_iso_sec, format_ymd, parse_iso_ms}`)"],
  // Adler-32's modulus, a dynamic block's code lengths (`0x190 +`), their order.
  [/\b65521L?\b|\b0x190\s*\+|\bclen_order\b/g, "a deflate or Adler-32 of its own: use base/flate (`@flate.{deflate, inflate, inflate_at, Deflater, adler32, adler32_update, zlib_compress, zlib_decompress, gzip, gunzip}`)"],
];

const lineAt = (text: string, index: number) => text.slice(0, index).split("\n").length;

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
const syncFs = new Map<string, number>();
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
    // The fetches it asks of its shell by name.
    const fetched = text.match(RAW_FETCH)?.length ?? 0;
    if (file === HOST_HTTP) {
      seen.add(file);
      if (fetched > HOST_HTTP_FETCHES) wrong.push(`${file}: asks its shell for ${fetched} fetches by name, more than HOST_HTTP_FETCHES (scripts/mb-station.ts, ${HOST_HTTP_FETCHES}): fetch through the one there`);
    } else if (fetched > 0) {
      wrong.push(`${file}: asks its shell for ${fetched} fetch${fetched === 1 ? "" : "es"} by name: only ${HOST_HTTP} does; fetch with \`@host.Host::fetch\`, which cancels it on failure (\`errdefer\` \`fetch.cancel\`) and says its timeout, headers and body one way`);
    }
    for (const pattern of REPARSED) {
      for (const found of text.matchAll(pattern)) {
        wrong.push(`${file}:${lineAt(text, found.index)}: a value written out and read again to be JSON (${found[0].replace(/\s+/g, " ")}…): use \`@jsjson.JValue::to_json\` / \`@jsjson.JValue::of_json\` (\`JV::of_js\` / \`JV::to_js\`), which write nothing`);
      }
    }
    for (const found of text.matchAll(OWN_SHA256)) {
      wrong.push(`${file}:${lineAt(text, found.index)}: a SHA-256 of its own (${found[0]}): hash with base/hash (\`@hash.{Sha256, sha256, sha256_hex, sha256_utf8_hex, hmac_sha256, hex_encode}\`), whose one implementation is tested`);
    }
    for (const [pattern, use] of OWN_BASE) {
      for (const found of text.matchAll(pattern)) {
        wrong.push(`${file}:${lineAt(text, found.index)}: ${use.replace(":", ` (${found[0]}):`)}, whose one implementation is tested`);
      }
    }
    if (/harness[^/]*\.mbt$/.test(file)) continue;
    // Its files written beside, each under a name of its own.
    for (const pattern of SHARED_TMP) {
      for (const found of text.matchAll(pattern)) {
        wrong.push(`${file}:${lineAt(text, found.index)}: a file written beside under a name another write of it takes too (${found[0]}): two fibers writing it at once rename each other's away (L13); write it with \`@host.Host::write_atomic\` / \`write_private\`, or name it by \`@host.unique_tmp\``);
      }
    }
    // A whole station's slice's waits on the disk on the program's thread, which only fall.
    if (/^station_main\/live_[^/]*\.mbt$/.test(file)) {
      syncFs.set(file, text.match(SYNC_FS)?.length ?? 0);
    }
    // Its fibers, each with a failure of its own.
    for (const found of text.matchAll(BARE_FORK)) {
      wrong.push(`${file}:${lineAt(text, found.index)}: a fiber forked and let go, whose failure fails the whole program: use \`fork_quiet\` (best effort, one-off) or \`fork_daemon(name, on_error=…, …)\` (a loop or a handler)`);
    }
    // Its walls, never the monotonic clock.
    for (const found of text.matchAll(MONOTONIC_WALL)) {
      wrong.push(`${file}:${lineAt(text, found.index)}: \`wall\` is the monotonic clock (${found[0].replace(/\s+/g, " ")}), which counts from the machine's start: use \`@host.epoch_ms()\` (the world's time) or \`@host.wall_ms()\` (a time shared with other programs)`);
    }
  }
}
for (const [file, count] of syncFs) {
  const most = MAIN_THREAD_SYNC_FS[file] ?? 0;
  if (count > most) {
    wrong.push(`${file}: ${count} waits on the disk on the program's thread (\`@drive.*\`, \`shell_sync("fs.*")\`), more than MAIN_THREAD_SYNC_FS's ${most} (scripts/mb-station.ts): read and write through \`@host.Host::{read_bytes, read_text, file_sha256, write_atomic, write_private}\` or \`host.shell("fs.*")\`, off the program's thread`);
  } else if (count < most) {
    wrong.push(`${file}: ${count} waits on the disk on the program's thread, fewer than MAIN_THREAD_SYNC_FS's ${most}: lower it to ${count} in scripts/mb-station.ts (it only falls)`);
  }
}
for (const [file, most] of Object.entries(MAIN_THREAD_SYNC_FS)) {
  if (!syncFs.has(file)) wrong.push(`${file}: in MAIN_THREAD_SYNC_FS (${most}) but not there or waiting on the disk no more: take it out of scripts/mb-station.ts`);
}
if (!seen.has(HOST_NET)) wrong.push(`${HOST_NET} is not there: HOST_NET (scripts/mb-station.ts) names the host's binding of the shell's sockets`);
if (!seen.has(HOST_HTTP)) wrong.push(`${HOST_HTTP} is not there: HOST_HTTP (scripts/mb-station.ts) names the host's binding of the shell's fetch`);

if (wrong.length > 0) {
  console.log(wrong.join("\n"));
  console.log(`(${relative(process.cwd(), ROOT) || "station/mb/src"}: every error is said as words, a socket is opened through base/net, a fiber let go is quiet or a daemon, a wall is not the monotonic clock, a file written beside has a name of its own, the slices' waits on the disk only fall, no value is written out to be read again, a fetch goes through Host::fetch, SHA-256 and SHA-1 are base/hash's, CRC-32 and base64 base/codec's, the civil calendar base/time's, deflate and Adler-32 base/flate's)`);
  process.exit(1);
}
