#!/usr/bin/env node
// Builds the ui.monoid.build multi-page static site and live mbui WebGL 2 embeds.
// Zero external npm dependencies.
//
// Usage:
//   node website/ui/build.mjs [--out dist/ui] [--skip-mbui]
//
// Page conventions (website/ui/pages/**/*.html):
//   Frontmatter comments at top of file:
//     <!-- title: ... -->          (required)
//     <!-- title-zh: ... -->       (optional, for EN/中文 title switching)
//     <!-- description: ... -->    (required)
//     <!-- page: <slug> -->        (optional; defaults to path slug, maps to assets/pages/<slug>.css)
//     <!-- body-class: ... -->     (optional)
//   Placeholders supported in pages & partials:
//     {{i:NAME}}                   -> <svg class="ico" aria-hidden="true"><use href="/assets/icons.svg#i-NAME"/></svg>
//     {{shot:NAME:ALT}}            -> <figure class="shot"><picture>...</picture></figure> (reads assets/shots/sizes.txt;
//                                     phone-* wrapped in .iphone hardware frame; graceful placeholder if shot not yet generated)
//     {{include:NAME}}             -> alone on a line: inlines website/ui/partials/NAME.html
//     {{page-style}}               -> alone on a line in head.html: inlines website/ui/assets/pages/<page>.css

import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../..");
const ORIGIN = "https://ui.monoid.build";
const REPO_URL = "https://github.com/AFK-surf/monoid";

const PAGES_DIR = resolve(HERE, "pages");
const PARTIALS_DIR = resolve(HERE, "partials");
const ASSETS_DIR = resolve(HERE, "assets");
const PAGE_CSS_DIR = resolve(ASSETS_DIR, "pages");
const SHOTS_DIR = resolve(ASSETS_DIR, "shots");

function parseArgs(argv) {
  let out = resolve(REPO, "dist/ui");
  let skipMbui = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--out" && argv[i + 1]) {
      out = resolve(REPO, argv[++i]);
    } else if (argv[i] === "--skip-mbui") {
      skipMbui = true;
    } else if (argv[i] === "--help" || argv[i] === "-h") {
      console.log("Usage: node website/ui/build.mjs [--out dist/ui] [--skip-mbui]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${argv[i]}`);
    }
  }
  return { out, skipMbui };
}

const esc = (s) =>
  String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

function walkHtml(dir, base = dir) {
  if (!existsSync(dir)) return [];
  const results = [];
  for (const entry of readdirSync(dir).sort()) {
    const full = resolve(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      results.push(...walkHtml(full, base));
    } else if (entry.endsWith(".html")) {
      results.push(relative(base, full).replaceAll("\\", "/"));
    }
  }
  return results;
}

