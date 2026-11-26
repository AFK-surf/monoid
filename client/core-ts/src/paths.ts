// Which bits of a message name a file on the station by its path, and how a chip shows it: the Markdown tree marks
// them (markdown.ts: an inline code's or a link's `path`, `line`, `shown`), each client draws them as chips with their
// cards (the web's Peeks.tsx FileRef, mbui's peeks.mbt).

const CODE_EXT = /\.(?:[cm]?[jt]sx?|json[c5l]?|ndjson|md|mdx|markdown|rs|gsa|py|ipynb|go|kt|kts|swift|java|dart|rb|php|c|cc|cpp|cxx|h|hh|hpp|m|mm|cs|mbt|mbti|mbui|css|scss|less|html?|vue|svelte|astro|ya?ml|toml|ini|cfg|conf|sh|zsh|fish|ps1|psm1|psd1|bat|cmd|cmake|sql|prisma|graphql|proto|lua|groovy|scala|ex|exs|erl|hs|clj|zig|nim|tex|vim|nix|tf|hcl|asm|wasm|sol|patch|diff|txt|log|csv|tsv|xml|svg|png|jpe?g|gif|webp|avif|bmp|ico|mp4|m4v|webm|mov|mp3|m4a|aac|wav|ogg|flac|pdf|xlsx|xls|docx|pptx|bin|hex|tar|gz|tgz|xz|zst|7z|parquet|sqlite3?|lock|gradle|plist|env)$/i;
/** Where an absolute path without an extension is still surely one of the machine's (not a page's route like /admin/api). */
const ROOTS = /^\/(?:Users|Volumes|home|tmp|private|opt|var|etc|srv|mnt|workspace|root)\//;

export function windowsPath(path: string): boolean {
  return /^[a-z]:[\\/]/i.test(path) || path.startsWith("\\\\") || path.startsWith(".\\") || path.startsWith("..\\") || (!path.includes("/") && path.includes("\\"));
}

/**
 * The file (or directory) a bit of inline code names, with the line it points at (`src/a.ts:12`, `a.ts:12:4`,
 * `a.ts#L12`); null when it is not a path. Paths only: absolute ones under the machine's roots or with a file's
 * extension, an absolute Windows drive path, `~/…`, `./…`, `../…`, or relative ones with a directory and an extension;
 * a bare name with a code file's extension, which is read under the session's working directory.
 */
export function pathIn(code: string): { path: string; line: number | null } | null {
  const text = code.trim();
  if (text === "" || text.length > 400 || /\s|:\/\/|[*?<>|$`'"{}()[\]=,;]/.test(text)) return null;
  const m = /^(.*?)(?::(\d+)(?::\d+)?|#L(\d+)(?:-L?\d+)?)?$/.exec(text)!;
  const path = m[1]!;
  const line = m[2] ?? m[3];
  // A drive's colon is part of its absolute path, not a scheme or a line number. Read either separator, but keep
  // the path as the message wrote it: the station, which may be Windows whichever client reads it, opens that.
  const drive = /^[a-z]:[\\/]/i.test(path);
  const winDot = path.startsWith(".\\") || path.startsWith("..\\");
  const winRel = !drive && !winDot && !path.includes("/") && path.includes("\\");
  const place = drive ? path.slice(2).replace(/\\/g, "/") : winDot || winRel ? path.replace(/\\/g, "/") : path;
  // `~/.stillfail/agent/...`, `src/…`: a place left out, not a file.
  if (place === "" || place.includes(":") || /(?:^|\/)(?:\.{3,}|…)$/.test(place) || place.includes("…")) return null;
  const last = place.replace(/\/$/, "").split("/").at(-1) ?? "";
  const ext = /\.[A-Za-z0-9]{1,10}$/.test(last) && !/^\.+$/.test(last);
  const ok = drive ? place.length > 1 :
    winDot
      ? path.length > 2 && /^(?:\.\\|\.\.\\)[\w@.-]+(?:[\\/][\w@.-]+)*[\\/]?$/.test(path) && !/^(?:\.\\|\.\.\\)[A-Za-z0-9]$/.test(path) && (last === ".env" || !last.startsWith(".") || last.slice(1).includes("."))
      : winRel
        ? /^[\w@.-]+(?:\\[\w@.-]+)+\\?$/.test(path) && (path.endsWith("\\") || (CODE_EXT.test(last) && (/^[^.].*\./.test(last) || last === ".env"))) && !/^\d+(?:\.\d+)*\\/.test(path)
        : path.startsWith("~/") || path.startsWith("./") || path.startsWith("../")
          ? path.length > 2
          : path.startsWith("/")
            ? path.split("/").filter(Boolean).length >= 2 && (ext || ROOTS.test(path))
            : path.includes("/")
              ? /^[\w@.-]/.test(path) && (ext || path.endsWith("/")) && !/^\d+(?:\.\d+)*\//.test(path)
              // A bare name: a code file's (not a library's name, as node.js, Vue.js).
              : CODE_EXT.test(last) && !/^\d/.test(last) && !/^[A-Za-z]+\.js$/.test(last);
  return ok ? { path, line: line ? Number(line) : null } : null;
}

/// A path as it is shown: a home directory (/Users/<name>, /home/<name>) as `~`.
export function shownPath(path: string): string {
  return path.replace(/^\/(?:Users|home)\/[^/]+(?=\/|$)/, "~");
}

/// A path as a chip shows it, as the message wrote it (shownPath): a long one cut in its middle, its first two parts and
/// last two kept.
export function chipPath(path: string): string {
  const short = shownPath(path);
  if (windowsPath(short)) {
    const sep = short.includes("\\") ? "\\" : "/";
    const trail = short.endsWith("\\") || short.endsWith("/") ? sep : "";
    const parts = short.replace(/[\\/]$/, "").split(/[\\/]/);
    if (short.length <= 48 || parts.length <= 5) return short;
    return `${parts.slice(0, 2).join(sep)}${sep}…${sep}${parts.slice(-2).join(sep)}${trail}`;
  }
  const slash = short.endsWith("/") ? "/" : "";
  const parts = short.replace(/\/$/, "").split("/");
  if (short.length <= 48 || parts.length <= 5) return short;
  return `${parts.slice(0, 2).join("/")}/…/${parts.slice(-2).join("/")}${slash}`;
}

/// What the Markdown tree says of an inline code or a link naming a file (`code`: its words, or a link's address): its
/// path (as `at` gives it: a run of the text, so its words go once), the line it points at, and a chip's words where they
/// are not the path's (a home as ~, a long one cut); nothing when it names none.
export function pathAttrs<P>(code: string, at: (path: string) => P): { path: P; line?: number; shown?: string } | Record<string, never> {
  const found = pathIn(code);
  if (!found) return {};
  const shown = chipPath(found.path);
  return { path: at(found.path), ...(found.line !== null ? { line: found.line } : {}), ...(shown !== found.path ? { shown } : {}) };
}
