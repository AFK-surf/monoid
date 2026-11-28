// Markdown -> Slack Block Kit blocks.
//
// Slack's `{ type: "markdown", text }` block draws headings, tables, quotes, code blocks and simple lists natively,
// but has two server-side parser bugs:
// 1. Ordered lists interrupted by nested sub-lists (or blank lines / non-1 starting numbers) lose their numbering:
//    Slack splits the parent list into separate `rich_text_list` elements without emitting `offset`, resetting every
//    resumed item back to `1.`.
// 2. Emphasis delimiters (`*` / `**` / `***`) touching an inline code span on the inside and a non-ASCII character
//    (such as CJK text or punctuation) on the outside fail Slack's flanking check, leaking literal `*` / `**`.
//
// We keep `{ type: "markdown", text }` for ordinary content (preserving native tables and heading levels) while
// emitting native `rich_text` blocks with explicit `indent` and `offset` for affected ordered list groups and
// inserting a zero-width boundary inside `markdown` blocks where code spans touch `*` beside non-ASCII characters.

type Json = any;

type InlineStyle = {
  bold?: boolean;
  italic?: boolean;
  strike?: boolean;
  code?: boolean;
};

type ListItem = {
  rawIndent: number;
  style: "ordered" | "bullet";
  startNum: number;
  text: string;
};

const MAX_SPLIT_BLOCKS = 40;
const MAX_SLACK_INDENT = 8;
const ZWSP = "\u200B";

const isAsciiWs = (ch: string) => ch === " " || ch === "\t" || ch === "\r" || ch === "\n";
const isAsciiAlnum = (ch: string) => {
  const c = ch.charCodeAt(0);
  return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
};
const isNonAscii = (ch: string) => ch.charCodeAt(0) >= 0x80;

/// Detects a fenced code block opener/closer (` ``` ` or `~~~`, up to 3 leading spaces).
function parseFence(line: string): { ch: string; len: number; rest: string } | null {
  let i = 0;
  let spaces = 0;
  while (i < line.length && line[i] === " " && spaces < 4) {
    i++;
    spaces++;
  }
  if (spaces > 3 || i >= line.length) return null;
  const ch = line[i]!;
  if (ch !== "`" && ch !== "~") return null;
  let len = 0;
  while (i + len < line.length && line[i + len] === ch) len++;
  if (len < 3) return null;
  return { ch, len, rest: line.slice(i + len) };
}

/// True when a line is a Markdown thematic break (`---`, `***`, `___`, optionally spaced).
function isThematicBreak(line: string): boolean {
  let i = 0;
  let spaces = 0;
  while (i < line.length && line[i] === " " && spaces < 4) {
    i++;
    spaces++;
  }
  if (spaces > 3 || i >= line.length) return false;
  const ch = line[i]!;
  if (ch !== "-" && ch !== "*" && ch !== "_") return false;
  let count = 0;
  for (; i < line.length; i++) {
    const c = line[i]!;
    if (c === ch) count++;
    else if (c !== " " && c !== "\t") return false;
  }
  return count >= 3;
}

/// Counts leading indentation in spaces (tab = 4 spaces) and returns the index of the first non-whitespace char.
function measureIndent(line: string): { rawIndent: number; pos: number } {
  let rawIndent = 0;
  let pos = 0;
  while (pos < line.length) {
    const ch = line[pos]!;
    if (ch === " ") {
      rawIndent++;
      pos++;
    } else if (ch === "\t") {
      rawIndent += 4 - (rawIndent % 4);
      pos++;
    } else {
      break;
    }
  }
  return { rawIndent, pos };
}

