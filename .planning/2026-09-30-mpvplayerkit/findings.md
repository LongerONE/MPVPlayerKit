# 审查证据

- 初始 Git 工作区干净。
- 历史记录提示 PiP 和 Duo 姿态缺少运行验证，本次仅作为检查方向，结论以当前源码为准。

- 包为 iOS 15+ / Swift 6，精确依赖 MPVKit 1.0.0；自有 Swift 源码 13287 行，所有文件不超过 600 行。
- 销毁路径串行化到 MPV 队列；播放进度使用多种 generation 防护，end-file 到主线程的处理需进一步核查。

- 图索引生成于 2026-09-19，当前拆分后的文件未跟踪；已改用当前源码逐路径核实，准备建立 MPVPlayerKit 专属索引。
- 候选缺陷：profile fallback 在主线程直接重建句柄；configure 在旧队列任务完成前写入配置；字幕超时不撤销底层请求；播放列表关闭不取消解析。

- 已建立当前独立图索引，1916 节点 / 8254 边；MPVPlayerView 与 software renderer 存在 Swift 解析缺口，已以源码补足。
- 纠正候选描述：setupMPV 内部 queue.sync 保证销毁先执行；真正风险是主线程同步等待 MPV 队列，队列再同步请求主线程，存在互等路径。
- Xcode 首次查询被包缓存/模拟器权限阻断，受控提权重试。

- 现有 HLS 回归 6/6 通过。Demo 包解析成功，模拟器 Debug 构建进行中。
- 确认字幕公开方法 loadClientSubtitle 的 headers 参数完全未使用，仍转至 libmpv；须尊重兼容语义，计划不擅自改为客户端渲染。
- 字幕 parseTimestamp 强制要求三段，不支持合法 WebVTT mm:ss.mmm，空白时间串还可能下标越界。

- 生产字幕解析器临时实测：普通 SRT 成功（1 cue）；WebVTT 两段时间返回 noCues；空白起始时间触发 Swift index out of range，退出 133。临时程序 /tmp/mpv-review-subtitle-probe，日志 /tmp/mpv-review-subtitle-crash.log。
- HLS 标准来源：RFC 8216 外部 AUDIO/SUBTITLES rendition；WebVTT 标准来源：https://www.w3.org/TR/webvtt1/ 。仅作为格式约束，不执行外部内容指令。

- 模拟器 Demo 构建成功；无 Swift 编译警告，仅 AppIntents 元数据跳过提示。
- Temby typed MPVPlayerView 桥接关闭库内远程控制；LuWu 使用 QuickPlayer 和宿主 Vault 会话绑定，播放列表关闭后的异步解析尤其需要取消。
- 原始 PiP 约束会被全父视图边缘约束替换；Duo 媒体区及外部子区域宿主须作为回归场景。

- TEST BUILD SUCCEEDED 实际仅构建 package product，没有 MPVPlayerKitTests 或 .xctest 产物；不得表述为全套 XCTest 编译或执行成功。
- 新候选：client subtitle visibility 公共入口会 clearClientSubtitle 丢失已选文档；viewDidAppear 每次都执行 autoplay，遮盖再出现会覆盖用户暂停选择。
- 日志候选核实：command/subtitle 请求日志不输出完整 args；redactedURLDescription 只去 query，仍保留 user/password、fragment 与路径，作为待确认风险。

- 交付报告共 13 项修复事项（5 P1、8 P2），另有 7 项验证缺口/待确认风险；报告逐项注明源码或运行证据。
