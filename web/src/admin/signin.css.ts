// The admin's sign-in page's ways (signin.tsx): one column, each as wide as the others, as the console's own page had them.
import { style } from "@vanilla-extract/css";
import { vars } from "@stillfail/ui/styles/tokens.css.ts";

export const ways = style({ display: "flex", flexDirection: "column", alignItems: "stretch", gap: "12px", width: "300px", maxWidth: "100%", marginTop: "8px" });
export const or = style({ color: vars.subtle, fontSize: vars.textMeta, textAlign: "center", lineHeight: "16px" });
export const form = style({ display: "flex", flexDirection: "column", gap: "12px" });
/** Under the fields, as far in as what is written in them. */
export const error = style({ textAlign: "left", paddingLeft: "18px" });
