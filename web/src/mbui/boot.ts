// The mark mbui.html shows from its first paint while the app comes (`#boot`: its font, mbui's host and the app's
// script on their way), taken away once the app's first frame is on the canvas, so nothing of it is left to lay out or
// draw after. A load that fails, or that takes far longer than it should, says so under the mark with a way to load the
// page again, as an app on the home screen has no reload of its own.
import { chineseFor } from "./gpu.ts";

/** How long a load may take before the page offers to load it again (index.html's splash waits as long). */
const WAIT_MS = 15_000;
let waiting = 0;

const boot = (): HTMLElement | null => document.getElementById("boot");

function zh(): boolean {
  let kept: string | null = null;
  try {
    kept = localStorage.getItem("stillfail.prefs");
  } catch {
    kept = null;
  }
  return chineseFor(navigator.language || "", kept);
}

/** Under the mark: what happened and 重新加载 (said once). */
function offerReload(failed: boolean): void {
  const b = boot();
  if (!b || b.querySelector(".again")) return;
  const z = zh();
  const said = document.createElement("p");
  said.className = "said";
  said.textContent = failed
    ? z ? "still.fail 没有加载完成，检查网络后重新加载。" : "still.fail did not finish loading. Check the connection and load it again."
    : z ? "加载得比平常久，可以重新加载。" : "This is taking longer than usual.";
  const again = document.createElement("button");
  again.type = "button";
  again.className = "again";
  again.textContent = z ? "重新加载" : "Reload";
  again.onclick = () => location.reload();
  b.classList.add("stuck");
  b.append(said, again);
}

/** The load has begun: offered again once it has taken too long (timer: a deadline). */
export function bootWaits(): void {
  clearTimeout(waiting);
  waiting = window.setTimeout(() => offerReload(false), WAIT_MS);
}

/** What the app needs did not come (a script that did not load, one that threw as it ran). */
export function bootFailed(): void {
  clearTimeout(waiting);
  offerReload(true);
}

/** Taken away: faded out over what was drawn under it where motion is not reduced (`now`: at once, for a page put up
 *  in the app's place), then gone from the page. */
export function bootGone(now = false): void {
  clearTimeout(waiting);
  const b = boot();
  if (!b) return;
  if (now || document.documentElement.hasAttribute("data-reduced-motion") || document.visibilityState !== "visible") {
    b.remove();
    return;
  }
  // (short: the app's first screen comes in by its own fade, from the bare ground, where the mark stands; then out
  // of the page whether or not the fade was seen, after mbui.html's #boot.gone)
  b.classList.add("gone");
  setTimeout(() => b.remove(), 120);
}

interface Presents { present(...args: unknown[]): unknown }

/** Taken away after the app's first frame is drawn (mbui's host draws every frame through `present`, which the app
 *  calls by name each time: host_js.mbt js_present): the host's own `present` is put back by that first call, so no
 *  frame after it runs anything of this. */
export function bootGoesWithFirstFrame(host: Presents | undefined): void {
  if (!host || typeof host.present !== "function") {
    bootGone();
    return;
  }
  const present = host.present;
  host.present = function (this: unknown, ...args: unknown[]) {
    host.present = present;
    const drawn = present.apply(this, args);
    // (the canvas shows what was drawn as the browser paints this frame: the mark goes from the one after)
    requestAnimationFrame(() => bootGone());
    return drawn;
  };
}
