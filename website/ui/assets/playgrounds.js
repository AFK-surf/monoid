// ui.monoid V3 Homepage Interactive Playgrounds (zero dependencies):
// 1. Playable Demo 1: Retained Tree & Fine-Grained Signals
// 2. Playable Demo 2: Closed-Form Spring Physics Lab (120 / 60 / 24 / 7 fps)
// 3. Playable Demo 3: Deterministic Offscreen Tester & Clipping Fault Injector

(() => {
  const isZh = () => document.documentElement.dataset.lang === "zh";
  const reducedMotion = () => window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches ?? false;
  const langListeners = [];
  const onLangChange = (fn) => langListeners.push(fn);

  new MutationObserver(() => {
    for (const fn of langListeners) fn();
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-lang"] });

  const observeOnce = (el, cb) => {
    if (!el) return;
    if (reducedMotion() || !("IntersectionObserver" in window)) return;
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          io.unobserve(el);
          cb();
        }
      },
      { threshold: 0.35 },
    );
    io.observe(el);
  };

  // ── 1. Playable Demo 1: Retained Tree & Fine-Grained Signals ──
  (() => {
    const root = document.getElementById("demo-signals");
    if (!root) return;

    const codeLine = document.getElementById("sig-code-line");
    const preview = document.getElementById("sig-preview");
    const previewBtn = document.getElementById("sig-preview-btn");
    const unreadPill = document.getElementById("sig-unread-pill");
    const unreadBtn = document.getElementById("sig-unread-btn");
    const statText = document.getElementById("sig-stat-text");
    const barFill = document.getElementById("sig-bar-fill");
    const colorBtns = [...root.querySelectorAll("[data-sig-color]")];
    const nodes = [...root.querySelectorAll(".sig-node")];

    let unreadCount = 3;
    let lastKind = "color"; // "color" | "unread"
    let lastAccent = "#ef6334";
    let lastSoft = "rgba(239, 99, 52, 0.14)";
    let interacted = false;

    const updateStat = () => {
      if (!statText) return;
      if (lastKind === "unread") {
        statText.dataset.en = "1 / 148 nodes touched · 0.08 ms · 0 tree diffs";
        statText.dataset.zh = "1 / 148 节点更新 · 0.08 ms · 0 次树对比";
      } else {
        statText.dataset.en = "2 / 148 nodes touched · 0.14 ms · 0 tree diffs";
        statText.dataset.zh = "2 / 148 节点更新 · 0.14 ms · 0 次树对比";
      }
      statText.textContent = isZh() ? statText.dataset.zh : statText.dataset.en;
    };

    const setDirtyNodes = (dirtySet, accent, soft) => {
      for (const node of nodes) {
        const key = node.dataset.node;
        const dirty = dirtySet.has(key);
        const tag = node.querySelector(".sig-state");
        node.classList.remove("is-flash");
        node.classList.toggle("is-dirty", dirty);
        node.style.setProperty("--sig-node-accent", accent);
        node.style.setProperty("--sig-node-soft", soft);
        node.style.setProperty("--sig-node-flash", soft.replace("0.14", "0.34"));
        if (tag) {
          tag.classList.toggle("sig-tag-dirty", dirty);
          tag.classList.toggle("plain", !dirty);
          tag.dataset.en = dirty ? "painted" : "skipped";
          tag.dataset.zh = dirty ? "已重绘" : "跳过";
          tag.textContent = isZh() ? tag.dataset.zh : tag.dataset.en;
        }
        if (dirty) {
          void node.offsetWidth;
          node.classList.add("is-flash");
        }
      }
    };

    const applyColor = (name, hex, soft, animate = true) => {
      lastKind = "color";
      lastAccent = hex;
      lastSoft = soft;
      if (codeLine) codeLine.textContent = `accent.set("${name}")`;
      if (preview) {
        preview.style.setProperty("--sig-accent", hex);
        preview.style.setProperty("--sig-soft", soft);
      }
      for (const b of colorBtns) {
        const active = b.dataset.sigColor === name;
        b.classList.toggle("is-active", active);
        b.setAttribute("aria-pressed", String(active));
      }
      setDirtyNodes(new Set(["button", "ring"]), hex, soft);
      if (barFill) {
        barFill.style.width = "14%";
        barFill.style.background = hex;
      }
      if (animate && previewBtn) {
        previewBtn.classList.add("is-bump");
        setTimeout(() => previewBtn.classList.remove("is-bump"), 180);
      }
      updateStat();
    };

    const applyUnread = () => {
      lastKind = "unread";
      unreadCount += 1;
      if (codeLine) codeLine.textContent = `unread.set(${unreadCount})`;
      if (unreadPill) {
        unreadPill.textContent = String(unreadCount);
        unreadPill.classList.add("is-bump");
        setTimeout(() => unreadPill.classList.remove("is-bump"), 220);
      }
      setDirtyNodes(new Set(["badge"]), "#171717", "rgba(23, 23, 23, 0.09)");
      if (barFill) {
        barFill.style.width = "8%";
        barFill.style.background = "#171717";
      }
      updateStat();
    };

    for (const btn of colorBtns) {
      btn.addEventListener("click", () => {
        interacted = true;
        applyColor(btn.dataset.sigColor, btn.dataset.hex, btn.dataset.soft, true);
      });
    }

    unreadBtn?.addEventListener("click", () => {
      interacted = true;
      applyUnread();
    });

    onLangChange(() => {
      updateStat();
      for (const node of nodes) {
        const tag = node.querySelector(".sig-state");
        if (tag && tag.dataset.en && tag.dataset.zh) {
          tag.textContent = isZh() ? tag.dataset.zh : tag.dataset.en;
        }
      }
    });

    // Auto-demo once on scroll-in: briefly transition from Ink to Vermilion
    observeOnce(root, () => {
      if (interacted) return;
      if (preview) {
        preview.style.setProperty("--sig-accent", "#171717");
        preview.style.setProperty("--sig-soft", "rgba(23, 23, 23, 0.1)");
      }
      if (codeLine) codeLine.textContent = 'accent.set("ink")';
      setTimeout(() => {
        if (!interacted) applyColor("vermilion", "#ef6334", "rgba(239, 99, 52, 0.14)", true);
      }, 420);
    });
  })();

  // ── 3. Playable Demo 2: Closed-Form Spring Physics Lab ──
  (() => {
    const root = document.getElementById("demo-motion");
    if (!root) return;

    const PRESETS = {
      snappy: { k: 320, d: 28, duration: 920 },
      bouncy: { k: 260, d: 14, duration: 1450 },
      gentle: { k: 140, d: 22, duration: 1350 },
    };

    const paramsEl = document.getElementById("mot-params");
    const clockEl = document.getElementById("mot-clock");
    const refEl = document.getElementById("mot-ref");
    const refLabel = document.getElementById("mot-ref-label");
    const deltaEl = document.getElementById("mot-delta");
    const statusEl = document.getElementById("mot-status");
    const replayBtn = document.getElementById("mot-replay");
    const interruptBtn = document.getElementById("mot-interrupt");
    const presetBtns = [...root.querySelectorAll("[data-spring-preset]")];
    const lanes = [...root.querySelectorAll(".mot-lane")].map((el) => ({
      el,
      fps: Number(el.dataset.fps) || 60,
      rail: el.querySelector(".mot-rail"),
      fill: el.querySelector(".mot-fill"),
      ball: el.querySelector(".mot-ball"),
    }));

    // Closed-form damped harmonic oscillator (mass = 1)
    const evalSpring = (k, d, x0, v0, target, tSec) => {
      if (tSec <= 0) return { x: x0, v: v0 };
      const disp = x0 - target;
      const w0 = Math.sqrt(k);
      const zeta = d / (2 * w0);

      if (zeta < 1) {
        const wd = w0 * Math.sqrt(1 - zeta * zeta);
        const env = Math.exp(-zeta * w0 * tSec);
        const c1 = disp;
        const c2 = (v0 + zeta * w0 * disp) / wd;
        const cos = Math.cos(wd * tSec);
        const sin = Math.sin(wd * tSec);
        const x = target + env * (c1 * cos + c2 * sin);
        const v = env * ((c2 * wd - c1 * zeta * w0) * cos - (c1 * wd + c2 * zeta * w0) * sin);
        return { x, v };
      }
      if (Math.abs(zeta - 1) < 1e-6) {
        const env = Math.exp(-w0 * tSec);
        const c2 = v0 + w0 * disp;
        const x = target + env * (disp + c2 * tSec);
        const v = env * (v0 - w0 * c2 * tSec);
        return { x, v };
      }
      const s = Math.sqrt(zeta * zeta - 1);
      const r1 = -w0 * (zeta - s);
      const r2 = -w0 * (zeta + s);
      const c1 = (v0 - r2 * disp) / (r1 - r2);
      const c2 = disp - c1;
      const e1 = Math.exp(r1 * tSec);
      const e2 = Math.exp(r2 * tSec);
      return {
        x: target + c1 * e1 + c2 * e2,
        v: c1 * r1 * e1 + c2 * r2 * e2,
      };
    };

    const START_P = 0.08;
    const END_P = 0.84;
    const toTrack = (norm) => Math.max(0.03, Math.min(0.97, START_P + norm * (END_P - START_P)));

    let presetKey = "snappy";
    let rafId = 0;
    let mode = "replay"; // "replay" | "interrupt"

    const setStatus = (en, zh) => {
      if (!statusEl) return;
      statusEl.dataset.en = en;
      statusEl.dataset.zh = zh;
      statusEl.textContent = isZh() ? zh : en;
    };

    const paintPosition = (lane, norm) => {
      const p = toTrack(norm);
      lane.el.style.setProperty("--p", p.toFixed(4));
    };

    const paintSettled = (finalNorm, durationMs) => {
      const p = toTrack(finalNorm);
      for (const lane of lanes) lane.el.style.setProperty("--p", p.toFixed(4));
      if (refEl) refEl.style.setProperty("--ref-pos", p.toFixed(4));
      if (refLabel) refLabel.textContent = `t = ${Math.round(durationMs)} ms`;
      if (clockEl) clockEl.textContent = `t = ${Math.round(durationMs)} ms`;
      if (deltaEl) deltaEl.textContent = "Δ = 0.00 px";
    };

    const runSpring = (nextMode) => {
      cancelAnimationFrame(rafId);
      mode = nextMode;
      const preset = PRESETS[presetKey] || PRESETS.snappy;
      if (paramsEl) paramsEl.textContent = `spring(k: ${preset.k}, d: ${preset.d})`;

      const interruptAt = 140; // ms
      const isInterrupt = mode === "interrupt";
      const totalMs = isInterrupt ? preset.duration + interruptAt : preset.duration;

      // Analytic state at interrupt point (0 -> 1 evaluated at 140ms)
      const mid = evalSpring(preset.k, preset.d, 0, 0, 1, interruptAt / 1000);
      const evalAtMs = (ms) => {
        if (!isInterrupt) {
          return evalSpring(preset.k, preset.d, 0, 0, 1, ms / 1000).x;
        }
        if (ms < interruptAt) {
          return evalSpring(preset.k, preset.d, 0, 0, 1, ms / 1000).x;
        }
        // Reverse target to 0 while preserving exact analytic velocity mid.v
        return evalSpring(preset.k, preset.d, mid.x, mid.v, 0, (ms - interruptAt) / 1000).x;
      };

      const finalTarget = isInterrupt ? 0 : 1;

      if (isInterrupt) {
        setStatus(
          "Interrupted at 140 ms — velocity preserved across all 4 frame rates",
          "140 ms 中途折返——四种帧率无缝继承速度，零跳变",
        );
      } else {
        setStatus(
          "All 4 frame rates sample the exact same analytic x(t)",
          "四种帧率实时采样同一闭式方程 x(t)",
        );
      }

      if (reducedMotion()) {
        paintSettled(finalTarget, totalMs);
        return;
      }

      const t0 = performance.now();
      const tick = (now) => {
        const elapsed = Math.min(now - t0, totalMs);
        const exactX = elapsed >= totalMs ? finalTarget : evalAtMs(elapsed);
        const refP = toTrack(exactX);

        if (refEl) refEl.style.setProperty("--ref-pos", refP.toFixed(4));
        if (clockEl) clockEl.textContent = `t = ${Math.round(elapsed)} ms`;
        if (refLabel) {
          refLabel.textContent = isInterrupt && elapsed >= interruptAt ? "reversed @ 140ms" : `t = ${Math.round(elapsed)} ms`;
        }

        for (const lane of lanes) {
          if (elapsed >= totalMs) {
            paintPosition(lane, finalTarget);
          } else {
            const stepMs = 1000 / lane.fps;
            const sampledMs = Math.floor(elapsed / stepMs) * stepMs;
            paintPosition(lane, evalAtMs(sampledMs));
          }
        }

        if (elapsed < totalMs) {
          rafId = requestAnimationFrame(tick);
        } else {
          paintSettled(finalTarget, totalMs);
          if (isInterrupt) {
            setStatus(
              "Reversed cleanly from 140 ms — all 4 frame rates settled together",
              "140 ms 折返完成——四种帧率同时精准落点",
            );
          } else {
            setStatus(
              "All 4 frame rates land on the exact same pixel",
              "四种帧率精确抵达同一像素",
            );
          }
        }
      };

      rafId = requestAnimationFrame(tick);
    };

    replayBtn?.addEventListener("click", () => runSpring("replay"));
    interruptBtn?.addEventListener("click", () => runSpring("interrupt"));

    for (const btn of presetBtns) {
      btn.addEventListener("click", () => {
        presetKey = btn.dataset.springPreset || "snappy";
        for (const b of presetBtns) {
          const active = b === btn;
          b.classList.toggle("is-active", active);
          b.setAttribute("aria-pressed", String(active));
        }
        runSpring("replay");
      });
    }

    onLangChange(() => {
      if (statusEl && statusEl.dataset.en && statusEl.dataset.zh) {
        statusEl.textContent = isZh() ? statusEl.dataset.zh : statusEl.dataset.en;
      }
    });

    // Settled initial state before scroll-in
    paintSettled(1, 480);

    observeOnce(root, () => {
      runSpring("replay");
    });
  })();

  // ── 4. Playable Demo 3: Interactive Tester & Visual Audit ──
  (() => {
    const root = document.getElementById("demo-tester");
    if (!root) return;

    const runBtn = document.getElementById("tst-run-btn");
    const faultBtn = document.getElementById("tst-fault-btn");
    const faultLabel = document.getElementById("tst-fault-label");
    const preview = document.getElementById("tst-preview");
    const previewBadge = document.getElementById("tst-preview-badge");
    const clipCallout = document.getElementById("tst-clip-callout");
    const clipRow = root.querySelector('[data-check="clip_bounds"]');
    const clipVal = document.getElementById("tst-clip-val");
    const clipBadge = document.getElementById("tst-clip-badge");
    const faultLog = document.getElementById("tst-fault-log");
    const foot = document.getElementById("tst-foot");
    const summary = document.getElementById("tst-summary");
    const timeEl = document.getElementById("tst-time");
    const rows = [...root.querySelectorAll(".tst-row")];

    let hasFault = false;

    const setFaultButtonMode = (faultActive) => {
      if (!faultBtn || !faultLabel) return;
      faultBtn.dataset.mode = faultActive ? "fix" : "inject";
      faultLabel.dataset.en = faultActive ? "Fix & Re-run" : "Inject Clipping Fault";
      faultLabel.dataset.zh = faultActive ? "修复并重跑" : "注入截断故障";
      faultLabel.textContent = isZh() ? faultLabel.dataset.zh : faultLabel.dataset.en;
    };

    const pulseRows = () => {
      rows.forEach((row, idx) => {
        row.classList.remove("is-pulse");
        setTimeout(() => {
          if (!row.classList.contains("is-fault")) {
            row.classList.add("is-pulse");
            setTimeout(() => row.classList.remove("is-pulse"), 240);
          }
        }, idx * 45);
      });
    };

    const renderClean = (animate = true) => {
      hasFault = false;
      preview?.classList.remove("has-fault");
      if (previewBadge) previewBadge.textContent = "0 faults";
      if (clipCallout) clipCallout.hidden = true;
      clipRow?.classList.remove("is-fault");
      if (clipVal) clipVal.textContent = "0";
      if (clipBadge) {
        clipBadge.textContent = "PASS";
        clipBadge.classList.remove("is-fault");
      }
      if (faultLog) faultLog.hidden = true;
      foot?.classList.remove("is-fault");
      if (summary) {
        summary.dataset.en = "5/5 audits passed · 0 faults";
        summary.dataset.zh = "5/5 审计全部通过 · 0 缺陷";
        summary.textContent = isZh() ? summary.dataset.zh : summary.dataset.en;
      }
      if (timeEl) timeEl.textContent = "38 ms";
      setFaultButtonMode(false);
      if (animate && !reducedMotion()) pulseRows();
    };

    const renderFault = () => {
      hasFault = true;
      preview?.classList.add("has-fault");
      if (previewBadge) previewBadge.textContent = "1 fault";
      if (clipCallout) clipCallout.hidden = false;
      clipRow?.classList.add("is-fault");
      if (clipVal) clipVal.textContent = "1";
      if (clipBadge) {
        clipBadge.textContent = "FAULT";
        clipBadge.classList.add("is-fault");
      }
      if (faultLog) faultLog.hidden = false;
      foot?.classList.add("is-fault");
      if (summary) {
        summary.dataset.en = "1 fault detected · 4/5 passed";
        summary.dataset.zh = "捕获 1 处缺陷 · 4/5 通过";
        summary.textContent = isZh() ? summary.dataset.zh : summary.dataset.en;
      }
      if (timeEl) timeEl.textContent = "41 ms";
      setFaultButtonMode(true);
    };

    runBtn?.addEventListener("click", () => {
      renderClean(true);
    });

    faultBtn?.addEventListener("click", () => {
      if (hasFault) renderClean(true);
      else renderFault();
    });

    onLangChange(() => {
      if (summary && summary.dataset.en && summary.dataset.zh) {
        summary.textContent = isZh() ? summary.dataset.zh : summary.dataset.en;
      }
      if (faultLabel && faultLabel.dataset.en && faultLabel.dataset.zh) {
        faultLabel.textContent = isZh() ? faultLabel.dataset.zh : faultLabel.dataset.en;
      }
    });

    observeOnce(root, () => {
      if (!hasFault) renderClean(true);
    });
  })();
})();
