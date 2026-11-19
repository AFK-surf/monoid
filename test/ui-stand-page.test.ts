// The design system's parts the pages standing alone are made of (web/ui/src/standPage.tsx, button.tsx, fields.tsx):
// what each draws for what it is given, read off the elements it returns (loaded through Vite as the web's build loads
// them, its styles' class names and all), with no page drawn.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import preact from "@preact/preset-vite";
import { vanillaExtractPlugin } from "@vanilla-extract/vite-plugin";
import { createServer, type ViteDevServer } from "vite";
import { uiAlias } from "../web/ui/alias.ts";

type Node = { type: unknown; props: Record<string, unknown> & { children?: unknown } } | string | number | boolean | null | undefined | Node[];
type Element = Exclude<Node, string | number | boolean | null | undefined | Node[]>;

let server: ViteDevServer;
// (loaded as modules of their own: the tests' TypeScript has no JSX to read the parts' sources with)
type Module = Record<string, any>;
let ui: { stand: Module; standCss: Module; button: Module; waiting: Module; fields: Module; fieldsCss: Module; controlsCss: Module };

before(async () => {
  server = await createServer({
    configFile: false, logLevel: "silent", root: fileURLToPath(new URL("../web/", import.meta.url)),
    plugins: [preact({ prefreshEnabled: false }), vanillaExtractPlugin()], resolve: { alias: [uiAlias] },
    server: { middlewareMode: true, hmr: false, ws: false }, appType: "custom", optimizeDeps: { noDiscovery: true, include: [] },
  });
  const load = (path: string) => server.ssrLoadModule(fileURLToPath(new URL(path, import.meta.url)));
  ui = {
    stand: await load("../web/ui/src/standPage.tsx"),
    standCss: await load("../web/ui/src/standPage.css.ts"),
    button: await load("../web/ui/src/button.tsx"),
    waiting: await load("../web/ui/src/waiting.tsx"),
    fields: await load("../web/ui/src/fields.tsx"),
    fieldsCss: await load("../web/ui/src/fields.css.ts"),
    controlsCss: await load("../web/ui/src/styles/controls.css.ts"),
  };
});
after(() => server?.close());

/** The elements under `node` (itself first), components left as they are (not called). */
function* elements(node: Node): Generator<Element> {
  if (Array.isArray(node)) {
    for (const n of node) yield* elements(n);
  } else if (node !== null && typeof node === "object") {
    yield node;
    yield* elements(node.props.children as Node);
  }
}
const tags = (node: Node) => [...elements(node)].map((e) => (typeof e.type === "string" ? e.type : (e.type as { name?: string }).name ?? "?"));
const classes = (e: Element) => String(e.props.className ?? "").split(" ").filter(Boolean);
/** A component's own element: `forwardRef`'s and plain ones alike take their props and give what they draw. */
const draw = (component: unknown, props: Record<string, unknown>) => (component as (p: Record<string, unknown>) => Node)(props) as Element;

test("a page standing alone: its picture, title, lead, own part and buttons, in that order; what it is not given is not drawn", () => {
  const { StandPage, StandActions } = ui.stand;
  const css = ui.standCss;
  const full = draw(StandPage, {
    illustration: { src: "/illus-sign-in.svg", width: 360, height: 200 }, title: "登录", lead: "接着做",
    children: { type: "form", props: { children: "…" } }, actions: "继续",
  });
  assert.equal(full.type, "main");
  assert.deepEqual(classes(full), [css.page]);
  assert.deepEqual(tags(full).slice(0, 4), ["main", "img", "h1", "p"]);
  const [img, h1, lead] = [...elements(full)].slice(1, 4) as Element[];
  assert.deepEqual([img!.props.src, img!.props.width, img!.props.height, img!.props.alt], ["/illus-sign-in.svg", 360, 200, ""]);
  assert.deepEqual([h1!.props.children, classes(h1!)], ["登录", [css.title]]);
  assert.deepEqual([lead!.props.children, classes(lead!)], ["接着做", [css.lead]]);
  const children = full.props.children as Node[];
  // (the form between the lead and the buttons, the buttons in their row last)
  assert.equal((children[3] as Element).type, "form");
  const row = children[4] as Element;
  assert.equal(row.type, StandActions);
  assert.equal(draw(StandActions, row.props).props.className, css.actions);

  // Only a title: no picture, no empty lead keeping a line, no empty row of buttons.
  for (const lead of [undefined, "", null, false]) {
    const bare = draw(StandPage, { title: "正在交给控制台…", lead, actions: undefined });
    assert.deepEqual(tags(bare), ["main", "h1"], `lead ${String(lead)}`);
  }
});

