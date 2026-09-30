# MPVPlayerKit 严格代码审查与修复计划

审查日期：2026-09-30。生产代码基线：`e3ccc58`。本次仅生成审查和计划文档，不实施修复。

## 1. 结论与证据边界

识别 **13 项修复事项：5 项 P1、8 项 P2**。其中字幕畸形输入崩溃与 WebVTT 拒绝已用生产解析器实际复现；其余以当前源码和调用关系确认缺陷路径，设备上的具体表现仍需按验收矩阵验证。不存在已证明的 P0 全场景故障。

优先处理错误回退中的跨队列同步等待、配置字段并发访问、旧会话结束事件污染，以及 HLS 丢失音轨。不能以编译通过替代这些路径的验证。

- **P1**：会造成崩溃、卡死、错播或主要播放能力丢失，应优先修复。
- **P2**：特定操作或输入下功能错误，应分批修复。
- **源码确认**：可指出输入、执行分支和缺失防护；不代表已观测所有设备表现。
- **运行复现**：直接编译当前生产解析器，在独立临时程序中得到结果。

### 审查范围

检查 Package.swift、README 中英文版、Demo 配置、Sources 的文件清单及高风险模式、Tests 的组织和关键契约。重点逐路径阅读播放控制、事件分发、初始化、销毁、回退、缓冲、渲染、字幕、系统控制、PiP、QuickPlayer 生命周期/播放列表/设置/布局。

自有播放器 Swift 源码约 13287 行，单文件均不超过 600 行。使用当前独立 codebase-memory 索引追踪回退与 configure 的调用，并检查全部 Sources 证据路径覆盖；索引生成时间为 `2026-09-30T06:08:08Z`。Swift `nonisolated(unsafe)` 等构造在 MPVPlayerView 和软件渲染器有解析缺口，已读取对应源码，不能仅依赖图判断无调用或无风险。

Temby 使用 typed MPVPlayerView 桥接，并关闭库内系统控制；LuWu 使用 QuickPlayer，部分播放列表关联 Vault HTTP 预览会话。宿主只检查相关调用入口，没有对两款应用进行完整审计。二进制 MPVKit/FFmpeg/libplacebo 内部和所有媒体组合不在本次可验证范围内；UI 面板和诊断以路径与配置检查为主，未完成每行代码的形式化验证。

## 2. 优先级总表

| ID | 等级 | 问题 | 证据 |
|---|---|---|---|
| R01 | P1 | 错误回退同步等待 MPV 队列，队列反向等待主线程 | 源码调用链确认 |
| R02 | P1 | 空白字幕时间戳导致数组越界崩溃 | 运行复现 |
| R03 | P1 | configure 与 MPV 队列共享配置字段发生无同步读写 | 源码确认 |
| R04 | P1 | end-file 回调未绑定源会话，可污染重新配置后的播放 | 源码确认 |
| R05 | P1 | HLS master 被替换为单视频 playlist，丢弃外置 rendition | 源码及解析 fixture |
| R06 | P2 | 合法 WebVTT 两段时间戳被拒绝 | 运行复现 |
| R07 | P2 | 字幕超时仅结束上层 completion，底层仍可成功激活 | 源码确认 |
| R08 | P2 | 关闭 QuickPlayer 未取消待解析的播放列表任务 | 源码确认 |
| R09 | P2 | 设置字幕可见性会清空客户端字幕文档 | 源码确认 |
| R10 | P2 | PiP 返回时丢弃宿主原约束，强制铺满父视图 | 源码确认 |
| R11 | P2 | HLS 预解析丢失请求上下文，并使用重定向前 URL 解析相对地址 | 源码确认 |
| R12 | P2 | loadClientSubtitle 的 headers 参数未被使用 | 源码确认 |
| R13 | P2 | 每次 viewDidAppear 都 autoplay，覆盖手动暂停意图 | 源码确认 |

## 3. 逐项缺陷与修复要求

