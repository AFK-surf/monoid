test "JavaScript's reading and writing" {
  let v = parse("{\"vault\":\"a\\ud800b\",\"b\":1,\"vault\":\"second\",\"k\\u0000x\":[1.5,true,null],\"10\":2,\"2\":{\"z\":1e400}}")
  inspect(stringify(v), content="{\"2\":{\"z\":null},\"10\":2,\"vault\":\"second\",\"b\":1,\"k\\u0000x\":[1.5,true,null]}")
  let w = parse("{\"vault\":\"a\\ud800b\"}")
  match w.get("vault") {
    Some(Str(s)) => {
      inspect(s, content="[97, 55296, 98]")
      inspect(stringify(Str(s)), content="\"a\\ud800b\"")
      inspect(text(s), content="a\u{fffd}b")
      inspect(utf16le(s), content="[97, 0, 0, 216, 98, 0]")
    }
    _ => fail("no vault")
  }
  let bad = (t : String) => (try Some(parse(t)) catch { _ => None }) is None
  inspect(bad("{\"a\":1,}"), content="true")
  inspect(bad("[01]"), content="true")
}

///|
test "written as bytes, what JSON.stringify writes as UTF-8, a line's ends escaped" {
  let v = parse(
    "{\"a\":\"x\\ud83d\\ude00y\\ud800z\\u2028\\u2029\\u0001\\\"\\\\\\n\",\"2\":[1.5,-0,1e21,null,true,{}],\"é\":\"ü中\"}",
  )
  let out = @buffer.new()
  write_utf8(out, v)
  let said = stringify(v).replace_all(old="\u{2028}", new="\\u2028").replace_all(old="\u{2029}", new="\\u2029")
  inspect(out.to_bytes() == @utf8.encode(said), content="true")
  inspect(stringify(parse(@utf8.decode(out.to_bytes()))) == stringify(v), content="true")
}

///|
test "JV: JavaScript's values with MoonBit's strings, keys in JavaScript's order" {
  let v = @jsjson.jv_parse("{\"b\":1,\"10\":\"x\",\"2\":[true,null,\"\\u00e9\"],\"a\":{\"k\":2.5}}")
  inspect(@jsjson.jv_stringify(v), content="{\"2\":[true,null,\"é\"],\"10\":\"x\",\"b\":1,\"a\":{\"k\":2.5}}")
  inspect(@jsjson.jstr(@jsjson.jget(Some(v), "10")), content="Some(x)")
  inspect(@jsjson.jnumber(@jsjson.jget(@jsjson.jget(Some(v), "a"), "k")), content="Some(2.5)")
  inspect(@jsjson.jitems(v.get("2")).length(), content="3")
  let o = @jsjson.jobj([("z", @jsjson.js("1")), ("3", @jsjson.jint(3)), ("1", @jsjson.jbool(true))])
  inspect(@jsjson.jv_stringify(o), content="{\"1\":true,\"3\":3,\"z\":\"1\"}")
  inspect(@jsjson.jv_stringify(@jsjson.jdel(@jsjson.jset(o, "z", @jsjson.jnum(0.5)), "3")), content="{\"1\":true,\"z\":0.5}")
  inspect(@jsjson.jv_js_string(Some(@jsjson.jarr([@jsjson.jnum(1.0), @jsjson.JV::Null, @jsjson.js("s")]))), content="1,,s")
  inspect(@jsjson.try_parse("{") is None, content="true")
}

///|
test "JV: undefined left out, @json.Json both ways" {
  let o = @jsjson.jobj([("a", @jsjson.jundef), ("b", @jsjson.jnum(1.0))]).filter_undef()
  inspect(@jsjson.jv_stringify(o), content="{\"b\":1}")
  inspect(@jsjson.defined(@jsjson.jundef) is None, content="true")
  let j : Json = { "b": 1, "7": [true, "x"], "n": Json::null() }
  let v = @jsjson.JV::of_json(j)
  inspect(@jsjson.jv_stringify(v), content="{\"7\":[true,\"x\"],\"b\":1,\"n\":null}")
  inspect(v.to_json().stringify(), content="{\"7\":[true,\"x\"],\"b\":1,\"n\":null}")
  inspect(@jsjson.JV::Num(@double.not_a_number).to_json().stringify(), content="null")
  let js = @jsjson.JV::to_js(v)
  inspect(@jsjson.JV::of_js(js) == v, content="true")
}

