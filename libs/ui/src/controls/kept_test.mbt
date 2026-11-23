///|
/// The real core's answers to its pure calls that this package's blackbox tests ask, kept: they have no core. Each line
/// is the app's own (apps/mbui/src/sfkept/kept.mbt, made by client/core-ts/scripts/kept-answers.ts), an answer a line:
/// [call, key, answer]; `markdown` by the text (libs/ui's AGENTS.md).
let kept_answers : String =
  #|["markdown","",[]]
  #|["markdown","![](wide1.png) ![](wide2.png)",[["p",[["img",{"src":"wide1.png"}],[14,15],["img",{"src":"wide2.png"}]]]]]
  #|["markdown","## 今天的进度\n\n改好了 **布局** 和 *动画*，见 [说明](https://example.com/notes)。\n\n- 第一项，`inline code`\n- 第二项\n  1. nested one\n- [x] 做完的事\n\n> 引用里的一句话\n\n```sh\nmoon test\n```",[["h",[[3,8]],{"depth":2}],["p",[[10,14],["b",[[16,18]]],[20,23],["i",[[24,26]]],[27,30],["a",[[31,33]],{"href":"https://example.com/notes"}],[61,62]]],["list",[["li",[[66,70],["code",{"content":[71,82]}]]],["li",[[86,89],["list",[["li",[[95,105]]]],{"ordered":true}]]],["li",[[112,116]],{"checked":true}]]],["quote",[["p",[[120,127]]]]],["pre",{"code":[135,144],"lang":"sh","ink":"i5d4"}]]]
  #|["markdown","```js\nlet total = items.map(fn(x) { x.price * x.count }).fold(init=0, fn(a, b) { a + b }) // a line longer than the message\n```\n\n之后的一段",[["pre",{"code":[6,123],"lang":"js","ink":"h4j6c2j5ci3ci2cic4jcj6h2jcj6c3i4cj4cfc2i2cic2jc4j2h2j2c3b33"}],["p",[[129,134]]]]]
  #|["markdown","| 一 | 二 | 三 |\n|---|---|---|\n| one a long cell of words that would wrap to a word or two if squeezed into the message | two a long cell of words that would wrap to a word or two if squeezed into the message | three a long cell of words that would wrap to a word or two if squeezed into the message |\n",[["table",[["tr",[["th",[[2,3]]],["th",[[6,7]]],["th",[[10,11]]]]],["tr",[["td",[[30,116]]],["td",[[119,205]]],["td",[[208,296]]]]]],{"align":[null,null,null],"md":"| 一 | 二 | 三 |\n| --- | --- | --- |\n| one a long cell of words that would wrap to a word or two if squeezed into the message | two a long cell of words that would wrap to a word or two if squeezed into the message | three a long cell of words that would wrap to a word or two if squeezed into the message |","csv":"一,二,三\none a long cell of words that would wrap to a word or two if squeezed into the message,two a long cell of words that would wrap to a word or two if squeezed into the message,three a long cell of words that would wrap to a word or two if squeezed into the message"}]]]
  #|["markdown","| 网页 | 手机网页 |\n|---|---|\n| ![](web%2Dfolded.png) | ![](phone.png) |\n",[["table",[["tr",[["th",[[2,4]]],["th",[[7,11]]]]],["tr",[["td",[["img",{"src":"web%2Dfolded.png"}]]],["td",[["img",{"src":"phone.png"}]]]]]],{"align":[null,null],"md":"| 网页 | 手机网页 |\n| --- | --- |\n| ![](web%2Dfolded.png) | ![](phone.png) |","csv":"网页,手机网页\nweb%2Dfolded.png,phone.png"}]]]
  #|["markdown","左边是新做法，右边是现在的：\n\n![](a.png) ![](b.png)\n",[["p",[[0,14]]],["p",[["img",{"src":"a.png"}],[26,27],["img",{"src":"b.png"}]]]]]
  #|["markdown","见 ![](web%2Dfolded%2D2%2Epng)",[["p",[[0,2],["img",{"src":"web%2Dfolded%2D2%2Epng"}]]]]]

///|
/// The kept `markdown` answers by their text.
let kept_markdown : Map[String, Json] = {
  let m : Map[String, Json] = Map([])
  for line in kept_answers.split("\n") {
    match (@json.parse(line.to_owned()) catch { _ => Json::null() }) {
      Array([String("markdown"), String(text), md]) => m[text] = md
      _ => ()
    }
  }
  m
}

///|
/// As the app's kept answers (apps/mbui/src/sfkept/answer.mbt) answer `markdown`; one not kept here, or another of the
/// core's pure calls, is said on the output (`kept-answers-ask`, scripts/check.sh) and an error.
fn kept_answer(name : String, params : Json, _bytes : Bytes?) -> Result[(Json, Bytes?), Json]? {
  let not_kept = fn(ask : Json) -> Result[(Json, Bytes?), Json]? {
    println("kept-answers-ask " + ask.stringify())
    Some(Err({ "code": "not_kept", "message": "the core's answer to \{name} is not kept: libs/ui/AGENTS.md" }))
  }
  match name {
    "markdown" => {
      let text = match params {
        Object(m) if m.get("text") is Some(String(s)) => s
        _ => ""
      }
      match kept_markdown.get(text) {
        Some(md) => Some(Ok(({ "md": md }, None)))
        None => not_kept({ "call": "markdown", "text": Json::string(text) })
      }
    }
    "code.ink" | "reader.book" | "reader.text" | "reader.search" | "ref.words" =>
      not_kept({ "call": Json::string(name), "params": params })
    _ => None
  }
}

///|
fn init {
  @controls.kept_call.val = Some(kept_answer)
}
