#!/bin/bash
# The gallery (src/gallery) built for the browser into OUT (default out/web): mbui's web host (host.js), the gallery
# minified as mbui's scripts/web.sh bundle makes it (app.js), and a page that starts them (index.html). The gallery's
# settings are the page's query, read by host.js as the program's environment (?MBUI_LG_PAGE=interactive&MBUI_DARK=1,
# MBUI_LG_CHROME=0); without MBUI_DARK the page asks for the system's look.
#   sh scripts/web.sh [OUT]
set -e
D="$(cd "$(dirname "$0")" && pwd)"
A=$(cd "$D/.." && pwd)
MBUI_DIR=$(cd "$A/../mbui" && pwd)
out=$(mkdir -p "${1:-out/web}" && cd "${1:-out/web}" && pwd)
APP=gallery MBUI_APP_MOD="$A" bash "$MBUI_DIR/scripts/web.sh" bundle "$out"
cat > "$out/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>ui.monoid — Liquid Glass</title>
<meta name="description" content="Liquid glass controls for mbui, ported from AndroidLiquidGlass: buttons, toggles, sliders, tabs, a dialog and the control center, in the browser.">
<!-- The gallery of ui.monoid's liquid glass (libs/liquid-glass, scripts/web.sh): mbui's web host drawing src/gallery
     on a canvas. Its ground is the wallpaper's own, light or dark, till the first frame covers it. -->
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #F2E9DD;
               overscroll-behavior: none; -webkit-tap-highlight-color: transparent; }
  html.dark, html.dark body { background: #101028; }
  #c { position: fixed; inset: 0; width: 100%; height: 100%; touch-action: none; display: block;
       user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
  #ime { position: fixed; left: 0; top: 0; width: 2px; height: 20px; opacity: 0; padding: 0; border: 0;
         resize: none; overflow: hidden; font-size: 16px; caret-color: transparent; color: transparent;
         background: transparent; outline: none; }
</style>
</head>
<body>
<canvas id="c"></canvas>
<textarea id="ime" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>
<script>
  (() => {
    // (the look: MBUI_DARK in the query, else the system's, put in the query for the program to read as it starts)
    const q = new URLSearchParams(location.search);
    if (!q.has("MBUI_DARK") && matchMedia("(prefers-color-scheme: dark)").matches) {
      q.set("MBUI_DARK", "1");
      history.replaceState(null, "", `${location.pathname}?${q}${location.hash}`);
    }
    document.documentElement.classList.toggle("dark", q.get("MBUI_DARK") === "1");
    for (const src of ["host.js", "app.js"]) {
      const s = document.createElement("script");
      s.src = src;
      s.async = false;
      document.body.appendChild(s);
    }
  })();
</script>
</body>
</html>
HTML
ls -la "$out"