function loadShotSizes() {
  const sizesPath = resolve(SHOTS_DIR, "sizes.txt");
  const map = new Map();
  if (!existsSync(sizesPath)) return map;
  for (const raw of readFileSync(sizesPath, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const parts = line.split(/\s+/);
    if (parts.length >= 3) {
      const w = Number.parseInt(parts[1], 10);
      const h = Number.parseInt(parts[2], 10);
      if (Number.isFinite(w) && Number.isFinite(h) && w > 0 && h > 0) {
        map.set(parts[0], { w, h });
      }
    }
  }
  return map;
}

function parsePageMeta(srcPath, relPath) {
  const raw = readFileSync(srcPath, "utf8");
  const meta = {};
  const bodyLines = [];
  let inHead = true;
  for (const line of raw.split(/\r?\n/)) {
    if (inHead) {
      const m = line.match(/^<!--\s*(title|title-zh|description|page|body-class):\s*(.*?)\s*-->$/);
      if (m) {
        meta[m[1]] = m[2];
        continue;
      }
      if (line.trim() === "") continue;
      inHead = false;
    }
    bodyLines.push(line);
  }
  if (!meta.title || !meta.description) {
    throw new Error(`${relPath}: missing <!-- title: ... --> or <!-- description: ... --> at top of file`);
  }
  const defaultSlug = relPath
    .replace(/\/index\.html$/, "")
    .replace(/\.html$/, "")
    .replaceAll("/", "-");
  return {
    title: meta.title,
    titleZh: meta["title-zh"] || meta.title,
    description: meta.description,
    page: meta.page || defaultSlug,
    bodyClass: meta["body-class"] ? ` class="${esc(meta["body-class"])}"` : "",
    body: bodyLines.join("\n"),
  };
}

function iconSvg(name) {
  return `<svg class="ico" aria-hidden="true"><use href="/assets/icons.svg#i-${esc(name)}"/></svg>`;
}

function wrapIphone(innerHtml, isDark) {
  const cls = isDark ? "iphone dark-screen" : "iphone";
  return (
    `<div class="${cls}"><figure class="body">` +
    `<i class="key l action"></i><i class="key l up"></i><i class="key l down"></i><i class="key r side"></i>` +
    `<div class="screen">` +
    `<div class="sbar" aria-hidden="true"><span class="clock">9:41</span><span class="island"></span>` +
    `<span class="sys">${iconSvg("signal")}${iconSvg("wifi")}${iconSvg("battery")}</span></div>` +
    innerHtml +
    `<div class="home" aria-hidden="true"></div></div></figure></div>`
  );
}

function renderShot(spec, shotSizes, shotCounter, pendingShots) {
  const idx = spec.indexOf(":");
  const name = (idx === -1 ? spec : spec.slice(0, idx)).trim();
  const alt = (idx === -1 ? "" : spec.slice(idx + 1)).trim();
  const isPhone = name.startsWith("phone-");
  const isDarkPhone = name.includes("-dark");
  const size = shotSizes.get(name);
  const fullPath = resolve(SHOTS_DIR, `${name}.webp`);

  if (!size || !existsSync(fullPath)) {
    pendingShots.add(name);
    const placeholder = `<figure class="shot shot-pending" data-shot="${esc(name)}"><div class="shot-pending-in"><code>{{shot:${esc(name)}}}</code><span>${esc(alt || "Offscreen WebP capture pending")}</span></div></figure>`;
    return isPhone ? wrapIphone(placeholder, isDarkPhone) : placeholder;
  }

  const { w, h } = size;
  const oneXExists = existsSync(resolve(SHOTS_DIR, `${name}-1x.webp`));
  const isFirst = shotCounter.count++ === 0;
  const loadAttr = isFirst ? ' fetchpriority="high"' : ' loading="lazy"';
  const srcAttr = oneXExists
    ? `src="/assets/shots/${name}-1x.webp" srcset="/assets/shots/${name}-1x.webp 1x, /assets/shots/${name}.webp 2x"`
    : `src="/assets/shots/${name}.webp"`;
  const img = `<picture><img ${srcAttr} alt="${esc(alt)}" width="${w}" height="${h}" decoding="async"${loadAttr}></picture>`;

  if (isPhone) {
    return wrapIphone(img, isDarkPhone);
  }
  return `<figure class="shot" style="max-width:${w}px">${img}</figure>`;
}

function expandTemplate(content, ctx, shotSizes, shotCounter, pendingShots) {
  // 1. Expand line-level {{page-style}} and {{include:NAME}}
  const lines = content.split(/\r?\n/);
  const inlined = [];
  for (const line of lines) {
    if (/^\s*\{\{page-style\}\}\s*$/.test(line)) {
      if (ctx.pageCss) {
        inlined.push("<style>");
        inlined.push(ctx.pageCss.trimEnd());
        inlined.push("</style>");
      }
      continue;
    }
    const inc = line.match(/^\s*\{\{include:([a-z0-9-]+)\}\}\s*$/);
    if (inc) {
      const pPath = resolve(PARTIALS_DIR, `${inc[1]}.html`);
      if (!existsSync(pPath)) {
        throw new Error(`Missing partial for {{include:${inc[1]}}}: ${pPath}`);
      }
      inlined.push(readFileSync(pPath, "utf8").trimEnd());
      continue;
    }
    inlined.push(line);
  }

  // 2. Expand scalar variables and {{i:NAME}} / {{shot:NAME:ALT}}
  let out = inlined.join("\n");
  out = out
    .replaceAll("{{title}}", esc(ctx.title))
    .replaceAll("{{title-zh}}", esc(ctx.titleZh))
    .replaceAll("{{description}}", esc(ctx.description))
    .replaceAll("{{here}}", esc(ctx.here))
    .replaceAll("{{page}}", esc(ctx.page))
    .replaceAll("{{body-class}}", ctx.bodyClass)
    .replaceAll("{{origin}}", ORIGIN)
    .replaceAll("{{repo}}", REPO_URL);

  out = out.replace(/\{\{(i|shot):([^}]+)\}\}/g, (_, kind, arg) => {
    if (kind === "i") return iconSvg(arg.trim());
    return renderShot(arg, shotSizes, shotCounter, pendingShots);
  });

  return out;
}

