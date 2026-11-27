#!/usr/bin/env node
// Composite 3x native OS chrome (iOS status bar / Android status bar / macOS menu bar / Safari bar)
// onto raw 3x apps/mbui screen captures before mapping them onto official 3D device meshes.
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

function statusIcons(scale = 1) {
  return `<svg width="${Math.round(78 * scale)}" height="${Math.round(16 * scale)}" viewBox="0 0 78 16" fill="none" xmlns="http://www.w3.org/2000/svg">
    <rect x="0" y="9" width="3" height="5" rx="1" fill="#1C1B1A"/>
    <rect x="4.5" y="7" width="3" height="7" rx="1" fill="#1C1B1A"/>
    <rect x="9" y="4.5" width="3" height="9.5" rx="1" fill="#1C1B1A"/>
    <rect x="13.5" y="2" width="3" height="12" rx="1" fill="#1C1B1A"/>
    <path d="M23.5 11.2a1.6 1.6 0 1 1 3.2 0 1.6 1.6 0 0 1-3.2 0ZM21.2 8.7a5.5 5.5 0 0 1 7.8 0l-1.3 1.3a3.7 3.7 0 0 0-5.2 0l-1.3-1.3ZM18.8 6.3a9 9 0 0 1 12.6 0L30.1 7.6a7.1 7.1 0 0 0-10 0L18.8 6.3Z" fill="#1C1B1A"/>
    <rect x="40" y="2.5" width="26" height="11.5" rx="3.2" stroke="#1C1B1A" stroke-opacity="0.45" stroke-width="1.3"/>
    <rect x="42.2" y="4.6" width="20.5" height="7.3" rx="1.6" fill="#1C1B1A"/>
    <path d="M67.5 6.2v4.1a1.5 1.5 0 0 0 1.2-1.5V7.7a1.5 1.5 0 0 0-1.2-1.5Z" fill="#1C1B1A" fill-opacity="0.45"/>
  </svg>`;
}

