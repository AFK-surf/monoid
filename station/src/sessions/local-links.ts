// Local Markdown destinations are files to deliver, not routes on the web client. The
// Rust reads the Markdown with pulldown-cmark; this reads what that finds of links: inline links and images (`[x](d)`,
// `![x](d)`, `<…>` destinations, nested ones), outside code spans and fenced code blocks, and reference links (which
// are refused when they name a local file), for what is read of a link by its name alone (`namedLocalPaths`). What is
// posted is read by the Rust's own code (native/mesh/src/local.rs, `prepare`).
import { fileURLToPath } from "node:url";
import { loadMesh } from "../mesh/native.ts";

export type Found = { inline: boolean; destination: string; start: number; end: number };

/// percent_decode_str(..).decode_utf8_lossy().
export function percentDecode(text: string): string {
  const bytes: number[] = [];
  const raw = Buffer.from(text, "utf8");
  for (let i = 0; i < raw.length; i++) {
    const hex = (c: number) => (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
    if (raw[i] === 0x25 && i + 2 < raw.length && hex(raw[i + 1]!) && hex(raw[i + 2]!)) {
      bytes.push(parseInt(String.fromCharCode(raw[i + 1]!, raw[i + 2]!), 16));
      i += 2;
    } else bytes.push(raw[i]!);
  }
  return new TextDecoder("utf-8").decode(Buffer.from(bytes));
}

const PUNCT = /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/;

/// A destination as pulldown-cmark gives it: without its `<>`, backslash escapes resolved.
const unescape = (raw: string) => raw.replace(/\\(.)/g, (all, c) => (PUNCT.test(c) ? c : all));

/// Where code is (fenced blocks and code spans), as [start, end) ranges: nothing in them is a link.
function codeRanges(text: string): [number, number][] {
  const ranges: [number, number][] = [];
  // Fenced blocks: a line opening with ``` or ~~~ (up to three spaces in), to a line closing it with as many.
  const lines = text.split("\n");
  let at = 0;
  let open: { start: number; fence: string } | null = null;
  for (const line of lines) {
    const fence = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (open === null && fence && !(fence[1]![0] === "`" && line.slice(fence[0].length).includes("`"))) open = { start: at, fence: fence[1]! };
    else if (open !== null && fence && fence[1]![0] === open.fence[0] && fence[1]!.length >= open.fence.length && line.slice(fence[0].length).trim() === "") {
      ranges.push([open.start, at + line.length]);
      open = null;
    }
    at += line.length + 1;
  }
  if (open !== null) ranges.push([open.start, text.length]);
  // Code spans: a run of backticks to the next run as long.
  const inBlock = (i: number) => ranges.some(([s, e]) => i >= s && i < e);
  const spans: [number, number][] = [];
  for (let i = 0; i < text.length; ) {
    if (text[i] === "\\") {
      i += 2;
      continue;
    }
    if (text[i] !== "`" || inBlock(i)) {
      i++;
      continue;
    }
    let n = 0;
    while (text[i + n] === "`") n++;
    const run = "`".repeat(n);
    let close = -1;
    for (let j = i + n; j < text.length; ) {
      const k = text.indexOf(run, j);
      if (k < 0) break;
      let m = 0;
      while (text[k + m] === "`") m++;
      if (m === n) {
        close = k;
        break;
      }
      j = k + m;
    }
    if (close < 0) {
      i += n;
      continue;
    }
    spans.push([i, close + n]);
    i = close + n;
  }
  return [...ranges, ...spans];
}

/// The `]` closing the bracket that opens at `open`, nested brackets counted, escapes and code skipped.
function closing(text: string, open: number, code: (i: number) => boolean): number {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "\\") {
      i++;
      continue;
    }
    if (code(i)) continue;
    if (text[i] === "[") depth++;
    else if (text[i] === "]" && --depth === 0) return i;
  }
  return -1;
}

