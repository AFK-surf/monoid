// A console's request to add a machine's station (connect.tsx): the sign-in page's column (login.css.ts), with the
// workspaces to pick from as a list of choices and the station's name as a field.
import { style } from "@vanilla-extract/css";
import { vars } from "@stillfail/ui/styles/tokens.css.ts";

export const form = style({ display: "grid", gap: "12px", width: "min(26em, 100%)", marginTop: "8px", textAlign: "left" });
export const label = style({ fontSize: vars.textMeta, color: vars.muted });
export const choices = style({ display: "grid", gap: "6px", margin: 0, padding: 0, border: 0 });
export const choice = style({
  display: "flex", alignItems: "flex-start", gap: "10px", padding: "10px 12px", borderRadius: vars.rCard,
  border: `1px solid ${vars.line}`, background: vars.canvas, cursor: "pointer",
  selectors: {
    "&:hover": { background: vars.hover },
    "&:has(input:checked)": { borderColor: vars.accent, background: vars.accentBg },
  },
});
export const radio = style({ margin: "3px 0 0", accentColor: vars.accent, flex: "none" });
export const choiceText = style({ display: "grid", gap: "2px", minWidth: 0 });
export const choiceName = style({ fontSize: vars.textUi, fontWeight: "500", color: vars.text, overflowWrap: "anywhere" });
export const choiceMeta = style({ fontSize: vars.textMeta, color: vars.muted, overflowWrap: "anywhere" });
export const field = style({
  height: "36px", padding: "0 12px", borderRadius: vars.rField, border: `1px solid ${vars.line}`, background: vars.canvas,
  color: vars.text, fontSize: vars.textInput, fontFamily: "inherit",
  selectors: { "&:focus": { outline: "none", borderColor: vars.fieldFocus } },
});
export const note = style({ margin: 0, fontSize: vars.textMeta, color: vars.muted });
export const error = style({ margin: 0, fontSize: vars.textMeta, color: vars.red });
