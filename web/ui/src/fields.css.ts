// Fields of their own (fields.tsx): the filled ones that stand together as one block, and a list of choices to pick one of.
import { style } from "@vanilla-extract/css";
import { vars } from "./styles/tokens.css.ts";

/** Email and password as one block: a grey ground, a hairline gap between, no outlines. */
export const fields = style({ display: "flex", flexDirection: "column", gap: "1px", borderRadius: "16px", overflow: "hidden" }); // own corner: the two fields as one block, as the console's sign-in had them
export const input = style({
  height: "44px", border: 0, padding: "0 18px", fontSize: vars.textInput, color: vars.text, outline: "none",
  background: `color-mix(in srgb, ${vars.text} 5%, transparent)`,
  selectors: { "&:hover, &:focus": { background: vars.hover } },
});

export const choices = style({ display: "grid", gap: "6px", margin: 0, padding: 0, border: 0, minWidth: 0 });
export const choice = style({
  display: "flex", alignItems: "flex-start", gap: "10px", padding: "10px 12px", borderRadius: vars.rCard,
  border: `1px solid ${vars.line}`, background: vars.canvas, cursor: "pointer", textAlign: "left",
  selectors: {
    "&:hover": { background: vars.hover },
    "&:has(input:checked)": { borderColor: vars.accent, background: vars.accentBg },
  },
});
export const radio = style({ margin: "3px 0 0", accentColor: vars.accent, flex: "none" });
export const choiceText = style({ display: "grid", gap: "2px", minWidth: 0 });
export const choiceName = style({ fontSize: vars.textUi, fontWeight: "500", color: vars.text, overflowWrap: "anywhere" });
export const choiceMeta = style({ fontSize: vars.textMeta, color: vars.muted, overflowWrap: "anywhere" });