### R01：错误回退可能形成主线程与 MPV 队列互等

**证据**：[Events:483](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Events.swift:483)、[ProfileFallback:44](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+ProfileFallback.swift:44)、[Setup:302](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Setup.swift:302)、[Bridge:299](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Bridge.swift:299)、[Layout:122](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Layout.swift:122)、[Setup:454](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Setup.swift:454)。

路径为 MPV end-file → 主线程 handleEndFileOnMain → retryNextProfileAfterPlaybackFailure → setupMPV → queue.sync。在成功初始化后的 applyContentModeOnMPVQueue 参数求值中，currentContentModeSnapshotForRendererSetup 必须 main.sync。主线程仍阻塞在 queue.sync，形成闭环。销毁和回退也可能等待当前队列内其他同步主线程工作。即使未走到闭环，网络解析和 mpv_initialize 也阻塞主线程。

触发：真机硬解 profile 发生播放错误，尚有 copy/software profile 可回退。模拟器只有 software profile，正常播放构建无法覆盖此分支。

**修复**：主线程只捕获恢复位置、播放意图和布局快照；把销毁、profile 选择、初始化与恢复整体提交到 MPV 队列。UI 回写异步并校验会话。禁止从 MainActor 同步等待执行建链的 MPV 队列。优先复用现有队列和 generation，无需整体改为 actor。

**验收**：通过可注入初始化/命令边界模拟 direct→copy→software 回退；主线程调度探针持续响应；回退期间 pause/stop/重新 configure 不被旧恢复覆盖。真机 iPhone 15 Pro 对故障媒体或注入错误实际复测。

### R02：畸形字幕可使进程崩溃

**证据**：[SubtitleDocument:242](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVSubtitleDocument.swift:242)。parseTimestamp 先 trim，再 split 后直接 `[0]`；空串没有元素。

复现输入：`1\n --> 00:00:02,000\n你好\n`。生产解析器独立程序输出 `Fatal error: Index out of range`，退出码 133。错误输入应跳过坏 cue 或抛出解析错误，不能终止宿主进程。

**修复**：用 first 安全取得时间部分，校验段数、有限值和时间范围；坏 cue 跳过，整份无有效 cue 保持现有 noCues。不要只捕获 thrown error，Swift 越界不是可 catch 的错误。

**验收**：空串、只含空格、单边缺失、非数值、极大值、负值均不崩溃；混合坏 cue 与好 cue 保留好 cue；全部坏 cue 明确失败。新增输入测试与 R06 共用一组解析验证。

### R03：重新配置绕过 Swift 6 并发保护

**证据**：[Lifecycle:48](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Lifecycle.swift:48)、[PlayerView:267](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView.swift:267)、[Setup:310](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Setup.swift:310)、[NetworkOptions:15](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+NetworkOptions.swift:15)、[Player:41](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayer.swift:41)。

configure 在 MainActor 调用 stop，但 stop 仅异步排队销毁旧句柄；随后主线程立即改写 url、headers、userAgent、forceSoftwareDecode、videoQualityPreset、debandEnabled、cacheConfiguration。队列中的旧 setup、诊断、网络选项仍可能读取这些 `nonisolated(unsafe)` 字段。队列更新 cacheConfiguration，公开 getter 又在主线程直接读取，同样缺少同步。generation 检查不能防止检查后继续执行期间的字段竞争。自定义字体字段也存在同类主线程写、队列读边界。

触发：初始化尚未结束时快速换片/重新配置/更新设置；或运行时设置和 getter 交错。后果可能包括新 URL 与旧 headers 混用、错误配置与未定义行为；本次未用 TSan 实测调度。

**修复**：将配置解析为不可变 Sendable 快照，和旧句柄 teardown/new setup 在队列中按顺序应用；主线程保留只供 UI 的值。公有 getter 从主线程镜像或锁保护的快照读，不能直接读队列可变状态。取消条件校验会话代次，而非仅查看临时 stopped 布尔值。将字体变更也提交为捕获后的不可变值。

