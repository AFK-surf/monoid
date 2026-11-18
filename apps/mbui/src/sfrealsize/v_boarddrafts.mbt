// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `boardDrafts` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"boardDrafts","scope":"ws"}
  let value =
    #|{"drafts":[{"id":"new:board-1791277200000-1","title":"修复 Android 上聊天列表滚动掉帧","station":"ws/maple","stationName":"Maple","files":[{"id":"f-0","name":"截图 1.png"}]},{"id":"new:board-1791273600000-1","title":"把 station 的日志轮转改成按天切","station":"ws/willow","stationName":"Willow"},{"id":"new:board-1791270000000-1","title":"Slack 连接断开后不会自动重连","station":"ws/studio","stationName":"Studio"},{"id":"new:board-1791266400000-1","title":"升级 Effect 到 4.0 并跑完全部测试","station":"ws/cedar","stationName":"Cedar"},{"id":"new:board-1791262800000-1","title":"首页加载时骨架屏闪一下","station":"ws/maple","stationName":"Maple"},{"id":"new:board-1791259200000-1","title":"用量页按模型拆分，加周对比","station":"ws/willow","stationName":"Willow"},{"id":"new:board-1791255600000-1","title":"Windows 安装包签名失败（signtool 0x800b0109）","station":"ws/studio","stationName":"Studio","files":[{"id":"f-6","name":"截图 7.png"}]},{"id":"new:board-1791252000000-1","title":"iOS 锁屏推送不显示正文","station":"ws/cedar","stationName":"Cedar"},{"id":"new:board-1791248400000-1","title":"Review #5231：归档策略的默认值","station":"ws/maple","stationName":"Maple"},{"id":"new:board-1791244800000-1","title":"写本周周报：发布、事故、下周计划","station":"ws/willow","stationName":"Willow"},{"id":"new:board-1791241200000-1","title":"订单列表慢查询，explain 看一下","station":"ws/studio","stationName":"Studio"},{"id":"new:board-1791237600000-1","title":"CI 迁到自建 runner，缓存命中率","station":"ws/cedar","stationName":"Cedar"}]}
  put(asked, value)
}
