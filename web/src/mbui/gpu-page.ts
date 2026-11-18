// The page shown in place of the app where the browser gives no WebGL 2 (gpu.ts says why): still.fail's ground and a
// card on it, how to turn graphics acceleration on in this browser, an address to copy where it has one, and 重试.
// Drawn by the page itself, the app never fetched: its colours are web/ui/src/palette.ts's, written out (the design
// system's CSS is the web pages' bundle, which this page does not load), light or dark as mbui.html's first script set
// the root (`data-theme`, else the system's); motion reduced as it set `data-reduced-motion`; the safe area by its vars
// (--safe-top …), which mbui.html sets.
import interLatin from "@fontsource-variable/inter/files/inter-latin-wght-normal.woff2?url";
import { browserOf, chineseFor, guideFor, type Words } from "./gpu.ts";

// The card's corner is 26; what sits in its corners (the steps' panel, 重试) is 6 in from its edge, so theirs is 20.
const STYLE = `
@font-face { font-family: "Inter"; src: url("${interLatin}") format("woff2"); font-weight: 100 900; font-display: swap; }
#gpu {
  --ground: #F5F3EF; --card: #FFFFFF; --panel: #F6F5F1; --ink: #24272B; --muted: #565B62; --line: #322D2424;
  --badge: #24272B13; --hover: #26211711; --primary: #24272B; --primary-hover: #41464C; --on-primary: #FFFFFF;
  --focus: #DC5929; --shadow: #13161B1A;
  position: fixed; inset: 0; overflow: auto; display: flex; box-sizing: border-box;
  padding: max(24px, var(--safe-top)) max(16px, var(--safe-right)) max(24px, var(--safe-bottom)) max(16px, var(--safe-left));
  background: var(--ground); color: var(--ink);
  font: 400 14px/20px "Inter", system-ui, -apple-system, "PingFang SC", "Noto Sans CJK SC", "Segoe UI", sans-serif;
  -webkit-font-smoothing: antialiased; text-size-adjust: 100%;
}
:root[data-theme="dark"] #gpu {
  --ground: #1F2023; --card: #26272B; --panel: #2C2D31; --ink: #E9E9EA; --muted: #A8AAAE; --line: #E9E9EA19;
  --badge: #E9E9EA0E; --hover: #FFFFFF0D; --primary: #ECEDED; --primary-hover: #D3D4D6; --on-primary: #1F2023;
  --focus: #E97342; --shadow: #00000040;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) #gpu {
    --ground: #1F2023; --card: #26272B; --panel: #2C2D31; --ink: #E9E9EA; --muted: #A8AAAE; --line: #E9E9EA19;
    --badge: #E9E9EA0E; --hover: #FFFFFF0D; --primary: #ECEDED; --primary-hover: #D3D4D6; --on-primary: #1F2023;
    --focus: #E97342; --shadow: #00000040;
  }
}
#gpu *, #gpu *::before { box-sizing: border-box; }
#gpu .card {
  margin: auto; width: 100%; max-width: 440px; padding: 6px; display: flex; flex-direction: column; gap: 6px;
  background: var(--card); border-radius: 26px; box-shadow: 0 0 0 1px var(--line), 0 8px 24px var(--shadow);
}
#gpu .head { padding: 18px 18px 8px; display: flex; flex-direction: column; gap: 12px; }
#gpu .mark { width: 32px; height: 32px; display: block; color: var(--ink); }
#gpu h1 { margin: 0; font-size: 18px; line-height: 26px; font-weight: 600; letter-spacing: -0.01em; text-wrap: balance; }
#gpu .lead { margin: 0; color: var(--muted); text-wrap: pretty; }
#gpu ol { list-style: none; margin: 0; padding: 4px 18px; background: var(--panel); border-radius: 20px; counter-reset: step; }
#gpu li { counter-increment: step; display: grid; grid-template-columns: 20px minmax(0, 1fr); column-gap: 12px; padding: 12px 0; }
#gpu li + li { border-top: 1px solid var(--line); }
/* the step's number on its first line, as tall as that line */
#gpu li::before {
  content: counter(step); width: 20px; height: 20px; border-radius: 999px; background: var(--badge); color: var(--muted);
  font-size: 12px; line-height: 20px; font-weight: 500; text-align: center; font-variant-numeric: tabular-nums;
}
#gpu b { font-weight: 500; }
#gpu .address { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 8px; }
#gpu code {
  font: 400 13px/20px ui-monospace, "SF Mono", Menlo, Consolas, monospace; padding: 4px 10px; border-radius: 999px;
  background: var(--card); box-shadow: 0 0 0 1px var(--line); overflow-wrap: anywhere; user-select: all;
}
#gpu .note { margin: 0; padding: 4px 18px 6px; color: var(--muted); font-size: 12px; line-height: 18px; text-wrap: pretty; }
#gpu .note b { color: var(--ink); overflow-wrap: anywhere; }
#gpu button {
  font: inherit; font-weight: 500; cursor: pointer; border: 0; margin: 0; -webkit-tap-highlight-color: transparent;
  border-radius: 999px; transition: background-color 150ms ease-out, transform 100ms ease-out;
}
#gpu button:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
#gpu button:active { transform: scale(0.97); }
#gpu .copy { height: 28px; padding: 0 12px; font-size: 12px; line-height: 28px; color: var(--ink); background: var(--card); box-shadow: 0 0 0 1px var(--line); }
#gpu .copy:hover { background: color-mix(in srgb, var(--ink) 6%, var(--card)); }
#gpu .retry { height: 40px; width: 100%; padding: 0 20px; color: var(--on-primary); background: var(--primary); }
#gpu .retry:hover { background: var(--primary-hover); }
:root[data-reduced-motion] #gpu button { transition: none; }
:root[data-reduced-motion] #gpu button:active { transform: none; }
`;

