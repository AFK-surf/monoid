// What each switch pressed in switches_still_wbtest.mbt is seen to change more than once, its core answering 400 ms
// late: a row a press (its screen size, screen and switch; an opener's choice after it), with how many times. Set
// from main at ba25bbd601 on 2026-11-14 and only falls: a press that changes once has no row, and the change that
// brings a press down writes its row down or takes it out (switches_against_known says the line). What is no page's
// own (a notice, a tip, a number running while it is seen) is never counted (switches_still_wbtest.mbt's head).

///|
let switches_known : Map[String, Int] = Map([
    // (大屏's sidebar's 筛选会话 to 我参与的: the menu gone, the pointer left still over the list's first row comes to rest
    // there as the lists' slide ends, and the row says its time once its whole row (chatRow) is answered)
    ("大屏 home-bars: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 home-jobs: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 home-news: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 home-sheet: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 home-station-updates-app: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 home-station-updates: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 home: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 newchat-files: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 newchat-lend: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 newchat-profiles: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 newchat-reading: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 newchat: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 search-jobs: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 search-results: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 search: opener 「筛选会话：全部」 › 「我参与的」", 2),
    ("大屏 settings-profile-login-failed: opener 「筛选会话：全部」 › 「我参与的」", 2),
    // (the rest, each its own)
    ("中屏 newchat-preset-new-browse-repos: opener 「选择文件夹所在的 station: Willow」 › 「Maple」", 2),
    ("中屏 player-ended: toggle 「下一个」", 2),
    ("中屏 player-failed: toggle 「上一个」", 2),
    ("中屏 player-failed: toggle 「下一个」", 2),
    ("中屏 player-opening: toggle 「上一个」", 2),
    ("中屏 player-opening: toggle 「下一个」", 2),
    ("中屏 player-video: toggle 「上一个」", 2),
    ("中屏 player-video: toggle 「下一个」", 2),
    ("大屏 chat-view-side: toggle 「搜索」", 2),
    ("大屏 newchat-preset-new-browse-repos: opener 「选择文件夹所在的 station: Willow」 › 「Maple」", 2),
    ("大屏 player-ended: toggle 「下一个」", 2),
    ("大屏 player-failed: toggle 「上一个」", 2),
    ("大屏 player-failed: toggle 「下一个」", 2),
    ("大屏 player-opening: toggle 「上一个」", 2),
    ("大屏 player-opening: toggle 「下一个」", 2),
    ("大屏 player-video: toggle 「上一个」", 2),
    ("大屏 player-video: toggle 「下一个」", 2),
    ("小屏 player-failed: toggle 「上一个」", 2),
    ("小屏 player-opening: toggle 「上一个」", 2),
    ("小屏 player-video: toggle 「上一个」", 2),
    ("小屏 player-video: toggle 「下一个」", 2),
])
