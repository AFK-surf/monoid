// Whether a Windows station has the optional LocalSystem screen service (`stillfail-screen-svc.exe`) installed, as the
// station's page shows it: the overview's `screenService` put in words. The switch where it stands (or where a change
// under way goes), what it means or how the change goes, how the last one failed, and whether the viewer may switch it.
// A station that says none (not Windows, or from before it) has none: the page shows nothing.
import { t } from "./i18n.ts";
import { isObject } from "./util.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const FAILURES = ["declined", "unanswered", "error"];

/// The overview's `screenService` (`{on, running, canChange, available, step?, want?, failed?, message?, manage}`) as
/// the page shows it; undefined when the station said none.
export function screenServiceShown(v: unknown): J | undefined {
  if (!isObject(v) || typeof v.on !== "boolean") return undefined;
  const step = typeof v.step === "string" ? v.step : null;
  const running = v.running === true;
  const available = v.available !== false;
  const canChangeHost = v.canChange === true;
  const line =
    step === "asking"
      ? t("core-views.screenService.asking")
      : step === "applying"
        ? t("core-views.screenService.applying")
        : !available
          ? t("core-views.screenService.notAvailable")
          : !canChangeHost
            ? t("core-views.screenService.notAdmin")
            : v.on && !running
              ? t("core-views.screenService.notRunning")
              : t("core-views.screenService.line");
  const failure = step === null && typeof v.failed === "string" && FAILURES.includes(v.failed) ? v.failed : null;
  const failed =
    failure === null
      ? undefined
      : failure === "error" && typeof v.message === "string" && v.message !== ""
        ? t("core-views.screenService.failed.errorWhy", { why: v.message })
        : t(`core-views.screenService.failed.${failure}`);
  return {
    on: step !== null && typeof v.want === "boolean" ? v.want : v.on,
    busy: step !== null,
    line,
    ...(failed !== undefined ? { failed } : {}),
    canChange: v.manage === true && canChangeHost && step === null,
  };
}
