// A page that stands alone, outside the app (signing in, a service or a console sending someone back, the admin's
// sign-in): a picture over it if it has one, what happened as its title, what to do next under it, then the page's own
// (a form) and its buttons in a row. Every one of them is this, so they look one way and say things in one order.
import type { ComponentChildren } from "preact";
import * as css from "./standPage.css.ts";

/** A picture over the page: drawn at its size, smaller where the page is narrower. */
export type Illustration = { src: string; width: number; height: number };

export function StandPage({ illustration, title, lead, actions, children }: {
  illustration?: Illustration | undefined;
  title: ComponentChildren;
  /** What to do next; none, or empty, says nothing (no line kept for it). */
  lead?: ComponentChildren;
  /** Its buttons (Button, ButtonLink), in a row under all else. */
  actions?: ComponentChildren;
  /** The page's own, under its lead: a form brings its buttons in `StandActions` of its own. */
  children?: ComponentChildren;
}) {
  return (
    <main className={css.page}>
      {illustration && <img className={css.illus} src={illustration.src} alt="" width={illustration.width} height={illustration.height} />}
      <h1 className={css.title}>{title}</h1>
      {present(lead) && <p className={css.lead}>{lead}</p>}
      {children}
      {present(actions) && <StandActions>{actions}</StandActions>}
    </main>
  );
}

/** A stand-alone page's buttons in their row: StandPage's `actions`, or a form's own at its end. */
export function StandActions({ children }: { children: ComponentChildren }) {
  return <div className={css.actions}>{children}</div>;
}

const present = (what: ComponentChildren) => what !== undefined && what !== null && what !== false && what !== "";