**验收**：重复 A→B→C configure，暂停、停止、cache/画质变更交错时，初始化请求中的 URL/headers/UA 均属于同一快照；最后一次配置获胜。TSan 检查不出现这组字段的竞争。保留 Temby Objective-C selector 与 NSDictionary 键。

### R04：旧 end-file 事件可作用于新会话

**证据**：[Events:483](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Events.swift:483)、[Events:493](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Events.swift:493)、[Events:518](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Events.swift:518)、[Bridge:413](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Bridge.swift:413)。

handleEndFile 复制 reason/error 后异步进入 MainActor，没有捕获并校验 MPVPlaybackUpdateSourceSession。主线程处理时才读取当前 playbackIntentGeneration；finishEndFile 仅让 timer 停止请求使用该值，其 isPlaying、系统 owner 和状态通知仍无会话防护。

触发：A 的 EOF/error 已从 MPV 队列发出，主线程先配置并播放 B，再处理 A 的回调。A 的 EOF 可使 B 被标为结束、触发播放列表自动跳集；A 的 error 可对 B 启动回退。进度路径已有源会话防护，不代表结束事件也受保护。

**修复**：在事件读取点捕获源 session token，将它贯穿 handleEndFile、fallback、最终状态发布，执行副作用前拒绝旧 token。对 shutdown、视频尺寸、字幕能力等排队回写同时检查同类缺口；只修有实质副作用的回调。

**验收**：可控制主线程交付顺序的测试：积压 A 的 EOF/error/shutdown，先 configure B 再交付；B 的状态、时间、owner、playlist index 和 profile 都不变化。有效 B EOF 仍自动下一集一次。

### R05：HLS 外置音频和字幕组信息被丢弃

**证据**：[HLSResolver:9](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVHLSMasterResolver.swift:9)、[HLSResolver:121](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVHLSMasterResolver.swift:121)、[Setup:346](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Setup.swift:346)。

