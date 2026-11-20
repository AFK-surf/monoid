// ui.monoid (ui.monoid.build) runtime:
// 1. Single-play scroll reveals (.demo, .reveal -> .in at threshold 0.33, then unobserve)
// 2. Sticky bar hairline on scroll (.bar.scrolled)
// 3. Mega-menus (Framework, Libraries) + mobile navigation drawer + active link marking
// 4. Stage tab switcher ([data-tabs]) + zero-flash in-place WebGL 2 live launcher ([data-live-src])
// 5. Copy buttons ([data-copy])
// 6. Lightweight EN / 中文 runtime i18n (data-en / data-zh)

// 1. Single-play scroll triggers for .demo blocks (.reveal is visible by default)
(() => {
  const parts = document.querySelectorAll(".demo");
  if (!parts.length) return;
  if (!("IntersectionObserver" in window)) {
    for (const p of parts) p.classList.add("in");
    return;
  }
  const seen = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.add("in");
        seen.unobserve(e.target);
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px 40px 0px" },
  );
  for (const p of parts) seen.observe(p);
})();

// 2. Sticky top bar hairline after scrolling off top
(() => {
  const bar = document.querySelector(".bar");
  if (!bar) return;
  let queued = false;
  const update = () => {
    queued = false;
    bar.classList.toggle("scrolled", window.scrollY > 4);
  };
  window.addEventListener(
    "scroll",
    () => {
      if (!queued) {
        queued = true;
        requestAnimationFrame(update);
      }
    },
    { passive: true },
  );
  update();
})();

// 3. Mega-menus, mobile drawer, active nav link
(() => {
  const bar = document.querySelector(".bar");
  if (!bar) return;
  const triggers = [...bar.querySelectorAll("[data-mega]")];
  const hoverable = window.matchMedia("(hover: hover) and (min-width: 861px)");
  let timer = 0;
  let hoverOpenedAt = 0;

  const shut = (except) => {
    for (const t of triggers) {
      if (t === except) continue;
      t.setAttribute("aria-expanded", "false");
      document.getElementById(t.dataset.mega)?.classList.remove("open");
    }
  };
  const open = (t) => {
    shut(t);
    t.setAttribute("aria-expanded", "true");
    document.getElementById(t.dataset.mega)?.classList.add("open");
  };

  for (const t of triggers) {
    const menu = document.getElementById(t.dataset.mega);
    t.addEventListener("click", () => {
      if (t.getAttribute("aria-expanded") === "true") {
        if (Date.now() - hoverOpenedAt < 400) return;
        shut();
      } else {
        open(t);
      }
    });
    for (const el of [t, menu]) {
      el?.addEventListener("pointerenter", (e) => {
        if (e.pointerType !== "mouse" || !hoverable.matches) return;
        clearTimeout(timer);
        if (t.getAttribute("aria-expanded") !== "true") {
          hoverOpenedAt = Date.now();
        }
        open(t);
      });
      el?.addEventListener("pointerleave", (e) => {
        if (e.pointerType !== "mouse" || !hoverable.matches) return;
        clearTimeout(timer);
        timer = setTimeout(() => shut(), 160);
      });
    }
  }

  // ?menu=mega-framework opens that menu directly for deterministic captures
  const asked = new URLSearchParams(location.search).get("menu");
  const askedTrigger = triggers.find((t) => t.dataset.mega === asked);
  if (askedTrigger) open(askedTrigger);

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") shut();
  });
  document.addEventListener("click", (e) => {
    if (!bar.contains(e.target)) shut();
  });

  const toggle = bar.querySelector(".menu-toggle");
  toggle?.addEventListener("click", () => {
    const on = !document.body.classList.contains("menu-open");
    document.body.classList.toggle("menu-open", on);
    toggle.setAttribute("aria-expanded", String(on));
    toggle.querySelector("use")?.setAttribute("href", `/assets/icons.svg#i-${on ? "close" : "menu"}`);
    if (!on) shut();
  });

  const here = bar.dataset.here;
  for (const a of bar.querySelectorAll(".nav > a")) {
    const href = a.getAttribute("href");
    if (href === here || (href !== "/" && here && here.startsWith(href))) {
      a.setAttribute("aria-current", "page");
    }
  }
})();

