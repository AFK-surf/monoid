// Whether this browser can draw the app, and what to do where it cannot. mbui's web host draws with WebGL 2 alone
// (libs/ui/web/host.js setupGL): with a browser's graphics acceleration off, `getContext("webgl2")` is null, the host
// threw on it and the page stayed white after fetching megabytes of the app for nothing. So the page asks first
// (start.ts), on a canvas of its own, never the app's `#c`: the context a canvas first gives is the only one it ever
// gives, and the host asks `#c` for its own attributes (alpha, premultiplied, no antialias). Where there is none, the
// app is not fetched and the page says how to turn acceleration on in the browser it is in (gpu-page.ts).
// Kept free of the DOM's globals so test/mbui-gpu.test.ts runs it in Node.

/** A canvas's one call the probe makes, and the extension that gives back what it took. */
interface Probed {
  getContext(kind: "webgl2"): { getExtension(name: string): { loseContext(): void } | null } | null;
}

/** Whether a WebGL 2 context can be had, asked of a canvas `make` gives (a new one, never the app's): its context let go
 *  at once, so the probe holds none of the few a browser allows while the app runs. */
export function hasWebgl2(make: () => Probed): boolean {
  let gl: ReturnType<Probed["getContext"]> = null;
  try {
    gl = make().getContext("webgl2");
  } catch {
    return false;
  }
  if (!gl) return false;
  try {
    gl.getExtension("WEBGL_lose_context")?.loseContext();
  } catch {
    // (kept till the canvas is collected: the probe's answer stands)
  }
  return true;
}

/** The browser as far as its steps differ: Chromium's ones by the scheme their settings pages are on. */
export type Browser =
  | { kind: "chromium"; name: string; scheme: "chrome" | "edge" | "brave" | "opera" }
  | { kind: "firefox" }
  | { kind: "safari" }
  | { kind: "other" };

/** Which browser `ua` is (`brave`: navigator.brave is there, Brave saying Chrome in its agent). A phone's Chromium has
 *  no system settings page: it is told the general steps. */
