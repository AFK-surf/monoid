// A page standing alone (standPage.tsx): the app's tokens and ground (the page's global styles), a column in the
// middle, what it says centred, its buttons in a row under it.
import { style } from "@vanilla-extract/css";
import { vars } from "./styles/tokens.css.ts";

export const page = style({
  minHeight: "100%", display: "grid", placeContent: "center", justifyItems: "center", gap: "8px", padding: "24px",
  textAlign: "center",
});
export const illus = style({ display: "block", maxWidth: "100%", height: "auto" });
export const title = style({ margin: "8px 0 0", fontSize: vars.textTitle, fontWeight: "600" });
export const lead = style({ margin: "0", color: vars.muted, maxWidth: "30em" });
export const actions = style({ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: "8px", marginTop: "4px" });
