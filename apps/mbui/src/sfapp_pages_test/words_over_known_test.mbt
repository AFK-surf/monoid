// The words over words these tests still show while a closing layer fades (mbui's words_over.mbt).

///|
fn init {
  @ui.words_over_closing_expected([
    ("src/sfapp_pages_test/model_pop_test.mbt", "想让 agent 做什么？", "DeepSeek V4.1 Flash"),
    ("src/sfapp_pages_test/model_pop_test.mbt", "想让 agent 做什么？", "GPT-6"),
    // (the configurations used most a row each: the first level taller, a configuration's capsule over the words)
    ("src/sfapp_pages_test/model_pop_test.mbt", "想让 agent 做什么？", "DSH · 高"),
    ("src/sfapp_pages_test/model_pop_test.mbt", "想让 agent 做什么？", "高"),
    ("src/sfapp_pages_test/model_pop_test.mbt", "描述要做的事。它会在 Willow 上使用所选模型新建会话。", "GPT-6 Astra"),
    ("src/sfapp_pages_test/model_pop_test.mbt", "描述要做的事。它会在 Willow 上使用所选模型新建会话。", "中"),
    ("src/sfapp_pages_test/model_pop_test.mbt", "描述要做的事。它会在 Willow 上使用所选模型新建会话。", "Opus 5.5"),
    ("src/sfapp_pages_test/model_pop_test.mbt", "描述要做的事。它会在 Willow 上使用所选模型新建会话。", "200K"),
  ])
}
