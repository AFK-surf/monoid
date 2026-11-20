(() => {
  "use strict";

  const root = document.documentElement;
  const THEME_KEY = "stillfail.site.theme";

  // ---- Theme Switch (instant 1-frame swap) ----
  function readTheme() {
    try {
      const saved = localStorage.getItem(THEME_KEY) ?? localStorage.getItem("ember.site.theme");
      return saved === "system" || saved === "light" ? saved : "dark";
    } catch {
      return "dark";
    }
  }

  function syncThemeButtons(theme) {
    for (const btn of document.querySelectorAll("[data-theme-choice]")) {
      btn.setAttribute("aria-checked", String(btn.dataset.themeChoice === theme));
    }
  }

  function chooseTheme(theme) {
    try { localStorage.setItem(THEME_KEY, theme); } catch {}
    root.dataset.themeSwitching = "";
    if (theme === "system") delete root.dataset.theme;
    else root.dataset.theme = theme;
    void root.offsetWidth;
    requestAnimationFrame(() => requestAnimationFrame(() => delete root.dataset.themeSwitching));
    syncThemeButtons(theme);
  }

  syncThemeButtons(readTheme());
  for (const btn of document.querySelectorAll("[data-theme-choice]")) {
    btn.addEventListener("click", () => chooseTheme(btn.dataset.themeChoice));
  }

  // ---- Hero 3-Tab Switcher ----
  const tabs = [...document.querySelectorAll('.tabs [role="tab"]')];
  const panes = [...document.querySelectorAll(".stage-wide [data-pane]")];

  function selectTab(id, focus = false) {
    for (const tab of tabs) {
      const active = tab.dataset.tab === id;
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
      if (active && focus) tab.focus();
    }
    for (const pane of panes) {
      if (pane.dataset.pane === id) pane.dataset.active = "";
      else delete pane.dataset.active;
    }
  }

  for (const tab of tabs) {
    tab.addEventListener("click", () => selectTab(tab.dataset.tab));
    tab.addEventListener("keydown", (e) => {
      const idx = tabs.indexOf(tab);
      if (e.key === "ArrowRight") {
        e.preventDefault();
        selectTab(tabs[(idx + 1) % tabs.length].dataset.tab, true);
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        selectTab(tabs[(idx - 1 + tabs.length) % tabs.length].dataset.tab, true);
      } else if (e.key === "Home") {
        e.preventDefault();
        selectTab(tabs[0].dataset.tab, true);
      } else if (e.key === "End") {
        e.preventDefault();
        selectTab(tabs[tabs.length - 1].dataset.tab, true);
      }
    });
  }

  // ---- Terminal Copy Button ----
  const copyBtn = document.querySelector(".terminal-copy");
  if (copyBtn) {
    const copyLabel = copyBtn.querySelector(".terminal-copy-label") || copyBtn;
    let timer = 0;
    copyBtn.addEventListener("click", () => {
      const text = copyBtn.dataset.copy || "";
      const done = () => {
        copyLabel.textContent = "已复制";
        clearTimeout(timer);
        timer = setTimeout(() => { copyLabel.textContent = "复制"; }, 1800);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, () => { fallbackCopy(text); done(); });
      } else {
        fallbackCopy(text);
        done();
      }
    });
  }

  function fallbackCopy(text) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch {}
    ta.remove();
  }

  // ---- Motion Primitives ----
  const wait = (s) => new Promise((ok) => setTimeout(ok, s * 1000));

  function cubicBezier(x1, y1, x2, y2) {
    const sampleX = (t) => ((1 - 3 * x2 + 3 * x1) * t + (3 * x2 - 6 * x1)) * t * t + 3 * x1 * t;
    const sampleY = (t) => ((1 - 3 * y2 + 3 * y1) * t + (3 * y2 - 6 * y1)) * t * t + 3 * y1 * t;
    const slopeX = (t) => (3 * (1 - 3 * x2 + 3 * x1) * t + 2 * (3 * x2 - 6 * x1)) * t + 3 * x1;
    return (x) => {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      let t = x;
      for (let i = 0; i < 6; i++) {
        const dx = sampleX(t) - x;
        if (Math.abs(dx) < 1e-5) break;
        const d = slopeX(t);
        if (Math.abs(d) < 1e-6) break;
        t -= dx / d;
      }
      return sampleY(Math.max(0, Math.min(1, t)));
    };
  }

  const EASE_OUT = cubicBezier(0, 0, 0.58, 1);

  function tween(durationSec, easeFn, delaySec, onUpdate) {
    let raf = 0;
    let timer = 0;
    let stopped = false;
    let resolveFn;
    const finished = new Promise((r) => { resolveFn = r; });

    const start = () => {
      if (stopped) return;
      const t0 = performance.now();
      const durMs = durationSec * 1000;
      const tick = (now) => {
        if (stopped) return;
        const raw = Math.min(1, (now - t0) / durMs);
        onUpdate(easeFn(raw));
        if (raw < 1) raf = requestAnimationFrame(tick);
        else resolveFn();
      };
      raf = requestAnimationFrame(tick);
    };

    if (delaySec > 0) timer = setTimeout(start, delaySec * 1000);
    else start();

    return {
      finished,
      stop() {
        stopped = true;
        clearTimeout(timer);
        cancelAnimationFrame(raf);
        resolveFn();
      },
    };
  }

  function springParams(visualDuration, bounce) {
    const zeta = Math.max(0.05, 1 - bounce);
    const omega = (2 * Math.PI) / (visualDuration * 1.35);
    return { stiffness: omega * omega, damping: 2 * zeta * omega };
  }

  function springAnim(visualDuration, bounce, onUpdate) {
    const { stiffness, damping } = springParams(visualDuration, bounce);
    let x = 0;
    let v = 0;
    let raf = 0;
    let last = performance.now();
    let stopped = false;
    let resolveFn;
    const finished = new Promise((r) => { resolveFn = r; });

    const tick = (now) => {
      if (stopped) return;
      const dt = Math.min(0.032, (now - last) / 1000);
      last = now;
      const h = dt / 2;
      for (let i = 0; i < 2; i++) {
        const a = -stiffness * (x - 1) - damping * v;
        v += a * h;
        x += v * h;
      }
      onUpdate(x);
      if (Math.abs(1 - x) < 0.001 && Math.abs(v) < 0.01) {
        onUpdate(1);
        resolveFn();
      } else {
        raf = requestAnimationFrame(tick);
      }
    };
    raf = requestAnimationFrame(tick);

    return {
      finished,
      stop() {
        stopped = true;
        cancelAnimationFrame(raf);
        resolveFn();
      },
    };
  }

  function springFollower(initial, visualDuration, bounce, onValue) {
    const { stiffness, damping } = springParams(visualDuration, bounce);
    let x = initial;
    let v = 0;
    let target = initial;
    let raf = 0;
    let last = 0;

    const tick = (now) => {
      const dt = Math.min(0.032, (now - last) / 1000);
      last = now;
      const a = -stiffness * (x - target) - damping * v;
      v += a * dt;
      x += v * dt;
      onValue(x);
      if (Math.abs(target - x) < 0.02 && Math.abs(v) < 0.05) {
        x = target;
        v = 0;
        onValue(x);
        raf = 0;
      } else {
        raf = requestAnimationFrame(tick);
      }
    };

    return {
      to(next) {
        target = next;
        if (!raf) {
          last = performance.now();
          raf = requestAnimationFrame(tick);
        }
      },
      stop() {
        cancelAnimationFrame(raf);
        raf = 0;
      },
    };
  }

  function keyframesAt(frames, t) {
    const scaled = t * (frames.length - 1);
    const i = Math.min(frames.length - 2, Math.floor(scaled));
    const f = scaled - i;
    return frames[i] + (frames[i + 1] - frames[i]) * f;
  }

  // ---- Hero Opening Motion (~2.1s tight cadence, zero letter collision) ----
  const DEPTH = { "still.fail": 4, "youdid.wtf": 6 };

  function startHeroMotion() {
    const hero = document.getElementById("hero");
    if (!hero) return;

    if (!root.hasAttribute("data-motion")) {
      root.dataset.opened = "";
      window.dispatchEvent(new Event("stillfail-site-opened"));
      return;
    }

    const title = hero.querySelector(".title");
    const overlay = hero.querySelector(".intro");
    if (!title || !overlay) return;

    let stopped = false;
    const running = [];
    const play = (run) => { running.push(run); return run.finished.catch(() => {}); };

    // Restrained pointer parallax (±6px max)
    if (matchMedia("(hover: hover)").matches) {
      const lines = [...hero.querySelectorAll("[data-domain]")].map((el) => {
        const depth = DEPTH[el.dataset.domain || ""] ?? 5;
        let x = 0, y = 0;
        const draw = () => { el.style.transform = `translate3d(${x}px, ${y}px, 0)`; };
        const fx = springFollower(0, 0.5, 0.35, (v) => { x = v; draw(); });
        const fy = springFollower(0, 0.5, 0.35, (v) => { y = v; draw(); });
        return { depth, fx, fy };
      });
      hero.addEventListener("pointermove", (e) => {
        const r = hero.getBoundingClientRect();
        const nx = ((e.clientX - r.left) / r.width) * 2 - 1;
        const ny = ((e.clientY - r.top) / r.height) * 2 - 1;
        for (const l of lines) {
          l.fx.to(nx * l.depth);
          l.fy.to(ny * l.depth * 0.5);
        }
      });
      hero.addEventListener("pointerleave", () => {
        for (const l of lines) { l.fx.to(0); l.fy.to(0); }
      });
    }

    (async () => {
      const large = [...overlay.querySelectorAll(".intro-char")];
      const glyphs = [...title.querySelectorAll(".dot-glyph")].map((el, i) => {
        const big = large[i];
        const look = getComputedStyle(big);
        const now = getComputedStyle(el);
        const rest = { fontSize: now.fontSize, fontWeight: now.fontWeight, color: now.color };
        Object.assign(el.style, {
          fontSize: look.fontSize,
          fontWeight: look.fontWeight,
          color: look.color,
        });
        return { el, big, line: big.closest(".intro-line"), x: 0, y: 0, rest };
      });

      const measure = () => {
        for (const g of glyphs) {
          const from = g.big.getBoundingClientRect();
          const box = g.el.parentElement.getBoundingClientRect();
          g.x = from.left + from.width / 2 - (box.left + box.width / 2);
          g.y = from.top + from.height / 2 - (box.top + box.height / 2);
        }
      };

      let holding = true;
      let tracking = true;
      const track = () => {
        if (!tracking) return;
        measure();
        if (holding) {
          for (const g of glyphs) g.el.style.translate = `${g.x}px ${g.y}px`;
        }
        requestAnimationFrame(track);
      };
      track();

      const stage = title.parentElement;
      const shake = (hard) => {
        const xs = [0, -hard, hard * 0.75, -hard * 0.4, hard * 0.2, 0];
        const ys = [0, hard * 0.35, -hard * 0.25, 0, 0, 0];
        return play(tween(0.22, EASE_OUT, 0, (t) => {
          const sx = keyframesAt(xs, t);
          const sy = keyframesAt(ys, t);
          stage.style.transform = t < 1 ? `translate3d(${sx}px, ${sy}px, 0)` : "";
        }));
      };

      // Phase 1 (~1.15s): Tight slam-in, JB hits hardest with clamped scale >= 0.92
      for (const line of overlay.querySelectorAll(".intro-line")) {
        const own = glyphs.filter((g) => g.line === line);
        for (let i = 0; i < own.length; i++) {
          if (stopped) return;
          const g = own[i];
          const last = i === own.length - 1;
          const hard = line.dataset.line === "youdid.wtf" && i >= own.length - 2;
          const fromScale = hard ? 3.8 : 2.6;
          const fromRot = (Math.random() - 0.5) * (hard ? 44 : 26);
          void play(springAnim(0.22, 0.42, (p) => {
            const clamped = Math.max(0, Math.min(1, p));
            const s = p <= 1 ? fromScale + (1 - fromScale) * p : Math.max(0.92, 1 - (p - 1) * 0.45);
            const r = fromRot * (1 - p);
            const blur = Math.max(0, 10 * (1 - clamped));
            g.el.style.opacity = String(clamped);
            g.el.style.transform = `scale(${s}) rotate(${r}deg)`;
            g.el.style.filter = blur > 0.05 ? `blur(${blur}px)` : "none";
          }));
          setTimeout(() => { if (!stopped) void shake(hard ? 11 : 4); }, 130);
          await wait(last ? 0.14 : hard ? 0.13 : 0.08);
        }
        await wait(0.18);
      }

      // Brief fuming tremble
      const fuming = glyphs.filter((g) => g.line.dataset.line === "youdid.wtf").map((g) => g.el);
      const fumeFrames = [0, -2.5, 2.5, -1.5, 1.5, 0];
      const fume = tween(0.22, (t) => t, 0, (t) => {
        const deg = keyframesAt(fumeFrames, t);
        for (const el of fuming) el.style.transform = `rotate(${deg}deg)`;
      });
      void play(fume);
      await wait(0.22);
      fume.stop();
      if (stopped) return;

      // Phase 2 (~0.95s): Characters shrink fast and spin cleanly ±360° into dot;
      // English radial reveal starts at 65% of fly (~0.48s delay) so zero mid-air collision.
      const easeWord = cubicBezier(0.4, 0, 0.2, 1);
      const easeFly = cubicBezier(0.65, 0, 0.2, 1);

      const reveal = [...title.querySelectorAll("[data-domain]")].flatMap((line) => {
        const dotEl = line.querySelector(".dot");
        return [...line.querySelectorAll(".word")].map((el) => {
          const draw = (t) => {
            const dot = dotEl.getBoundingClientRect();
            const box = el.getBoundingClientRect();
            const far = Math.hypot(Math.max(Math.abs(dot.left - box.left), Math.abs(box.right - dot.left)), box.height);
            el.style.clipPath = `circle(${far * t}px at ${dot.left - box.left}px ${dot.top - box.top - box.height * 0.08}px)`;
          };
          draw(0);
          el.style.opacity = "1";
          return play(tween(0.62, easeWord, 0.48, draw)).then(() => {
            el.style.removeProperty("clip-path");
          });
        });
      });

      holding = false;
      const fly = glyphs.map((g, i) => {
        const from = {
          size: parseFloat(g.el.style.fontSize),
          weight: parseFloat(g.el.style.fontWeight),
          color: g.el.style.color,
        };
        const to = {
          size: parseFloat(g.rest.fontSize),
          weight: parseFloat(g.rest.fontWeight),
          color: g.rest.color,
        };
        const turn = i % 2 ? 360 : -360;
        const delay = (glyphs.length - 1 - i) * 0.022;
        return play(tween(0.68, easeFly, delay, (t) => {
          const at = (a, b) => a + (b - a) * t;
          const sizeT = Math.pow(t, 0.55);
          const rotT = Math.pow(t, 1.35);
          g.el.style.fontSize = `${from.size + (to.size - from.size) * sizeT}px`;
          g.el.style.fontWeight = `${Math.round(at(from.weight, to.weight))}`;
          g.el.style.color = t < 1 ? `color-mix(in srgb, ${to.color} ${t * 100}%, ${from.color})` : to.color;
          g.el.style.translate = `${g.x * (1 - t)}px ${g.y * (1 - t)}px`;
          g.el.style.transform = `rotate(${turn * rotT}deg)`;
        }));
      });

      await Promise.all(fly);
      tracking = false;
      if (stopped) return;

      root.dataset.opened = "";
      for (const g of glyphs) {
        for (const p of ["font-size", "font-weight", "color", "translate", "transform", "filter"]) {
          g.el.style.removeProperty(p);
        }
        g.el.style.opacity = "1";
      }
      overlay.style.display = "none";
      await Promise.all(reveal);
      for (const el of title.querySelectorAll(".word")) el.style.removeProperty("clip-path");
      window.dispatchEvent(new Event("stillfail-site-opened"));
    })();
  }

  // ---- Terminal Scroll Reveal (IntersectionObserver) ----
  const term = document.querySelector(".terminal.reveal");
  if (term) {
    const show = () => { term.dataset.visible = ""; };
    if (
      root.hasAttribute("data-still") ||
      matchMedia("(prefers-reduced-motion: reduce)").matches ||
      typeof IntersectionObserver === "undefined"
    ) {
      show();
    } else {
      const rect = term.getBoundingClientRect();
      if (rect.top < window.innerHeight * 0.92 && rect.bottom > 0) {
        show();
      } else {
        const io = new IntersectionObserver(
          (entries) => {
            if (entries.some((e) => e.isIntersecting)) {
              show();
              io.disconnect();
            }
          },
          { threshold: 0.2 },
        );
        io.observe(term);
      }
    }
  }

  startHeroMotion();
})();
