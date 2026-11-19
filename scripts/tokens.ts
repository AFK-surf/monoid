// Writes the app's tokens (libs/sf-ui/src/tokens_data.mbt) from still.fail's type scale, lines and corners
// (web/ui/src/tokens.ts), so the web's pages and the app have one set; and holds still.fail's colours
// (web/ui/src/palette.ts) to what reads: each ink on the grounds it is drawn on, by WCAG 2.1's contrast ratio and
// APCA's Lc. `--check` fails when the file is not what the tokens make or a pair falls under its floor; `--report`
// prints every pair.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { PALETTE, TONE } from "../web/ui/src/palette.ts";
import { LEADING, RADII, TYPE_SCALE } from "../web/ui/src/tokens.ts";

const at = (p: string) => fileURLToPath(new URL(`../${p}`, import.meta.url));
const out = at("libs/sf-ui/src/tokens_data.mbt");

// --- the app's tokens

const num = (n: number) => (Number.isInteger(n) ? `${n}.0` : `${n}`);
const lets: [string, number][] = [];
for (const screen of ["wide", "narrow"] as const)
  for (const [role, t] of Object.entries(TYPE_SCALE[screen])) {
    lets.push([`token_${screen}_${role}`, t.size], [`token_${screen}_${role}_line`, t.line]);
  }
for (const [name, n] of Object.entries(LEADING)) lets.push([`token_leading_${name}`, n]);
for (const [name, n] of Object.entries(RADII.app)) lets.push([`token_${name}`, n]);
const text =
  "// Made by scripts/tokens.ts from web/ui/src/tokens.ts: do not edit.\n" +
  lets.map(([name, n]) => `\n///|\nlet ${name} : Double = ${num(n)}\n`).join("");

// --- contrast

type Theme = "light" | "dark";
type Rgba = [number, number, number, number];
const rgba = (c: string): Rgba => {
  const h = c.slice(1).padEnd(8, "F");
  return [0, 2, 4, 6].map((i) => parseInt(h.slice(i, i + 2), 16) / 255) as Rgba;
};
/** A colour of the palette, drawn over `under` (opaque): a tone's ground is its ink at the theme's opacity. */
const over = (theme: Theme, name: string, under: Rgba): Rgba => {
  const v = (PALETTE[theme] as Record<string, string | { tone: string }>)[name];
  if (v === undefined) throw new Error(`web/ui/src/palette.ts has no ${name} for ${theme}`);
  const [r, g, b, a0] = typeof v === "string" ? rgba(v) : rgba(v.tone);
  const a = typeof v === "string" ? a0 : TONE[theme];
  return [r * a + under[0] * (1 - a), g * a + under[1] * (1 - a), b * a + under[2] * (1 - a), 1];
};
const white: Rgba = [1, 1, 1, 1];
/** A ground: a name, or a name over a ground (a tone on the page). */
const ground = (theme: Theme, g: string): Rgba =>
  g.split(" on ").reverse().reduce<Rgba>((under, name) => over(theme, name, under), over(theme, "bg", white));

// WCAG 2.1: relative luminance and contrast ratio
const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const luminance = ([r, g, b]: Rgba) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
const ratio = (a: Rgba, b: Rgba) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
};
// APCA (APCA-W3 0.0.98G-4g): Lc of text on a ground, positive dark on light, negative light on dark
const apca = (text: Rgba, bg: Rgba) => {
  const y = ([r, g, b]: Rgba) => {
    const v = 0.2126729 * r ** 2.4 + 0.7151522 * g ** 2.4 + 0.072175 * b ** 2.4;
    return v > 0.022 ? v : v + (0.022 - v) ** 1.414;
  };
  const [yt, yb] = [y(text), y(bg)];
  if (Math.abs(yb - yt) < 0.0005) return 0;
  if (yb > yt) {
    const s = (yb ** 0.56 - yt ** 0.57) * 1.14;
    return s < 0.1 ? 0 : (s - 0.027) * 100;
  }
  const s = (yb ** 0.65 - yt ** 0.62) * 1.14;
  return s > -0.1 ? 0 : (s + 0.027) * 100;
};

