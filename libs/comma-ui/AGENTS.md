# Comma's parts in mbui (for agents)

A component library of its own beside mbui (`libs/mbui`), which it alone imports: Comma's design system (`clients/packages/ui` of the
AFK-surf/Cue repository, not a path of this one; Figma `VnkgBb2xCr5bRp4KHrLrqs`) drawn by mbui. mbui is the framework and holds no look; a
library like this one holds the looks; an app uses a library (the user, 2026-11-13: mbui 和组件库应该分开). It started as
a sample of what mbui needs to carry a second design (the user, 2026-11-13: 先在 monoid 做样板).

- `src/cm` is the library; `src/pages` the gallery's two pages, shown by `src/gallery` in a window and drawn by `src/shots` offscreen at 3× (`MBUI_CM_SHOTS=<dir>`: each page light and dark and each floating part open, mbui's `@film.picture`), the pictures to look at; `src/gallery` (`MBUI_CM_PAGE=more` the second; `MBUI_CM_OPEN` a floating part open at start; `APP=gallery MBUI_APP_MOD=libs/comma-ui
  libs/mbui/scripts/mac.sh run`; `MBUI_DARK=1`; `MBUI_CM_FONT`: Inter's variable file). `scripts/check.sh` is its
  check, CI's `check-comma-ui`.
- The numbers are Comma's, never typed here: `src/cm/tokens_made.mbt` is written by `scripts/cm-tokens.mjs` from Cue's
  token modules (`node scripts/cm-tokens.mjs <Cue checkout>`), and a part reads them by name (`colors()`, `space_*`,
  `radius_*`, `type_*`, `ms_*`, `ease_*`). A value Comma's tokens lack is added there first, in Cue. Its icons are Central Icons as Comma has them: `src/cm/icons_made.mbt`, written by `scripts/cm-icons.mjs` from a Cue checkout with its packages installed (Central's are licensed npm packages), drawn by `src/cm/icon.mbt` at Comma's one on-screen stroke.
- A part takes its look from the Comma component of the same name (its `styles.ts`, its classes), and is read out as
  that component's role (react-aria's). Every part is a node of mbui's window's tree (`libs/mbui/src/view`), never an old view.
- The library is looks (`libs/mbui/AGENTS.md`, Components): what a control is to the hand, the keyboard and a screen
  reader is mbui's headless component's (`libs/mbui/src/headless`) where there is one, and the part here is that
  component with Comma's look, saying no role, press or focus of its own: buttons (the button, a tag's ✕, a toast's ✕,
  what closes a floating part from outside it) over `@headless.button`; the checkbox and the toggle over
  `@headless.toggle`; the collapse over `@headless.disclosure`; a lone radio over `@headless.choice`; the radio group,
  the button group (react-aria's ToggleButtonGroup choosing one) and the status indicator over `@headless.radio_group`;
  the slider over `@headless.slider`; a menu's rows (the menu's and the dropdown's list's) over `@headless.menu`, the
  dropdown's trigger over `@headless.disclosure`. Where what floats goes beside what opened it is the framework's
  (`View::beside`, which flips and keeps it in the window as it lays out), not `@headless.anchor_place`'s numbers: those
  are for a look that places what it draws itself, and reading the anchor's laid-out box back to feed them is what
  mbui's layout forbids (`layout-told`). `src/cm/presses.mbt` keeps only what a look reads of the hand (`lit`,
  `ring_node`). Toasts are `@headless.toaster` with Comma's card (its time stopped while the pointer is over one or the
  focus is on its ✕, `ToastItem::holds_focus`; swiped away to the right; read out a status in a region). How a look moves (`src/cm/eased.mbt`) wraps
  mbui's `@motion.Eased` (`libs/mbui/src/motion/eased.mbt`) on Comma's cubic-bezier curves.
- What floats (tooltip, menu, dropdown, popup, dialog, toast) is drawn in the layer `layer_node` makes in the window's root: mbui's `View::over_all` puts a node over all else only among what the root holds; made elsewhere it is drawn under the page.
- mbui's rules hold here as in an app (`libs/mbui/AGENTS.md`): tests declare their moments, warnings are errors or off
  (`moon.mod`'s line), no Python.