///|
test "JValue::to_json: what @json.parse reads of JSON.stringify's text" {
  let k = (s : String) => @jsjson.units(s)
  let lone : @jsjson.JValue = Str([0x61, 0xd800, 0x62])
  let cases : Array[@jsjson.JValue] = [
    Null,
    Bool(true),
    Num(1.5),
    Num(-3.0),
    Str(k("é😀\u{2028}\"\\\n")),
    Arr([Num(1.0), Null, Arr([]), Obj([])]),
    Obj([(k("b"), Num(1.0)), (k("10"), Str(k("x"))), (k("2"), Bool(false)), (k("a"), Obj([(k("z"), Null)]))]),
    Obj([(k("a"), Num(1.0)), (k("b"), Num(2.0)), (k("a"), Num(3.0))]),
  ]
  for v in cases {
    let reread = @json.parse(@jsjson.stringify(v))
    assert_eq(v.to_json().stringify(), reread.stringify())
    assert_true(v.to_json() == reread)
  }
  let dup = @jsjson.JValue::Obj([(k("a"), Num(1.0)), (k("b"), Num(2.0)), (k("a"), Num(3.0))])
  inspect(dup.to_json().stringify(), content="{\"a\":3,\"b\":2}")
  inspect(@jsjson.JValue::Obj([(k("b"), Num(1.0)), (k("10"), Num(2.0)), (k("2"), Num(3.0))]).to_json().stringify(), content="{\"2\":3,\"10\":2,\"b\":1}")
  // a lone surrogate kept (raw_text), not U+FFFD, in a key too: @json.parse refuses the `\ud800` JSON.stringify
  // writes of it, so stringify and @json.parse again gives nothing there
  match lone.to_json() {
    String(s) => inspect(@jsjson.units(s), content="[97, 55296, 98]")
    _ => fail("not a string")
  }
  let keyed : @jsjson.JValue = Obj([(k("x") + [0xd800], lone)])
  assert_true((try Some(@json.parse(@jsjson.stringify(keyed))) catch { _ => None }) is None)
  assert_eq(@jsjson.stringify(@jsjson.JValue::of_json(keyed.to_json())), @jsjson.stringify(keyed))
  // NaN and the infinities as null, as JSON.stringify writes them
  let odd = @jsjson.JValue::Arr([Num(@double.not_a_number), Num(@double.infinity), Num(@double.neg_infinity)])
  inspect(odd.to_json().stringify(), content="[null,null,null]")
  assert_true(odd.to_json() == @json.parse(@jsjson.stringify(odd)))
}

///|
test "JValue::of_json: what JSON.parse reads of the JSON's text, keys in the map's order" {
  let cases : Array[Json] = [
    Json::null(),
    Json::boolean(false),
    Json::number(-0.25),
    Json::string("é😀"),
    Json::string(@jsjson.raw_text([0x61, 0xd800, 0x62])),
    [1, "x", [true, Json::null()], {}],
    { "b": 1, "a": { "z": [Json::null()] }, "c": "s" },
  ]
  for j in cases {
    let v = @jsjson.JValue::of_json(j)
    assert_eq(@jsjson.stringify(v), @jsjson.stringify(@jsjson.parse(j.stringify())))
    assert_eq(v.to_json().stringify(), j.stringify())
  }
  match @jsjson.JValue::of_json(Json::string(@jsjson.raw_text([0x61, 0xd800, 0x62]))) {
    Str(u) => inspect(u, content="[97, 55296, 98]")
    _ => fail("not a string")
  }
  // insertion order kept where JSON.stringify would put integer keys first
  let v = @jsjson.JValue::of_json({ "b": 1, "10": 2, "2": 3 })
  inspect(@jsjson.jval_keys_of(v), content="[b, 10, 2]")
  inspect(@jsjson.stringify(v), content="{\"2\":3,\"10\":2,\"b\":1}")
}