/// Parses a Markdown list item start line (`- `, `* `, `+ `, `1. `, `2) `). Returns null for non-list lines and
/// thematic breaks.
function parseListLine(line: string): ListItem | null {
  if (isThematicBreak(line)) return null;
  const { rawIndent, pos } = measureIndent(line);
  if (pos >= line.length) return null;
  const ch = line[pos]!;
  if (ch === "-" || ch === "*" || ch === "+") {
    const next = line[pos + 1];
    if (next !== " " && next !== "\t") return null;
    return { rawIndent, style: "bullet", startNum: 1, text: line.slice(pos + 2).replace(/^[ \t]+/, "") };
  }
  if (ch >= "0" && ch <= "9") {
    let end = pos;
    while (end < line.length && line[end]! >= "0" && line[end]! <= "9" && end - pos < 9) end++;
    const delim = line[end];
    const after = line[end + 1];
    if ((delim === "." || delim === ")") && (after === " " || after === "\t")) {
      return {
        rawIndent,
        style: "ordered",
        startNum: Number(line.slice(pos, end)),
        text: line.slice(end + 2).replace(/^[ \t]+/, ""),
      };
    }
  }
  return null;
}

/// Finds a matching closing backtick run of exact length `ticks` starting at `from`.
function findClosingTicks(line: string, from: number, ticks: number): number {
  let i = from;
  while (i < line.length) {
    if (line[i] === "`") {
      let run = 0;
      while (i + run < line.length && line[i + run] === "`") run++;
      if (run === ticks) return i;
      i += run;
    } else {
      i++;
    }
  }
  return -1;
}

/// Checks if `line` contains an unescaped exact `*` run of length `want` outside inline code spans within `[from, to)`.
function hasStarRun(line: string, from: number, to: number, want: number): boolean {
  let i = from;
  while (i < to) {
    const ch = line[i]!;
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === "`") {
      let ticks = 0;
      while (i + ticks < to && line[i + ticks] === "`") ticks++;
      const close = findClosingTicks(line, i + ticks, ticks);
      if (close >= 0 && close + ticks <= to) {
        i = close + ticks;
        continue;
      }
      i += ticks;
      continue;
    }
    if (ch === "*") {
      let run = 0;
      while (i + run < to && line[i + run] === "*") run++;
      if (run === want) return true;
      i += run;
      continue;
    }
    i++;
  }
  return false;
}

/// Fixes Slack's markdown-block flanking bug where `*`/`**`/`***` touches an inline code span on the inside and a
/// non-ASCII character (e.g. CJK text or punctuation) on the outside. Inserts a zero-width space between the backtick
/// and the `*` run only when a matching `*` run exists on the same line. Leaves fenced code blocks and code spans untouched.
export function fixMarkdownEmphasis(md: string): string {
  if (!md.includes("`") || !md.includes("*")) return md;
  const lines = md.split("\n");
  let fence: { ch: string; len: number } | null = null;
  let changed = false;

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li]!;
    const f = parseFence(line);
    if (fence === null) {
      if (f !== null && !(f.ch === "`" && f.rest.includes("`"))) {
        fence = { ch: f.ch, len: f.len };
        continue;
      }
    } else {
      if (f !== null && f.ch === fence.ch && f.len >= fence.len && f.rest.trim() === "") {
        fence = null;
      }
      continue;
    }
    if (!line.includes("`") || !line.includes("*")) continue;

    let out = "";
    let i = 0;
    let lineChanged = false;
    while (i < line.length) {
      const ch = line[i]!;
      if (ch === "\\") {
        out += line.slice(i, i + 2);
        i += 2;
        continue;
      }
      if (ch === "`") {
        let ticks = 0;
        while (i + ticks < line.length && line[i + ticks] === "`") ticks++;
        const close = findClosingTicks(line, i + ticks, ticks);
        if (close >= 0) {
          const spanEnd = close + ticks;
          // Opening side: `<non-ASCII><1..3 '*'>` immediately before code span, with matching `*` run after span.
          let leftStars = 0;
          while (leftStars < 3 && i - 1 - leftStars >= 0 && line[i - 1 - leftStars] === "*") leftStars++;
          const beforeStarsIdx = i - 1 - leftStars;
          if (
            leftStars >= 1 &&
            leftStars <= 3 &&
            beforeStarsIdx >= 0 &&
            line[beforeStarsIdx] !== "*" &&
            line[beforeStarsIdx] !== "\\" &&
            isNonAscii(line[beforeStarsIdx]!) &&
            hasStarRun(line, spanEnd, line.length, leftStars)
          ) {
            out += ZWSP;
            lineChanged = true;
          }
          out += line.slice(i, spanEnd);
          // Closing side: `<1..3 '*'><non-ASCII>` immediately after code span, with matching `*` run before span.
          let rightStars = 0;
          while (rightStars < 3 && spanEnd + rightStars < line.length && line[spanEnd + rightStars] === "*") rightStars++;
          const afterStarsIdx = spanEnd + rightStars;
          if (
            rightStars >= 1 &&
            rightStars <= 3 &&
            afterStarsIdx < line.length &&
            line[afterStarsIdx] !== "*" &&
            isNonAscii(line[afterStarsIdx]!) &&
            hasStarRun(line, 0, i, rightStars)
          ) {
            out += ZWSP;
            lineChanged = true;
          }
          i = spanEnd;
          continue;
        }
        out += line.slice(i, i + ticks);
        i += ticks;
        continue;
      }
      out += ch;
      i++;
    }
    if (lineChanged) {
      lines[li] = out;
      changed = true;
    }
  }
  return changed ? lines.join("\n") : md;
}

