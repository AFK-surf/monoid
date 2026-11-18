// A message's text as plain words on a line, one rule for where it is shown in brief: a chat's row and a notice in the
// core (format.ts plainText), a push still.fail cloud sends (cloud/src/noticeText.ts). Pure: the words a link, a
// picture and a file are shown as are the caller's, in its own language.

/// What a link, a picture and a file are shown as ([链接], [图片], [文件]).
export type PlainWords = { link: string; image: string; file: string };

/// Markdown's and Slack's marks out, code as its letters, a link as its words or [链接] (a file's as [文件], a picture
/// as [图片]).
export function plainText(text: string, said: PlainWords): string {
  const words = (k: keyof PlainWords) => said[k];
  const target = (url: string) => (/^(https?:|mailto:|www\.)/i.test(url) ? words("link") : IMAGE.test(url) ? words("image") : words("file"));
  const marks = (part: string) =>
    part
      .replace(/!\[[^\]\n]*\]\(\s*<?([^)\s>]*)>?[^)]*\)/g, (_, url: string) => (/^(https?:|mailto:)/i.test(url) || IMAGE.test(url) ? words("image") : words("file")))
      .replace(/\[([^\]\n]*)\]\(\s*<?([^)\s>]*)>?[^)]*\)/g, (_, label: string, url: string) => (label.trim() !== "" ? label : target(url)))
      .replace(/<((?:https?|mailto):[^>|\s]+)\|([^>]+)>/g, "$2")
      .replace(/<((?:https?|mailto):[^>|\s]+)>/g, () => words("link"))
      .replace(/<#[A-Z0-9]+\|([^>]+)>/g, "#$1")
      .replace(/<@[A-Z0-9]+\|([^>]+)>/g, "@$1")
      .replace(/<!(here|channel|everyone)(\|[^>]*)?>/g, "@$1")
      .replace(/https?:\/\/[^\s<>()]+/g, () => words("link"))
      .replace(/(\*\*|__|~~)(?=\S)([^\n]*?\S)\1/g, "$2")
      .replace(/(^|[^\w*])([*_])(?=[^\s*_])([^\n]*?[^\s*_])\2(?![\w*])/gm, "$1$3")
      .replace(/\\([\\`*_{}[\]()#+\-.!|~>])/g, "$1")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&");
  const lines = text
    .split("\n")
    .filter((l) => !/^ {0,3}(```|~~~)/.test(l) && !/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(l))
    .map((l) =>
      l
        .replace(/^ {0,3}(#{1,6}\s+|>\s?)+/, "")
        .replace(/^\s*([-*+•]|\d+[.)])\s+(\[[ xX]\]\s+)?/, "")
        .replace(/^\s*\|(.*?)\|?\s*$/, (_, cells: string) => cells.split("|").map((c) => c.trim()).join(" "))
        .replace(/^ {0,3}([-*_]\s*){3,}$/, ""),
    );
  // Code keeps its letters as they are: only what is outside it loses marks.
  return lines.join("\n").split(/(`+)([^`]*?)\1/).map((part, i) => (i % 3 === 0 ? marks(part) : i % 3 === 2 ? part : "")).join("");
}

/// What a link's address names as a picture.
const IMAGE = /\.(png|jpe?g|gif|webp|svg|heic|avif)(\?[^)\s]*)?$/i;
