///|
test "the core's tight nested list retains the nested list after its words" {
  let nodes : Array[Json] = [["list", [["li", ["outer", ["list", [["li", ["inner"]]]]]]]]]
  let blocks = core_blocks(nodes, "")
  guard blocks is [List(l)] else { fail("missing list") }
  guard l.items[0].blocks is [Paragraph(words),List(inner)] else { fail("nested list was flattened") }
  assert_eq(md_plain(words), "outer")
  guard inner.items[0].blocks is [Paragraph(words)] else { fail("missing inner words") }
  assert_eq(md_plain(words), "inner")
}

///|
test "a core tree replaces a legacy tree and shares its bounded cache entry" {
  parsed.clear(); parsed_order.clear(); parsed_cost.clear(); parsed_used.val = 0; core_parsed.clear()
  blocks_of("$x$",None) |> ignore
  let tree : Json = [["p", [["code", {"content":"x","math":true,"drawing":null}]]]]
  let blocks = blocks_of("$x$",Some(tree))
  guard blocks is [Paragraph([Formula(source,_)])] else { fail("core tree not used") }
  assert_eq(source,"x")
  assert_eq(parsed_order.length(),1)
  for i in 0..=parsed_most { blocks_of("text\{i}",Some(Json::array([]))) |> ignore }
  assert_false(parsed.contains("$x$"))
  assert_false(core_parsed.contains("$x$"))
}

///|
test "a live renderer leaves syntax to the core and drawing data counts toward its cache" {
  parsed.clear(); parsed_order.clear(); parsed_cost.clear(); parsed_used.val = 0; core_parsed.clear()
  markdown_read.val = Some(fn(_,_) { })
  let pending = blocks_of("**pending**",None)
  markdown_read.val = None
  assert_eq(pending.length(),0)
  let large = "x".repeat(parsed_budget / 2)
  for i in 0..<3 {
    let tree : Json = [["p", [["code", {"content":"x","math":true,"drawing":{"unused":large}}]]]]
    blocks_of("formula\{i}",Some(tree)) |> ignore
  }
  assert_false(parsed.contains("formula0"))
  assert_true(parsed.contains("formula2"))
  assert_true(parsed_used.val <= parsed_budget)
}

///|
test "a core link first appears with its working hit region" {
  let answer : Ref[((Json?) -> Unit)?] = Ref(None)
  let opened : Array[String] = []
  let source = "详见 https://example.com/e2e"
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0)
  markdown_read.val = Some(fn(_, done) { answer.val = Some(done) })
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    markdown_node(root, fn() { source }, on_link=fn(href) { opened.push(href) }) |> ignore
  })
  t.draw()
  assert_true(t.find("example.com") is None)
  // meanwhile said to be laid out, as Markdown.kt's 正在排版
  assert_true(t.find("正在排版") is Some(_))
  let tree : Json = [["p", ["详见 ", ["a", ["https://example.com/e2e"], {"href":"https://example.com/e2e"}]]]]
  (answer.val.unwrap())(Some(tree))
  t.draw()
  assert_true(t.find("正在排版") is None)
  t.tap_run("example.com")
  markdown_read.val = None
  assert_eq(opened,["https://example.com/e2e"])
}

///|
test "code colours use the core's runs rather than interpreting its language again" {
  let blocks = core_blocks([["pre", {"code":"const x = 1","lang":"ts","ink":"h6j2c2f"}]], "")
  guard blocks is [CodeBlock("ts",code,Some(ink))] else { fail("core ink lost") }
  let runs = core_ink(code,ink,false)
  assert_eq(runs.map(fn(r) { r.text }),["const ","x ","= ","1"])
  assert_eq(runs[0].color,Scope::Storage.light())
  assert_eq(core_ink("const x = 1","d11",false)[0].color,Scope::Str.light())
}

///|
/// markdown_pieces as it was worked out of the blocks read (blocks_of): what core_pieces is held to.
fn md_pieces_read(text : String, tree : Json?) -> Array[MdPiece]? {
  guard tree is Some(_) && text != "" else { return None }
  let out : Array[MdPiece] = []
  for i, b in blocks_of(text, tree) {
    match b {
      Table(t) if t.rows.length() + 1 > md_table_piece_rows => {
        let all = t.rows.length() + 1
        let mut r = 0
        while r < all {
          let upto = if r + md_table_piece_rows < all { r + md_table_piece_rows } else { all }
          out.push({ from: i, upto: i + 1, rows: Some((r, upto)), last: false })
          r = upto
        }
      }
      List(l) if l.items.length() > md_list_piece_items => {
        let all = l.items.length()
        let mut r = 0
        while r < all {
          let upto = if r + md_list_piece_items < all { r + md_list_piece_items } else { all }
          out.push({ from: i, upto: i + 1, rows: Some((r, upto)), last: false })
          r = upto
        }
      }
      _ => out.push({ from: i, upto: i + 1, rows: None, last: false })
    }
  }
  guard out.length() > 1 else { return None }
  let n = out.length()
  out[n - 1] = { ..out[n - 1], last: true }
  Some(out)
}