/**
 * What is held, each at what the faintest of its pairs reads now, so no colour fades further. Words (each ink on
 * every ground it is drawn on): WCAG's AA for text, 4.5:1; APCA Lc 52, the dark theme's muted on a card (light on
 * dark scores lower on APCA than on WCAG; Lc 45 is APCA's least for any text people read, 60 for a body's). A line (a
 * divider, a quiet ground) is seen, not read: 1.13:1, the dark theme's neutral_bg on its sidebar; APCA gives none (it
 * puts what is under Lc 7.5 at 0), so it has no floor there.
 */
const floors = { words: { wcag: 4.5, apca: 52 }, line: { wcag: 1.13, apca: 0 } };
const grounds = ["bg", "card", "sidebar", "paper"];
const inks = ["text", "muted", "accent_text", "red", "green_ink", "warn_ink", "blue", "purple"];
const pairs: { kind: keyof typeof floors; ink: string; ground: string }[] = [
  ...inks.flatMap((ink) => grounds.map((g) => ({ kind: "words" as const, ink, ground: g }))),
  // each tone's ink on its own ground, on the page and on a card
  ...[["accent_text", "accent_bg"], ["red", "red_bg"], ["green_ink", "green_bg"], ["warn_ink", "amber_bg"],
    ["blue", "blue_bg"], ["purple", "purple_bg"]].flatMap(([ink, tone]) =>
    ["bg", "card"].map((g) => ({ kind: "words" as const, ink: ink!, ground: `${tone} on ${g}` }))),
  { kind: "words", ink: "on_primary", ground: "primary" },
  { kind: "words", ink: "text", ground: "neutral_bg on bg" },
  { kind: "words", ink: "text", ground: "selected" },
  ...["line", "line_strong", "neutral_bg"].flatMap((ink) =>
    grounds.map((g) => ({ kind: "line" as const, ink, ground: g }))),
];
const rows = (["light", "dark"] as const).flatMap((theme) =>
  pairs.map(({ kind, ink, ground: g }) => {
    const bg = ground(theme, g);
    const fg = over(theme, ink, bg);
    const w = ratio(fg, bg);
    const lc = apca(fg, bg);
    const f = floors[kind];
    return { theme, kind, ink, ground: g, wcag: w, apca: lc, ok: w >= f.wcag && Math.abs(lc) >= f.apca };
  }));
const low = rows.filter((r) => !r.ok);

if (process.argv.includes("--report")) {
  console.log("theme  kind   ink           ground                 WCAG    APCA Lc");
  for (const r of rows)
    console.log(`${r.theme.padEnd(6)} ${r.kind.padEnd(6)} ${r.ink.padEnd(13)} ${r.ground.padEnd(22)} ${r.wcag.toFixed(2).padStart(5)}:1 ${r.apca.toFixed(1).padStart(7)}${r.ok ? "" : "  under its floor"}`);
  for (const kind of Object.keys(floors) as (keyof typeof floors)[]) {
    const of = rows.filter((r) => r.kind === kind);
    const w = of.reduce((a, b) => (b.wcag < a.wcag ? b : a));
    const l = of.reduce((a, b) => (Math.abs(b.apca) < Math.abs(a.apca) ? b : a));
    console.log(`${kind}: least WCAG ${w.wcag.toFixed(2)}:1 (${w.theme} ${w.ink} on ${w.ground}), least |Lc| ${Math.abs(l.apca).toFixed(1)} (${l.theme} ${l.ink} on ${l.ground}); floors ${floors[kind].wcag}:1, Lc ${floors[kind].apca}`);
  }
}
if (process.argv.includes("--check")) {
  let was = "";
  try { was = readFileSync(out, "utf8"); } catch {}
  if (was !== text) { console.error(`not what web/ui/src/tokens.ts makes: ${out} — run node scripts/tokens.ts`); process.exit(1); }
  if (low.length) {
    for (const r of low) console.error(`${r.theme}: ${r.ink} on ${r.ground} reads ${r.wcag.toFixed(2)}:1, Lc ${r.apca.toFixed(1)}: under ${r.kind}' floor (${floors[r.kind].wcag}:1, Lc ${floors[r.kind].apca}) — web/ui/src/palette.ts`);
    process.exit(1);
  }
} else if (!process.argv.includes("--report")) writeFileSync(out, text);