test("a button is the pill in its variant, a spinner in its icon's place while busy and not pressed again", () => {
  const { Button, ButtonLink, buttonClass } = ui.button;
  const c = ui.controlsCss;
  assert.equal(buttonClass("secondary"), c.btn);
  assert.equal(buttonClass("primary", "mine"), `${c.btn} ${c.btnPrimary} mine`);
  assert.equal(buttonClass("ghost"), `${c.btn} ${c.btnGhost}`);

  const plain = draw(Button, { children: "取消" });
  assert.deepEqual([plain.type, plain.props.type, plain.props.disabled, plain.props["aria-busy"]], ["button", "button", undefined, undefined]);
  // A form's own: submits, and while busy it is disabled and says so.
  const submit = draw(Button, { type: "submit", variant: "primary", busy: true, children: "添加" });
  assert.deepEqual([submit.props.type, submit.props.disabled, submit.props["aria-busy"]], ["submit", true, true]);
  assert.deepEqual(classes(submit), [c.btn, c.btnPrimary]);
  const [spinner, words] = submit.props.children as Element[];
  assert.equal(spinner!.type, ui.waiting.Spinner);
  assert.equal(words, "添加");

  const icon = function KeyIcon() { return null; };
  const ghost = draw(Button, { variant: "ghost", icon, children: "用密码登录" });
  const [drawn] = ghost.props.children as Element[];
  assert.deepEqual([drawn!.type, drawn!.props.size, drawn!.props.strokeWidth], [icon, 16, 1.7]);

  const link = draw(ButtonLink, { href: "/login?return_to=%2F", children: "登录 still.fail" });
  assert.deepEqual([link.type, link.props.href, classes(link)], ["a", "/login?return_to=%2F", [c.btn]]);
  assert.deepEqual(classes(draw(ButtonLink, { href: "/", variant: "primary", children: "x" })), [c.btn, c.btnPrimary]);
});

test("fields: a lined pill or a filled one of a stack, a textarea, what went wrong said as an alert", () => {
  const { TextInput, TextArea, FieldStack, ErrorLine } = ui.fields;
  const c = ui.controlsCss;
  const f = ui.fieldsCss;
  const lined = draw(TextInput, { id: "ws-name", value: "Acme", maxLength: 80 });
  assert.deepEqual([lined.type, lined.props.id, lined.props.value, lined.props.maxLength, classes(lined)], ["input", "ws-name", "Acme", 80, [c.input]]);
  assert.equal("filled" in lined.props, false, "filled is the part's own, not the input's");
  assert.deepEqual(classes(draw(TextInput, { filled: true, type: "password" })), [f.input]);
  assert.deepEqual(classes(draw(TextArea, { rows: 3, className: "reply" })), [c.input, "reply"]);
  assert.deepEqual(classes(draw(FieldStack, { children: [] })), [f.fields]);
  const error = draw(ErrorLine, { children: "邮箱或密码错误", className: "in" });
  assert.deepEqual([error.type, error.props.role, error.props.children, classes(error)], ["p", "alert", "邮箱或密码错误", [c.fieldError, "in"]]);
});

test("choices: one card each, the one picked checked, picking another says which, all off while disabled", () => {
  const { RadioChoices } = ui.fields;
  const f = ui.fieldsCss;
  const picked: string[] = [];
  const set = draw(RadioChoices, {
    name: "workspace", label: "工作区", value: "w2", onChange: (v: string) => picked.push(v), disabled: true,
    options: [{ value: "w1", label: "Acme", meta: "lin@acme.dev" }, { value: "w2", label: "Lab" }],
  });
  assert.deepEqual([set.type, set.props.disabled, set.props["aria-label"], classes(set)], ["fieldset", true, "工作区", [f.choices]]);
  const inputs = [...elements(set)].filter((e) => e.type === "input");
  assert.deepEqual(inputs.map((i) => [i.props.type, i.props.name, i.props.value, i.props.checked]), [["radio", "workspace", "w1", false], ["radio", "workspace", "w2", true]]);
  (inputs[0]!.props.onChange as () => void)();
  assert.deepEqual(picked, ["w1"]);
  // What tells one apart (its account's email) only where it was given.
  const metas = [...elements(set)].filter((e) => classes(e).includes(f.choiceMeta));
  assert.deepEqual(metas.map((m) => m.props.children), ["lin@acme.dev"]);
  assert.equal([...elements(set)].filter((e) => e.type === "label").length, 2);
});
