#!/usr/bin/env node
// Composite 3x native OS chrome onto pure apps/mbui 3x captures before mapping onto official 3D CAD meshes:
//   - duo:     Apple iPhone 18 Pro Max (1170x2544 @3x = 390x848; Apple USDZ provides real 3D Dynamic Island)
//   - android: Samsung Galaxy S25+ (1170x2532 @3x = 390x844; status bar + gesture pill, pure apps/mbui)
//   - desk:    the desktop app maximized on a Windows 11 laptop, 3:2 (4320x2880 @3x = 1440x960; title bar + taskbar)
//   - web:     the web app in a full-screen browser on a MacBook Air 15" (2940x1908 @2x = 1470x954; notch band + bar)
// Usage: node website/devices-chrome.mjs <raw-screens-dir> <out-screens-dir> [keys...]
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdirSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";

const execFileAsync = promisify(execFile);
const [, , rawDir, outDir, ...only] = process.argv;
if (!rawDir || !outDir) {
  console.error("Usage: node website/devices-chrome.mjs <raw-dir> <out-dir> [keys...]");
  process.exit(1);
}
mkdirSync(outDir, { recursive: true });

const ALL_KEYS = ["duo-en", "duo-zh", "android-en", "android-zh", "desk-en", "desk-zh", "web-en", "web-zh"];
const CHROMIUM = process.env.CHROMIUM_BIN || "chromium";

function phoneStatusIcons(scale = 1) {
  return `<svg width="${Math.round(74 * scale)}" height="${Math.round(16 * scale)}" viewBox="0 0 74 16" fill="none" xmlns="http://www.w3.org/2000/svg">
    <rect x="0" y="9" width="3" height="5" rx="1" fill="#1C1B1A"/>
    <rect x="4.5" y="7" width="3" height="7" rx="1" fill="#1C1B1A"/>
    <rect x="9" y="4.5" width="3" height="9.5" rx="1" fill="#1C1B1A"/>
    <rect x="13.5" y="2" width="3" height="12" rx="1" fill="#1C1B1A"/>
    <path d="M23.5 11.2a1.6 1.6 0 1 1 3.2 0 1.6 1.6 0 0 1-3.2 0ZM21.2 8.7a5.5 5.5 0 0 1 7.8 0l-1.3 1.3a3.7 3.7 0 0 0-5.2 0l-1.3-1.3ZM18.8 6.3a9 9 0 0 1 12.6 0L30.1 7.6a7.1 7.1 0 0 0-10 0L18.8 6.3Z" fill="#1C1B1A"/>
    <rect x="38" y="2.5" width="25" height="11.5" rx="3.2" stroke="#1C1B1A" stroke-opacity="0.45" stroke-width="1.3"/>
    <rect x="40.2" y="4.6" width="19.5" height="7.3" rx="1.6" fill="#1C1B1A"/>
    <path d="M64.5 6.2v4.1a1.5 1.5 0 0 0 1.2-1.5V7.7a1.5 1.5 0 0 0-1.2-1.5Z" fill="#1C1B1A" fill-opacity="0.45"/>
  </svg>`;
}

