// still.fail's type scale, lines, corners, room and motion's length, the one place they are written: the web's pages
// take them as CSS variables (web/src/styles/global.css.ts) and the app as its tokens (libs/sf-ui/src/tokens_data.mbt,
// made from this by scripts/tokens.ts; libs/sf-ui/src/tokens.mbt reads it). Three layers, as the colours'
// (palette.ts): the numbers (a size and its line), what each is for (a role: caption … display; a corner of a field,
// a card …), and where that role is said (a CSS variable, a token of the app's). Only plain numbers here: what the
// app works out of them (a corner concentric in another: card_corner, row_corner …) is worked out there.

/** A size of words and the line it stands on, in px. */
export type Type = { size: number; line: number };

const wide = {
  /** times and tags */
  caption: { size: 11, line: 16 },
  /** a row's second line, notes */
  meta: { size: 12, line: 18 },
  /** lists, menus, buttons and settings */
  ui: { size: 13, line: 20 },
  /** what is read */
  body: { size: 14, line: 22 },
  /** a section's or a dialog's title */
  title: { size: 16, line: 24 },
  /** a page's title */
  heading: { size: 22, line: 30 },
  /** big numbers (usage); its line is the app's alone (the web's says none) */
  display: { size: 28, line: 36 },
} satisfies Record<string, Type>;

/** The type's roles: with keyboard and mouse (wide), and a phone's, a size up (narrow, as Android's; the rest as wide). */
export const TYPE_SCALE = {
  wide,
  narrow: {
    caption: { size: 12, line: 16 },
    meta: { size: 13, line: 18 },
    ui: { size: 15, line: 22 },
    body: { size: 15, line: 22 },
  },
} as const;

/** What is typed in (the web's): as what is read. */
export const TEXT_INPUT = 14;

/** The lines the app says by name (mbui's Leading L4 … L7), in place of a size's own. */
export const LEADING = { l4: 16, l5: 18, l6: 20, l7: 22 } as const;

/** Corners and the room they are concentric by, in px. */
export const RADII = {
  /** The web's (--r-*, each times --corner-scale): a field's, a card's, a dialog's, the nav's, a menu's, an option's. */
  web: { field: 12, card: 20, dialog: 32, nav: 12, menu: 20, option: 12 },
  /**
   * The app's corner ladder's first numbers (tokens.mbt: the rest is worked out of these, concentric): a panel's corner,
   * how far a card stands in it, how far a row stands in a card, a field's corner; and a page card's padding.
   */
  app: { pane_corner: 42, panel_card_in: 16, corner_inset: 8, r_field: 12, card_pad: 24 },
} as const;

/** How long a motion takes, in ms: the web's one length (--dur). */
export const MOTION_MS = { dur: 140 } as const;
