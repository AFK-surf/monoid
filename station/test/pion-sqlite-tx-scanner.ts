// Shared SQLite lexical static raw-transaction guard for `pion/station/packages/*/src/*.pion`.
// Extracted from `builders-index-pion-switch.test.ts` for reuse by `W8-E1` (`sessions_actors`) and `W8-F`.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

function unescapePionString(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    if (ch === "\\" && i + 1 < raw.length) {
      const next = raw[i + 1]!;
      if (next === "n") { out += "\n"; i++; continue; }
      if (next === "r") { out += "\r"; i++; continue; }
      if (next === "t") { out += "\t"; i++; continue; }
      if (next === '"' || next === "\\") { out += next; i++; continue; }
    }
    out += ch;
  }
  return out;
}

type SqlTok = { kind: "word"; upper: string } | { kind: "ident" } | { kind: "str" } | { kind: "semi" } | { kind: "other" };

function isSqlIdentStart(c: number): boolean {
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c >= 0x80;
}

function isSqlIdentPart(c: number): boolean {
  return isSqlIdentStart(c) || (c >= 48 && c <= 57) || c === 36;
}

function tokenizeSql(sql: string): SqlTok[] {
  const tokens: SqlTok[] = [];
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    const code = sql.charCodeAt(i);
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n" || ch === "\f" || ch === "\v" || code === 0xfeff) {
      i++;
      continue;
    }
    if (ch === "-" && i + 1 < n && sql[i + 1] === "-") {
      i += 2;
      while (i < n && sql[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && i + 1 < n && sql[i + 1] === "*") {
      i += 2;
      while (i + 1 < n && !(sql[i] === "*" && sql[i + 1] === "/")) i++;
      i = Math.min(i + 2, n);
      continue;
    }
    if (ch === "'" || ch === '"' || ch === "`") {
      const quote = ch;
      i++;
      while (i < n) {
        if (sql[i] === quote) {
          if (i + 1 < n && sql[i + 1] === quote) { i += 2; continue; }
          i++;
          break;
        }
        i++;
      }
      tokens.push({ kind: quote === "'" ? "str" : "ident" });
      continue;
    }
    if (ch === "[") {
      i++;
      while (i < n && sql[i] !== "]") i++;
      if (i < n) i++;
      tokens.push({ kind: "ident" });
      continue;
    }
    if (ch === ";") {
      tokens.push({ kind: "semi" });
      i++;
      continue;
    }
    if (isSqlIdentStart(code)) {
      const start = i;
      i++;
      while (i < n && isSqlIdentPart(sql.charCodeAt(i))) i++;
      tokens.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    tokens.push({ kind: "other" });
    i++;
  }
  return tokens;
}

/// Expression-scoped SQLite lexical static guard for `.pion` source files:
/// - Never leaks `inTriggerHeader`/`inTriggerBody` across statements, array elements, or functions:
///   trigger state only spans `+`-concatenated literals within the same expression (reset on `,`/`;`/`}`/`]`
///   or any newline whose previous line did not end with `+`).
/// - Inside a trigger body, an interpolated helper call (`+ helper(...) +`) is treated as completing a SQL
///   statement so the matching `" END;"` closes `inTriggerBody`, while any subsequent `BEGIN`/`COMMIT`/`END`/
///   `SAVEPOINT`/`RELEASE`/`ROLLBACK` outside the trigger body is immediately flagged.
export function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  // Collapse string-literal concatenations (`"ROLL" + "BACK"`, including across newlines) while
  // preserving line numbers so split-literal raw transaction SQL cannot bypass the guard.
  const normalized = source.replace(/"((?:\\.|[^"\\])*)"(\s*\+\s*)"((?:\\.|[^"\\])*)"/g, (_m, a: string, sep: string, b: string) => {
    const nlCount = (sep.match(/\n/g) ?? []).length;
    return `"${a}${b}"${"\n".repeat(nlCount)}`;
  });
  let collapsed = normalized;
  for (;;) {
    const next = collapsed.replace(/"((?:\\.|[^"\\])*)"(\s*\+\s*)"((?:\\.|[^"\\])*)"/g, (_m, a: string, sep: string, b: string) => {
      const nlCount = (sep.match(/\n/g) ?? []).length;
      return `"${a}${b}"${"\n".repeat(nlCount)}`;
    });
    if (next === collapsed) break;
    collapsed = next;
  }
  const lines = collapsed.split("\n");
  let inTriggerHeader = false;
  let inTriggerBody = false;
  let atTriggerStmtStart = false;
  let triggerParenDepth = 0;
  let prevLineEndedWithPlus = false;
  let parenDepth = 0;

  const resetTrigger = () => {
    inTriggerHeader = false;
    inTriggerBody = false;
    atTriggerStmtStart = false;
  };

  const scanGap = (gap: string) => {
    let sawTriggerBoundary = false;
    let sawTriggerPlus = false;
    for (let i = 0; i < gap.length; i++) {
      const ch = gap[i]!;
      if (ch === "(") {
        parenDepth++;
      } else if (ch === ")") {
        if ((inTriggerHeader || inTriggerBody) && parenDepth <= triggerParenDepth) sawTriggerBoundary = true;
        parenDepth = Math.max(0, parenDepth - 1);
      } else if ((inTriggerHeader || inTriggerBody) && parenDepth <= triggerParenDepth) {
        if (ch === ";" || ch === "}" || ch === "]" || ch === ",") sawTriggerBoundary = true;
        else if (ch === "+") sawTriggerPlus = true;
      }
    }
    if (sawTriggerBoundary) resetTrigger();
    else if (inTriggerBody && sawTriggerPlus) atTriggerStmtStart = true;
  };

  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx]!;
    const trimmed = line.trim();
    if (trimmed.startsWith("//")) continue;
    if (!prevLineEndedWithPlus && parenDepth <= triggerParenDepth) resetTrigger();

    const litRe = /"((?:\\.|[^"\\])*)"/g;
    let lastEnd = 0;
    let m: RegExpExecArray | null;
    while ((m = litRe.exec(line)) !== null) {
      const gap = line.slice(lastEnd, m.index);
      lastEnd = m.index + m[0].length;
      scanGap(gap);

      const literal = m[1]!;
      const afterLiteral = line.slice(lastEnd);
      const nextLineStartsWithPlus =
        afterLiteral.trim() === "" && (lines[idx + 1]?.trimStart().startsWith("+") ?? false);
      const isStandaloneMethodLiteral =
        !literal.includes("\\{") &&
        /^(?:release|savepoint)$/.test(unescapePionString(literal)) &&
        /(?:==|!=)\s*$/.test(gap) &&
        !afterLiteral.trimStart().startsWith("+") &&
        !nextLineStartsWithPlus;
      const tokens = tokenizeSql(unescapePionString(literal));
      if ((inTriggerHeader || inTriggerBody) && parenDepth > triggerParenDepth) {
        let argStmtStart = true;
        for (let t = 0; t < tokens.length; t++) {
          const tok = tokens[t]!;
          if (tok.kind === "semi") { argStmtStart = true; continue; }
          if (!argStmtStart) continue;
          argStmtStart = false;
          if (tok.kind === "word" && forbiddenHeads.has(tok.upper)) {
            if ((tok.upper === "RELEASE" || tok.upper === "SAVEPOINT") && isStandaloneMethodLiteral) {
              continue;
            }
            violations.push(`${filename}:${idx + 1}: forbidden raw transaction SQL "${tok.upper}" in literal "${literal}"`);
          }
        }
        continue;
      }
      let atStmtStart = true;

      for (let t = 0; t < tokens.length; t++) {
        const tok = tokens[t]!;
        if (inTriggerBody) {
          if (tok.kind === "semi") {
            atTriggerStmtStart = true;
          } else if (atTriggerStmtStart && tok.kind === "word" && tok.upper === "END") {
            inTriggerBody = false;
            atTriggerStmtStart = false;
            atStmtStart = false;
          } else {
            atTriggerStmtStart = false;
          }
          continue;
        }
        if (inTriggerHeader) {
          if (tok.kind === "word" && tok.upper === "BEGIN") {
            inTriggerHeader = false;
            inTriggerBody = true;
            atTriggerStmtStart = true;
          } else if (tok.kind === "semi") {
            inTriggerHeader = false;
            atStmtStart = true;
          }
          continue;
        }
        if (tok.kind === "semi") {
          atStmtStart = true;
          continue;
        }
        if (!atStmtStart) continue;
        atStmtStart = false;
        if (tok.kind !== "word") continue;

        if (tok.upper === "CREATE") {
          const t1 = tokens[t + 1];
          const t2 = tokens[t + 2];
          if (
            (t1?.kind === "word" && t1.upper === "TRIGGER") ||
            (t1?.kind === "word" && (t1.upper === "TEMP" || t1.upper === "TEMPORARY") && t2?.kind === "word" && t2.upper === "TRIGGER")
          ) {
            inTriggerHeader = true;
            triggerParenDepth = parenDepth;
          }
          continue;
        }

        if (forbiddenHeads.has(tok.upper)) {
          if (tok.upper === "END") {
            const next = tokens[t + 1];
            const isTxEnd = next === undefined || next.kind === "semi" || (next.kind === "word" && next.upper === "TRANSACTION");
            if (!isTxEnd) continue;
          }
          // Exempt only an exact standalone `"release"` / `"savepoint"` method-name literal with
          // no whitespace, no `\{...}` interpolation, and no `+` concatenation on either side.
          if ((tok.upper === "RELEASE" || tok.upper === "SAVEPOINT") && isStandaloneMethodLiteral) {
            continue;
          }
          violations.push(`${filename}:${idx + 1}: forbidden raw transaction SQL "${tok.upper}" in literal "${literal}"`);
        }
      }
    }
    const tail = line.slice(lastEnd);
    scanGap(tail);
    prevLineEndedWithPlus = tail.trimEnd().endsWith("+");
    if (!prevLineEndedWithPlus && parenDepth <= triggerParenDepth) resetTrigger();
  }
  return violations;
}

/// Scan all non-test `.pion` files in `srcDir` for forbidden raw SQLite transaction SQL.
/// Throws if `srcDir` does not exist so callers never get a false-green empty result.
export function scanPionDirForRawTxControl(srcDir: string): string[] {
  if (!existsSync(srcDir)) {
    throw new Error(`scanPionDirForRawTxControl: directory does not exist: ${srcDir}`);
  }
  const files = readdirSync(srcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion")).sort();
  const violations: string[] = [];
  for (const file of files) {
    violations.push(...findRawTxControlViolations(file, readFileSync(join(srcDir, file), "utf8")));
  }
  return violations;
}