// 4. Stage tab switcher & zero-flash in-place WebGL 2 live launcher
(() => {
  for (const tabs of document.querySelectorAll("[data-tabs]")) {
    const stage = document.getElementById(tabs.dataset.tabs);
    if (!stage) continue;
    const buttons = [...tabs.querySelectorAll("button")];
    for (const b of buttons) {
      b.addEventListener("click", () => {
        for (const o of buttons) o.setAttribute("aria-selected", String(o === b));
        for (const p of stage.querySelectorAll(".pane")) {
          p.classList.toggle("on", p.id === b.getAttribute("aria-controls"));
        }
      });
    }
  }

  const hasWebGL2 = () => {
    try {
      const gl = document.createElement("canvas").getContext("webgl2");
      if (!gl) return false;
      gl.getExtension("WEBGL_lose_context")?.loseContext();
      return true;
    } catch {
      return false;
    }
  };

  for (const box of document.querySelectorAll("[data-live-src]")) {
    const launchBtn = box.querySelector("[data-live-launch]");
    const stageId = box.closest(".stage")?.id;
    const closeBtn = box.querySelector("[data-live-close]") || (stageId ? document.querySelector(`[data-live-close="${stageId}"]`) : null);
    const wrap = box.querySelector(".live-frame-wrap");
    const fallback = box.querySelector(".live-fallback");
    if (!launchBtn || !wrap) continue;

    if (closeBtn && closeBtn.classList.contains("live-close-dock")) {
      const syncClose = () => {
        closeBtn.hidden = !box.classList.contains("is-live");
      };
      new MutationObserver(syncClose).observe(box, { attributes: true, attributeFilter: ["class"] });
      syncClose();
    }

    launchBtn.addEventListener("click", () => {
      if (!hasWebGL2()) {
        if (fallback) fallback.hidden = false;
        return;
      }
      let frame = wrap.querySelector("iframe");
      if (!frame) {
        const label = launchBtn.querySelector("span") || launchBtn;
        const isZh = document.documentElement.dataset.lang === "zh";
        const origText = label.textContent;
        const restoreBtn = () => {
          launchBtn.disabled = false;
          const nowZh = document.documentElement.dataset.lang === "zh";
          label.textContent = label.dataset?.en && label.dataset?.zh
            ? (nowZh ? label.dataset.zh : label.dataset.en)
            : origText;
        };
        launchBtn.disabled = true;
        label.textContent = isZh ? "正在加载 WebGL 2…" : "Loading WebGL 2…";
        frame = document.createElement("iframe");
        frame.title = box.dataset.liveTitle || "Live mbui WebGL 2";
        frame.allow = "clipboard-read; clipboard-write";
        frame.addEventListener(
          "load",
          () => {
            restoreBtn();
            box.classList.add("is-live");
          },
          { once: true },
        );
        frame.addEventListener("error", restoreBtn, { once: true });
        let src = box.dataset.liveSrc;
        if (src && src.startsWith("/components/app/") && !src.includes("MBUI_LANG=")) {
          src += (src.includes("?") ? "&" : "?") + "MBUI_LANG=" + (isZh ? "zh" : "en");
        }
        frame.src = src;
        wrap.appendChild(frame);
      } else {
        box.classList.add("is-live");
      }
    });

    closeBtn?.addEventListener("click", () => {
      box.classList.remove("is-live");
    });
  }
})();

// 5. Copy buttons
(() => {
  for (const b of document.querySelectorAll("[data-copy]")) {
    b.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(b.dataset.copy);
        const lang = document.documentElement.dataset.lang === "zh" ? "zh" : "en";
        const was = b.textContent;
        b.textContent = lang === "zh" ? "已复制" : "Copied";
        setTimeout(() => {
          b.textContent = was;
        }, 1400);
      } catch {}
    });
  }
})();

// 6. Lightweight EN / 中文 runtime i18n
(() => {
  const STORAGE_KEY = "ui.monoid.lang";
  const html = document.documentElement;
  const toggle = document.getElementById("lang-toggle");

  const applyLang = (lang) => {
    const isZh = lang === "zh";
    html.lang = isZh ? "zh-CN" : "en";
    html.dataset.lang = isZh ? "zh" : "en";

    const title = isZh ? html.dataset.titleZh : html.dataset.titleEn;
    if (title) document.title = title;

    for (const el of document.querySelectorAll("[data-en][data-zh]")) {
      el.textContent = isZh ? el.dataset.zh : el.dataset.en;
    }
    for (const el of document.querySelectorAll("[data-en-aria][data-zh-aria]")) {
      el.setAttribute("aria-label", isZh ? el.dataset.zhAria : el.dataset.enAria);
    }
    for (const el of document.querySelectorAll("[data-en-placeholder][data-zh-placeholder]")) {
      el.setAttribute("placeholder", isZh ? el.dataset.zhPlaceholder : el.dataset.enPlaceholder);
    }
    if (toggle) {
      toggle.textContent = isZh ? "EN" : "中文";
      toggle.setAttribute("aria-label", isZh ? "Switch to English" : "切换到中文");
    }
  };

  const param = new URLSearchParams(location.search).get("lang");
  let initial = "en";
  if (param === "zh" || param === "en") {
    initial = param;
  } else {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved === "zh" || saved === "en") initial = saved;
    } catch {}
  }

  applyLang(initial);

  toggle?.addEventListener("click", () => {
    const next = html.dataset.lang === "zh" ? "en" : "zh";
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {}
    applyLang(next);
  });
})();