function styleObj(s: InlineStyle): InlineStyle | undefined {
  const out: InlineStyle = {};
  if (s.bold) out.bold = true;
  if (s.italic) out.italic = true;
  if (s.strike) out.strike = true;
  if (s.code) out.code = true;
  return Object.keys(out).length > 0 ? out : undefined;
}

function sameStyle(a: InlineStyle | undefined, b: InlineStyle | undefined): boolean {
  return Boolean(a?.bold) === Boolean(b?.bold) &&
    Boolean(a?.italic) === Boolean(b?.italic) &&
    Boolean(a?.strike) === Boolean(b?.strike) &&
    Boolean(a?.code) === Boolean(b?.code);
}

function pushText(out: Json[], text: string, style: InlineStyle) {
  if (text === "") return;
  const st = styleObj(style);
  const prev = out[out.length - 1];
  if (prev?.type === "text" && sameStyle(prev.style, st)) {
    prev.text += text;
    return;
  }
  out.push(st ? { type: "text", text, style: st } : { type: "text", text });
}

function isAllowedUrl(url: string): boolean {
  if (url === "" || /[\s<>]/.test(url)) return false;
  return /^(https?:\/\/|mailto:|slack:\/\/)/i.test(url);
}

/// Parses Slack angle-bracket tokens (`<@U…>`, `<#C…>`, `<!subteam^S…>`, `<!here>`, `<https://…|label>`).
function parseSlackToken(s: string, at: number, style: InlineStyle): { node: Json; next: number } | null {
  const end = s.indexOf(">", at + 1);
  if (end < 0) return null;
  const body = s.slice(at + 1, end);
  if (body === "" || body.includes("<") || body.includes("\n")) return null;
  const st = styleObj(style);
  const withStyle = (node: Json) => (st ? { ...node, style: st } : node);

  if (body.startsWith("@")) {
    const id = body.slice(1).split("|")[0]!;
    if (/^[A-Z0-9]+$/.test(id)) return { node: withStyle({ type: "user", user_id: id }), next: end + 1 };
    return null;
  }
  if (body.startsWith("#")) {
    const id = body.slice(1).split("|")[0]!;
    if (/^[A-Z0-9]+$/.test(id)) return { node: withStyle({ type: "channel", channel_id: id }), next: end + 1 };
    return null;
  }
  if (body.startsWith("!subteam^")) {
    const id = body.slice("!subteam^".length).split("|")[0]!;
    if (/^[A-Z0-9]+$/.test(id)) return { node: withStyle({ type: "usergroup", usergroup_id: id }), next: end + 1 };
    return null;
  }
  if (body === "!here" || body === "!channel" || body === "!everyone") {
    return { node: withStyle({ type: "broadcast", range: body.slice(1) }), next: end + 1 };
  }
  const pipe = body.indexOf("|");
  const url = pipe >= 0 ? body.slice(0, pipe) : body;
  const label = pipe >= 0 ? body.slice(pipe + 1) : "";
  if (isAllowedUrl(url)) {
    const node: Json = label !== "" ? { type: "link", url, text: label } : { type: "link", url };
    return { node: withStyle(node), next: end + 1 };
  }
  return null;
}

