// A console's request to add a machine's station (connect.tsx): on a page standing alone (@stillfail/ui standPage), a
// form as wide as a column, the workspaces to pick from and the station's name as its fields.
import { style } from "@vanilla-extract/css";
import { vars } from "@stillfail/ui/styles/tokens.css.ts";

export const form = style({ display: "grid", gap: "12px", width: "min(26em, 100%)", marginTop: "8px", textAlign: "left" });
export const note = style({ margin: 0, fontSize: vars.textMeta, color: vars.muted });