function renderLiquidGlassAppHtml() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>ui.monoid — Liquid Glass</title>
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #F5F5F7; }
  html[data-dark="1"], html[data-dark="1"] body { background: #0E0E10; }
  #c { position: fixed; inset: 0; width: 100%; height: 100%; touch-action: none; display: block; }
  #ime { position: fixed; left: 0; top: 0; width: 2px; height: 20px; opacity: 0; padding: 0; border: 0;
         resize: none; overflow: hidden; font-size: 16px; caret-color: transparent; color: transparent;
         background: transparent; outline: none; }
  #nogl { position: fixed; inset: 0; display: grid; place-items: center; padding: 24px;
          font: 400 14px/1.6 system-ui, sans-serif; color: #171717; background: #F7F7F6; }
  #nogl[hidden] { display: none; }
</style>
<script>
  if (new URLSearchParams(location.search).get("MBUI_DARK") === "1") {
    document.documentElement.dataset.dark = "1";
  }
</script>
</head>
<body>
<canvas id="c"></canvas>
<textarea id="ime" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>
<div id="nogl" hidden>WebGL 2 is required to render the mbui Liquid Glass gallery.</div>
<script>
  (function () {
    var ok = !!globalThis.__mbrender;
    if (!ok) {
      try {
        var gl = document.createElement("canvas").getContext("webgl2");
        if (gl) {
          ok = true;
          var lose = gl.getExtension("WEBGL_lose_context");
          if (lose) lose.loseContext();
        }
      } catch (e) {}
    }
    if (!ok) {
      document.getElementById("c").style.display = "none";
      document.getElementById("nogl").hidden = false;
      return;
    }
    ["host.js", "app.js"].forEach(function (src) {
      var s = document.createElement("script");
      s.src = src;
      s.async = false;
      document.body.appendChild(s);
    });
  })();
</script>
</body>
</html>
`;
}

function renderStubAppHtml(title) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
  html, body { margin: 0; height: 100%; display: grid; place-items: center;
               font: 500 14px/1.5 system-ui, sans-serif; background: #F7F7F6; color: #171717; }
</style>
</head>
<body>
<div>${esc(title)} (built with --skip-mbui)</div>
</body>
</html>
`;
}

