import { globalStyle, style } from "@vanilla-extract/css";
import { vars } from "@stillfail/ui/styles/tokens.css.ts";

// The admin console. Only names are bold and only what is off is coloured; rows stand apart by spacing, with no rules.

const NARROW = "(max-width: 700px)";

export const accountEmail = style({
  fontSize: vars.textMeta, color: vars.muted, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
});
export const adminFoot = style({ padding: "8px" });
export const adminAccount = style({
  flex: "1", minWidth: "0", display: "flex", alignItems: "center", gap: "8px", padding: "0 6px",
});

// ── a list, and the item open beside it ──
export const split = style({
  flex: "1", minHeight: "0", display: "grid", gridTemplateColumns: "minmax(0, 1fr)",
  selectors: { "&[data-open]": { gridTemplateColumns: "minmax(0, 1fr) 380px" } },
  "@media": { [NARROW]: { selectors: { "&[data-open]": { gridTemplateColumns: "minmax(0, 1fr)" } } } },
});
export const listPage = style({
  "@media": { [NARROW]: { selectors: { [`${split}[data-open] &`]: { display: "none" } } } },
});
export const mid = style({});
globalStyle(`${mid} > *`, { maxWidth: "760px", marginLeft: "auto", marginRight: "auto" });
export const total = style({ marginLeft: "10px", fontSize: vars.textBody, fontWeight: "400", color: vars.subtle, fontVariantNumeric: "tabular-nums" });

/** The search, then the area and the order; on a phone the search a line of its own over the two. */
export const toolbar = style({
  display: "flex", gap: "12px", alignItems: "center",
  "@media": { [NARROW]: { flexWrap: "wrap", rowGap: "8px" } },
});
export const search = style({
  flex: "1",
  "@media": { [NARROW]: { flexBasis: "100%" } },
});
export const sort = style({ flex: "none", display: "flex", alignItems: "center", gap: "6px", fontSize: vars.textUi });
export const sortBy = style({ whiteSpace: "nowrap" });
export const filters = style({ margin: "12px 0 16px" });

export const list = style({ display: "grid", gap: "2px" });
export const empty = style({ margin: "24px 12px", fontSize: vars.textUi, color: vars.muted });
export const row = style({
  display: "flex", alignItems: "center", gap: "12px", minWidth: "0", padding: "8px 12px", borderRadius: vars.rNav,
  color: vars.text, cornerShape: vars.cornerShape, transition: `background ${vars.dur} ${vars.easeOut}`,
  selectors: {
    "&:not([data-static]):hover": { background: vars.hover },
    "&[aria-current=page]": { background: vars.selected },
  },
});
export const rowText = style({ flex: "1", minWidth: "0", display: "grid" });
export const rowLine1 = style({
  display: "flex", alignItems: "center", gap: "8px", minWidth: "0", fontSize: vars.textUi, lineHeight: "22px",
  // (narrow, a title with its marks wraps them and the time under it, from the row's start, rather than being cut to a
  // word: rowTail)
  "@media": { [NARROW]: { flexWrap: "wrap", rowGap: "4px" } },
});
/** A row's marks and its time: after its title, the time at the line's end; where they do not fit beside the title
 * (narrow), a line of their own. */