///|
/// md_links_to as it was worked out of the blocks read (blocks_of): what core_links is held to.
fn md_links_read(text : String, tree : Json?) -> Map[String, LinkTo] {
  let out : Map[String, LinkTo] = Map([])
  fn inl(xs : Array[MdInline]) -> Unit {
    for x in xs {
      match x {
        Link(href, c, to) => {
          if !out.contains(href) {
            out[href] = to
          }
          inl(c)
        }
        Emph(c) | Strong(c) | Strike(c) => inl(c)
        _ => ()
      }
    }
  }
  fn blocks(bs : Array[MdBlock]) -> Unit {
    for b in bs {
      match b {
        Paragraph(xs) | Heading(_, xs) => inl(xs)
        Quote(inner) => blocks(inner)
        List(l) => for item in l.items { blocks(item.blocks) }
        Table(t) => {
          for cell in t.head {
            inl(cell)
          }
          for row in t.rows {
            for cell in row {
              inl(cell)
            }
          }
        }
        _ => ()
      }
    }
  }
  blocks(blocks_of(text, tree))
  out
}

///|
/// A link to `href`, its words `words`, to what `to` says.
fn md_test_link(href : Json, words : Json, to? : Json = Json::null(), bare? : Bool = false) -> Json {
  ["a", [words], { "href": href, "to": to, "bare": Json::boolean(bare) }]
}

///|
/// Rows of a table, `n` of them, each of two cells, the `link`th row's second a link.
fn md_test_rows(n : Int, link : Int) -> Array[Json] {
  Array::makei(n, fn(i) {
    let second : Json = if i == link {
      ["td", [md_test_link(Json::string("https://t.example/\{i}"), Json::string("行\{i}"), to={ "card": "c\{i}" })]]
    } else {
      ["td", ["b\{i}"]]
    }
    ["tr", [["td", ["a\{i}"]], second]]
  })
}

///|
/// Items of a list, `n` of them, the `link`th item's words a link in bold, its last a list of its own.
fn md_test_items(n : Int, link : Int) -> Array[Json] {
  Array::makei(n, fn(i) {
    let words : Json = if i == link {
      ["b", [md_test_link(Json::string("https://l.example/\{i}"), Json::string("项\{i}"))]]
    } else {
      Json::string("项\{i}")
    }
    if i == n - 1 {
      ["li", [words, ["list", [["li", [md_test_link(Json::string("https://l.example/inner"), Json::string("里"))]]]]]]
    } else {
      ["li", [words]]
    }
  })
}

///|
test "a message's pieces and links worked out of the core's tree's shape are what its blocks read make, nothing read" {
  let text = "https://a.example 正文"
  let trees : Array[Json] = [
    // (paragraphs, a heading, a code block, a quote, a rule; links again and again, one whose address is a run)
    [
      ["p", [[0, 17], md_test_link([0, 17], Json::string("首"), to={ "station": "st1", "screen": "s1" }, bare=true)]],
      ["h", [["i", [md_test_link(Json::string("https://h.example"), Json::string("题"))]]], { "depth": 2 }],
      ["pre", [], { "code": "let a = 1", "lang": "mbt", "ink": "" }],
      ["quote", [["p", [md_test_link(Json::string("https://a.example"), Json::string("又"), to={ "card": "other" })]], ["list", md_test_items(2, 0)]]],
      ["hr"],
      ["p", [["code", [], { "content": "x", "path": "a.mbt" }], ["s", [md_test_link(Json::string("https://s.example"), Json::string("删"))]], ["br"], ["img", [], { "src": "p.png", "alt": "图" }]]],
    ],
    // (a table of 6 rows, one of 4, one of 5, a row alone, none; lists of 5 items, 3, 4, none; a block in what is not one)
    [
      ["table", md_test_rows(6, 3), { "align": ["left", "right"] }],
      ["table", md_test_rows(4, 0)],
      ["table", md_test_rows(5, 4)],
      ["table", md_test_rows(1, 0)],
      ["table", []],
      ["list", md_test_items(5, 1), { "ordered": true, "start": 3 }],
      ["list", md_test_items(3, 2)],
      ["list", [["li", [["p", ["松"]], ["p", [md_test_link(Json::string("https://loose.example"), Json::string("散"))]]]], ["li", ["二"]], ["li", ["三"]], ["li", ["四"]]]],
      ["list", []],
      ["div", [["p", ["里面"]], ["table", md_test_rows(7, 6)], ["div", [["list", md_test_items(4, 3)]]]]],
      ["div", []],
      "not a block",
    ],
    // (one block: no pieces)
    [["p", ["只有一段"]]],
    [],
  ]
  let faults : Array[String] = []
  for i, tree in trees {
    parsed.clear(); parsed_order.clear(); parsed_cost.clear(); parsed_used.val = 0; core_parsed.clear()
    let pieces = markdown_pieces(text, Some(tree))
    let links = md_links_to(text, Some(tree))
    // (nothing read as blocks, nothing kept for it)
    if parsed.length() > 0 || parsed_order.length() > 0 || core_parsed.length() > 0 {
      faults.push("\{i}: read as blocks")
    }
    if pieces != md_pieces_read(text, Some(tree)) {
      faults.push("\{i}: pieces \{Repr(pieces)}, read \{Repr(md_pieces_read(text, Some(tree)))}")
    }
    let read = md_links_read(text, Some(tree))
    let same = links.length() == read.length() &&
      links.iter().zip(read.iter()).all(fn(x) { x.0.0 == x.1.0 && x.0.1 == x.1.1 })
    if !same {
      faults.push("\{i}: links \{links.keys().collect().join(" ")}, read \{read.keys().collect().join(" ")}")
    }
  }
  // (the trees above held what they are for: pieces of tables and lists, links of every place)
  guard markdown_pieces(text, Some(trees[1])) is Some(ps) else { fail("no pieces") }
  assert_true(ps.length() > 12, msg="pieces \{ps.length()}")
  assert_eq(md_links_to(text, Some(trees[0])).length(), 5)
  assert_eq(md_links_to(text, Some(trees[1])).length(), 9)
  assert_eq(faults, [])
}