///|
test "JValue's makers and readers" {
  let o = @jsjson.JValue::of_object([
    ("s", @jsjson.JValue::of_string("é")),
    ("d", @jsjson.JValue::of_double(1.5)),
    ("i", @jsjson.JValue::of_int(-2)),
    ("b", @jsjson.JValue::of_bool(true)),
    ("a", @jsjson.JValue::of_array([@jsjson.JValue::Null])),
    ("ss", @jsjson.JValue::of_strings(["x", "y"])),
    ("o", @jsjson.JValue::of_opt_string(Some("z"))),
    ("n", @jsjson.JValue::of_opt_string(None)),
    ("s", @jsjson.JValue::of_string("second")),
  ])
  inspect(
    @jsjson.stringify(o),
    content="{\"s\":\"é\",\"d\":1.5,\"i\":-2,\"b\":true,\"a\":[null],\"ss\":[\"x\",\"y\"],\"o\":\"z\",\"n\":null,\"s\":\"second\"}",
  )
  let v = Some(o)
  // a repeated key's first entry, as JValue::get
  inspect(@jsjson.jval_str_of(@jsjson.jval_at(v, "s")), content="Some(é)")
  inspect(@jsjson.jval_at(v, "none") is None, content="true")
  inspect(@jsjson.jval_at(Some(@jsjson.JValue::Arr([])), "s") is None, content="true")
  inspect(@jsjson.jval_at(None, "s") is None, content="true")
  inspect(@jsjson.jval_num_of(@jsjson.jval_at(v, "i")), content="Some(-2)")
  inspect(@jsjson.jval_num_of(@jsjson.jval_at(v, "s")), content="None")
  inspect(@jsjson.jval_bool_of(@jsjson.jval_at(v, "b")), content="Some(true)")
  inspect(@jsjson.jval_bool_of(@jsjson.jval_at(v, "d")), content="None")
  inspect(@jsjson.jval_arr_of(@jsjson.jval_at(v, "ss")).map(a => a.length()), content="Some(2)")
  inspect(@jsjson.jval_arr_of(@jsjson.jval_at(v, "o")) is None, content="true")
  let ss = @jsjson.jval_at(v, "ss")
  inspect(@jsjson.jval_str_of(@jsjson.jval_at_i(ss, 1)), content="Some(y)")
  inspect(@jsjson.jval_at_i(ss, 2) is None, content="true")
  inspect(@jsjson.jval_at_i(ss, -1) is None, content="true")
  inspect(@jsjson.jval_at_i(v, 0) is None, content="true")
  // a lone surrogate's text as U+FFFD
  inspect(@jsjson.jval_str_of(Some(Str([0xd800]))), content="Some(\u{fffd})")
  inspect(@jsjson.jval_keys_of(o), content="[s, d, i, b, a, ss, o, n, s]")
  inspect(@jsjson.jval_keys_of(Null), content="[]")
  inspect(@jsjson.jval_is_true(Some(Bool(true))), content="true")
  inspect(@jsjson.jval_is_true(Some(Num(1.0))), content="false")
  inspect(@jsjson.jval_is_true(None), content="false")
}

