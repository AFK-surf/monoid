#!/usr/bin/env node
// Composite 3x native OS chrome (iPhone Duo iOS 27.1 trailing Liquid Glass column, Android status
// bar + virtual-screen notification, macOS desktop + app/Safari window) onto raw 3x apps/mbui
// screen captures before mapping them onto official 3D device meshes.
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

// Phone status bar icons (cellular + Wi-Fi + battery) — ONLY for Android phone
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

// macOS menu bar icons (Wi-Fi + Battery ONLY — no phone cellular bars)
function macStatusIcons(color = "#1C1B1A", scale = 1) {
  return `<svg width="${Math.round(52 * scale)}" height="${Math.round(14 * scale)}" viewBox="0 0 52 14" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M7.2 10.6a1.45 1.45 0 1 1 2.9 0 1.45 1.45 0 0 1-2.9 0ZM4.8 8.2a5.2 5.2 0 0 1 7.7 0l-1.2 1.2a3.5 3.5 0 0 0-5.3 0L4.8 8.2ZM2.4 5.8a8.6 8.6 0 0 1 12.5 0l-1.2 1.2a6.9 6.9 0 0 0-10.1 0L2.4 5.8Z" fill="${color}"/>
    <rect x="21" y="2" width="24" height="10.2" rx="2.8" stroke="${color}" stroke-opacity="0.52" stroke-width="1.2"/>
    <rect x="23" y="3.8" width="18.6" height="6.6" rx="1.4" fill="${color}"/>
    <path d="M46.4 5.2v3.8a1.3 1.3 0 0 0 1.1-1.3V6.5a1.3 1.3 0 0 0-1.1-1.3Z" fill="${color}" fill-opacity="0.52"/>
  </svg>`;
}

function appleGlyph(color = "#1C1B1A") {
  return `<svg width="10" height="12" viewBox="0 0 14 17" fill="${color}"><path d="M11.6 8.9c0-1.9 1.5-2.8 1.6-2.9-.9-1.3-2.2-1.5-2.7-1.5-1.1-.1-2.2.7-2.8.7-.6 0-1.5-.7-2.4-.7-1.2 0-2.4.7-3 1.8-1.3 2.3-.3 5.6.9 7.4.6.9 1.3 1.9 2.3 1.8.9 0 1.3-.6 2.4-.6s1.4.6 2.4.6c1 0 1.6-.9 2.2-1.8.7-1 1-2 1-2.1 0 0-1.9-.7-1.9-2.7ZM9.7 3.2c.5-.6.9-1.5.8-2.3-.7 0-1.6.5-2.1 1.1-.5.5-.9 1.4-.8 2.2.8.1 1.6-.4 2.1-1Z"/></svg>`;
}

function trafficLights(size = 11, gap = 7) {
  return `<div style="display:flex;align-items:center;gap:${gap}px;">
    <span style="width:${size}px;height:${size}px;border-radius:50%;background:#FF5F57;border:0.5px solid rgba(0,0,0,0.16);display:inline-block;"></span>
    <span style="width:${size}px;height:${size}px;border-radius:50%;background:#FEBC2E;border:0.5px solid rgba(0,0,0,0.16);display:inline-block;"></span>
    <span style="width:${size}px;height:${size}px;border-radius:50%;background:#28C840;border:0.5px solid rgba(0,0,0,0.16);display:inline-block;"></span>
  </div>`;
}

