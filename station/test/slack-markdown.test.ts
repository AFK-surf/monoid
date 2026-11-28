import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { fixMarkdownEmphasis, markdownBlocks, parseInlineToRichText } from "../src/slack/markdown.ts";
import { answeredBlocks, questionBlocks } from "../src/slack/cards.ts";

describe("slack markdown blocks", () => {
  test("plain markdown without affected lists stays a single markdown block", () => {
    const simple = "**hello** [x](https://x)";
    assert.deepEqual(markdownBlocks(simple), [{ type: "markdown", text: simple }]);

    const flatOrdered = "1. First\n2. Second\n3. Third";
    assert.deepEqual(markdownBlocks(flatOrdered), [{ type: "markdown", text: flatOrdered }]);

    const nestedBullets = "- Parent A\n  - Child A1\n- Parent B\n  - Child B1";
    assert.deepEqual(markdownBlocks(nestedBullets), [{ type: "markdown", text: nestedBullets }]);
  });

  test("ordered list with nested bullets emits rich_text with accurate indent and offset", () => {
    const md = [
      "确认过了，**现有逻辑准确**：",
      "",
      "1. **第一项（`path/a.ex:1`，`#4105` 合入）**：",
      "   - 只要带了 `voice_item.media`，Comma 也**不直接当正文信任**；",
      "   - 只有在没给 `media` 时才退回。",
      "",
      "2. **第二项**：",
      "   - 这次那两条中文语音**微信根本没给 `voice_item.text`**（命中的是 `{[], true}`）。",
      "   - 真正卡住的是 `#!OPUS_RAW_V1`。",
      "",
      "3. **第三项**：",
      "   - 配上 **方案 A**（加 **120s / 25 MiB**硬上限）。",
      "",
      "<@U0AU3GAP8ER> 确认吗？",
    ].join("\n");

    const blocks = markdownBlocks(md);
    assert.equal(blocks.length, 3);
    assert.deepEqual(blocks[0], { type: "markdown", text: "确认过了，**现有逻辑准确**：" });
    assert.equal(blocks[1].type, "rich_text");
    assert.deepEqual(blocks[2], { type: "markdown", text: "<@U0AU3GAP8ER> 确认吗？" });

    const lists = blocks[1].elements;
    assert.equal(lists.length, 6);
    // 1.
    assert.equal(lists[0].style, "ordered");
    assert.equal(lists[0].indent, 0);
    assert.equal(lists[0].offset, undefined);
    // nested bullets under 1.
    assert.equal(lists[1].style, "bullet");
    assert.equal(lists[1].indent, 1);
    assert.equal(lists[1].elements.length, 2);
    // 2. -> offset: 1
    assert.equal(lists[2].style, "ordered");
    assert.equal(lists[2].indent, 0);
    assert.equal(lists[2].offset, 1);
    // nested bullets under 2., verifying bold + inline code adjacent to CJK punctuation
    assert.equal(lists[3].style, "bullet");
    assert.equal(lists[3].indent, 1);
    assert.deepEqual(lists[3].elements[0].elements, [
      { type: "text", text: "这次那两条中文语音" },
      { type: "text", text: "微信根本没给 ", style: { bold: true } },
      { type: "text", text: "voice_item.text", style: { bold: true, code: true } },
      { type: "text", text: "（命中的是 " },
      { type: "text", text: "{[], true}", style: { code: true } },
      { type: "text", text: "）。" },
    ]);
    // 3. -> offset: 2
    assert.equal(lists[4].style, "ordered");
    assert.equal(lists[4].indent, 0);
    assert.equal(lists[4].offset, 2);
    // nested bullets under 3.
    assert.equal(lists[5].style, "bullet");
    assert.equal(lists[5].indent, 1);
  });

  test("tight ordered list with nested bullets, nested ordered lists, and non-1 start preserve offsets", () => {
    const nestedOrdered = [
      "1. Outer A",
      "   1. Inner A1",
      "   2. Inner A2",
      "2. Outer B",
      "   1. Inner B1",
    ].join("\n");
    const blocks = markdownBlocks(nestedOrdered);
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].type, "rich_text");
    assert.deepEqual(
      blocks[0].elements.map((e: any) => ({ style: e.style, indent: e.indent, offset: e.offset, n: e.elements.length })),
      [
        { style: "ordered", indent: 0, offset: undefined, n: 1 },
        { style: "ordered", indent: 1, offset: undefined, n: 2 },
        { style: "ordered", indent: 0, offset: 1, n: 1 },
        { style: "ordered", indent: 1, offset: undefined, n: 1 },
      ],
    );

    // Ordered list interrupted by a fenced code block resumes at 2. via non-1 startNum.
    const withCode = [
      "1. Run this:",
      "```sh",
      "1. not a list",
      "   - not a nested bullet",
      "```",
      "2. Next step",
      "3. Final step",
    ].join("\n");
    const codeBlocks = markdownBlocks(withCode);
    assert.equal(codeBlocks.length, 2);
    assert.equal(codeBlocks[0].type, "markdown");
    assert.equal(codeBlocks[1].type, "rich_text");
    assert.equal(codeBlocks[1].elements[0].style, "ordered");
    assert.equal(codeBlocks[1].elements[0].offset, 1);
    assert.equal(codeBlocks[1].elements[0].elements.length, 2);
  });

  test("fenced code blocks containing nested ordered lists are never converted", () => {
    const fenced = "```markdown\n1. A\n   - B\n2. C\n```";
    assert.deepEqual(markdownBlocks(fenced), [{ type: "markdown", text: fenced }]);
  });

  test("fixMarkdownEmphasis inserts ZWSP only at code-span + star + non-ASCII boundaries", () => {
    const zwsp = "\u200B";
    assert.equal(
      fixMarkdownEmphasis("这次语音**微信根本没给 `voice_item.text`**（命中的是"),
      `这次语音**微信根本没给 \`voice_item.text\`${zwsp}**（命中的是`,
    );
    assert.equal(
      fixMarkdownEmphasis("文件头是 *`#!OPUS_RAW_V1`*：既不是 MP3"),
      `文件头是 *\`#!OPUS_RAW_V1\`${zwsp}*：既不是 MP3`,
    );
    assert.equal(
      fixMarkdownEmphasis("中文**`code`**中文"),
      `中文**${zwsp}\`code\`${zwsp}**中文`,
    );
    // ASCII-only and fenced code blocks stay completely untouched.
    assert.equal(fixMarkdownEmphasis("**bold `code`** text"), "**bold `code`** text");
    assert.equal(fixMarkdownEmphasis("```\n中文**`code`**中文\n```"), "```\n中文**`code`**中文\n```");
    // Unmatched star without a partner stays untouched.
    assert.equal(fixMarkdownEmphasis("`code`*中文"), "`code`*中文");
  });

  test("parseInlineToRichText handles links, Slack tokens, styles, escapes, and safe relative links", () => {
    assert.deepEqual(
      parseInlineToRichText("See <@U123> in <#C456|dev> <!here> [**docs**](https://example.com/a_(b)) and `a_b_c` and [rel](foo.ts) and <T>"),
      [
        { type: "text", text: "See " },
        { type: "user", user_id: "U123" },
        { type: "text", text: " in " },
        { type: "channel", channel_id: "C456" },
        { type: "text", text: " " },
        { type: "broadcast", range: "here" },
        { type: "text", text: " " },
        { type: "link", url: "https://example.com/a_(b)", text: "docs", style: { bold: true } },
        { type: "text", text: " and " },
        { type: "text", text: "a_b_c", style: { code: true } },
        { type: "text", text: " and [rel](foo.ts) and <T>" },
      ],
    );

    // Snake_case and multiplication are not misread as emphasis.
    assert.deepEqual(parseInlineToRichText("foo_bar_baz and 2 * 3 * 4"), [
      { type: "text", text: "foo_bar_baz and 2 * 3 * 4" },
    ]);
  });

  test("cards questionBlocks and answeredBlocks preserve nested ordered lists", () => {
    const md = "结论：\n\n1. 第一项\n   - 细则\n\n2. 第二项\n   - 细则";
    const q = questionBlocks(md, { type: "options", options: [{ label: "确认", recommended: true }] }, "zh");
    assert.deepEqual(q.map((b: any) => b.type), ["markdown", "rich_text", "actions"]);
    assert.equal(q[1].elements[2].offset, 1);

    const a = answeredBlocks({ markdown: md }, "Jimmfly", "确认", "zh");
    assert.deepEqual(a.map((b: any) => b.type), ["markdown", "rich_text", "context"]);
    assert.equal(a[1].elements[2].offset, 1);
  });
});
