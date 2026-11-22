# mbui headless components (for agents)

- mbui separates UI into three layers:
  1. Framework (`libs/mbui/src/view`): primitives every node needs (tree, layout, motion, virtual lists). Component libraries never reimplement these.
  2. Headless components (`libs/mbui/src/headless`): pointer, keyboard, and screen-reader behavior per control kind. Draw nothing, lay out nothing, and know no theme.
  3. Look libraries (such as `libs/sf-ui` or `libs/comma-ui`): styling and visual presentation over headless components, nothing else.
- Read the header of `libs/mbui/src/headless/headless.mbt` before writing a component or a look: it defines ownership, state management, allowed look overrides, and multi-part controls. Update rules there if they change.
- Follow the button component as the reference pattern for new controls.
- Put every new component and every component migrated off `Ctx` in `libs/mbui/src/headless` with caller-supplied looks. Never add to `libs/mbui/src/kit`, which stays frozen until its callers migrate (`libs/mbui/src/headless/toaster.mbt` handles tree toasts while kit's `toast_due` and `toast_rest` bridge both).