/// An inline link's destination after its `](`: the raw destination's [start, end), and where the link ends.
function inlineDestination(text: string, at: number): [number, number, number] | null {
  let i = at;
  while (text[i] === " " || text[i] === "\t" || text[i] === "\n") i++;
  let start: number;
  let end: number;
  if (text[i] === "<") {
    start = i + 1;
    let j = start;
    while (j < text.length && text[j] !== ">" && text[j] !== "\n" && text[j] !== "<") j += text[j] === "\\" ? 2 : 1;
    if (text[j] !== ">") return null;
    end = j;
    i = j + 1;
  } else {
    start = i;
    let depth = 0;
    let j = i;
    for (; j < text.length; j++) {
      const c = text[j]!;
      if (c === "\\") {
        j++;
        continue;
      }
      if (/\s/.test(c)) break;
      if (c === "(") depth++;
      else if (c === ")") {
        if (depth === 0) break;
        depth--;
      }
    }
    end = j;
    i = j;
  }
  // An optional title.
  while (text[i] === " " || text[i] === "\t" || text[i] === "\n") i++;
  const quote = text[i];
  if (quote === '"' || quote === "'" || quote === "(") {
    const shut = quote === "(" ? ")" : quote;
    let j = i + 1;
    while (j < text.length && text[j] !== shut) j += text[j] === "\\" ? 2 : 1;
    if (text[j] !== shut) return null;
    i = j + 1;
    while (text[i] === " " || text[i] === "\t" || text[i] === "\n") i++;
  }
  return text[i] === ")" ? [start, end, i + 1] : null;
}

/// The links and images Markdown finds in `text`, in order of where they start.
export function links(text: string): Found[] {
  const code = codeRanges(text);
  const inCode = (i: number) => code.some(([s, e]) => i >= s && i < e);
  // Reference definitions: `[label]: destination` at a line's start.
  const definitions = new Map<string, string>();
  const defined: [number, number][] = [];
  for (const m of text.matchAll(/^ {0,3}\[([^\]\n]+)\]:[ \t]*(<[^>\n]*>|\S+)[^\n]*$/gm)) {
    if (inCode(m.index!)) continue;
    const label = m[1]!.trim().toLowerCase().replace(/\s+/g, " ");
    const raw = m[2]!;
    if (!definitions.has(label)) definitions.set(label, unescape(raw.startsWith("<") ? raw.slice(1, -1) : raw));
    defined.push([m.index!, m.index! + m[0].length]);
  }
  const found: Found[] = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") {
      i++;
      continue;
    }
    if (text[i] !== "[" || inCode(i) || defined.some(([s, e]) => i >= s && i < e)) continue;
    const start = i > 0 && text[i - 1] === "!" && !(i > 1 && text[i - 2] === "\\") ? i - 1 : i;
    const close = closing(text, i, inCode);
    if (close < 0) continue;
    if (text[close + 1] === "(") {
      const at = inlineDestination(text, close + 2);
      if (at) {
        const raw = text.slice(at[0], at[1]);
        found.push({ inline: true, destination: unescape(raw), start, end: at[2] });
        continue;
      }
    }
    // A reference: [text][label], [label][] or [label].
    let label = text.slice(i + 1, close);
    if (text[close + 1] === "[") {
      const end = text.indexOf("]", close + 2);
      if (end >= 0 && end > close + 2) label = text.slice(close + 2, end);
    }
    const destination = definitions.get(label.trim().toLowerCase().replace(/\s+/g, " "));
    if (destination !== undefined) found.push({ inline: false, destination, start, end: close + 1 });
  }
  // Autolinks naming a file: <file:///…>.
  for (const m of text.matchAll(/<(file:[^\s<>]*)>/g)) {
    if (!inCode(m.index!) && !found.some((f) => m.index! >= f.start && m.index! < f.end)) found.push({ inline: false, destination: m[1]!, start: m.index!, end: m.index! + m[0].length });
  }
  return found.sort((a, b) => a.start - b.start);
}

/// The local paths `text`'s links name (file URLs, absolute paths), read by name only: nothing on disk is looked at.
/// Each with its destination as the link has it (escapes resolved).
export function namedLocalPaths(text: string): { destination: string; path: string }[] {
  const named: { destination: string; path: string }[] = [];
  for (const link of links(text)) {
    let path: string | null = null;
    if (link.destination.startsWith("file:")) {
      try {
        path = fileURLToPath(new URL(link.destination));
      } catch {}
    } else {
      const decoded = percentDecode(link.destination);
      if (decoded.startsWith("/") && !decoded.startsWith("//")) path = decoded;
    }
    if (path !== null) named.push({ destination: link.destination, path });
  }
  return named;
}

/// Keeps ordinary prose and code untouched. Makes actual local links refer to immutable message attachments (adding
/// their files to `paths`). Run before posting anything, so a missing or ambiguous attachment can be corrected by the
/// agent. Read by the Rust station's own reading of the Markdown (pulldown-cmark, in the native addon, which every
/// station has): what this read without it is the tests' (test/reference/local-links.ts `prepareHere`).
export function prepare(text: string, paths: string[], workspace: string): string {
  const prepared = loadMesh().prepareLocalLinks(text, paths, workspace);
  paths.splice(0, paths.length, ...prepared.paths);
  return prepared.text;
}
