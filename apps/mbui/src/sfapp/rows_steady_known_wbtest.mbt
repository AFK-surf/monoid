// The rows not steady these tests still show (mbui's rows_steady.mbt: a row of a list turning back again soon
// after it turned, or going at a speed off the frames round it, while what is in the list moves), a file at a time:
// how many a Tester made in it may show. Each only falls: a jolt mended takes its file's number down, and a file at 0
// leaves the list.

///|
fn init {
  @ui.rows_steady_known([
    // (each screen walked over a core answering late, at 60 and 120, as an answer comes: 小屏's 文件 list's foot goes 96
    // in a frame (82 on 大屏), 账号's second row -235, a chat's row -60 to -82, 归档's second row -3; the framework's change for answers, then
    // the list's line)
    ("src/sfapp/answers_still_wbtest.mbt", 2),
    // (words sent in a chat, the core answering 300 to 700 ms after: a row above them goes 82 in a frame as it comes,
    // every screen, at 60 and 120)
    ("src/sfapp/core_pace_rows_wbtest.mbt", 1),
    // (大屏 at 1.3, the chat's panel opened and closed: a row of the chat goes 14 one way, stands 217 ms and comes back
    // 2.8, at 60 and 120)
    ("src/sfapp/daily_paths_wbtest.mbt", 1),
    ("src/sfapp/desk_service_wbtest.mbt", 1),
    // (a settings page's list put where the page that came puts it, in the frame it comes: 推送历史's -31 as 修复 opens,
    // seen once Tree::lists_steady looks at the window's tree's lists, 2026-11-16, as the replays' on main)
    ("src/sfapp/history_fixes_wbtest.mbt", 1),
    // (a message come at the foot of a chat's page made as nodes as it is caught up on, not said: there at once in the
    // change that brings it, as the file's head says it is to be, its rows over it 84 up in that frame; Tree::lists_steady's,
    // 2026-11-16)
    ("src/sfapp/chat_nodes_seen_whole_wbtest.mbt", 1),
    // (each screen over a core answering late: a place's list -330 to -479 in a frame as the page it opens comes;
    // Tree::lists_steady's, 2026-11-16, as history_fixes')
    ("src/sfapp/late_core_wbtest.mbt", 1),
    // (设置's lists as main's pages of them came as nodes (2026-11-16): a search's list -816 in a frame as its answer comes,
    // a page's list -206 as the page that came puts it; 大屏's list 5 in a frame as its foot's own way sets out; seen
    // once Tree::lists_steady looks at the window's tree's lists)
    ("src/sfapp/settings_search_wbtest.mbt", 1),
    ("src/sfapp/settings_wbtest.mbt", 1),
    // (大屏 over a core answering late: a chat's rows go -73 to -82 in a frame as its answer comes, 归档's second row -4,
    // at 60 and 120)
    ("src/sfapp/ways_told_wbtest.mbt", 1),
    ("src/sfapp/wide_wbtest.mbt", 1),
  ])
}