///|
test "JValue's changes as JavaScript makes them" {
  let k = (s : String) => @jsjson.units(s)
  let o : @jsjson.JValue = Obj([(k("a"), Num(1.0)), (k("b"), Num(2.0)), (k("a"), Num(3.0))])
  // `o[k] = v`: the first of a repeated key in its place, a new one at the end, the value given kept as it was
  inspect(@jsjson.stringify(@jsjson.jval_set(o, "a", Null)), content="{\"a\":null,\"b\":2,\"a\":3}")
  inspect(@jsjson.stringify(@jsjson.jval_set(o, "c", Null)), content="{\"a\":1,\"b\":2,\"a\":3,\"c\":null}")
  inspect(@jsjson.stringify(o), content="{\"a\":1,\"b\":2,\"a\":3}")
  inspect(@jsjson.stringify(@jsjson.jval_set(Num(1.0), "c", Null)), content="1")
  inspect(@jsjson.stringify(@jsjson.jval_set_or_new(Num(1.0), "c", Null)), content="{\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_set_or_new(o, "b", Bool(true))), content="{\"a\":1,\"b\":true,\"a\":3}")
  // `delete o[k]`: each entry of it
  inspect(@jsjson.stringify(@jsjson.jval_del(o, "a")), content="{\"b\":2}")
  inspect(@jsjson.stringify(@jsjson.jval_del(Str(k("x")), "a")), content="\"x\"")
  // `{ ...a, ...b }`
  let b : @jsjson.JValue = Obj([(k("b"), Str(k("B"))), (k("c"), Null)])
  inspect(@jsjson.stringify(@jsjson.jval_spread(o, b)), content="{\"a\":1,\"b\":\"B\",\"a\":3,\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(Null, b)), content="{\"b\":\"B\",\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(b, Arr([Num(1.0)]))), content="{\"b\":\"B\",\"c\":null}")
  inspect(@jsjson.stringify(@jsjson.jval_spread(Num(1.0), Str(k("s")))), content="{}")
  // `!!v` and `v == null`
  let vs : Array[@jsjson.JValue?] = [
    None,
    Some(Null),
    Some(Bool(false)),
    Some(Bool(true)),
    Some(Num(0.0)),
    Some(Num(-0.0)),
    Some(Num(@double.not_a_number)),
    Some(Num(2.0)),
    Some(Str([])),
    Some(Str(k("0"))),
    Some(Arr([])),
    Some(Obj([])),
  ]
  inspect(vs.map(@jsjson.jval_truthy), content="[false, false, false, true, false, false, false, true, false, true, true, true]")
  inspect(vs.map(@jsjson.jval_nullish), content="[true, true, false, false, false, false, false, false, false, false, false, false]")
}

///|
test "JValue extended ops: at_last, at_path, text, arr, entries, js_str, js_num, safe_int, to_json_lossy" {
  let k = (s : String) => @jsjson.units(s)
  let o : @jsjson.JValue = Obj([
    (k("a"), Num(1.0)),
    (k("b"), Obj([(k("c"), Str(k("hi"))), (k("c"), Str(k("last")))])),
    (k("a"), Num(2.0)),
  ])
  inspect(@jsjson.jval_num_of(@jsjson.jval_at(Some(o), "a")), content="Some(1)")
  inspect(@jsjson.jval_num_of(@jsjson.jval_at_last(Some(o), "a")), content="Some(2)")
  inspect(@jsjson.jval_str_of(@jsjson.jval_at_path(Some(o), ["b", "c"])), content="Some(hi)")
  inspect(@jsjson.jval_str_of(@jsjson.jval_at_path_last(Some(o), ["b", "c"])), content="Some(last)")
  inspect(@jsjson.jval_text(Some(Str(k("ok")))), content="ok")
  inspect(@jsjson.jval_text(Some(Num(1.0))), content="")
  inspect(@jsjson.jval_arr(Some(Arr([Num(1.0)]))).length(), content="1")
  inspect(@jsjson.jval_arr(Some(Null)).length(), content="0")
  inspect(@jsjson.jval_entries(Some(o)).length(), content="3")
  inspect(@jsjson.jval_entries(Some(Null)).length(), content="0")
  // String(v)
  inspect(@jsjson.jval_js_str(None), content="undefined")
  inspect(@jsjson.jval_js_str(Some(Null)), content="null")
  inspect(@jsjson.jval_js_str(Some(Arr([Null]))), content="")
  inspect(@jsjson.jval_js_str(Some(Arr([Num(1.0), Null, Str(k("x"))]))), content="1,,x")
  inspect(@jsjson.jval_js_str(Some(Obj([]))), content="[object Object]")
  // Number(v)
  inspect(@jsjson.jval_js_num(None).is_nan(), content="true")
  inspect(@jsjson.jval_js_num(Some(Null)), content="0")
  inspect(@jsjson.jval_js_num(Some(Bool(true))), content="1")
  inspect(@jsjson.jval_js_num(Some(Str(k("")))), content="0")
  inspect(@jsjson.jval_js_num(Some(Str(k(" \t\n")))), content="0")
  inspect(@jsjson.jval_js_num(Some(Str(k("007")))), content="7")
  inspect(@jsjson.jval_js_num(Some(Arr([]))), content="0")
  inspect(@jsjson.jval_js_num(Some(Arr([Null]))), content="0")
  inspect(@jsjson.jval_js_num(Some(Arr([Str(k("42"))]))), content="42")
  inspect(@jsjson.jval_js_num(Some(Arr([Num(1.0), Num(2.0)]))).is_nan(), content="true")
  // is_integer / safe_int
  inspect(@jsjson.jval_is_integer(Some(Num(42.0))), content="true")
  inspect(@jsjson.jval_is_integer(Some(Num(42.5))), content="false")
  inspect(@jsjson.jval_safe_int(Some(Num(9007199254740991.0))), content="true")
  inspect(@jsjson.jval_safe_int(Some(Num(9007199254740992.0))), content="false")
  // to_json_lossy replaces lone surrogate with U+FFFD
  let lone : @jsjson.JValue = Str([0x61, 0xd800, 0x62])
  inspect(lone.to_json_lossy().stringify(), content="\"a\u{fffd}b\"")
  inspect(@jsjson.jval_try_parse("{bad}") is None, content="true")
  inspect(@jsjson.jval_try_parse("{\"x\":1}") is Some(_), content="true")
}

///|
test "JV in-place put/delete, raw parse, jat, jkeys, jvalues, js_round, string helpers" {
  // raw parse keeps lone surrogates
  let raw = @jsjson.jv_parse_raw("{\"s\":\"a\\ud800b\"}")
  match raw.get("s") {
    Some(Str(s)) => inspect(@jsjson.units(s), content="[97, 55296, 98]")
    _ => fail("expected string")
  }
  inspect(@jsjson.try_parse_raw("{") is None, content="true")
  // in-place put & delete preserve JS key order (integer keys ascending first)
  let o = @jsjson.JV::Obj([])
  o.put("b", @jsjson.jint(1))
  o.put("10", @jsjson.jint(10))
  o.put("2", @jsjson.jint(2))
  o.put("b", @jsjson.jint(9))
  inspect(@jsjson.jkeys(o), content="[2, 10, b]")
  inspect(@jsjson.jvalues(o).length(), content="3")
  o.delete("10")
  inspect(@jsjson.jkeys(o), content="[2, b]")
  // jat
  let a = @jsjson.jarr([@jsjson.jint(10), @jsjson.jint(20)])
  inspect(@jsjson.jnumber(@jsjson.jat(Some(a), 1)), content="Some(20)")
  inspect(@jsjson.jat(Some(a), -1) is None, content="true")
  inspect(@jsjson.jat(Some(a), 2) is None, content="true")
  // js_round: JS Math.round semantics
  inspect(@jsjson.js_round(0.5), content="1")
  inspect(@jsjson.js_round(0.49999999999999994), content="0")
  inspect(@jsjson.js_round(-0.5), content="0")
  inspect(@jsjson.js_round(-0.5).reinterpret_as_uint64() == (-0.0 : Double).reinterpret_as_uint64(), content="true")
  inspect(@jsjson.js_round(-0.6), content="-1")
  inspect(@jsjson.js_round(4503599627370497.0), content="4503599627370497")
  inspect(@jsjson.js_round(@double.not_a_number).is_nan(), content="true")
  inspect(@jsjson.js_round(@double.infinity).is_inf(), content="true")
  // js_slice / js_index_of / js_last_index_of / js_split
  inspect(@jsjson.js_slice("abcdef", 1, end=4), content="bcd")
  inspect(@jsjson.js_slice("abcdef", -2), content="ef")
  inspect(@jsjson.js_slice("abcdef", 4, end=2), content="")
  inspect(@jsjson.js_index_of("ababa", "ba"), content="1")
  inspect(@jsjson.js_index_of("ababa", "ba", from=2), content="3")
  inspect(@jsjson.js_index_of("abc", "", from=10), content="3")
  inspect(@jsjson.js_last_index_of("ababa", "ba"), content="3")
  inspect(@jsjson.js_split("a,,b,", ","), content="[a, , b, ]")
  inspect(@jsjson.js_split("ab", ""), content="[a, b]")
}