export function browserOf(ua: string, brave = false): Browser {
  const phone = /Android|iPhone|iPad|iPod|Mobile/.test(ua);
  if (/Firefox\/|FxiOS\//.test(ua)) return { kind: "firefox" };
  if (!phone && /Edg\//.test(ua)) return { kind: "chromium", name: "Edge", scheme: "edge" };
  if (!phone && /OPR\//.test(ua)) return { kind: "chromium", name: "Opera", scheme: "opera" };
  if (!phone && /Chrome\//.test(ua)) return brave ? { kind: "chromium", name: "Brave", scheme: "brave" } : { kind: "chromium", name: "Chrome", scheme: "chrome" };
  if (/Safari\//.test(ua) && !/Chrome\/|CriOS\/|EdgiOS\//.test(ua)) return { kind: "safari" };
  return { kind: "other" };
}

/** Whether the page speaks Chinese: the language the app was set to on this device where the web's pages kept it
 *  (src/prefs.ts' copy, `stillfail.prefs`), else the browser's. */
export function chineseFor(navigatorLanguage: string, kept: string | null): boolean {
  let lang = "";
  try {
    const prefs = kept ? (JSON.parse(kept) as { language?: unknown; lang?: unknown }) : null;
    const said = prefs?.language ?? prefs?.lang;
    if (typeof said === "string") lang = said;
  } catch {
    // unreadable: the browser's
  }
  if (!/^(zh|en)/i.test(lang)) lang = navigatorLanguage;
  return /^zh/i.test(lang);
}

/** A part of a step's words: plain, or the name of a setting or a button (drawn stronger). */
export type Words = string | { b: string };
/** A step: its words, and an address to open (with a button that copies it) where it has one. */
export interface Step { words: Words[]; address?: string }
export interface Guide { title: string; lead: string; steps: Step[]; note: Words[]; retry: string; copy: string; copied: string; copyBy: string }

/** What the page says, for `b`, in Chinese or English. */
export function guideFor(b: Browser, zh: boolean): Guide {
  const name = b.kind === "chromium" ? b.name : b.kind === "firefox" ? "Firefox" : b.kind === "safari" ? "Safari" : zh ? "这个浏览器" : "this browser";
  const base = {
    title: zh ? "打开浏览器的硬件加速" : "Turn on hardware acceleration",
    lead: zh
      ? `still.fail 用显卡绘制界面，需要 WebGL 2。${b.kind === "other" ? name : `${name} `}现在没有开启图形硬件加速，界面画不出来。按下面的步骤打开后，点「重试」。`
      : `still.fail draws with your graphics card and needs WebGL 2. ${b.kind === "other" ? "This browser" : name} has graphics acceleration turned off, so nothing can be drawn. Turn it on as below, then press Retry.`,
    retry: zh ? "重试" : "Retry",
    copy: zh ? "复制" : "Copy",
    copied: zh ? "已复制" : "Copied",
    copyBy: zh ? "选中地址后手动复制" : "Select the address to copy it",
  };
  if (b.kind === "chromium") {
    const setting = zh
      ? b.scheme === "edge" ? "在可用时使用图形加速" : b.scheme === "opera" ? "可用时使用硬件加速" : "使用图形加速功能（如果可用）"
      : b.scheme === "opera" ? "Use hardware acceleration when available" : "Use graphics acceleration when available";
    return {
      ...base,
      steps: [
        { words: [zh ? "在新标签页的地址栏打开：" : "Open this address in a new tab:"], address: `${b.scheme}://settings/system` },
        { words: zh ? ["打开", { b: `「${setting}」` }, "。"] : ["Turn on ", { b: setting }, "."] },
        { words: zh ? ["点设置旁出现的", { b: "「重新启动」" }, "，再回到这里点「重试」。"] : ["Press ", { b: "Relaunch" }, ", then come back here and press Retry."] },
      ],
      note: zh
        ? ["已经打开了？在地址栏打开 ", { b: `${b.scheme}://gpu` }, "，看 WebGL2 一项是否为 Hardware accelerated；若是 Disabled，更新显卡驱动或浏览器后再试。"]
        : ["Already on? Open ", { b: `${b.scheme}://gpu` }, " and check that WebGL2 says Hardware accelerated. If it says Disabled, update your graphics driver or the browser."],
    };
  }
  if (b.kind === "firefox") {
    return {
      ...base,
      steps: [
        { words: [zh ? "在新标签页的地址栏打开：" : "Open this address in a new tab:"], address: "about:preferences#general" },
        {
          words: zh
            ? ["在", { b: "「性能」" }, "里取消勾选", { b: "「使用推荐的性能设置」" }, "，再勾选", { b: "「自动启用硬件加速」" }, "。"]
            : ["Under ", { b: "Performance" }, ", clear ", { b: "Use recommended performance settings" }, ", then turn on ", { b: "Use hardware acceleration when available" }, "."],
        },
        { words: [zh ? "重新启动 Firefox，再回到这里点「重试」。" : "Restart Firefox, then come back here and press Retry."] },
      ],
      note: zh
        ? ["已经打开了？在地址栏打开 ", { b: "about:support" }, "，看 WebGL 2 的渲染器一项是否写着你的显卡。"]
        : ["Already on? Open ", { b: "about:support" }, " and check that WebGL 2 Driver Renderer names your graphics card."],
    };
  }
  if (b.kind === "safari") {
    return {
      ...base,
      steps: [
        { words: [zh ? "把系统和 Safari 更新到最新版本。" : "Update your system and Safari to the latest version."] },
        {
          words: zh
            ? ["若在", { b: "「开发」›「功能标志」" }, "里改过设置，确认", { b: "「WebGL 2.0」" }, "是打开的。"]
            : ["If you changed ", { b: "Develop › Feature Flags" }, ", check that ", { b: "WebGL 2.0" }, " is on."],
        },
        { words: [zh ? "退出 Safari 再打开，回到这里点「重试」。" : "Quit and reopen Safari, then come back here and press Retry."] },
      ],
      note: [zh ? "Safari 15 起都支持 WebGL 2。" : "Safari has WebGL 2 from version 15."],
    };
  }
  return {
    ...base,
    steps: [
      { words: [zh ? "把浏览器更新到最新版本。" : "Update the browser to its latest version."] },
      { words: zh ? ["在浏览器的设置里打开", { b: "「硬件加速」" }, "或", { b: "「图形加速」" }, "。"] : ["Turn on ", { b: "hardware acceleration" }, " or ", { b: "graphics acceleration" }, " in its settings."] },
      { words: [zh ? "重新启动浏览器，再回到这里点「重试」。" : "Restart the browser, then come back here and press Retry."] },
    ],
    note: [zh ? "Chrome、Edge、Firefox 和 Safari 的新版本都支持 WebGL 2。" : "Recent Chrome, Edge, Firefox and Safari all have WebGL 2."],
  };
}