export const rowTail = style({ flex: "1 0 auto", display: "flex", alignItems: "center", gap: "8px" });
globalStyle(`${rowLine1} > b`, { fontWeight: "600", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const rowTime = style({
  marginLeft: "auto", flex: "none", display: "flex", alignItems: "center", gap: "6px", fontSize: vars.textMeta, color: vars.subtle, whiteSpace: "nowrap",
});
export const rowLine2 = style({ fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const code = style({ fontSize: vars.textBody, letterSpacing: ".04em" });
export const keyPrefix = style({
  flex: "none", padding: "1px 6px", borderRadius: vars.rOption, background: vars.sidebar, fontSize: vars.textMeta, color: vars.muted,
});
export const vaultTip = style({
  display: "grid", gap: "4px", padding: "10px 12px", borderRadius: vars.rOption, background: vars.sidebar,
  fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted, cornerShape: vars.cornerShape,
});
globalStyle(`${vaultTip} > b`, { fontSize: vars.textUi, fontWeight: "600", color: vars.text });
globalStyle(`${vaultTip} > ul`, { margin: "2px 0 0", paddingLeft: "18px", display: "grid", gap: "2px" });
export const wsMark = style({
  flex: "none", width: "28px", height: "28px", display: "grid", placeItems: "center", borderRadius: "9px", background: vars.paper,
  fontSize: vars.textUi, fontWeight: "600", cornerShape: vars.cornerShape,
});
export const wsMarkLarge = style({ width: "40px", height: "40px", borderRadius: "12px", fontSize: vars.textTitle });
export const more = style({
  margin: "8px auto 0", height: "32px", padding: "0 14px", color: vars.muted, fontSize: vars.textMeta,
  selectors: { "&:hover": { color: vars.text } },
});

// ── an item's page ──
export const detail = style({
  minHeight: "0", overflowY: "auto", display: "flex", flexDirection: "column", gap: "2px", padding: "28px 24px 40px",
  background: vars.sidebar, fontSize: vars.textUi,
  "@media": { [NARROW]: { padding: "24px 18px 60px" } },
});
export const detailHead = style({ display: "flex", alignItems: "flex-start", gap: "12px", marginBottom: "18px" });
export const detailTitle = style({ flex: "1", minWidth: "0", display: "grid" });
globalStyle(`${detailTitle} > b`, { fontSize: vars.textTitle, fontWeight: "600", overflow: "hidden", textOverflow: "ellipsis" });
globalStyle(`${detailTitle} > span`, { fontSize: vars.textMeta, color: vars.muted, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const close = style({
  alignSelf: "flex-start", display: "grid", placeItems: "center", width: "28px", height: "28px", borderRadius: "50%", color: vars.muted,
  selectors: { "&:hover": { background: vars.hover, color: vars.text } },
  "@media": { [NARROW]: { display: "none" } },
});
export const kv = style({ display: "grid", gridTemplateColumns: "72px minmax(0, 1fr)", gap: "6px 12px", margin: "0 0 10px" });
globalStyle(`${kv} dt`, { color: vars.muted });
globalStyle(`${kv} dd`, { margin: "0", minWidth: "0", overflowWrap: "anywhere" });
export const group = style({ margin: "16px 0 4px", fontSize: vars.textMeta, color: vars.muted });
export const line = style({
  display: "flex", alignItems: "center", gap: "8px", minWidth: "0", minHeight: "36px", padding: "6px 12px", borderRadius: vars.rOption,
  background: vars.canvas, color: vars.text, cornerShape: vars.cornerShape,
  selectors: {
    "a&:hover": { background: vars.hover },
    "&[data-quiet]": { color: vars.muted },
    // (a button at its end, 32px: centred where a chevron of a row of words is, the row as tall as one, 36px)
    "&[data-tight]": { paddingTop: "2px", paddingBottom: "2px", paddingRight: "4px" },
  },
});
globalStyle(`${line} > svg`, { flex: "none", color: vars.subtle });
export const grow = style({ flex: "1", minWidth: "0", display: "grid", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const hint = style({ fontSize: vars.textMeta, color: vars.muted, whiteSpace: "normal", overflowWrap: "anywhere" });
/** A switch or buttons beside a title and its hint: on the title's line, however many lines the hint takes (never centred on them). */
export const switchLine = style({
  alignItems: "flex-start", paddingTop: "7px", paddingBottom: "7px",
  selectors: { "&[data-tight]": { paddingTop: "7px", paddingBottom: "7px", paddingRight: "4px" } },
});
export const switchTitle = style({ lineHeight: "22px" });
/** As tall as the title's line, so what it holds (a 32px button too) is centred on that line. */
export const switchBox = style({ flex: "none", height: "22px", display: "flex", alignItems: "center", gap: "8px" });
export const lineAside = style({ flex: "none", fontSize: vars.textMeta, color: vars.muted, whiteSpace: "nowrap" });
globalStyle(`${lineAside} [data-off]`, { color: vars.amber });
export const link = style({ color: vars.text, textDecoration: "underline", textDecorationColor: vars.lineStrong, textUnderlineOffset: "3px" });
export const actions = style({ display: "flex", flexWrap: "wrap", gap: "8px", marginTop: "20px" });
/** A command as wide as the dialog, scrolled within rather than spilling past it. */
export const command = style({ display: "grid", gridTemplateColumns: "minmax(0, 1fr)" });

// ── a bug report ──
export const fbNumber = style({ flex: "none", fontSize: vars.textMeta });
export const fbTitle = style({ minWidth: "0", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const fbBar = style({ display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap", marginBottom: "14px" });
export const fbBody = style({ whiteSpace: "pre-wrap", overflowWrap: "anywhere", padding: "10px 12px", borderRadius: vars.rOption, background: vars.canvas, cornerShape: vars.cornerShape });
export const fbContext = style({ gridTemplateColumns: "minmax(72px, max-content) minmax(0, 1fr)", fontSize: vars.textMeta });
export const fbLogs = style({
  margin: "0", maxHeight: "360px", overflow: "auto", padding: "10px 12px", borderRadius: vars.rOption, background: vars.canvas,
  cornerShape: vars.cornerShape, fontSize: vars.textMeta, lineHeight: "18px", whiteSpace: "pre", tabSize: 4,
});

// ── a bug report's replies: each its head (who, which side, delivered, when) over what it says ──
export const replies = style({ display: "grid", gap: "6px" });
export const reply = style({
  display: "grid", gap: "2px", padding: "8px 12px", borderRadius: vars.rOption, background: vars.canvas, cornerShape: vars.cornerShape, minWidth: "0",
});
export const replyHead = style({ display: "flex", alignItems: "center", gap: "8px", minWidth: "0", lineHeight: "22px" });
globalStyle(`${replyHead} > b`, { fontWeight: "600", minWidth: "0", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const replyDelivery = style({
  flex: "none", fontSize: vars.textMeta, color: vars.muted, whiteSpace: "nowrap",
  selectors: { "&[data-pending]": { color: vars.amber } },
});
export const replyTime = style({ marginLeft: "auto", flex: "none", fontSize: vars.textMeta, color: vars.subtle, whiteSpace: "nowrap" });
export const replyText = style({ whiteSpace: "pre-wrap", overflowWrap: "anywhere" });
export const replyForm = style({ display: "grid", gap: "8px", marginTop: "8px" });
export const replyInput = style({ resize: "vertical", minHeight: "76px", fontFamily: "inherit", lineHeight: "20px" });
export const replySend = style({ display: "flex", justifyContent: "flex-end" });

/** Giving a workspace's limits back: what it does, then the button, each on its own line. */
export const resetLimits = style({ display: "grid", justifyItems: "start", gap: "8px", marginTop: "4px" });

// ── the overview ──
export const stats = style({
  display: "grid", gridTemplateColumns: "repeat(4, minmax(0, 1fr))", gap: "8px", marginBottom: "8px",
  "@media": { [NARROW]: { gridTemplateColumns: "repeat(2, minmax(0, 1fr))" } },
});
export const stat = style({
  display: "grid", padding: "16px 18px", borderRadius: vars.rCard, background: vars.sidebar, color: vars.text, fontSize: vars.textMeta,
  cornerShape: vars.cornerShape, transition: `background ${vars.dur} ${vars.easeOut}`,
  selectors: { "&:hover": { background: vars.selected } },
});
export const statValue = style({ fontSize: vars.textDisplay, lineHeight: "40px", fontWeight: "600", fontVariantNumeric: "tabular-nums" });
export const statNote = style({ color: vars.subtle });
export const chart = style({ padding: "16px 18px 12px", borderRadius: vars.rCard, background: vars.sidebar, cornerShape: vars.cornerShape, marginBottom: "32px" });
export const chartHead = style({ display: "flex", alignItems: "baseline", gap: "8px", marginBottom: "12px", fontSize: vars.textUi });
globalStyle(`${chartHead} > b`, { fontWeight: "600" });
globalStyle(`${chartHead} > span`, { fontSize: vars.textMeta });
export const bars = style({ display: "grid", gridTemplateColumns: "repeat(12, minmax(0, 1fr))", gap: "8px", height: "150px" });
export const bar = style({ display: "flex", flexDirection: "column", justifyContent: "flex-end", alignItems: "stretch", minHeight: "0" });
export const barCount = style({ fontSize: vars.textMeta, color: vars.subtle, textAlign: "center", lineHeight: "18px", fontVariantNumeric: "tabular-nums" });
export const barFill = style({
  minHeight: "3px", borderRadius: "6px", background: vars.lineStrong,
  selectors: { "&[data-now]": { background: vars.accent } },
});
export const barLabel = style({ marginTop: "6px", fontSize: vars.textCaption, lineHeight: "14px", color: vars.subtle, textAlign: "center", whiteSpace: "nowrap", overflow: "hidden" });
export const h2 = style({ marginTop: "0", marginBottom: "8px", paddingLeft: "12px", fontSize: vars.textBody, fontWeight: "600" });
export const todo = style({
  display: "flex", alignItems: "center", gap: "12px", minHeight: "44px", padding: "0 12px", borderRadius: vars.rNav, color: vars.text,
  fontSize: vars.textUi, cornerShape: vars.cornerShape,
  selectors: { "&:hover": { background: vars.hover } },
});
globalStyle(`${todo} > svg`, { marginLeft: "auto", flex: "none", color: vars.subtle });
export const todoText = style({ fontWeight: "500" });
export const todoHint = style({ fontSize: vars.textMeta, color: vars.muted, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });

// ── the relays: a card each (pages.css.ts card), its numbers, its load over time ──
export const relays = style({});
/** None to show: under the title, on its line (only the bottom margin: the page's column centres it, mid). */
export const relaysNone = style({ marginTop: "0", marginBottom: "0", fontSize: vars.textUi, color: vars.muted });
export const relay = style({ gap: "18px" });
/** One line high whether it has the button to take the relay off or not (the button stands over its line, centred on
 * it), so every card's lines below start alike. */
export const relayHead = style({ display: "flex", alignItems: "center", gap: "8px", minWidth: "0", height: "22px", fontSize: vars.textUi, lineHeight: "22px" });
globalStyle(`${relayHead} > b`, { fontWeight: "600", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" });
export const relaySeen = style({ marginLeft: "auto", flex: "none", fontSize: vars.textMeta, color: vars.subtle, whiteSpace: "nowrap" });
/** The head's tools: the range and issuing a token, wrapping under each other where the page is narrow. */
export const relaysTools = style({ display: "flex", alignItems: "center", justifyContent: "flex-end", flexWrap: "wrap", gap: "8px 12px" });
/** How a relay came onto the list, and the ways into it, each a line to take off. */
export const relayKept = style({ display: "grid", gap: "6px", minWidth: "0" });
export const relayHow = style({ fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted, overflowWrap: "anywhere" });
/** (a part breaks onto the next line whole: "负载按来源 IP 认定" never split in two) */
globalStyle(`${relayHow} > span`, { whiteSpace: "nowrap" });
/** The tokens made for relays not used yet: a card above the relays'. */
export const relayTokens = style({ gap: "8px", marginBottom: "10px" });
globalStyle(`${relayTokens} > b`, { fontSize: vars.textUi, fontWeight: "600", lineHeight: "22px" });
/** Its numbers side by side, as wide as each one's value, wrapping onto more lines where the card is narrow. */
export const relayNumbers = style({
  margin: "0", display: "flex", flexWrap: "wrap", gap: "12px 32px",
  "@media": { [NARROW]: { columnGap: "24px" } },
});
globalStyle(`${relayNumbers} dt`, { fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" });
globalStyle(`${relayNumbers} dd`, { margin: "0", fontSize: vars.textHeading, lineHeight: "30px", fontWeight: "600", whiteSpace: "nowrap" });
globalStyle(`${relayNumbers} dd[data-tone=amber]`, { color: vars.amber });
globalStyle(`${relayNumbers} dd[data-tone=red]`, { color: vars.red });

/** What the probes from China's carriers and Hong Kong found: a line of its own over the charts, each network's round
 * trip and loss side by side, wrapping where the card is narrow. */
export const probes = style({ display: "grid", gap: "6px", minWidth: "0" });
export const probesHead = style({ display: "flex", alignItems: "baseline", flexWrap: "wrap", gap: "4px 12px", fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted });
globalStyle(`${probesHead} > b`, { fontSize: vars.textUi, fontWeight: "500", color: vars.text });
globalStyle(`${probesHead} > span`, { marginLeft: "auto", color: vars.subtle, whiteSpace: "nowrap" });
export const probeItems = style({ margin: "0", display: "flex", flexWrap: "wrap", gap: "8px 28px" });
globalStyle(`${probeItems} dt`, { fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted, whiteSpace: "nowrap" });
globalStyle(`${probeItems} dd`, { margin: "0", fontSize: vars.textUi, lineHeight: "22px", fontWeight: "500", whiteSpace: "nowrap", fontVariantNumeric: "tabular-nums" });
globalStyle(`${probeItems} dd[data-tone=amber]`, { color: vars.amber });
globalStyle(`${probeItems} dd[data-tone=red]`, { color: vars.red });

// A series' colour, by its place in the chart (the first blue, the second the accent), for its line, wash and key.
export const seriesFirst = style({ vars: { "--series": vars.blue } });
export const seriesSecond = style({ vars: { "--series": vars.accent } });
/** The charts after the first, side by side where the card has the width (a lone one takes all of it). */
export const relayCharts = style({ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: "18px 32px", minWidth: "0" });
export const loadChart = style({ margin: "0", display: "grid", gap: "8px", minWidth: "0" });
export const loadHead = style({
  display: "flex", alignItems: "baseline", flexWrap: "wrap", gap: "4px 12px", fontSize: vars.textMeta, lineHeight: "18px", color: vars.muted,
});
globalStyle(`${loadHead} > b`, { fontSize: vars.textUi, fontWeight: "500", color: vars.text });
/** A series' name, its colour only in the short line before it (words stay in the text's colours). */
export const legend = style({
  display: "inline-flex", alignItems: "center", gap: "6px", whiteSpace: "nowrap",
  selectors: { "&::before": { content: "''", width: "12px", height: "2px", borderRadius: "1px", background: "var(--series)" } },
});
export const peak = style({ marginLeft: "auto", color: vars.subtle, whiteSpace: "nowrap", fontVariantNumeric: "tabular-nums" });
export const plot = style({ height: "96px", minWidth: "0" });
globalStyle(`${plot} > svg`, { display: "block", width: "100%", height: "100%", overflow: "visible" });
globalStyle(`${plot} g`, { color: "var(--series)" });
/** The foot (0) and the top (the peak): hairlines. */
export const rule = style({ stroke: vars.line, strokeWidth: 1 });
export const wash = style({ fill: "currentColor", fillOpacity: 0.1, stroke: "none" });
export const trace = style({ fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinejoin: "round", strokeLinecap: "round" });
export const ticks = style({ position: "relative", height: "16px", fontSize: vars.textCaption, lineHeight: "16px", color: vars.subtle, fontVariantNumeric: "tabular-nums" });
globalStyle(`${ticks} > span`, { position: "absolute", top: "0", transform: "translateX(-50%)", whiteSpace: "nowrap" });
globalStyle(`${ticks} > span[data-edge=start]`, { transform: "none" });
globalStyle(`${ticks} > span[data-edge=end]`, { transform: "translateX(-100%)" });