// Native iPhone Duo iOS 27.1 trailing right-edge Liquid Glass column
function duoTrailingColumn() {
  return `
  <div style="position:absolute;top:0;right:6px;width:82px;height:669px;display:flex;flex-direction:column;align-items:center;padding:20px 0 24px;box-sizing:border-box;justify-content:space-between;">
    <div style="display:flex;flex-direction:column;align-items:center;gap:5px;">
      <div style="font-size:13.5px;font-weight:700;color:#1C1B1A;letter-spacing:-0.02em;line-height:1;">09:41</div>
      <svg width="36" height="36" viewBox="0 0 36 36" fill="none">
        <circle cx="18" cy="18" r="14.2" stroke="rgba(28,27,26,0.12)" stroke-width="2.4"/>
        <path d="M 8.0 28.0 A 14.2 14.2 0 1 1 29.8 25.8" stroke="#34C759" stroke-width="2.6" stroke-linecap="round"/>
        <path d="M18.6 6.2 L16.5 9.4 H18.2 L17.5 12.1 L19.8 8.8 H18.1 L18.6 6.2 Z" fill="#34C759"/>
        <path d="M16.7 21.3a1.4 1.4 0 1 1 2.6 0 1.4 1.4 0 0 1-2.6 0ZM14.6 19.1a4.7 4.7 0 0 1 6.8 0l-1.1 1.1a3.2 3.2 0 0 0-4.6 0l-1.1-1.1ZM12.5 16.9a7.7 7.7 0 0 1 11.0 0l-1.1 1.1a6.1 6.1 0 0 0-8.8 0l-1.1-1.1Z" fill="#1C1B1A"/>
        <circle cx="13.8" cy="27.2" r="1.2" fill="#1C1B1A"/>
        <circle cx="16.6" cy="28.1" r="1.2" fill="#1C1B1A"/>
        <circle cx="19.4" cy="28.1" r="1.2" fill="#1C1B1A"/>
        <circle cx="22.2" cy="27.2" r="1.2" fill="rgba(28,27,26,0.32)"/>
      </svg>
    </div>

    <div style="display:flex;flex-direction:column;align-items:center;gap:14px;">
      <div style="width:46px;padding:12px 0;border-radius:23px;background:rgba(255,255,255,0.74);border:1px solid rgba(255,255,255,0.88);box-shadow:0 4px 16px rgba(28,27,26,0.08), inset 0 1px 0 rgba(255,255,255,0.9);display:flex;flex-direction:column;align-items:center;gap:18px;color:#2E2C29;">
        <svg width="19" height="19" viewBox="0 0 20 20" fill="currentColor"><circle cx="4.5" cy="10" r="1.5"/><circle cx="10" cy="10" r="1.5"/><circle cx="15.5" cy="10" r="1.5"/></svg>
        <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.55"><circle cx="10" cy="10" r="7.2"/><path d="M10 9v4.2" stroke-linecap="round"/><circle cx="10" cy="6.6" r="0.85" fill="currentColor" stroke="none"/></svg>
        <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linejoin="round"><rect x="3" y="4" width="14" height="12" rx="2.5"/><path d="M8 4v12"/></svg>
        <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"><rect x="3.2" y="4.2" width="13.6" height="3.2" rx="1"/><path d="M4.6 7.4v7.2a1.4 1.4 0 0 0 1.4 1.4h8a1.4 1.4 0 0 0 1.4-1.4V7.4"/><path d="M8.3 11h3.4"/></svg>
      </div>

      <div style="width:46px;padding:7px 0;border-radius:23px;background:rgba(255,255,255,0.74);border:1px solid rgba(255,255,255,0.88);box-shadow:0 4px 16px rgba(28,27,26,0.08), inset 0 1px 0 rgba(255,255,255,0.9);display:flex;flex-direction:column;align-items:center;gap:12px;">
        <div style="width:36px;height:36px;border-radius:18px;background:rgba(224,90,43,0.13);display:flex;align-items:center;justify-content:center;color:#D95326;">
          <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h7A2.5 2.5 0 0 1 16 5.5v5a2.5 2.5 0 0 1-2.5 2.5H9l-3.2 2.6V13H6.5A2.5 2.5 0 0 1 4 10.5v-5Z"/></svg>
        </div>
        <div style="width:36px;height:30px;display:flex;align-items:center;justify-content:center;color:#2E2C29;">
          <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linejoin="round"><path d="M3.2 6.2a1.8 1.8 0 0 1 1.8-1.8h3.4l1.6 1.8h5a1.8 1.8 0 0 1 1.8 1.8v6.2a1.8 1.8 0 0 1-1.8 1.8H5a1.8 1.8 0 0 1-1.8-1.8V6.2Z"/></svg>
        </div>
        <div style="width:36px;height:30px;display:flex;align-items:center;justify-content:center;color:#2E2C29;">
          <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="14" height="9.5" rx="2"/><path d="M7.5 16.5h5M10 13.5v3"/></svg>
        </div>
        <div style="width:36px;height:30px;display:flex;align-items:center;justify-content:center;color:#2E2C29;">
          <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.55" stroke-linecap="round"><circle cx="10" cy="10" r="2.7"/><path d="M10 3.2v1.6M10 15.2v1.6M3.2 10h1.6M15.2 10h1.6M5.2 5.2l1.1 1.1M13.7 13.7l1.1 1.1M14.8 5.2l-1.1 1.1M6.3 13.7l-1.1 1.1"/></svg>
        </div>
      </div>
    </div>

    <div style="width:44px;height:44px;border-radius:22px;background:rgba(255,255,255,0.78);border:1px solid rgba(255,255,255,0.92);box-shadow:0 4px 16px rgba(28,27,26,0.09), inset 0 1px 0 rgba(255,255,255,0.95);display:flex;align-items:center;justify-content:center;color:#2E2C29;">
      <svg width="19" height="19" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 4.5v11M4.5 10h11"/></svg>
    </div>
  </div>`;
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
      w: 951, h: 669, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:951px;height:669px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
        <img src="${imgUrl}" style="display:block;width:951px;height:669px;">
        ${duoTrailingColumn()}
      </body></html>`
    };
  }

  if (dev === "android") {
    const nTitle = isZh ? "调试已共享给 2 个对话" : "Debugging shared with 2 chats";
    const nBody = isZh
      ? "「手机上的登录页」正在后台使用虚拟屏幕"
      : "“Login page on phones” is using a virtual screen in the background";
    const nAction = isZh ? "关闭调试共享" : "Turn off debug sharing";
    const nMeta = isZh ? "monoid · 2 分钟前" : "monoid · 2m";

    return {
      w: 412, h: 892, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:412px;height:892px;overflow:hidden;position:relative;font-family:${font};background:#F5F3EF;">
        <div style="position:absolute;top:0;left:0;right:0;height:28px;background:#F5F3EF;display:flex;align-items:center;justify-content:space-between;padding:0 18px;box-sizing:border-box;font-size:12.5px;font-weight:600;color:#1C1B1A;">
          <span>9:41</span>
          <div style="display:flex;align-items:center;gap:5px;">
            <span style="font-size:10.5px;font-weight:700;letter-spacing:-0.02em;">5G</span>
            ${phoneStatusIcons(0.84)}
          </div>
        </div>
        <div style="position:absolute;top:28px;left:0;width:412px;height:82px;overflow:hidden;">
          <img src="${imgUrl}" style="display:block;width:412px;height:915px;">
        </div>
        <div style="position:absolute;z-index:3;top:110px;left:12px;right:12px;background:#FFFFFF;border-radius:18px;padding:11px 14px 11px;box-sizing:border-box;border:1px solid rgba(28,27,26,0.09);box-shadow:0 6px 20px rgba(28,27,26,0.08);">
          <div style="display:flex;align-items:center;gap:7px;margin-bottom:4px;">
            <span style="width:16px;height:16px;border-radius:50%;background:#1C1B1A;display:inline-flex;align-items:center;justify-content:center;">
              <span style="width:6px;height:6px;border-radius:50%;background:#34C759;display:inline-block;"></span>
            </span>
            <span style="font-size:11.5px;font-weight:500;color:#6B6860;">${nMeta}</span>
          </div>
          <div style="font-size:13.5px;font-weight:700;color:#1C1B1A;line-height:1.28;margin-bottom:3px;">${nTitle}</div>
          <div style="font-size:12px;color:#4F4C46;line-height:1.35;margin-bottom:6px;">${nBody}</div>
          <div style="font-size:12px;font-weight:600;color:#C24D24;">${nAction}</div>
        </div>
        <div style="position:absolute;top:240px;left:0;width:412px;height:639px;overflow:hidden;">
          <img src="${imgUrl}" style="display:block;width:412px;height:915px;transform:translateY(-276px);">
        </div>
        <div style="position:absolute;bottom:0;left:0;right:0;height:14px;background:#F5F3EF;display:flex;align-items:center;justify-content:center;">
          <div style="width:116px;height:4px;border-radius:3px;background:rgba(28,27,26,0.28);"></div>
        </div>
      </body></html>`
    };
  }

  if (dev === "desk") {
    const menus = isZh
      ? ["monoid", "文件", "编辑", "显示", "窗口", "帮助"]
      : ["monoid", "File", "Edit", "View", "Window", "Help"];
    const clock = isZh ? "周五 09:41" : "Fri 9:41 AM";
    const winTitle = isZh ? "Willow — Station" : "Willow — Stations";
    return {
      w: 1066, h: 692, dpr: 3,
      html: `<!doctype html><html><body style="margin:0;width:1066px;height:692px;overflow:hidden;position:relative;font-family:${font};background:linear-gradient(138deg,#9F8E7D 0%,#7D6D5E 48%,#5A4D43 100%);">
        <div style="position:absolute;inset:0;background:radial-gradient(ellipse 75% 60% at 18% 16%, rgba(255,236,210,0.34), transparent 64%), radial-gradient(ellipse 65% 55% at 86% 88%, rgba(34,26,20,0.38), transparent 64%);"></div>
        <div style="position:relative;z-index:2;height:24px;background:rgba(246,243,238,0.88);border-bottom:1px solid rgba(28,27,26,0.08);box-sizing:border-box;display:flex;align-items:center;justify-content:space-between;padding:0 16px;font-size:11.5px;color:#1C1B1A;">
          <div style="display:flex;align-items:center;gap:14px;">
            ${appleGlyph("#1C1B1A")}
            <span style="font-weight:700;">${menus[0]}</span>
            ${menus.slice(1).map(m => `<span style="font-weight:500;opacity:0.86;">${m}</span>`).join("")}
          </div>
          <div style="display:flex;align-items:center;gap:10px;font-weight:500;">
            ${macStatusIcons("#1C1B1A", 0.90)}
            <span>${clock}</span>
          </div>
        </div>
        <div style="position:absolute;top:31px;left:43px;width:980px;height:651px;border-radius:11px;overflow:hidden;background:#F5F3EF;box-shadow:0 20px 52px rgba(18,12,8,0.40), 0 0 0 0.75px rgba(28,27,26,0.18);">
          <div style="height:26px;display:flex;align-items:center;position:relative;border-bottom:1px solid rgba(28,27,26,0.06);box-sizing:border-box;">
            <div style="width:336px;height:100%;background:#EDE9E0;display:flex;align-items:center;padding-left:12px;box-sizing:border-box;">
              ${trafficLights(10.5, 6.5)}
            </div>
            <div style="flex:1;height:100%;background:#F5F3EF;display:flex;align-items:center;justify-content:center;font-size:11.5px;font-weight:600;color:rgba(28,27,26,0.58);padding-right:336px;">
              ${winTitle}
            </div>
          </div>
          <img src="${imgUrl}" style="display:block;width:980px;height:625px;">
        </div>
      </body></html>`
    };
  }

  const wMenus = isZh
    ? ["Safari 浏览器", "文件", "编辑", "显示", "历史记录", "书签", "窗口", "帮助"]
    : ["Safari", "File", "Edit", "View", "History", "Bookmarks", "Window", "Help"];
  const wClock = isZh ? "周五 09:41" : "Fri 9:41 AM";
  return {
    w: 1360, h: 765, dpr: 3,
    html: `<!doctype html><html><body style="margin:0;width:1360px;height:765px;overflow:hidden;position:relative;font-family:${font};background:linear-gradient(135deg,#9E8D7C 0%,#7A6A5B 48%,#56493F 100%);">
      <div style="position:absolute;inset:0;background:radial-gradient(ellipse 70% 58% at 18% 18%, rgba(255,236,210,0.34), transparent 64%), radial-gradient(ellipse 60% 55% at 86% 84%, rgba(34,26,20,0.40), transparent 64%);"></div>
      <div style="position:relative;z-index:2;height:24px;background:rgba(246,243,238,0.88);border-bottom:1px solid rgba(28,27,26,0.08);box-sizing:border-box;display:flex;align-items:center;justify-content:space-between;padding:0 16px;font-size:11.5px;color:#1C1B1A;">
        <div style="display:flex;align-items:center;gap:14px;">
          ${appleGlyph("#1C1B1A")}
          <span style="font-weight:700;">${wMenus[0]}</span>
          ${wMenus.slice(1).map(m => `<span style="font-weight:500;opacity:0.86;">${m}</span>`).join("")}
        </div>
        <div style="display:flex;align-items:center;gap:10px;font-weight:500;">
          ${macStatusIcons("#1C1B1A", 0.90)}
          <span>${wClock}</span>
        </div>
      </div>
      <div style="position:absolute;top:34px;left:110px;width:1140px;height:718px;border-radius:12px;overflow:hidden;background:#F5F3EF;box-shadow:0 24px 62px rgba(18,12,8,0.42), 0 0 0 0.75px rgba(28,27,26,0.18);">
        <div style="height:38px;background:linear-gradient(180deg,#F4F1EB 0%,#EAE6DE 100%);border-bottom:1px solid rgba(28,27,26,0.10);box-sizing:border-box;display:flex;align-items:center;padding:0 15px;position:relative;">
          ${trafficLights(11, 7)}
          <div style="display:flex;align-items:center;gap:12px;margin-left:18px;color:rgba(28,27,26,0.44);">
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.5 5.5 8 10 12.5"/></svg>
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5 10.5 8 6 12.5"/></svg>
          </div>
          <div style="position:absolute;left:50%;transform:translateX(-50%);width:368px;height:24px;border-radius:6.5px;background:rgba(255,255,255,0.78);border:1px solid rgba(28,27,26,0.09);display:flex;align-items:center;justify-content:center;gap:6px;font-size:12px;font-weight:500;color:#2E2D2A;letter-spacing:-0.01em;">
            <svg width="9.5" height="10.5" viewBox="0 0 12 14" fill="none"><rect x="1.5" y="6" width="9" height="6.8" rx="1.6" fill="#6F6B64"/><path d="M3.5 6V4.3a2.5 2.5 0 0 1 5 0V6" stroke="#6F6B64" stroke-width="1.5" stroke-linecap="round"/></svg>
            <span>app.monoid.build</span>
          </div>
        </div>
        <img src="${imgUrl}" style="display:block;width:1140px;height:680px;">
      </div>
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
