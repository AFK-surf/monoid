// What each screen still shows with its words at words_large_scale (words_large_wbtest.mbt), by window, language and
// screen: squeezed, or words over words at rest. The bar it may only fall from; a screen not listed has none. Counted
// as the sweep first ran (2026-11-10): 87 screens (each language counted) with 229, and the share card's looks
// (share-card-senren-*) with 770, most of those words laid over words by the look's design, as at the default size.
// The card made as nodes (2026-11-17), drawn smaller in a phone's stage, is judged where it is drawn its own size
// (mbui's tree_drawn_scaled): what is left of it is the looks' words laid over words by design.
// The window tree's nodes held to the squeeze as an old view's are (squeeze_tree.mbt, 2026-11-11) added what each line
// beside it says (`was`: its bar before), each to be mended and its bar brought down: 定高不随字号 a box of a fixed height
// its words' line outgrows at this size; 真问题 squeezed as it shows.

///|
let words_large_known : Map[String, Int] = {
  let known = Map([])
  for k in [
    ("phone-zh settings-new-connect-platform", 1),
    ("phone-zh settings-new-connect-platform-group", 1),
    ("phone-zh settings-vault-words", 14),  // was 10, +4 (a) vault.mbt:859 真问题，待修
    ("phone-zh share-card-senren-adv", 1),
    ("phone-zh share-card-senren-ciallo", 34),
    ("phone-zh share-card-senren-parfait", 87),
    ("phone-zh share-card-senren-title", 160),
    ("phone-zh share-card-senren-affection", 38),
    ("phone-zh share-card-senren-party", 0),
    ("phone-en chat-agent", 2),  // was 0, +2 (a) hover.mbt:1113 真问题，待修
    ("phone-en chat-preview-csv", 1),
    ("phone-en chat-preview-html", 1),
    // (its switch's title 「Send as file in this chat」 on two lines beside the switch, 40,642 224×50: the old panel's, told
    // of its nodes again as the tree's squeeze came to say what shares their row; it was 1 before its panel became nodes)
    ("phone-en chat-station-sheet", 1),
    ("phone-en drive-upload", 1),
    ("phone-en history-details", 1),  // was 0, +1 (a) hover.mbt:1113 真问题，待修
    ("phone-en screen-files-done", 2),
    ("phone-en settings-station-env", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-lower", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-versions", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-network", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-copies", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-copies-alone", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-restore", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-restore-offer", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-restore-confirm", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-restore-confirm-long", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-station-restored", 2),  // was 0, +2 (a)+(g) station_node.mbt:2093 真问题，待修
    ("phone-en settings-vault-words", 14),  // was 10, +4 (a) vault.mbt:859 真问题，待修
    ("phone-en settings-about", 1),  // was 0, +1 (g) page_node.mbt:1267 真问题，待修
    ("phone-en share-card-senren-adv", 1),
    ("phone-en share-card-senren-ciallo", 18),
    ("phone-en share-card-senren-parfait", 87),
    ("phone-en share-card-senren-title", 161),
    ("phone-en share-card-senren-affection", 38),
    ("phone-en share-card-senren-gahou-mako", 1),
    ("phone-en share-card-senren-gahou-roka", 1),
    ("phone-en share-card-senren-gahou-koharu", 2),
    ("phone-en share-card-senren-gahou-roka2", 1),
    ("phone-en share-card-senren-party", 1),
  ] {
    known[k.0] = k.1
  }
  known
}

///|
/// Words a box with its height said does not hold (mbui's Tester::fixed_outgrown) on each screen in a phone's window at
/// words_large_scale (words_large_wbtest.mbt), by language and screen: the bar it may only fall from, counted as the
/// rule first ran (2026-11-11). A screen not listed has none. What they are (the coordinator of the migration,
/// 2026-11-11): the old views' (a screen's timer, a chat's old
/// parts), mended as each is made as nodes. None is left of search's lines (their
/// lines as high as their words at least, @sf.touch_found), of a model's configuration's capsule (newchat-model), of a mark's letter (drawn at 1 as its mark is, @sf.mark_words_node), of a tag, a video's length or 用量's months (as
/// high as their words' line, @sf.tag_node, box_at, a least), of 智能体's card's spend (on its line of 26), or of a checkbox's tick (drawn by its stroke, @sf.check_node's).
/// None now: a chat's picture coming and its screens', the last, made as nodes with the chat's page (2026-11-19).
let words_large_outgrown_known : Map[String, Int] = Map([])