/** still.fail's mark in one colour (web/public/mark.svg's shape, its face cut out of it). */
const MARK = `<svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="M7.2 0h17.6A7.2 7.2 0 0 1 32 7.2v17.6a7.2 7.2 0 0 1-7.2 7.2H7.2A7.2 7.2 0 0 1 0 24.8V7.2A7.2 7.2 0 0 1 7.2 0ZM10.37 13.12a2.11 2.11 0 1 0 0 4.22a2.11 2.11 0 1 0 0-4.22ZM21.63 13.12a2.11 2.11 0 1 0 0 4.22a2.11 2.11 0 1 0 0-4.22ZM5.73 21.7a1.245 1.245 0 0 0 0 2.49h2.11a1.245 1.245 0 0 0 0-2.49ZM24.16 21.7a1.245 1.245 0 0 0 0 2.49h2.11a1.245 1.245 0 0 0 0-2.49Z"/></svg>`;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text) e.textContent = text;
  return e;
}

function words(into: HTMLElement, parts: Words[]): void {
  for (const p of parts) into.append(typeof p === "string" ? document.createTextNode(p) : el("b", "", p.b));
}

/** The address onto the clipboard: the browser's way, else the old one (a page not served securely has no
 *  navigator.clipboard). */
async function copied(address: string): Promise<boolean> {
  try {
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(address);
      return true;
    }
  } catch {
    // refused: the old way
  }
  const t = el("textarea");
  t.value = address;
  t.setAttribute("readonly", "");
  t.style.cssText = "position:fixed;left:-9999px;top:0;opacity:0";
  document.body.append(t);
  t.select();
  let done = false;
  try {
    done = document.execCommand("copy");
  } catch {
    done = false;
  }
  t.remove();
  return done;
}

let kept: string | null = null;
try {
  kept = localStorage.getItem("stillfail.prefs");
} catch {
  kept = null;
}

/** Puts the page up in place of the app (start.ts, where hasWebgl2 says no). */
export function showGpuGuide(): void {
  const zh = chineseFor(navigator.language || "", kept);
  const g = guideFor(browserOf(navigator.userAgent, "brave" in navigator), zh);
  document.documentElement.lang = zh ? "zh-CN" : "en";
  const style = el("style");
  style.textContent = STYLE;
  document.head.append(style);

  const page = el("main");
  page.id = "gpu";
  const card = el("div", "card");
  card.setAttribute("role", "alert");
  const head = el("div", "head");
  head.innerHTML = MARK;
  head.append(el("h1", "", g.title), el("p", "lead", g.lead));
  const list = el("ol");
  for (const step of g.steps) {
    const li = el("li");
    const body = el("div");
    words(body, step.words);
    const address = step.address;
    if (address) {
      const row = el("div", "address");
      const code = el("code", "", address);
      const copy = el("button", "copy", g.copy);
      copy.type = "button";
      copy.setAttribute("aria-live", "polite");
      let back = 0;
      copy.onclick = () => {
        void copied(address).then((ok) => {
          if (!ok) {
            // the address selected for the person to copy themselves
            const range = document.createRange();
            range.selectNodeContents(code);
            getSelection()?.removeAllRanges();
            getSelection()?.addRange(range);
          }
          copy.textContent = ok ? g.copied : g.copyBy;
          clearTimeout(back);
          back = window.setTimeout(() => { copy.textContent = g.copy; }, 1600); // (the word back once it was seen)
        });
      };
      row.append(code, copy);
      body.append(row);
    }
    li.append(body);
    list.append(li);
  }
  const note = el("p", "note");
  words(note, g.note);
  const retry = el("button", "retry", g.retry);
  retry.type = "button";
  retry.onclick = () => location.reload();
  card.append(head, list, note, retry);
  page.append(card);
  document.body.append(page);
}
