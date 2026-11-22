// What a command's output and the page it opens say (网址和端口的解析; a login command's, mostly:
// the profiles' sign-in, accounts/login.ts, and a person's remote login, logins/): the pages it names,
// whether one of them comes back to a loopback port on this machine (and to which path, with which state), a device
// code to enter, a prompt that asks for Enter. Pure: read from text, nothing run.

/// Drops what a terminal is told rather than shown: CSI sequences (colours, cursor moves), OSC (titles, colour
/// queries) and the two-character escapes; a carriage return is a line's end here.
export function plainText(text: string): string {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (c === "\u001b") {
      const next = text[i + 1];
      if (next === "[") {
        i += 2;
        while (i < text.length && !/[@-~]/.test(text[i]!)) i++;
      } else if (next === "]") {
        i += 2;
        while (i < text.length && text[i] !== "\u0007" && !(text[i] === "\u001b" && text[i + 1] === "\\")) i++;
        if (text[i] === "\u001b") i++;
      } else i += 1;
      continue;
    }
    if (c === "\r") {
      // "\r\r\n" too (a "\r\n" written through the terminal's own newline translation) is one line's end.
      let j = i + 1;
      while (text[j] === "\r") j++;
      if (text[j] !== "\n") out += "\n";
      i = j - 1;
      continue;
    }
    if (c === "\b" || c === "\u0007" || c === "\u000f" || c === "\u000e") continue;
    out += c;
  }
  return out;
}

