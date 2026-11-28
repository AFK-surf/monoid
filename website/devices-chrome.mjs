#!/usr/bin/env node
// Composite 3x native OS chrome onto pure apps/mbui 3x captures before mapping onto official 3D CAD meshes:
//   - duo:     Apple iPhone 18 Pro Max (1170x2544 @3x = 390x848; Apple USDZ provides real 3D Dynamic Island)
//   - android: Samsung Galaxy S25+ (1170x2532 @3x = 390x844; status bar + gesture pill, pure apps/mbui)
//   - mac:     the desktop app in a window on a MacBook Air 15" (2940x1908 @2x = 1470x954; menu bar + Dock)
//   - linux:   the desktop app in a window on a GNOME laptop, 3:2 (3840x2560 @2x = 1920x1280; top bar + dock)
//   - win:     the desktop app in a window on a Windows 11 laptop, 3:2 (3840x2560 @2x = 1920x1280; desktop + taskbar)
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

const ALL_KEYS = ["duo", "android", "mac", "linux", "win", "web"].flatMap((d) => [`${d}-en`, `${d}-zh`]);
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

  // The app's icon (assets/mark.svg) at a size, for a dock or a taskbar.
  const markAt = (px) => readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "assets/mark.svg"), "utf8")
    .replace(/<title>.*?<\/title>/, "").replace('width="32" height="32"', `width="${px}" height="${px}"`);
  // Plain icons for the other apps in a dock (a folder, a browser, a terminal, settings): no other maker's art.
  const tile = (px, bg, inner) => `<div style="width:${px}px;height:${px}px;border-radius:${px * 0.225}px;background:${bg};display:flex;align-items:center;justify-content:center;box-shadow:0 1px 2px rgba(0,0,0,.25);">${inner}</div>`;
  const dockApps = (px) => [
    tile(px, "linear-gradient(#5AB8F7,#2B7CE0)", `<svg width="${px * 0.6}" height="${px * 0.6}" viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z" fill="#fff" fill-opacity=".92"/></svg>`),
    tile(px, "linear-gradient(#FFFFFF,#E4E6EA)", `<svg width="${px * 0.66}" height="${px * 0.66}" viewBox="0 0 24 24" fill="none" stroke="#2F7DE1" stroke-width="1.6"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3Z"/></svg>`),
    tile(px, "linear-gradient(#3A3B3F,#1E1F22)", `<svg width="${px * 0.56}" height="${px * 0.56}" viewBox="0 0 24 24" fill="none" stroke="#E8E8EA" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 8l4 4-4 4M12 17h7"/></svg>`),
    tile(px, "linear-gradient(#B9BDC4,#7D838C)", `<svg width="${px * 0.62}" height="${px * 0.62}" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v3M12 18.2v3M2.8 12h3M18.2 12h3M5.5 5.5l2.1 2.1M16.4 16.4l2.1 2.1M5.5 18.5l2.1-2.1M16.4 7.6l2.1-2.1"/></svg>`),
  ];

  if (dev === "mac") {
    // The desktop app in a window on a MacBook Air 15" (1470x954 @2x = 2940x1908): the 1280x800 apps/mbui capture 1:1,
    // filmed as macOS with an inset window (the app leaves the top left of its top row to the window's buttons, which
    // AppKit puts 16 in from the left, centred on the first 44: mac_app.m), its 16pt corners and the shadow macOS gives
    // a window, over the wallpaper, the menu bar (the notch sits in its middle) and the Dock with the app running.
    const menus = isZh ? ["文件", "编辑", "显示", "窗口", "帮助"] : ["File", "Edit", "View", "Window", "Help"];
    const clock = isZh ? "11月28日 周六 9:41" : "Sat Nov 28  9:41 AM";
    const light = (c, x) => `<span style="position:absolute;left:${x}px;top:16px;width:12px;height:12px;border-radius:6px;background:${c};box-shadow:inset 0 0 0 .5px rgba(0,0,0,.18);"></span>`;
    return {
      w: 1470, h: 954, dpr: 2,
      html: `<!doctype html><html><body style="margin:0;width:1470px;height:954px;overflow:hidden;position:relative;font-family:${font};background:#141826;">
      <div style="position:absolute;inset:0;background:
        radial-gradient(ellipse 70% 60% at 22% 85%, rgba(232,120,90,0.55) 0%, rgba(120,50,90,0) 70%),
        radial-gradient(ellipse 65% 55% at 78% 30%, rgba(90,110,230,0.60) 0%, rgba(40,40,120,0) 70%),
        radial-gradient(ellipse 50% 45% at 50% 60%, rgba(160,80,200,0.40) 0%, rgba(60,30,90,0) 70%),
        linear-gradient(170deg,#1b2140 0%,#2a1f45 50%,#12142a 100%);"></div>
      <div style="position:absolute;left:0;right:0;top:0;height:37px;background:rgba(20,20,30,0.28);backdrop-filter:blur(30px);display:flex;align-items:center;padding:0 14px;box-sizing:border-box;color:#fff;font-size:13.5px;">
        <svg width="15" height="17" viewBox="0 0 24 24" style="margin:0 18px 2px 6px;"><use href="#apple"/></svg>
        <b style="margin-right:20px;font-weight:700;">monoid</b>
        ${menus.map((m) => `<span style="margin-right:20px;">${m}</span>`).join("")}
        <div style="margin-left:auto;display:flex;align-items:center;gap:16px;">
          <svg width="17" height="13" viewBox="0 0 16 12" fill="none"><path d="M8 11.2a1.1 1.1 0 1 0 0-2.2 1.1 1.1 0 0 0 0 2.2ZM4.6 7.4a4.8 4.8 0 0 1 6.8 0M2 4.8a8.5 8.5 0 0 1 12 0" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/></svg>
          <svg width="26" height="12" viewBox="0 0 26 12" fill="none"><rect x=".75" y=".75" width="21.5" height="10.5" rx="3" stroke="#fff" stroke-opacity=".55" stroke-width="1.2"/><rect x="2.6" y="2.6" width="15" height="6.8" rx="1.6" fill="#fff"/><path d="M24 4.2v3.6" stroke="#fff" stroke-opacity=".55" stroke-width="1.5" stroke-linecap="round"/></svg>
          <svg width="16" height="14" viewBox="0 0 16 14" fill="none" stroke="#fff" stroke-width="1.4"><rect x="1" y="1" width="14" height="5" rx="2.5"/><rect x="1" y="8" width="14" height="5" rx="2.5"/><circle cx="4.5" cy="3.5" r="1.2" fill="#fff"/><circle cx="11.5" cy="10.5" r="1.2" fill="#fff"/></svg>
          <span style="font-variant-numeric:tabular-nums;">${clock}</span>
        </div>
      </div>
      <svg width="0" height="0" style="position:absolute"><symbol id="apple" viewBox="0 0 24 24"><path fill="#fff" d="M16.4 12.6c0-2.4 2-3.5 2-3.6-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.1-2.8.9-3.5.9s-1.9-.9-3.1-.8C6.8 7.3 5.3 8.2 4.5 9.6c-1.7 2.9-.4 7.2 1.2 9.6.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8s1.9.8 3.1.8c1.3 0 2.1-1.2 2.9-2.4.9-1.3 1.3-2.6 1.3-2.7 0 0-2.7-1-2.7-3.9ZM14.1 5.5c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.7 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2.1-.5 2.7-1.3Z"/></symbol></svg>
      <div style="position:absolute;left:95px;top:58px;width:1280px;height:800px;border-radius:16px;box-shadow:0 0 0 .5px rgba(0,0,0,.45),0 0 0 1px rgba(255,255,255,.08) inset,0 28px 70px rgba(0,0,0,.55),0 10px 24px rgba(0,0,0,.3);overflow:hidden;">
        <img src="${imgUrl}" style="display:block;width:1280px;height:800px;">
        ${light("#FF5F57", 16)}${light("#FEBC2E", 36)}${light("#28C840", 56)}
      </div>
      <div style="position:absolute;left:50%;bottom:5px;transform:translateX(-50%);height:66px;padding:0 9px;border-radius:20px;background:rgba(255,255,255,0.20);backdrop-filter:blur(30px);box-shadow:0 0 0 .5px rgba(255,255,255,.28) inset,0 0 0 .5px rgba(0,0,0,.3);display:flex;align-items:center;gap:8px;">
        ${dockApps(50).join("")}
        <div style="position:relative;width:50px;height:50px;border-radius:11.25px;box-shadow:0 0 0 1px rgba(255,255,255,.16),0 1px 2px rgba(0,0,0,.25);">${markAt(50)}<span style="position:absolute;left:50%;bottom:-6px;width:4px;height:4px;margin-left:-2px;border-radius:2px;background:rgba(255,255,255,.85);"></span></div>
      </div>
    </body></html>`
    };
  }

  if (dev === "linux") {
    // The desktop app in a window on a GNOME laptop's desktop (3:2, 1920x1280 @2x = 3840x2560): the 1520x980
    // apps/mbui capture 1:1, filmed as Linux with an inset window (GTK's title bar hidden, the app draws its own
    // minimize/maximize/close: linux_app.c, corner_of.mbt) and square corners (mb_host_window_corner 0), with a GTK
    // shadow, over the wallpaper, the top bar and a dock on the left with the app running.
    const clock = isZh ? "11月28日 09:41" : "Nov 28  09:41";
    return {
      w: 1920, h: 1280, dpr: 2,
      html: `<!doctype html><html><body style="margin:0;width:1920px;height:1280px;overflow:hidden;position:relative;font-family:'Cantarell','Noto Sans','Noto Sans CJK SC',${font};background:#101418;">
      <div style="position:absolute;inset:0;background:
        radial-gradient(ellipse 60% 55% at 70% 70%, rgba(40,170,150,0.50) 0%, rgba(20,80,90,0) 70%),
        radial-gradient(ellipse 55% 50% at 25% 25%, rgba(70,90,200,0.45) 0%, rgba(30,40,110,0) 70%),
        radial-gradient(ellipse 45% 40% at 85% 15%, rgba(220,120,80,0.30) 0%, rgba(90,40,30,0) 70%),
        linear-gradient(160deg,#141a2a 0%,#13263a 50%,#0c1418 100%);"></div>
      <div style="position:absolute;left:0;right:0;top:0;height:32px;background:#0a0a0b;color:#f2f2f2;display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:700;">
        <div style="position:absolute;left:14px;display:flex;align-items:center;gap:5px;">
          <span style="width:30px;height:8px;border-radius:4px;background:#f2f2f2;"></span><span style="width:8px;height:8px;border-radius:4px;background:rgba(242,242,242,.45);"></span><span style="width:8px;height:8px;border-radius:4px;background:rgba(242,242,242,.45);"></span>
        </div>
        <span style="font-variant-numeric:tabular-nums;">${clock}</span>
        <div style="position:absolute;right:12px;display:flex;align-items:center;gap:12px;padding:0 4px;">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="#f2f2f2"><path d="M8 13.5 1 5.6a10.6 10.6 0 0 1 14 0L8 13.5Z"/></svg>
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M2 6h2.6L8 3v10L4.6 10H2V6Z" fill="#f2f2f2"/><path d="M10.6 5.2a4 4 0 0 1 0 5.6M12.4 3.4a6.5 6.5 0 0 1 0 9.2" stroke="#f2f2f2" stroke-width="1.3" stroke-linecap="round"/></svg>
          <svg width="18" height="16" viewBox="0 0 18 16" fill="none"><rect x="1" y="4" width="14" height="8" rx="1.6" stroke="#f2f2f2" stroke-width="1.2"/><rect x="2.8" y="5.8" width="9" height="4.4" rx=".6" fill="#f2f2f2"/><path d="M16.5 6.5v3" stroke="#f2f2f2" stroke-width="1.4" stroke-linecap="round"/></svg>
        </div>
      </div>
      <div style="position:absolute;left:0;top:32px;bottom:0;width:72px;background:rgba(20,20,22,0.78);display:flex;flex-direction:column;align-items:center;gap:12px;padding-top:14px;box-sizing:border-box;">
        ${dockApps(46).join("")}
        <div style="position:relative;width:46px;height:46px;border-radius:10.35px;box-shadow:0 0 0 1px rgba(255,255,255,.16),0 1px 2px rgba(0,0,0,.25);">${markAt(46)}<span style="position:absolute;left:-12px;top:50%;width:4px;height:4px;margin-top:-2px;border-radius:2px;background:#f2f2f2;"></span></div>
        <div style="margin-top:auto;margin-bottom:16px;display:grid;grid-template-columns:repeat(3,6px);gap:5px;">${'<span style="width:6px;height:6px;border-radius:1.5px;background:#e6e6e6;"></span>'.repeat(9)}</div>
      </div>
      <img src="${imgUrl}" style="position:absolute;left:236px;top:166px;width:1520px;height:980px;box-shadow:0 0 0 1px rgba(0,0,0,0.35),0 14px 42px rgba(0,0,0,0.5),0 4px 12px rgba(0,0,0,0.3);">
    </body></html>`
    };
  }

  const searchLabel = isZh ? "搜索" : "Search";
  const timeStr = "09:41";
  const dateStr = isZh ? "2026/11/28" : "11/28/2026";

  if (dev === "win") {
    // The desktop app in a window on a Windows 11 laptop's desktop (3:2, 1920x1280 @2x = 3840x2560): the 1520x980
    // apps/mbui capture 1:1, filmed as Windows with an inset window (the app draws its own minimize/maximize/close in
    // its top row, as the Windows app does), with the corners and shadow Windows 11 gives a window, over the
    // wallpaper and the 48px taskbar with the app (its icon: assets/mark.svg) running.
    const mark = readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "assets/mark.svg"), "utf8")
      .replace(/<title>.*?<\/title>/, "").replace('width="32" height="32"', 'width="20" height="20"');
    return {
      w: 1920, h: 1280, dpr: 2,
      html: `<!doctype html><html><body style="margin:0;width:1920px;height:1280px;overflow:hidden;position:relative;font-family:${font};background:#0d2b5c;">
      <div style="position:absolute;inset:0;background:
        radial-gradient(ellipse 60% 55% at 62% 58%, rgba(120,170,255,0.95) 0%, rgba(60,110,220,0.55) 35%, rgba(20,50,120,0) 70%),
        radial-gradient(ellipse 45% 40% at 30% 30%, rgba(90,200,255,0.55) 0%, rgba(40,90,200,0) 70%),
        radial-gradient(ellipse 80% 70% at 80% 100%, rgba(150,110,255,0.45) 0%, rgba(40,30,120,0) 70%),
        linear-gradient(160deg,#0d2b5c 0%,#1a4a9a 45%,#0e2350 100%);"></div>
      <img src="${imgUrl}" style="position:absolute;left:200px;top:126px;width:1520px;height:980px;border-radius:8px;box-shadow:0 0 0 1px rgba(0,0,0,0.18),0 24px 64px rgba(0,0,0,0.45),0 8px 20px rgba(0,0,0,0.25);">
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
            ${mark}
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