function buildMbuiEmbeds(out, skipMbui) {
  const compAppDir = resolve(out, "components/app");
  const lgAppDir = resolve(out, "liquid-glass/app");
  mkdirSync(compAppDir, { recursive: true });
  mkdirSync(lgAppDir, { recursive: true });

  if (skipMbui) {
    writeFileSync(resolve(compAppDir, "index.html"), renderStubAppHtml("ui.monoid — Components"));
    writeFileSync(resolve(lgAppDir, "index.html"), renderStubAppHtml("ui.monoid — Liquid Glass"));
    return;
  }

  const env = {
    ...process.env,
    PATH: `${process.env.HOME}/.moon/bin:${process.env.PATH || ""}`,
  };

  console.log("[ui.monoid] building sfstories Storybook via apps/mbui/scripts/kit-web.sh ...");
  execFileSync("bash", ["apps/mbui/scripts/kit-web.sh", compAppDir], {
    cwd: REPO,
    env,
    stdio: "inherit",
  });

  const kitIndexPath = resolve(compAppDir, "index.html");
  let kitHtml = readFileSync(kitIndexPath, "utf8");
  if (!existsSync(resolve(compAppDir, "assets/inter.woff2"))) {
    kitHtml = kitHtml.replace(/carried\("inter\.woff2"\)\s*,\s*/g, "");
  }
  kitHtml = kitHtml.replace(/<meta\s+name="robots"\s+content="noindex">\s*/i, "");
  kitHtml = kitHtml.replace(/<title>[^<]*<\/title>/i, "<title>ui.monoid — Components</title>");
  kitHtml = kitHtml.replace(
    "</head>",
    `<style>html[data-dark="1"], html[data-dark="1"] body { background: #0E0E10; }</style>
<script>if (new URLSearchParams(location.search).get("MBUI_DARK") === "1") document.documentElement.dataset.dark = "1";</script>
</head>`,
  );
  writeFileSync(kitIndexPath, kitHtml);

  console.log("[ui.monoid] building Liquid Glass gallery via libs/mbui/scripts/web.sh bundle ...");
  execFileSync("bash", ["libs/mbui/scripts/web.sh", "bundle", lgAppDir], {
    cwd: REPO,
    env: {
      ...env,
      APP: "gallery",
      MBUI_APP_MOD: resolve(REPO, "libs/liquid-glass"),
      MBUI_WEB_BROTLI: "0",
    },
    stdio: "inherit",
  });
  writeFileSync(resolve(lgAppDir, "index.html"), renderLiquidGlassAppHtml());

  const ghosttySrc = resolve(compAppDir, "ghostty-vt.wasm");
  const ghosttyDst = resolve(lgAppDir, "ghostty-vt.wasm");
  if (existsSync(ghosttySrc) && !existsSync(ghosttyDst)) {
    cpSync(ghosttySrc, ghosttyDst);
  }
}

function copyAssets(out) {
  const assetsOut = resolve(out, "assets");
  mkdirSync(assetsOut, { recursive: true });
  cpSync(ASSETS_DIR, assetsOut, {
    recursive: true,
    filter: (src) => {
      // Per-page stylesheets are inlined into <head> and do not need to be served separately.
      const rel = relative(ASSETS_DIR, src).replaceAll("\\", "/");
      return rel !== "pages" && !rel.startsWith("pages/");
    },
  });
}

