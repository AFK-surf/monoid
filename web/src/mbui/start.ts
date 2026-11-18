// mbui.html's script: the browser asked for WebGL 2 before anything of the app is fetched (gpu.ts says why). Where it
// gives one, the app's host page (core.ts: its core's worker, mbui's host, the app) as ever; where not, how to turn
// graphics acceleration on, in place of a white page (gpu-page.ts).
import { bootFailed, bootGone, bootWaits } from "./boot.ts";
import { hasWebgl2 } from "./gpu.ts";
import { showGpuGuide } from "./gpu-page.ts";

if (hasWebgl2(() => document.createElement("canvas"))) {
  bootWaits();
  import("./core.ts").catch((e: unknown) => {
    console.error("still.fail:", e);
    bootFailed();
  });
} else {
  showGpuGuide();
  bootGone();
}