/// Parses a Markdown link `[label](url)` with balanced parentheses in `url`.
function parseMarkdownLink(s: string, at: number, style: InlineStyle): { node: Json; next: number } | null {
  // Find matching `]` skipping code spans and escapes.
  let i = at + 1;
  let depth = 0;
  let closeBracket = -1;
  while (i < s.length) {
    const ch = s[i]!;
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === "`") {
      let ticks = 0;
      while (i + ticks < s.length && s[i + ticks] === "`") ticks++;
      const close = findClosingTicks(s, i + ticks, ticks);
      if (close >= 0) {
        i = close + ticks;
        continue;
      }
      i += ticks;
      continue;
    }
    if (ch === "[") depth++;
    else if (ch === "]") {
      if (depth === 0) {
        closeBracket = i;
        break;
      }
      depth--;
    }
    i++;
  }
  if (closeBracket < 0 || s[closeBracket + 1] !== "(") return null;

  // Find matching `)` with balanced parentheses.
  let u = closeBracket + 2;
  let parens = 0;
  let closeParen = -1;
  while (u < s.length) {
    const ch = s[u]!;
    if (ch === "\\") {
      u += 2;
      continue;
    }
    if (ch === "(") parens++;
    else if (ch === ")") {
      if (parens === 0) {
        closeParen = u;
        break;
      }
      parens--;
    } else if (isAsciiWs(ch)) {
      break;
    }
    u++;
  }
  if (closeParen < 0) return null;
  let url = s.slice(closeBracket + 2, closeParen).trim();
  if (url.startsWith("<") && url.endsWith(">")) url = url.slice(1, -1);
  if (!isAllowedUrl(url)) return null;

  // Unwrap simple full-label inline formatting (e.g. `[**bold**](url)` or `` [`code`](url) ``).
  let label = s.slice(at + 1, closeBracket);
  const linkStyle: InlineStyle = { ...style };
  for (;;) {
    if (label.length >= 4 && label.startsWith("**") && label.endsWith("**") && !label.slice(2, -2).includes("**")) {
      linkStyle.bold = true;
      label = label.slice(2, -2);
    } else if (label.length >= 4 && label.startsWith("~~") && label.endsWith("~~") && !label.slice(2, -2).includes("~~")) {
      linkStyle.strike = true;
      label = label.slice(2, -2);
    } else if (label.length >= 2 && label.startsWith("`") && label.endsWith("`") && !label.slice(1, -1).includes("`")) {
      linkStyle.code = true;
      label = label.slice(1, -1);
    } else if (label.length >= 2 && label.startsWith("*") && label.endsWith("*") && !label.slice(1, -1).includes("*")) {
      linkStyle.italic = true;
      label = label.slice(1, -1);
    } else {
      break;
    }
  }
  const st = styleObj(linkStyle);
  const node: Json = label !== "" ? { type: "link", url, text: label } : { type: "link", url };
  return { node: st ? { ...node, style: st } : node, next: closeParen + 1 };
}

/// Finds a matching closing emphasis delimiter (`***`, `**`, `*`, `__`, `_`, `~~`), skipping inline code spans,
/// escaped characters, and whitespace immediately inside the closing delimiter.
function findClosingDelim(s: string, from: number, delim: string, wordBoundary: boolean): number {
  const ch = delim[0]!;
  const len = delim.length;
  let i = from;
  while (i < s.length) {
    const c = s[i]!;
    if (c === "\\") {
      i += 2;
      continue;
    }
    if (c === "`") {
      let ticks = 0;
      while (i + ticks < s.length && s[i + ticks] === "`") ticks++;
      const close = findClosingTicks(s, i + ticks, ticks);
      if (close >= 0) {
        i = close + ticks;
        continue;
      }
      i += ticks;
      continue;
    }
    if (c === ch) {
      let run = 0;
      while (i + run < s.length && s[i + run] === ch) run++;
      if (run === len && i > from) {
        const before = s[i - 1]!;
        const after = s[i + len];
        if (!isAsciiWs(before) && (!wordBoundary || after === undefined || !isAsciiAlnum(after))) {
          return i;
        }
      }
      i += run;
      continue;
    }
    i++;
  }
  return -1;
}

