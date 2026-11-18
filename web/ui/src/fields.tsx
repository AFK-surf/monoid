// What is written or picked, apart from parts.tsx (which gives these too) so a page that loads nothing else of the
// parts has them without Radix: a field (one line or several), filled fields that stand together as one block, what
// went wrong said under them, and a list of choices to pick one of.
import type { ComponentChildren } from "preact";
import { forwardRef, type InputHTMLAttributes, type TextareaHTMLAttributes } from "preact/compat";
import * as controlsCss from "./styles/controls.css.ts";
import * as css from "./fields.css.ts";

const join = (...names: (string | false | undefined)[]) => names.filter(Boolean).join(" ");

/**
 * A field of one line: a pill with a light line round it (the one every form has, in a `Field`); `filled`, one of a
 * `FieldStack`, a grey ground and no line.
 */
export const TextInput = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & { filled?: boolean }>(
  function TextInput({ filled = false, className, ...rest }, ref) {
    return <input ref={ref} {...rest} className={join(filled ? css.input : controlsCss.input, className as string | undefined)} />;
  },
);

/** A field of several lines, as a one-line field is but for its corner (--r-field). */
export const TextArea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(
  function TextArea({ className, ...rest }, ref) {
    return <textarea ref={ref} {...rest} className={join(controlsCss.input, className as string | undefined)} />;
  },
);

/** Filled fields (`TextInput filled`) as one block, a hairline between each. */
export function FieldStack({ children }: { children: ComponentChildren }) {
  return <div className={css.fields}>{children}</div>;
}

/** What went wrong, in red, said to a screen reader as it comes. */
export function ErrorLine({ children, className }: { children: ComponentChildren; className?: string | undefined }) {
  return <p className={join(controlsCss.fieldError, className)} role="alert">{children}</p>;
}

export type Choice<T extends string> = { value: T; label: ComponentChildren; meta?: ComponentChildren };

/** One of a few to pick, each a card of its own (what it is, and under it what tells it apart), the picked one lit. */
export function RadioChoices<T extends string>({ name, value, onChange, options, label, disabled = false }: {
  name: string; value: T | ""; onChange(value: T): void; options: Choice<T>[]; label: string; disabled?: boolean;
}) {
  return (
    <fieldset className={css.choices} disabled={disabled} aria-label={label}>
      {options.map((o) => (
        <label key={o.value} className={css.choice}>
          <input className={css.radio} type="radio" name={name} value={o.value} checked={value === o.value} onChange={() => onChange(o.value)} />
          <span className={css.choiceText}>
            <span className={css.choiceName}>{o.label}</span>
            {o.meta !== undefined && o.meta !== null && o.meta !== false && <span className={css.choiceMeta}>{o.meta}</span>}
          </span>
        </label>
      ))}
    </fieldset>
  );
}