/// What a URL in some text is made of, and what RFC 3986 allows in one.
const URL_AT_END = /https?:\/\/[^\s"'<>`]+$/;
const URL_CHARS = /^[A-Za-z0-9._~:/?#[\]@!$&()*+,;=%-]+$/;
/// A query's or a percent-encoding's mark: what only a URL's part has.
const URL_MARK = (s: string) => /[&=+]/.test(s) || /%[0-9A-Fa-f]{2}/.test(s);
/// A line of separators (a box's rule), drawn under a link.
const RULE = /^[=\-_~*─━═·.]+$/;

/// Whether `next` goes on with the link `lineTrimmed` ends in, broken by a program (or its terminal) over lines; the width
/// it was broken at if so (`wrapWidth`, the first line's, kept for the lines after), else null. `prevRaw` is the line
/// just before `next` as it was said; `cols` the terminal's width. A line as wide as the terminal (a few columns short,
/// for a box's margin) goes on, as before. A narrower one (a CLI breaking its own lines at 80 or so, a margin, a word
/// break) goes on only where the link is long and `next` reads as more of it: a query's marks or a path, a break at a
/// query's mark, a long run of URL characters after a long line of a query's link, or the short end of a link broken at
/// the same width as its lines above. Never a code, a rule, a prompt, a second link or a sentence.
export function urlContinuation(prevRaw: string, lineTrimmed: string, next: string, cols: number, wrapWidth: number | null): number | null {
  const at = URL_AT_END.exec(lineTrimmed);
  if (at === null || !/^\s*[^\s"'<>`]/.test(next)) return null;
  const prevRawLen = prevRaw.trimEnd().length;
  if (prevRawLen >= cols - 4) return wrapWidth ?? cols;
  const url = at[0];
  if (url.length < 40) return null;
  const nextTrim = next.trim();
  if (nextTrim === "" || /^https?:\/\//i.test(nextTrim)) return null;
  const goes = wrapWidth ?? prevRawLen;
  if (/\s/.test(nextTrim)) {
    const first = nextTrim.split(/\s/)[0]!;
    const ok = url.includes("?") && !/["'<>`]/.test(first) && !/^https?:\/\//i.test(first) && !RULE.test(first) && URL_MARK(first);
    return ok ? goes : null;
  }
  if (/["'<>`]/.test(nextTrim) || RULE.test(nextTrim)) return null;
  if (/^[A-Z0-9]{4}-[A-Z0-9]{4,6}$/.test(nextTrim) || /^[(\[]?[yYnN]\/[yYnN][)\]]?$/.test(nextTrim)) return null;
  if (/[:：?？]$/.test(nextTrim) && !/[&=+%]/.test(nextTrim)) return null;
  const urlChars = URL_CHARS.test(nextTrim);
  if (
    URL_MARK(nextTrim) || (nextTrim.includes("/") && nextTrim.length >= 8) ||
    /[?&=+%]$/.test(lineTrimmed) ||
    (url.includes("?") && prevRawLen >= 60 && nextTrim.length >= 16 && urlChars) ||
    (wrapWidth !== null && prevRawLen >= wrapWidth - 4 && urlChars)
  ) return goes;
  return null;
}

/// A link a program broke over lines put back together (`urlContinuation`: Devin's, past 200 columns, comes on two
/// lines; a CLI breaking at 80 columns, on several).
export function unwrapped(text: string, cols: number): string {
  const lines = text.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i]!;
    let prevRaw = line;
    let wrapWidth: number | null = null;
    while (i + 1 < lines.length) {
      const trimmed = line.trimEnd();
      const next = lines[i + 1]!;
      const width = urlContinuation(prevRaw, trimmed, next, cols, wrapWidth);
      if (width === null) break;
      line = trimmed + next.trimStart();
      prevRaw = next;
      wrapWidth = width;
      i++;
    }
    out.push(line);
  }
  return out.join("\n");
}

/// The http(s) addresses in some text, in order, without the punctuation that ends a sentence around them.
export function urlsIn(text: string): string[] {
  const found: string[] = [];
  for (const m of text.matchAll(/https?:\/\/[^\s"'<>`]+/g)) {
    let url = m[0];
    while (/[.,;:!?)\]}'"…]$/.test(url) && !(url.endsWith(")") && url.includes("("))) url = url.slice(0, -1);
    url = url.replace(/\.\.\.$/, "");
    if (url.length > "https://".length) found.push(url);
  }
  return found;
}

/// Where a login's browser comes back to on this machine: `redirect_uri` (or a parameter like it) at localhost,
/// 127.0.0.1 or [::1] with a port; the page's `state`; `post` when the callback is a form posted to it (response_mode
/// form_post, az's).
export type Loopback = { host: string; port: number; path: string; state: string | null; post: boolean };

const REDIRECTS = ["redirect_uri", "redirect_url", "redirecturi", "redirect", "callback", "callback_url", "return_to"];
const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

function parsed(text: string): URL | null {
  try {
    return new URL(text);
  } catch {
    return null;
  }
}

/// A URL's loopback callback, looked for in its own parameters and one level of addresses inside them (a sign-in page
/// handing on to an authorize URL); none when it comes back elsewhere, or names no port.
export function loopbackOf(url: string, depth = 0): Loopback | null {
  const page = parsed(url);
  if (page === null) return null;
  const post = page.searchParams.get("response_mode") === "form_post";
  const state = page.searchParams.get("state");
  for (const [name, value] of page.searchParams) {
    if (!REDIRECTS.includes(name.toLowerCase())) continue;
    const back = parsed(value);
    if (back === null || back.protocol !== "http:" || !LOOPBACK.has(back.hostname)) continue;
    const port = Number(back.port);
    if (!Number.isInteger(port) || port <= 0 || port > 65535) continue;
    return { host: back.hostname === "::1" ? "[::1]" : back.hostname, port, path: back.pathname === "" ? "/" : back.pathname, state, post };
  }
  if (depth > 0) return null;
  for (const [, value] of page.searchParams) {
    if (!/^https?:\/\//.test(value)) continue;
    const inner = loopbackOf(value, depth + 1);
    if (inner !== null) return { ...inner, state: inner.state ?? state, post: inner.post || post };
  }
  return null;
}

/// A page's host, as shown beside its button (github.com).
export function domainOf(url: string): string | null {
  return parsed(url)?.host ?? null;
}

/// A device code in some output, whichever tool says it, or in a page it opened: a `user_code=` in a page's address
/// (RFC 8628's verification_uri_complete: Vercel's, Wrangler's), its case kept; one like ABCD-1234 (four capitals or
/// digits, a dash, four to six more: gh, Docker, AWS, Cloudflare); a word of six to twelve letters and digits alone on
/// the line under one ending "code:" (Wrangler's vFA9uVPF, a blank line between); else on a line that says "code", a
/// word right after it (after a colon one that is no word of prose, after a space capitals and digits or one with a
/// digit in it: az's GQGFJ2QXM), or of six to ten capitals and digits with a digit in it anywhere on it. Never one in a
/// page's other parameters (a PKCE challenge, a state).
export function deviceCodeIn(said: string, opened: readonly string[] = []): string | null {
  const whole = /^[A-Za-z0-9]{4,12}(?:-[A-Za-z0-9]{3,8})?$/;
  for (const u of [...opened, ...urlsIn(said)]) {
    const given = parsed(u)?.searchParams.get("user_code");
    if (given && whole.test(given)) return given;
  }
  const given = /[?&]user_code=([A-Za-z0-9]{4,12}(?:-[A-Za-z0-9]{3,8})?)(?![A-Za-z0-9_-])/.exec(said);
  if (given) return given[1]!;
  const text = said.replace(/https?:\/\/[^\s"'<>`]+/g, " ");
  for (const word of text.split(/[^A-Za-z0-9_-]/)) {
    const parts = word.split("-");
    const code = (s: string, min: number, max: number) => s.length >= min && s.length <= max && /^[A-Z0-9]+$/.test(s);
    for (let i = 0; i + 1 < parts.length; i++) if (code(parts[i]!, 4, 4) && code(parts[i + 1]!, 4, 6)) return `${parts[i]}-${parts[i + 1]}`;
  }
  // No word of prose: letters (and digits), not all small, not a capitalised word (Continue, Devin).
  const codeWord = (w: string) => /^[A-Za-z0-9]{6,12}$/.test(w) && /[A-Za-z]/.test(w) && !/^[a-z]+$/.test(w) && !/^[A-Z][a-z]+$/.test(w);
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!/\bcode\s*:\s*$/i.test(lines[i]!)) continue;
    const next = lines[i + 1]?.trim() === "" ? lines[i + 2] : lines[i + 1];
    const alone = next !== undefined ? /^\s*([A-Za-z0-9]{6,12})\s*$/.exec(next) : null;
    if (alone && codeWord(alone[1]!)) return alone[1]!;
  }
  for (const line of lines) {
    if (!/code/i.test(line)) continue;
    const marked = /\bcode(?:\s+is)?\s*[:=]\s*([A-Za-z0-9]{6,12})\b/i.exec(line);
    if (marked && codeWord(marked[1]!)) return marked[1]!;
    const spaced = /\bcode(?:\s+is)?\s+([A-Za-z0-9]{6,12})\b/i.exec(line);
    if (spaced && (/^[A-Z0-9]{6,10}$/.test(spaced[1]!) || (/[0-9]/.test(spaced[1]!) && codeWord(spaced[1]!)))) return spaced[1]!;
    const after = /code[^A-Za-z0-9]{1,3}([A-Z0-9]{6,10})\b/i.exec(line);
    if (after && /^[A-Z0-9]+$/.test(after[1]!)) return after[1]!;
    for (const word of line.split(/[^A-Za-z0-9]+/)) if (/^[A-Z0-9]{6,10}$/.test(word) && /[0-9]/.test(word) && /[A-Z]/.test(word)) return word;
  }
  return null;
}

/// Where a device code is entered, of the pages named: one whose path says device, activate or verify first, else the
/// first that comes back to no loopback port; and the one with the code in it, where one has (`user_code=`).
export function deviceUrls(urls: string[], code: string): { url: string | null; codeUrl: string | null } {
  const pages = urls.filter((u) => u.startsWith("https://") && loopbackOf(u) === null);
  const withCode = pages.find((u) => u.includes(code) || /[?&](user_code|code)=/.test(u)) ?? null;
  const verify = pages.find((u) => /device|activate|verif/i.test(parsed(u)?.pathname ?? "")) ?? pages[0] ?? null;
  return { url: verify, codeUrl: withCode };
}

/// Whether a line asks only for Enter to open a page in a browser (gh, npm, docker: "Press Enter to open … in your
/// browser…", "Press ENTER to open in the browser…"): nothing to choose there.
export const asksEnter = (line: string) => /press\s+(enter|return)\b[^?]*\b(open|browser)/i.test(line) && !/\([yn]\/[yn]\)|\[[yn]\/[yn]\]/i.test(line);

/// Whether what a command said after its browser step says it is logged in (✓ Authentication complete, Logged in as …,
/// You are now logged in, Successfully authenticated): nothing is left for a person then.
export const saysDone = (text: string) =>
  /\b(authentication|authorization|login|sign[- ]?in)\s+(is\s+)?(complete|completed|succeeded|successful)\b|\b(logged|signed)\s+in\b|\bsuccessfully\s+(authenticated|logged|signed|authorized)\b|\bauthenticated\s+(as|to|with)\b/i.test(text);

/// Whether a program (a process's name) keeps credentials in a store that may ask the OS (the keychain, a credential
/// helper, a passphrase prompt): one of those waiting is waiting on a dialog nobody here sees.
export const storesSecret = (name: string) => /credential|keychain|keyring|pinentry|askpass|secret-tool|kwallet/i.test(name.split("/").at(-1) ?? name);

/// Whether a line looks like a question waiting for an answer (ends in :, ?, >, a (Y/n), or a choice's arrow).
export const prompts = (line: string) => /(\?|:|>|\)|\]|＞|：|？)\s*$/.test(line.trim()) || /\([yY]\/[nN]\)|\[[yY]\/[nN]\]/.test(line) || /^\s*[>❯]\s/.test(line);

/// Whether a prompt asks for a secret (its input is then not echoed).
export const secretAsked = (line: string) => /password|passphrase|token|secret|密码/i.test(line);

/// A command's words split where a shell would: the environment it is given before its program (`NAME=value`, a value
/// starting `~/` taken from `home` as a shell expands it) and the program with its arguments.
export function assignmentsOf(words: string[], home: string | undefined): { env: Record<string, string>; rest: string[] } {
  const env: Record<string, string> = {};
  let i = 0;
  for (; i < words.length; i++) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s.exec(words[i]!);
    if (!m) break;
    const value = m[2]!;
    env[m[1]!] = home !== undefined && (value === "~" || value.startsWith("~/")) ? home + value.slice(1) : value;
  }
  return { env, rest: words.slice(i) };
}

/// What a command runs, by its program's name (devin, not env or /x/bin/devin): past the environment it is given (`env`,
/// its options, `VAR=value`) and what only runs it (sudo, npx, uvx, pnpm dlx…), a package without its version.
export function programOf(words: string[]): string {
  let i = 0;
  const skip = (valued: string[]) => {
    while (i < words.length && words[i]!.startsWith("-") && words[i] !== "-") {
      const option = words[i++]!;
      if (option === "--") break;
      if (valued.includes(option)) i++;
    }
  };
  for (;;) {
    while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i]!)) i++;
    const word = words[i];
    if (word === undefined) break;
    const base = word.split(/[\\/]/).at(-1)!;
    const two = RUNNERS[`${base} ${words[i + 1] ?? ""}`];
    const one = RUNNERS[base];
    if (two === undefined && one === undefined) break;
    i += two !== undefined ? 2 : 1;
    skip(two ?? one!);
  }
  const word = words[i] ?? words[0] ?? "";
  return word.split(/[\\/]/).at(-1)!.replace(/(.)@.*$/, "$1");
}

/// What only runs another command, and its options that take a value.
const RUNNERS: Record<string, string[]> = {
  env: ["-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-P"],
  sudo: ["-u", "--user", "-g", "--group", "-C", "--close-from", "-D", "--chdir", "-h", "--host", "-p", "--prompt", "-r", "--role", "-t", "--type", "-T", "--command-timeout", "-U", "--other-user"],
  doas: ["-u", "-C"],
  nohup: [],
  command: [],
  exec: ["-a"],
  npx: ["-p", "--package", "-c", "--call"],
  pnpx: ["-p", "--package"],
  bunx: ["-p", "--package"],
  uvx: ["--from", "--with", "-p", "--python", "--index", "--index-url"],
  "npm exec": ["-p", "--package", "-c", "--call"],
  "pnpm dlx": ["-p", "--package"],
  "pnpm exec": [],
  "yarn dlx": ["-p", "--package"],
  "pipx run": ["--spec", "--python"],
};

/// A command line in words (`vercel login --scope "my team"`): split as a POSIX shell would split plain words and
/// quotes (no variables, no globs); null when a quote is left open.
export function commandWords(line: string): string[] | null {
  const words: string[] = [];
  let word = "";
  let has = false;
  let quote: '"' | "'" | null = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (quote === "'") {
      if (c === "'") quote = null;
      else word += c;
    } else if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === "\\" && i + 1 < line.length && /["\\$`]/.test(line[i + 1]!)) word += line[++i];
      else word += c;
    } else if (c === "'" || c === '"') {
      quote = c;
      has = true;
    } else if (c === "\\" && i + 1 < line.length) {
      word += line[++i];
      has = true;
    } else if (/\s/.test(c)) {
      if (has || word !== "") words.push(word);
      word = "";
      has = false;
    } else word += c;
  }
  if (quote !== null) return null;
  if (has || word !== "") words.push(word);
  return words;
}

/// Whether `url` is a web page (http or https), as a login's page must be to open in a browser.
export const webPage = (url: string | null | undefined): url is string => typeof url === "string" && /^https?:\/\//i.test(url);