/// Parses inline Markdown into Slack `rich_text_section` elements with CJK-friendly emphasis matching.
export function parseInlineToRichText(s: string, style: InlineStyle = {}, out: Json[] = []): Json[] {
  let i = 0;
  while (i < s.length) {
    const ch = s[i]!;

    // Backslash escape for inline Markdown punctuation.
    if (ch === "\\" && i + 1 < s.length && "*_`~[]\\".includes(s[i + 1]!)) {
      pushText(out, s[i + 1]!, style);
      i += 2;
      continue;
    }

    // Inline code span.
    if (ch === "`") {
      let ticks = 0;
      while (i + ticks < s.length && s[i + ticks] === "`") ticks++;
      const close = findClosingTicks(s, i + ticks, ticks);
      if (close >= 0) {
        let code = s.slice(i + ticks, close);
        if (code.length >= 2 && code.startsWith(" ") && code.endsWith(" ") && code.trim() !== "") {
          code = code.slice(1, -1);
        }
        pushText(out, code, { ...style, code: true });
        i = close + ticks;
        continue;
      }
      pushText(out, s.slice(i, i + ticks), style);
      i += ticks;
      continue;
    }

    // Slack tokens (`<@U…>`, `<#C…>`, `<!here>`, `<https://…|label>`).
    if (ch === "<") {
      const tok = parseSlackToken(s, i, style);
      if (tok !== null) {
        out.push(tok.node);
        i = tok.next;
        continue;
      }
    }

    // Markdown link `[label](url)`.
    if (ch === "[") {
      const link = parseMarkdownLink(s, i, style);
      if (link !== null) {
        out.push(link.node);
        i = link.next;
        continue;
      }
    }

    // Strikethrough `~~...~~`.
    if (ch === "~" && s[i + 1] === "~" && s[i + 2] !== "~" && i + 2 < s.length && !isAsciiWs(s[i + 2]!)) {
      const close = findClosingDelim(s, i + 2, "~~", false);
      if (close >= 0) {
        parseInlineToRichText(s.slice(i + 2, close), { ...style, strike: true }, out);
        i = close + 2;
        continue;
      }
    }

    // Emphasis `*`, `**`, `***`.
    if (ch === "*") {
      let run = 0;
      while (i + run < s.length && s[i + run] === "*") run++;
      if (run >= 1 && run <= 3 && i + run < s.length && !isAsciiWs(s[i + run]!)) {
        const delim = "*".repeat(run);
        const close = findClosingDelim(s, i + run, delim, false);
        if (close >= 0) {
          const nextStyle: InlineStyle = {
            ...style,
            ...(run >= 2 ? { bold: true } : {}),
            ...(run === 1 || run === 3 ? { italic: true } : {}),
          };
          parseInlineToRichText(s.slice(i + run, close), nextStyle, out);
          i = close + run;
          continue;
        }
      }
      pushText(out, s.slice(i, i + run), style);
      i += run;
      continue;
    }

    // Underscore emphasis `_`, `__` (word-boundary guarded so snake_case stays literal).
    if (ch === "_") {
      let run = 0;
      while (i + run < s.length && s[i + run] === "_") run++;
      const prev = i > 0 ? s[i - 1] : undefined;
      if (run >= 1 && run <= 2 && (prev === undefined || !isAsciiAlnum(prev)) && i + run < s.length && !isAsciiWs(s[i + run]!)) {
        const delim = "_".repeat(run);
        const close = findClosingDelim(s, i + run, delim, true);
        if (close >= 0) {
          const nextStyle: InlineStyle = { ...style, ...(run === 2 ? { bold: true } : { italic: true }) };
          parseInlineToRichText(s.slice(i + run, close), nextStyle, out);
          i = close + run;
          continue;
        }
      }
      pushText(out, s.slice(i, i + run), style);
      i += run;
      continue;
    }

    pushText(out, ch, style);
    i++;
  }
  return out;
}