function makeHtml(key) {
  const isZh = key.endsWith("-zh");
  const dev = key.split("-")[0];
  const imgUrl = `/img/${key}.png`;
  const font = isZh
    ? `system-ui, -apple-system, 'PingFang SC', 'Noto Sans CJK SC', sans-serif`
    : `system-ui, -apple-system, 'SF Pro Text', 'Inter', sans-serif`;

  if (dev === "duo") {
    // Apple iPhone 18 Pro Max: 390x848 @3x = 1170x2544 (exact 0.4599 matching EHjrGDHNHzgNjtE).
    // Apple USDZ already provides the real 3D Dynamic Island & front camera lens mesh above the screen.
    return {
      w: 390, h: 848, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:390px;height:848px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
        <div style="height:38px;background:#F5F3EF;display:flex;align-items:center;justify-content:space-between;padding:4px 24px 0;box-sizing:border-box;position:relative;font-size:13.5px;font-weight:700;color:#1C1B1A;letter-spacing:-0.02em;">
          <span>9:41</span>
          ${phoneStatusIcons(0.86)}
        </div>
        <img src="${imgUrl}" style="display:block;width:390px;height:796px;">
        <div style="height:14px;background:#F5F3EF;display:flex;align-items:center;justify-content:center;">
          <div style="width:132px;height:4.5px;border-radius:3px;background:rgba(28,27,26,0.30);"></div>
        </div>
      </body></html>`
    };
  }

  if (dev === "android") {
    // Samsung Galaxy S25+ (large concentric rounded corners): 390x844 @3x = 1170x2532 (exact 0.4621).
    return {
      w: 390, h: 844, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:390px;height:844px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
        <div style="height:28px;background:#F5F3EF;display:flex;align-items:center;justify-content:space-between;padding:0 22px;box-sizing:border-box;font-size:12.5px;font-weight:600;color:#1C1B1A;">
          <span>9:41</span>
          <div style="display:flex;align-items:center;gap:5px;">
            <span style="font-size:10.5px;font-weight:700;letter-spacing:-0.02em;">5G</span>
            ${phoneStatusIcons(0.84)}
          </div>
        </div>
        <img src="${imgUrl}" style="display:block;width:390px;height:802px;">
        <div style="height:14px;background:#F5F3EF;display:flex;align-items:center;justify-content:center;">
          <div style="width:116px;height:4px;border-radius:3px;background:rgba(28,27,26,0.28);"></div>
        </div>
      </body></html>`
    };
  }

  const searchLabel = isZh ? "搜索" : "Search";
  const timeStr = "09:41";
  const dateStr = isZh ? "2026/11/28" : "11/28/2026";

  if (dev === "desk") {
    // The desktop app on a Windows 11 laptop (3:2, 1440x960 @3x = 4320x2880), maximized: a 32px title bar, the
    // 1440x880 apps/mbui capture 1:1, and the 48px taskbar with the app running.
    return {
      w: 1440, h: 960, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:1440px;height:960px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
      <div style="height:32px;background:#EBE8E1;display:flex;align-items:center;justify-content:space-between;padding:0 0 0 12px;color:#2B2926;">
        <div style="display:flex;align-items:center;gap:8px;font-size:12px;">
          <svg width="16" height="16" viewBox="0 0 20 20" fill="none"><circle cx="10" cy="10" r="8.5" fill="#1C1B1A"/><circle cx="7.4" cy="9.6" r="1.25" fill="#FFFFFF"/><circle cx="12.6" cy="9.6" r="1.25" fill="#FFFFFF"/><path d="M7.5 12.8h5" stroke="#EF6334" stroke-width="1.5" stroke-linecap="round"/></svg>
          <span>monoid</span>
        </div>
        <div style="display:flex;align-items:center;height:100%;">
          <div style="width:46px;height:100%;display:flex;align-items:center;justify-content:center;"><svg width="10" height="10" viewBox="0 0 10 10"><path d="M1 5h8" stroke="currentColor" stroke-width="1"/></svg></div>
          <div style="width:46px;height:100%;display:flex;align-items:center;justify-content:center;"><svg width="10" height="10" viewBox="0 0 10 10"><rect x="1.5" y="1.5" width="7" height="7" rx="0.8" fill="none" stroke="currentColor" stroke-width="1"/></svg></div>
          <div style="width:46px;height:100%;display:flex;align-items:center;justify-content:center;"><svg width="10" height="10" viewBox="0 0 10 10"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" stroke="currentColor" stroke-width="1" stroke-linecap="round"/></svg></div>
        </div>
      </div>
      <img src="${imgUrl}" style="display:block;width:1440px;height:880px;">
      <div style="position:absolute;left:0;right:0;bottom:0;height:48px;background:rgba(238,236,232,0.96);border-top:1px solid rgba(28,27,26,0.10);box-sizing:border-box;display:flex;align-items:center;justify-content:center;padding:0 16px;">
        <div style="display:flex;align-items:center;gap:10px;">
          <div style="width:30px;height:30px;border-radius:6px;display:flex;align-items:center;justify-content:center;">
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
              <rect x="1" y="1" width="7.4" height="7.4" rx="1" fill="#0078D4"/>
              <rect x="9.6" y="1" width="7.4" height="7.4" rx="1" fill="#1A8CE8"/>
              <rect x="1" y="9.6" width="7.4" height="7.4" rx="1" fill="#006CBE"/>
              <rect x="9.6" y="9.6" width="7.4" height="7.4" rx="1" fill="#2CA0F5"/>
            </svg>
          </div>
          <div style="height:26px;padding:0 12px 0 9px;border-radius:13px;background:rgba(255,255,255,0.88);border:1px solid rgba(28,27,26,0.09);display:flex;align-items:center;gap:6px;font-size:11px;color:#5A5752;">
            <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="7" cy="7" r="4.6"/><path d="M10.5 10.5 14 14" stroke-linecap="round"/></svg>
            <span>${searchLabel}</span>
          </div>
          <div style="width:30px;height:30px;border-radius:6px;display:flex;align-items:center;justify-content:center;">
            <svg width="19" height="19" viewBox="0 0 20 20" fill="none"><path d="M2.5 5.5A1.5 1.5 0 0 1 4 4h4l1.5 1.8H16A1.5 1.5 0 0 1 17.5 7.3V15a1.5 1.5 0 0 1-1.5 1.5H4A1.5 1.5 0 0 1 2.5 15V5.5Z" fill="#F2C94C"/><rect x="6" y="13" width="8" height="2.4" rx="0.8" fill="#0078D4"/></svg>
          </div>
          <div style="width:32px;height:30px;border-radius:6px;background:rgba(255,255,255,0.75);border:1px solid rgba(28,27,26,0.08);display:flex;align-items:center;justify-content:center;position:relative;">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none"><circle cx="10" cy="10" r="7.5" fill="#1C1B1A"/><circle cx="7.4" cy="9.6" r="1.15" fill="#FFFFFF"/><circle cx="12.6" cy="9.6" r="1.15" fill="#FFFFFF"/><path d="M7.5 12.6h5" stroke="#EF6334" stroke-width="1.4" stroke-linecap="round"/></svg>
            <span style="position:absolute;bottom:2px;left:50%;transform:translateX(-50%);width:12px;height:2.5px;border-radius:2px;background:#0078D4;"></span>
          </div>
          <div style="width:30px;height:30px;border-radius:6px;display:flex;align-items:center;justify-content:center;">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none"><rect x="2.5" y="3.5" width="15" height="13" rx="2.4" fill="#2C2C2E"/><path d="M6 8l2.5 2.2L6 12.4M10 12.4h3.5" stroke="#E5E5EA" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </div>
        </div>
        <div style="position:absolute;right:14px;display:flex;align-items:center;gap:12px;color:#1C1B1A;">
          <div style="display:flex;align-items:center;gap:7px;">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M7.2 12a1 1 0 1 1 1.6 0 1 1 0 0 1-1.6 0ZM5.2 9.8a4 4 0 0 1 5.6 0M3 7.6a7 7 0 0 1 10 0" stroke="#1C1B1A" stroke-width="1.35" stroke-linecap="round"/></svg>
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M2.5 6.2h2.6l3.4-2.7v9l-3.4-2.7H2.5V6.2Z" stroke="#1C1B1A" stroke-width="1.25" stroke-linejoin="round"/><path d="M11 5.8a3.2 3.2 0 0 1 0 4.4" stroke="#1C1B1A" stroke-width="1.25" stroke-linecap="round"/></svg>
            <svg width="18" height="14" viewBox="0 0 20 16" fill="none"><rect x="1.5" y="4" width="15" height="8" rx="2" stroke="#1C1B1A" stroke-width="1.2"/><rect x="3.2" y="5.7" width="9" height="4.6" rx="0.9" fill="#1C1B1A"/><path d="M18 6.6v2.8" stroke="#1C1B1A" stroke-width="1.4" stroke-linecap="round"/></svg>
          </div>
          <div style="text-align:right;line-height:1.18;font-size:10.5px;font-weight:500;">
            <div>${timeStr}</div>
            <div style="font-size:9.5px;opacity:0.78;">${dateStr}</div>
          </div>
        </div>
      </div>
    </body></html>`
    };
  }

  // web: the web app in a full-screen browser on a MacBook Air 15" (1470x954 @2x = 2940x1908): the black band the notch
  // sits in, a 40px browser bar, and the top 1470x878 of the apps/mbui capture 1:1.
  return {
    w: 1470, h: 954, dpr: 2,
    html: `<!doctype html><html><body style="margin:0;width:1470px;height:954px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
      <div style="height:36px;background:#070709;"></div>
      <div style="height:40px;background:#EBE8E1;border-bottom:1px solid rgba(28,27,26,0.10);box-sizing:border-box;display:flex;align-items:center;justify-content:space-between;padding:0 0 0 16px;position:relative;">
        <div style="display:flex;align-items:center;gap:14px;color:rgba(28,27,26,0.55);">
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 3.5 6 8l4.5 4.5"/></svg>
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 3.5 10 8l-4.5 4.5"/></svg>
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"><path d="M12.8 8a4.8 4.8 0 1 1-1.2-3.2"/><path d="M12.8 2.6v2.6h-2.6"/></svg>
        </div>
        <div style="position:absolute;left:50%;transform:translateX(-50%);width:480px;height:26px;border-radius:13px;background:#FFFFFF;border:1px solid rgba(28,27,26,0.09);display:flex;align-items:center;justify-content:center;gap:6px;font-size:12.5px;font-weight:500;color:#2E2D2A;">
          <svg width="9.5" height="10.5" viewBox="0 0 12 14" fill="none"><rect x="1.5" y="6" width="9" height="6.8" rx="1.6" fill="#6F6B64"/><path d="M3.5 6V4.3a2.5 2.5 0 0 1 5 0V6" stroke="#6F6B64" stroke-width="1.5" stroke-linecap="round"/></svg>
          <span>app.monoid.build</span>
        </div>
      </div>
      <img src="${imgUrl}" style="display:block;width:1470px;height:878px;object-fit:cover;object-position:top;">
    </body></html>`
  };
}

const server = http.createServer((req, res) => {
  const m = /^\/img\/([a-z-]+)\.png$/.exec(req.url);
  if (m && ALL_KEYS.includes(m[1])) {
    res.writeHead(200, { "Content-Type": "image/png" });
    res.end(readFileSync(path.join(rawDir, `${m[1]}.png`)));
    return;
  }
  const p = /^\/page\/([a-z-]+)$/.exec(req.url);
  if (p && ALL_KEYS.includes(p[1])) {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(makeHtml(p[1]).html);
    return;
  }
  res.writeHead(404); res.end();
});

await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

try {
  const keys = only.length ? only : ALL_KEYS;
  for (const key of keys) {
    const spec = makeHtml(key);
    const outPath = path.join(outDir, `${key}.png`);
    await execFileAsync(CHROMIUM, [
      "--headless=new", "--no-sandbox", "--disable-gpu",
      "--hide-scrollbars",
      `--window-size=${spec.w},${spec.h}`,
      `--force-device-scale-factor=${spec.dpr}`,
      `--screenshot=${outPath}`,
      `http://127.0.0.1:${port}/page/${key}`,
    ]);
    console.log(`✓ ${key}.png (${spec.w * spec.dpr}x${spec.h * spec.dpr})`);
  }
} finally {
  server.close();
}