所有检测到的网络 HLS 都预解析并直接 loadfile 选中 variant URL；Variant 没有 AUDIO/SUBTITLES 组信息，parseVariants 忽略 EXT-X-MEDIA。若 variant 是 video-only，音频只存在 master 引用的外置 audio playlist，打开 video-only 后无法发现该音轨。标准允许这种组合：[RFC 8216 §4.3.4](https://www.rfc-editor.org/rfc/rfc8216.html#section-4.3.4)。

临时 fixture 含 `EXT-X-MEDIA TYPE=AUDIO` 和 `STREAM-INF AUDIO=aud`，生产解析器只返回 video-only.m3u8。这证明 rendition 信息丢失，实际解码无声需配套媒体验证。

**最小修复**：识别外置 rendition 依赖时保留 master，由 mpv 正常处理。只对已确认音视频复用、自包含的 variant 做简化。若原问题必须裁剪多 rendition master，生成保留选中 STREAM-INF 和必要 EXT-X-MEDIA 的最小 master；应先证明简单回退不足再实现这一较复杂方案。

**验收**：本地 HTTP fixture 覆盖复用 A/V、独立 audio、多个语言 audio、外置 subtitle；实际播放有声音，轨道选择存在，原防止 master 卡顿的场景不回归。保留所有默认/语言关系。

### R06：合法 WebVTT 时间戳不被接受

**证据**：[SubtitleDocument:242](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVSubtitleDocument.swift:242)。强制 components.count == 3。

生产实测 `WEBVTT\n\n00:01.000 --> 00:02.000\n你好\n` 返回 noCues，而三段 SRT 返回 1 cue。WebVTT 可省略小时：[W3C WebVTT](https://www.w3.org/TR/webvtt1/#webvtt-timestamp)。

**修复**：针对 timed text 支持 mm:ss.mmm 和 hh:mm:ss.mmm；保留 SRT 逗号及 ASS 时间兼容。先检查结构再转换；不要放宽到任意冒号数量。

**验收**：上述输入得到 start=1/end=2；带小时、大于一小时、CRLF、cue setting、BOM 不回归。独立测试既验证解析成功也验证实际 cue 的时间和文本。

### R07：字幕超时后仍可在底层激活

**证据**：[Player:214](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayer.swift:214)、[Player:245](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayer.swift:245)、[Player:391](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayer.swift:391)、[Events:151](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Events.swift:151)。

10 秒 timeout 只 finishSubtitleLoad(false)，移除 wrapper pending；没有调用底层 cancelSubtitleLoad。迟到 mpv reply 仍完成选择事务并激活该字幕，wrapper 随后忽略通知。调用方看到失败但画面出现字幕，或新选择被旧请求改变。

**修复**：超时统一进入明确的取消路径，先撤销 requestID 的底层选择权，再完成 false；保留底层 selectionEpoch/rollback。相同 URL 合并时，取消一个订阅者不应取消另一个仍有效订阅者。移除 cancelExternalSubtitleLoad 对同一底层取消的重复调用。

**验收**：延迟 reply >10 秒后 completion(false) 只调用一次，迟到 reply 不激活；同 URL 两个 request 取消其中一个后另一个仍成功；stop/换片/主动取消均无重复完成。

### R08：关闭播放器后播放列表解析仍能重启播放

**证据**：[Playlist:88](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVQuickPlayerViewController+Playlist.swift:88)、[Playlist:110](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVQuickPlayerViewController+Playlist.swift:110)、[QuickPlayer:247](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVQuickPlayerViewController.swift:247)、[QuickPlayer:468](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVQuickPlayerViewController.swift:468)。

closePlayer、viewDidDisappear 未取消 playlistSwitchTask 或推进 generation。任务 await 后只判断瞬时 isBeingDismissed；导航 pop 时该值并不代表关闭，dismiss 完成后也会回到 false。控制器若仍被宿主持有，迟到解析会 configure+play；错误分支甚至没有关闭状态判断。

**修复**：建立终止动作统一 cancel 任务、推进 generation、标记永久关闭，再 stop。处理 navigation pop、宿主 dismiss 与关闭按钮；暂时打开 picker 不应终止。解析恢复和错误 UI 都检查该状态。

**验收**：解析延迟期间 close、navigation pop、宿主 dismiss，强持有旧 controller 并释放解析结果，不能新建 MPV handle、播放音频或弹错。正常切换和 EOF 自动下一集保留。LuWu Vault 会话不可在播放器关闭后重新申请/激活。

### R09：客户端字幕的隐藏/显示会丢失文档

**证据**：[Playback:403](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Playback.swift:403)、[ClientSubtitles:18](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+ClientSubtitles.swift:18)、[ClientSubtitles:61](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+ClientSubtitles.swift:61)、[SubtitleRenderer:139](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVSubtitleRenderer.swift:139)。

selectClientSubtitle 选中的文档存于 presentation controller。setSubtitlesVisible 最终调用 setSubtitleVisible，立即 clearClientSubtitle；已有 applyClientSubtitleVisibility 未接入此入口。隐藏后再显示无法恢复原文档。

**修复**：当存在客户端选择时，只更新 isVisible，不 clear 文档；同时维持原生字幕关闭，防止双层绘制。显式 clear、切换原生轨或加载外挂时才清空客户端选择。

**验收**：注入 recording renderer，select document→show→hide→show，最后恢复同一 cue；delay/style 保留；原生轨选择仍清除自绘。公开方法不改名。

### R10：PiP 返回破坏宿主布局契约

**证据**：[PiPPlacement:75](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPictureInPictureViewPlacement.swift:75)、[QuickLayout:81](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVQuickPlayerViewController+Layout.swift:81)。

placement 捕获 originalConstraints，但 restorePlayer 不重新启用，而是创建四边等于 originalSuperview 的新约束。原布局若只是父视图的子区域，返回后变成全父视图；Duo 播放区约束也会被替换。代码专门试图修复 PiP 返回的残留 frame，但恢复 frame 不应丢失宿主原布局。

**修复**：保留并恢复原约束、translatesAutoresizingMaskIntoConstraints 和必要 frame/autoresizing 信息；布局后再执行现有有界 geometry resynchronization。只在原宿主不存在有效约束且明确为全屏时才用全边缘兜底。不能把旧 PiP frame 当作永久 inline 布局。

**验收**：自定义居中子区域、safe-area inset、Duo 半屏、frame 布局分别进出 PiP，恢复后几何与进入前契约相同；反复启动/取消/stop 不留下约束冲突。普通全屏恢复不回归。

### R11：HLS 预解析不继承请求上下文，重定向基址错误

**证据**：[HLSResolver:47](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVHLSMasterResolver.swift:47)、[HLSResolver:82](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVHLSMasterResolver.swift:82)、[Setup:347](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+Setup.swift:347)、[NetworkOptions:65](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+NetworkOptions.swift:65)。

两种 resolver 只创建固定 User-Agent 请求，没有播放器 headers/userAgent 入参。HTTP 重定向成功后仍使用 masterURL 解析相对 playlist，而非 response.url。要求自定义 UA/Referer/X-Emby-Token 的 master 预解析失败后只能回退，保留原易卡顿路径；重定向相对 variant 更会得到错误路径。

**修复**：传入与播放器一致的允许头及有效 UA；保持既有 Authorization 排除政策，不能顺手扩大跨域凭据转发。使用最终 response.url 为相对解析基址。绑定会话取消条件，避免快速换片后临时 stopped=false 让旧请求继续等待。

**验收**：URLProtocol 检查请求头/UA；本地服务 master 302 到另一个目录，返回相对 variant，最终解析到新目录；HTTP失败/超时仍保留正确 fallback；取消不耗满15秒。跨域重定向不新增凭据泄漏。

### R12：公开字幕 headers 参数静默失效

**证据**：[Player:237](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayer.swift:237)、[ClientSubtitles:35](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVPlayerView+ClientSubtitles.swift:35)。

loadClientSubtitle(from:headers:completion:) 未引用 headers，直接调用 libmpv loadSubtitle。调用方传入只对字幕生效的请求头不能影响请求。兼容入口已经明确约定 libmpv 渲染，因此修复不应突然改成客户端解析。

**修复**：为该请求使用传入头获取字幕到受控临时文件，再走 libmpv 加载，或以已验证的 mpv 请求级能力传递头。先验证是否可按请求应用，不能全局覆盖媒体 headers。保留旧签名和渲染语义，临时文件生命周期覆盖取消、失败、stop。

**验收**：字幕服务要求独有 header，媒体服务要求不同 header；两者都成功且媒体配置未被改写。失败/取消后临时文件清理，completion 恰好一次。

### R13：再次出现时覆盖用户暂停状态

**证据**：[QuickPlayer:221](/Users/tangwanlong/Projects/Combines/MPVPlayerKit/Sources/MPVPlayerKit/MPVQuickPlayerViewController.swift:221)。autoplay=true 且 player.isPlaying=false 就 play，没有“仅首次”的限制。

触发：用户暂停后打开导致 QuickPlayer 消失的全屏 picker/覆盖页，再关闭覆盖页；viewDidAppear 会继续播放。导航复现和不同 presentation style 的具体生命周期需设备验证。初始 autoplay 选项不应反复覆盖后来用户选择。

**修复**：初始自动播放只消费一次；回来时保持现有播放意图。若宿主要求临时覆盖暂停并恢复，应按消失前意图恢复，不读取一个默认 autoplay 标志来决定。

**验收**：暂停→覆盖页→返回保持暂停；正在播放→返回符合约定；首次 autoplay true/false 均正确；切换播放列表仍主动播放，不被首次标记拦截。

## 4. 验证缺口与待确认风险

这些不计入上面的 13 项已识别缺陷，先补证据，再决定是否单独修复。

| ID | 内容 | 下一步 |
|---|---|---|
| V01 | Demo TestAction 没有 Testables；依赖包 scheme 的 build-for-testing 只产出 package product | 建立可重复运行的 package XCTest/宿主测试入口；检查测试数和 .xcresult，不能只看命令退出码 |
| V02 | 多个 contract test 只检查源码字符串包含某调用 | 保留兼容键检查；新增实际观察异步顺序、状态和副作用的测试，避免照抄实现 |
| V03 | DualPane 每次 willLayout 中先 layoutIfNeeded，再移除/重加 host 并新建约束 | 用 UIKit layout 计数与 Instruments 证实是否重复布局/重入；若发生，安装 host 一次，仅切换约束组 |
| V04 | MetalLayer 后台 setter 异步转主线程，getter 即刻读旧值；具体渲染依赖行为未知 | 真机检查交换链、颜色切换和时序；不未经证据替换整个渲染层 |
| V05 | redactedURLDescription 只清 query，保留 URL user/password、路径和 fragment；探针会写路径到诊断 | 用合成 URL 做日志泄漏测试，再确定安全字段白名单；不记录真实 Token |
| V06 | HLS picker 为所有设备优先 AVC≤720p，注释说用于 software decode | 确认真机是否同样需要此保护；确认后将设备解码能力与选择策略分开，不能把渲染画质当作流码率 |
| V07 | 回调 userdata 的释放依赖 libmpv 回调停止语义 | 按绑定 MPVKit 版本核实契约，压力测试 stop/deinit；现有证据不足以定性 UAF |

保留既有 UserDefaults 缓存优先级，不重置用户选择。README 明确排除 Authorization 与 X-Emby-Authorization，本次不把这种已声明策略当作新 bug，也不在修复时擅自改变。

## 5. 分批实施计划

| 批次 | 范围 | 前置 | 主要变更 | 验收与回滚 |
|---|---|---|---|---|
| A | V01、R02、R06 | 用户确认实施 | 建立测试入口；解析器安全取值与格式修正 | 输入测试实际执行；普通 SRT/ASS/编码测试不回归；独立提交可回滚 |
| B | R01、R03、R04 | A 的异步测试入口 | 不可变请求快照、MPV队列回退、会话有效性校验 | 注入积压事件/初始化停顿，验证主线程响应；Temby与LuWu编译；单独提交 |
| C | R07、R09、R12 | B 会话边界稳定 | 字幕取消唯一完成；显示保留文档；请求头按请求生效 | 慢请求/取消/合并及自绘行为实测；不改原生渲染兼容语义 |
| D | R05、R11 | B 取消语义稳定 | 保留 HLS rendition、请求上下文和最终基址 | 本地HTTP媒体 fixture实际播放及轨道验证；原问题样本复测 |
| E | R08、R10、R13 | B/C | QuickPlayer终止路径、暂停意图、PiP原布局恢复 | iPhone15Pro手动验收；Temby/LuWu接口与布局回归 |
| F | V02—V07、文档 | A—E | 对风险补证据；仅修实证问题；完善契约与运行记录 | 不将推测并入生产代码；每项证据与提交对应 |

每批优先新增能失败的行为测试，修复后只运行必要回归。尽量复用已有 generation、queue、状态机；新增文件按当前架构组织且不超过600行。不整体重写播放器，不迁移缓存键，不更换二进制版本，不扩展未经请求的功能。

粗略工作量：A约0.5—1天、B约2—3天、C约1—2天、D约1—2天、E约1—2天。是工程拆解估算，受故障媒体可复现程度及真实设备验证影响；不是完成时间承诺。各批完成编译及必要验证后按项目要求用简体中文提交 Git，不 push。

## 6. 双宿主与设备验收矩阵

| 场景 | Kit验证 | Temby | LuWu |
|---|---|---|---|
| 错误回退/stop/configure交错 | 注入初始化和事件、主线程探针 | typed桥接与通知；保留宿主系统owner | QuickPlayer与Vault会话取消 |
| seek/pause/倍速/EOF | 旧token拒绝；有效请求一次完成 | resume/remote/字幕选择不回归 | playlist自动下一集与关闭 |
| 字幕 | 坏输入、SRT/VTT/ASS、慢请求、独立header、自绘显示 | 宿主字幕UI/字体/既有completion | 文件picker和原生字幕 |
| HLS | 独立audio/subtitle、重定向、取消、自定义UA | 带Token/Referer的媒体请求 | 远程流与本地HTTP流 |
| PiP | 子区域原约束与全屏恢复 | 保留宿主远程命令策略 | QuickPlayer与Duo媒体区域 |
| 缓存与画质 | 不改持久化优先级 | MMKV宿主缓存策略保持 | UserDefaults已有用户选择保持 |
| 布局 | 普通屏、宽屏、safe area | 普通iPhone播放器 | 普通iPhone、Duo姿态/内外屏需分别验证 |

需要交互调试时按项目约定运行到 **iPhone 15 Pro**，等待用户手动操作后分析。当前未安装或启动宿主播放界面；未声称完成 PiP、HDR、后台、Duo 姿态或设备运行验收。模拟器使用不同渲染器和缓存策略，不能替代真机 GPU/VideoToolbox 验证。

## 7. 本次实际执行结果

| 验证 | 结果 | 限制 |
|---|---|---|
| Demo Debug / generic iOS Simulator | BUILD SUCCEEDED | 编译证明，未播放媒体 |
| Demo Debug / generic iOS device，禁用签名 | BUILD SUCCEEDED | 真机架构编译；未安装运行 |
| Package dependency scheme build-for-testing | TEST BUILD SUCCEEDED | 未生成 MPVPlayerKitTests/.xctest；不算全套测试编译或运行 |
| Tests/run_hls_resolver_tests.sh | 6 tests，0 failures | 解析/取消/超时；无实际音视频 |
| check_background_hardware_decode.swift | 通过 | 纯策略验证 |
| check_duo_layout.swift | 通过 | 纯几何验证 |
| 生产字幕解析器临时输入探针 | SRT 1 cue；VTT noCues；畸形时间越界退出133 | 已复现 R02/R06，未修改源码 |
| 生产 HLS parser 外置 audio fixture | 只选 video-only playlist | 确认数据丢失；未解码媒体 |

本次构建唯一看到的 warning 是 AppIntents 元数据提取被跳过；没有 Swift 编译错误。初次无提权 Xcode 查询因系统包缓存与 CoreSimulator 权限失败，受控提权后成功。图 CLI 初次因私有缓存权限失败，受控提权后成功。未遇到网络下载失败。

原始日志位于临时目录：`/tmp/mpv-review-build.log`、`/tmp/mpv-review-device-build.log`、`/tmp/mpv-review-test-build.log`、`/tmp/mpv-review-hls.log`、`/tmp/mpv-review-subtitle-crash.log`。临时文件可能被系统清理，因此关键结果已保存在本报告。

## 8. 开发开始前需要落实的决定

用户本次授权为审查和修复计划，尚未授权上述修复实施。实施前按项目要求先完成需求沟通并获得明确确认，重点敲定 HLS 保留 master 的 fallback、字幕 headers 获取方案及首次 autoplay 的产品语义；不自动采用推荐方案继续开发。

当前可以先确认 A 批作为最小开始范围；B 批涉及播放会话与回退边界，应单独审阅方案。审查报告本身不构成生产修改已完成或设备验证通过的承诺。
