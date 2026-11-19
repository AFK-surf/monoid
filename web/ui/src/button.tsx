// The button, apart from parts.tsx (which gives it too) so a page that loads nothing else of the parts (the sign-in
// pages, login/) has it without Radix: a pill in one of its variants, an icon before its words or a spinner in its
// place while what it set going is under way; `ButtonLink` the same pill as a link to another page.
import { forwardRef, type AnchorHTMLAttributes, type ButtonHTMLAttributes, type ComponentType } from "preact/compat";
import * as controlsCss from "./styles/controls.css.ts";
import { Spinner } from "./waiting.tsx";

export const ICON = { size: 16, strokeWidth: 1.7 } as const;

export type IconType = ComponentType<{ size?: number; strokeWidth?: number }>;
export type Variant = "primary" | "secondary" | "ghost" | "danger" | "danger-solid";
const VARIANT: Record<Variant, string> = { primary: controlsCss.btnPrimary, secondary: "", ghost: controlsCss.btnGhost, danger: controlsCss.btnDanger, "danger-solid": controlsCss.btnDangerSolid };

/** A button's classes: the pill, its variant's, then the caller's own. */
export const buttonClass = (variant: Variant, className?: string) => `${controlsCss.btn}${VARIANT[variant] ? ` ${VARIANT[variant]}` : ""}${className ? ` ${className}` : ""}`;

export const Button = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; icon?: IconType; busy?: boolean | undefined }>(
  function Button({ variant = "secondary", icon: Icon, busy, children, className, ...rest }, ref) {
    return (
      <button ref={ref} type="button" {...rest} aria-busy={busy || undefined} disabled={rest.disabled || busy}
        className={buttonClass(variant, className as string | undefined)}>
        {busy ? <Spinner /> : Icon && <Icon {...ICON} />}
        {children}
      </button>
    );
  },
);

/** A link drawn as a button: to another page (back to the app, on to signing in, into an app on this device). */
export const ButtonLink = forwardRef<HTMLAnchorElement, AnchorHTMLAttributes<HTMLAnchorElement> & { href: string; variant?: Variant; icon?: IconType }>(
  function ButtonLink({ variant = "secondary", icon: Icon, children, className, ...rest }, ref) {
    return (
      <a ref={ref} {...rest} className={buttonClass(variant, className as string | undefined)}>
        {Icon && <Icon {...ICON} />}
        {children}
      </a>
    );
  },
);
