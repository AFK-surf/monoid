// A link to a station's login (`/w/<ws>/s/<station>/login/<id>`): the station's page opens at its 设置, its 登录 (the
// pages' station_cards.mbt station_logins) brought into view.

///|
/// The login a link pointed to (AppState.open's `login`: Screen.Station(address, login)), on the station's page that
/// opens: its card marked, brought into view once (`true` once it was).
let login_marked : Ref[(String, String, Bool)?] = Ref(None)
