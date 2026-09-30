# MPVPlayerKit 修复实施记录

日期：2026-09-30。审查基线：385bdb7。用户已授权按照审查计划实施。

## 已实施的修复

| 项目 | 变更 | 验证证据 |
|---|---|---|
| R01 | 主线程只提交回退请求；profile 重建、销毁和初始化在 MPV 队列执行 | 队列被阻塞时回退入口仍返回；停止后待执行回退失效 |
| R02 / R06 | 安全读取时间 token；支持两段 WebVTT；拒绝非有限数、负数和越界分秒 | SRT / VTT / ASS 与畸形输入回归 |
| R03 | 配置镜像由锁保护，队列消费一次捕获的 Sendable 快照；缓存和字体更新分别同步到两侧 | 连续配置的 UI 值与队列应用值一致；Swift 6 编译 |
| R04 | END_FILE、SHUTDOWN、状态、解码和缓冲通知绑定来源会话；销毁原子推进当前会话，过期销毁不能推进新会话或清理新 seek | 旧结束事件不停止新播放；旧 teardown 不能推进新配置；已有时间更新与 seek 回归 |
| R05 | 存在外置 AUDIO / SUBTITLES / VIDEO URI 时保留 master | 三类 rendition fixture；不拆散组关联 |
| R07 | 超时走真正取消路径，abort 原生异步请求或取消下载 Task；completion 去重 | 超时取消 URLSession 下载、一次完成；合并订阅保留其他等待者 |
| R08 | 关闭、dismiss 和导航 pop 的终止路径取消 playlist Task 并推进代次 | 不协作取消的晚到结果不能重配或重启播放器 |
| R09 | 客户端文档可见性切换保留选择；选择客户端文档时取消未完成原生选择 | hide / show 保留文档；原生绘制保持关闭 |
| R10 | PiP 返回恢复原约束、frame / autoresizing 与 translates 状态 | frame 子区域、约束子区域和约束常量变化回归 |
| R11 | HLS 解析请求继承允许头和有效 UA，使用 response.url 为相对路径基址；取消绑定会话 | URLProtocol 检查 Token / UA、排除 Authorization 及最终基址 |
| R12 | 独立字幕头用于 URLSession 下载，生成实例管理的临时文件交给 libmpv | 成功下载文件可解析；媒体头保持；stop 清理文件；失败和超时取消 |
| R13 | autoplay 只消费一次 | 首次显示后暂停，再次出现不推进播放意图 |

新增源码按当前 extension 架构放置于 `MPVPlayerView+ConfigurationSnapshot.swift` 和 `MPVPlayerView+SetupConstants.swift`，保持生产 Swift 文件不超过 600 行。未更换 MPVKit 二进制或迁移缓存持久化键。

## 验证缺口处理

- V01：Demo 新增真实 hosted XCTest target 和共享 Testables，并提供 `Tests/run_ios_tests.sh`；测试宿主不会自动播放网络示例。
- V02：新增行为回归；修正原测试中模拟器渲染器、PiP 全屏、隐藏 transport 按钮和同步模拟异步回调的过期假设。保留兼容键检查。
- V05：合成 URL 确认诊断字符串会保留敏感字段；现在清除 user、password、path、query 和 fragment，保留 host 与 query 数量。新增泄漏回归。
- 现有缓冲测试发现 seek 未更新原因字段：seek 优先结束缓冲并取消 fallback，不显示 spinner。
- V03 / V04 / V06 / V07：未把推测改写成生产重构。布局性能、真机交换链时序、硬解码率策略和 libmpv 回调释放压力测试继续作为设备验收项。

## 实际执行结果

| 验证 | 结果与边界 |
|---|---|
| Demo hosted XCTest / iOS 27 模拟器 | 最终实际执行 154 项，0 失败，TEST SUCCEEDED |
| 字幕纯解析测试入口 | 3 项，0 失败；完整 iOS 套件也包含这 3 项 |
| Temby / LuWu / generic iOS | 最终真机架构构建通过；无宿主源码修改 |
| Demo / generic iOS | 真机架构签名构建通过，保留可安装 app |
| Swift 6 | 生产包与测试 target 使用 Swift 6；已清理测试并发警告 |
| 文件与 diff | 生产及 XCTest Swift 文件均不超过 600 行；git diff --check 通过 |
| 图索引 | 最终 2068 节点 / 8847 边；三处既有 Swift 解析缺口由源码补足，不能把图当作完整证明 |

日志保存在 `/tmp/mpv-ios-tests-final-delivery.log`、`/tmp/mpv-temby-release-check.log`、`/tmp/mpv-luwu-release-check.log`、`/tmp/mpv-demo-release-check.log`。完整测试结果：`/tmp/mpv-review-derived/Logs/Test/Test-MPVPlayerKitDemo-2026.09.30_16-17-32-+0800.xcresult`。临时目录可能被清理，关键数量与结果已保存于本记录。

最终构建仍有 AppIntents 元数据跳过提示及 Demo 原有方向声明警告；没有 Swift 并发编译警告。

中间失败包括过期断言、未等待的 expectation 和诊断测试订阅了全部状态导致重复 fulfill；已修复后以最终完整运行为准。测试宿主最低 iOS 17 是当前 Xcode XCTest 运行时要求，生产包最低 iOS 15 保持。

## 尚需设备验收

已签名构建 Demo，并尝试安装到 iPhone 15 Pro。CoreDevice 返回 4016：设备缺少已连接且受信任的远程服务状态；未成功安装、启动或完成手动验收。已请用户 USB 连接、解锁并信任 Mac。

设备恢复连接后，运行修复版 Demo，等待用户手动操作后分析：播放/暂停→覆盖页返回、横竖屏、PiP 进出/关闭、后台恢复，以及有外置音轨的 HLS。Temby 宿主通知/远程控制和 LuWu Vault / Duo 内外屏与姿态需按矩阵分别验收。

交互式返回取消时，控制器重新出现会清除待退出标记，保留原播放会话；只有实际消失才结束交互退出。

自动测试证明解析、取消、会话隔离与 UIKit 约束契约；不能替代真实 GPU / VideoToolbox、PiP 系统窗口、HDR、实际 HLS 音视频和 Duo 姿态验收。保留 master 会恢复外置 rendition 关联，也保留原 demuxer 打开多 rendition 的成本。