/// Builds Slack `rich_text_list` elements with proper `indent` and `offset` tracking across nested lists.
function buildRichTextLists(items: ListItem[]): Json[] {
  type Level = { rawIndent: number; style: "ordered" | "bullet"; count: number; baseOffset: number };
  const stack: Level[] = [];
  const lists: Json[] = [];

  for (const item of items) {
    // Pop deeper levels.
    while (stack.length > 1 && stack[stack.length - 1]!.rawIndent > item.rawIndent) {
      stack.pop();
    }
    const top = stack[stack.length - 1];
    if (top === undefined) {
      stack.push({
        rawIndent: item.rawIndent,
        style: item.style,
        count: 0,
        baseOffset: item.style === "ordered" ? Math.max(0, item.startNum - 1) : 0,
      });
    } else if (item.rawIndent >= top.rawIndent + 2) {
      stack.push({
        rawIndent: item.rawIndent,
        style: item.style,
        count: 0,
        baseOffset: item.style === "ordered" ? Math.max(0, item.startNum - 1) : 0,
      });
    } else if (top.style !== item.style) {
      stack[stack.length - 1] = {
        rawIndent: top.rawIndent,
        style: item.style,
        count: 0,
        baseOffset: item.style === "ordered" ? Math.max(0, item.startNum - 1) : 0,
      };
    }

    const level = stack[stack.length - 1]!;
    const indent = Math.min(stack.length - 1, MAX_SLACK_INDENT);
    const elements = parseInlineToRichText(item.text);
    const section: Json = {
      type: "rich_text_section",
      elements: elements.length > 0 ? elements : [{ type: "text", text: " " }],
    };

    const prev = lists[lists.length - 1];
    if (prev !== undefined && prev.style === item.style && prev.indent === indent) {
      prev.elements.push(section);
    } else {
      const listNode: Json = { type: "rich_text_list", style: item.style, indent, elements: [section] };
      if (item.style === "ordered") {
        const offset = level.baseOffset + level.count;
        if (offset > 0) listNode.offset = offset;
      }
      lists.push(listNode);
    }
    level.count++;
  }

  return lists;
}

/// True when a list group hits Slack's markdown-block ordered-list bugs (nested sub-items under/with an ordered list,
/// blank lines between ordered items, mixed styles, or a starting number other than 1).
function listNeedsRichText(items: ListItem[], hasBlankBetween: boolean): boolean {
  let hasOrdered = false;
  let firstIndent = items[0]!.rawIndent;
  let hasNested = false;
  let hasMixedStyle = false;
  let hasNonOneStart = false;
  const firstStyle = items[0]!.style;

  // Track ordered run starts at each indent level.
  const indentStack: { rawIndent: number; style: "ordered" | "bullet" }[] = [];
  for (const item of items) {
    if (item.style === "ordered") hasOrdered = true;
    if (item.rawIndent >= firstIndent + 2) hasNested = true;
    if (item.style !== firstStyle) hasMixedStyle = true;

    while (indentStack.length > 1 && indentStack[indentStack.length - 1]!.rawIndent > item.rawIndent) {
      indentStack.pop();
    }
    const top = indentStack[indentStack.length - 1];
    const opened = top === undefined || item.rawIndent >= top.rawIndent + 2 || top.style !== item.style;
    if (opened) {
      if (item.style === "ordered" && item.startNum !== 1) hasNonOneStart = true;
      if (top === undefined || item.rawIndent >= top.rawIndent + 2) {
        indentStack.push({ rawIndent: item.rawIndent, style: item.style });
      } else {
        indentStack[indentStack.length - 1] = { rawIndent: top.rawIndent, style: item.style };
      }
    }
  }

  return hasOrdered && (hasNested || hasNonOneStart || hasBlankBetween || hasMixedStyle);
}