function makeHtml(key) {
  const isZh = key.endsWith("-zh");
  const dev = key.split("-")[0];
  const imgUrl = `/img/${key}.png`;
  const font = isZh
    ? `system-ui, -apple-system, "PingFang SC", "Noto Sans CJK SC", sans-serif`
    : `system-ui, -apple-system, "SF Pro Text", "Inter", sans-serif`;

  if (dev === "duo") {
    return {
      w: 890, h: 626, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:890px;height:626px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
        <img src="${imgUrl}" style="display:block;width:890px;height:626px;">
        <div style="position:absolute;top:5px;left:20px;right:20px;height:16px;display:flex;align-items:center;justify-content:space-between;font-size:12px;font-weight:600;color:#1C1B1A;letter-spacing:-0.01em;">
          <span>9:41</span>${statusIcons(0.88)}
        </div>
        <div style="position:absolute;bottom:6px;left:50%;transform:translateX(-50%);width:136px;height:4.5px;border-radius:3px;background:rgba(28,27,26,0.28);"></div>
      </body></html>`,
    };
  }
  if (dev === "android") {
    return {
      w: 412, h: 892, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:412px;height:892px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
        <div style="position:absolute;top:0;left:0;right:0;height:28px;background:#F5F3EF;display:flex;align-items:center;justify-content:space-between;padding:0 18px;box-sizing:border-box;font-size:12.5px;font-weight:600;color:#1C1B1A;">
          <span>9:41</span>
          <div style="display:flex;align-items:center;gap:5px;"><span style="font-size:10.5px;font-weight:700;letter-spacing:-0.02em;">5G</span>${statusIcons(0.84)}</div>
        </div>
        <div style="position:absolute;top:28px;left:0;width:412px;height:85px;overflow:hidden;"><img src="${imgUrl}" style="display:block;width:412px;height:915px;"></div>
        <div style="position:absolute;top:113px;left:0;width:412px;height:762px;overflow:hidden;"><img src="${imgUrl}" style="display:block;width:412px;height:915px;transform:translateY(-153px);"></div>
        <div style="position:absolute;bottom:0;left:0;right:0;height:17px;background:#F5F3EF;display:flex;align-items:center;justify-content:center;">
          <div style="width:116px;height:4px;border-radius:3px;background:rgba(28,27,26,0.28);"></div>
        </div>
      </body></html>`,
    };
  }
  if (dev === "desk") {
    const menus = isZh ? ["monoid", "文件", "编辑", "显示", "窗口", "帮助"] : ["monoid", "File", "Edit", "View", "Window", "Help"];
    const clock = isZh ? "周五 09:41" : "Fri 9:41 AM";
    return {
      w: 980, h: 649, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:980px;height:649px;overflow:hidden;position:relative;font-family:${font};background:#EFECE6;">
        <div style="height:24px;background:#E8E4DC;border-bottom:1px solid rgba(28,27,26,0.08);box-sizing:border-box;display:flex;align-items:center;justify-content:space-between;padding:0 14px;font-size:11.5px;color:#1C1B1A;">
          <div style="display:flex;align-items:center;gap:14px;">
            <svg width="10" height="12" viewBox="0 0 14 17" fill="#1C1B1A"><path d="M11.6 8.9c0-1.9 1.5-2.8 1.6-2.9-.9-1.3-2.2-1.5-2.7-1.5-1.1-.1-2.2.7-2.8.7-.6 0-1.5-.7-2.4-.7-1.2 0-2.4.7-3 1.8-1.3 2.3-.3 5.6.9 7.4.6.9 1.3 1.9 2.3 1.8.9 0 1.3-.6 2.4-.6s1.4.6 2.4.6c1 0 1.6-.9 2.2-1.8.7-1 1-2 1-2.1 0 0-1.9-.7-1.9-2.7ZM9.7 3.2c.5-.6.9-1.5.8-2.3-.7 0-1.6.5-2.1 1.1-.5.5-.9 1.4-.8 2.2.8.1 1.6-.4 2.1-1Z"/></svg>
            <span style="font-weight:700;">${menus[0]}</span>${menus.slice(1).map((m) => `<span style="font-weight:500;opacity:0.86;">${m}</span>`).join("")}
          </div>
          <div style="display:flex;align-items:center;gap:10px;font-weight:500;">${statusIcons(0.75)}<span>${clock}</span></div>
        </div>
        <img src="${imgUrl}" style="display:block;width:980px;height:625px;">
      </body></html>`,
    };
  }
  return {
    w: 1140, h: 642, dpr: 3,
    html: `<!doctype html><html><body style="margin:0;width:1140px;height:642px;overflow:hidden;position:relative;font-family:${font};background:#EBE7DF;">
      <div style="height:42px;background:linear-gradient(180deg,#F2EFE9 0%,#E8E4DC 100%);border-bottom:1px solid rgba(28,27,26,0.11);box-sizing:border-box;display:flex;align-items:center;padding:0 16px;position:relative;">
        <div style="display:flex;align-items:center;gap:7px;">
          <span style="width:11px;height:11px;border-radius:50%;background:#FF5F57;border:0.5px solid rgba(0,0,0,0.14);display:inline-block;"></span>
          <span style="width:11px;height:11px;border-radius:50%;background:#FEBC2E;border:0.5px solid rgba(0,0,0,0.14);display:inline-block;"></span>
          <span style="width:11px;height:11px;border-radius:50%;background:#28C840;border:0.5px solid rgba(0,0,0,0.14);display:inline-block;"></span>
        </div>
        <div style="display:flex;align-items:center;gap:12px;margin-left:18px;color:rgba(28,27,26,0.45);">
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5 10.5 8 6 12.5"/></svg>
        </div>
        <div style="position:absolute;left:50%;transform:translateX(-50%);width:360px;height:26px;border-radius:7px;background:rgba(255,255,255,0.72);border:1px solid rgba(28,27,26,0.09);display:flex;align-items:center;justify-content:center;gap:6px;font-size:12px;font-weight:500;color:#2E2D2A;letter-spacing:-0.01em;">
          <svg width="10" height="11" viewBox="0 0 12 14" fill="none"><rect x="1.5" y="6" width="9" height="6.8" rx="1.6" fill="#6F6B64"/><path d="M3.5 6V4.3a2.5 2.5 0 0 1 5 0V6" stroke="#6F6B64" stroke-width="1.5" stroke-linecap="round"/></svg>
          <span>app.monoid.build</span>
        </div>
      </div>
      <img src="${imgUrl}" style="display:block;width:1140px;height:600px;">
    </body></html>`,
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
  for (const key of (only.length ? only : ALL_KEYS)) {
    const spec = makeHtml(key);
    const outPath = path.join(outDir, `${key}.png`);
    await execFileAsync(CHROMIUM, [
      "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
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