function writeMetadataFiles(out, routes) {
  const headers = `# Cache immutable bundles, fonts, and wasm assets; keep HTML fresh.
/assets/fonts/*
  Cache-Control: public, max-age=31536000, immutable

/assets/shots/*
  Cache-Control: public, max-age=31536000, immutable

/assets/*
  Cache-Control: public, max-age=3600

/components/app/assets/*
  Cache-Control: public, max-age=31536000, immutable

/components/app/*.js
  Cache-Control: public, max-age=3600

/liquid-glass/app/*.js
  Cache-Control: public, max-age=3600

/*.wasm
  Cache-Control: public, max-age=31536000, immutable

/*.woff2
  Cache-Control: public, max-age=31536000, immutable

/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
`;

  const robots = `User-agent: *
Allow: /
Sitemap: ${ORIGIN}/sitemap.xml
`;

  const sitemapUrls = routes.filter((r) => r !== "/404.html").sort();
  const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${sitemapUrls.map((u) => `  <url><loc>${ORIGIN}${u}</loc></url>`).join("\n")}
</urlset>
`;

  writeFileSync(resolve(out, "_headers"), headers);
  writeFileSync(resolve(out, "robots.txt"), robots);
  writeFileSync(resolve(out, "sitemap.xml"), sitemap);
}

function verifyInternalLinks(out, builtFiles) {
  const broken = new Set();
  for (const file of builtFiles) {
    const html = readFileSync(file, "utf8");
    const matches = html.matchAll(/href="(\/[^"#?]*)"/g);
    for (const m of matches) {
      const target = m[1];
      if (target === "/") {
        if (!existsSync(resolve(out, "index.html"))) broken.add(target);
      } else if (target.endsWith("/")) {
        if (!existsSync(resolve(out, target.slice(1), "index.html"))) broken.add(target);
      } else {
        const direct = resolve(out, target.slice(1));
        const asDir = resolve(out, target.slice(1), "index.html");
        if (!existsSync(direct) && !existsSync(asDir)) broken.add(target);
      }
    }
  }
  if (broken.size > 0) {
    throw new Error(`Broken internal links in built site: ${[...broken].sort().join(", ")}`);
  }
}

function main() {
  const { out, skipMbui } = parseArgs(process.argv.slice(2));
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });

  copyAssets(out);
  buildMbuiEmbeds(out, skipMbui);

  const headTpl = readFileSync(resolve(PARTIALS_DIR, "head.html"), "utf8");
  const navTpl = readFileSync(resolve(PARTIALS_DIR, "nav.html"), "utf8");
  const footerTpl = readFileSync(resolve(PARTIALS_DIR, "footer.html"), "utf8");
  const shotSizes = loadShotSizes();

  const pageFiles = walkHtml(PAGES_DIR);
  if (pageFiles.length === 0) {
    throw new Error(`No page files found under ${PAGES_DIR}`);
  }

  const routes = [];
  const builtFiles = [];
  const pendingShots = new Set();

  for (const rel of pageFiles) {
    const srcPath = resolve(PAGES_DIR, rel);
    const meta = parsePageMeta(srcPath, rel);

    let here;
    let dest;
    if (rel === "index.html") {
      here = "/";
      dest = resolve(out, "index.html");
    } else if (rel === "404.html") {
      here = "/404.html";
      dest = resolve(out, "404.html");
    } else if (rel.endsWith("/index.html")) {
      const dir = rel.slice(0, -"/index.html".length);
      here = `/${dir}/`;
      dest = resolve(out, rel);
    } else {
      const stem = rel.slice(0, -".html".length);
      here = `/${stem}/`;
      dest = resolve(out, stem, "index.html");
    }

    const cssPath = resolve(PAGE_CSS_DIR, `${meta.page}.css`);
    const pageCss = existsSync(cssPath) ? readFileSync(cssPath, "utf8") : "";
    const ctx = { ...meta, here, pageCss };
    const shotCounter = { count: 0 };

    const html = [
      expandTemplate(headTpl, ctx, shotSizes, shotCounter, pendingShots),
      expandTemplate(navTpl, ctx, shotSizes, shotCounter, pendingShots),
      "<main>",
      expandTemplate(meta.body, ctx, shotSizes, shotCounter, pendingShots),
      "</main>",
      expandTemplate(footerTpl, ctx, shotSizes, shotCounter, pendingShots),
    ].join("\n") + "\n";

    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, html);
    routes.push(here);
    builtFiles.push(dest);
  }

  writeMetadataFiles(out, routes);
  verifyInternalLinks(out, builtFiles);

  if (pendingShots.size > 0) {
    console.log(`[ui.monoid] note: ${pendingShots.size} pending shot placeholder(s): ${[...pendingShots].sort().join(", ")}`);
  }
  console.log(
    `[ui.monoid] built ${pageFiles.length} pages ${skipMbui ? "(--skip-mbui)" : "(full WebGL2 embeds)"} -> ${out}`,
  );
}

main();