/// True when a non-list line cannot be an indented continuation of a list item (starts a block of its own).
function startsOwnBlock(line: string): boolean {
  const trimmed = line.trimStart();
  if (trimmed === "") return true;
  if (parseFence(trimmed) !== null) return true;
  if (/^#{1,6}[ \t]/.test(trimmed)) return true;
  if (trimmed.startsWith(">")) return true;
  if (trimmed.startsWith("|")) return true;
  if (isThematicBreak(trimmed)) return true;
  return false;
}

/// Converts Markdown into Slack Block Kit blocks: native `rich_text` blocks (with accurate `indent` and `offset`) for
/// ordered list groups that Slack's `markdown` block misnumbers, and `{ type: "markdown", text }` for everything else.
export function markdownBlocks(text: string): Json[] {
  const normalized = text.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  const blocks: Json[] = [];
  let mdLines: string[] = [];
  let hasRichText = false;
  let fence: { ch: string; len: number } | null = null;

  const flushMd = () => {
    while (mdLines.length > 0 && mdLines[0]!.trim() === "") mdLines.shift();
    while (mdLines.length > 0 && mdLines[mdLines.length - 1]!.trim() === "") mdLines.pop();
    if (mdLines.length > 0) {
      blocks.push({ type: "markdown", text: fixMarkdownEmphasis(mdLines.join("\n")) });
    }
    mdLines = [];
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i]!;
    const f = parseFence(line);
    if (fence === null) {
      if (f !== null && !(f.ch === "`" && f.rest.includes("`"))) {
        fence = { ch: f.ch, len: f.len };
        mdLines.push(line);
        i++;
        continue;
      }
    } else {
      if (f !== null && f.ch === fence.ch && f.len >= fence.len && f.rest.trim() === "") {
        fence = null;
      }
      mdLines.push(line);
      i++;
      continue;
    }

    const firstItem = parseListLine(line);
    if (firstItem === null) {
      mdLines.push(line);
      i++;
      continue;
    }

    // Collect contiguous list group (including loose blank lines between items and indented continuations).
    const items: ListItem[] = [firstItem];
    const startLine = i;
    let j = i + 1;
    let hasBlankBetween = false;
    while (j < lines.length) {
      const cur = lines[j]!;
      const parsed = parseListLine(cur);
      if (parsed !== null) {
        items.push(parsed);
        j++;
        continue;
      }
      if (cur.trim() === "") {
        let k = j + 1;
        while (k < lines.length && lines[k]!.trim() === "") k++;
        if (k < lines.length) {
          const after = parseListLine(lines[k]!);
          // Stay in the list group across blank lines unless an unrelated indent-0 list of a different style starts.
          if (after !== null && !(after.rawIndent <= firstItem.rawIndent && after.style !== firstItem.style)) {
            hasBlankBetween = true;
            j = k;
            continue;
          }
        }
        break;
      }
      const { rawIndent } = measureIndent(cur);
      const last = items[items.length - 1]!;
      if (rawIndent >= last.rawIndent + 2 && !startsOwnBlock(cur)) {
        last.text = `${last.text}\n${cur.trim()}`;
        j++;
        continue;
      }
      break;
    }

    if (listNeedsRichText(items, hasBlankBetween)) {
      flushMd();
      blocks.push({ type: "rich_text", elements: buildRichTextLists(items) });
      hasRichText = true;
    } else {
      for (let k = startLine; k < j; k++) mdLines.push(lines[k]!);
    }
    i = j;
  }

  if (!hasRichText) {
    return [{ type: "markdown", text: fixMarkdownEmphasis(text) }];
  }
  flushMd();
  if (blocks.length === 0 || blocks.length > MAX_SPLIT_BLOCKS) {
    return [{ type: "markdown", text: fixMarkdownEmphasis(text) }];
  }
  return blocks;
}
