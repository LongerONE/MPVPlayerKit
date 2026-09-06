# MPVPlayerKit

[English](README.md) | 简体中文

一个 iOS 15+ 的 Swift Package，用一套轻量 UIKit API 封装 [MPVKit](https://github.com/mpvkit/MPVKit)。

## 功能特性

- HTTP 与本地视频播放
- 播放、暂停、停止、精确 seek 与倍速控制
- 硬件解码，VideoToolbox 失败时自动降级到软解
- 支持 HDR 与 Dolby Vision，按屏幕 EDR 能力自适应 Metal 输出
- 音频、视频、字幕轨道的发现与切换
- 框架自带的 SRT/VTT 解析、时间轴、样式与默认渲染
- 可替换的客户端字幕渲染器，适配应用自定义 UI
- 通过 MPV 加载外挂 ASS/SSA，支持保留原始样式
- 字幕延迟、样式预设与实例级自定义字体
- 自定义界面与快捷播放器均支持画中画
- 锁屏与控制中心的 Now Playing 播放控制
- 内存缓冲（cache）配置，支持 10/30/60/120 秒时长
- 全屏滑动手势：seek、亮度、音量，可逐项关闭
- 强制横屏，宿主 App 仅声明竖屏时同样生效
- 可复用的渲染视图，用于自定义播放器界面
- 可选的开箱即用 `MPVQuickPlayerViewController`

## 环境要求

- iOS 15.0 或更高
- Swift 6 工具链（包使用 swift-tools 6.0、Swift 6 语言模式构建）
- [MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0（精确锁定）
- 渲染运行在自定义 `CAMetalLayer` 上；EDR 输出需要 iOS 16+ 且设备支持

## 安装

发布本包后，在 Xcode 中通过 **File > Add Package Dependencies** 添加仓库 URL。包产品名为 `MPVPlayerKit`。

本地检出的仓库可直接将 `MPVPlayerKit` 目录作为本地包依赖加入。

## 自定义播放器界面

应用已有自己的控制层时，直接使用 `MPVPlayer`：

```swift
import MPVPlayerKit

let configuration = MPVPlayerConfiguration(
    url: videoURL,
    headers: ["Authorization": "Bearer token"],
    userAgent: "ExampleApp/1.0"
)
let player = MPVPlayer(configuration: configuration)

containerView.addSubview(player.playbackView)
player.playbackView.frame = containerView.bounds
player.play()

player.seek(to: 120, autoPlay: true)
player.startPictureInPicture()

let audioTracks = player.tracks(ofType: .audio)
if let track = audioTracks.first {
    player.select(track: track)
}

let subtitleTracks = player.tracks(ofType: .subtitle)
if let subtitle = subtitleTracks.first {
    player.select(track: subtitle)
}
```

`MPVPlayerConfiguration` 支持以下字段：

| 字段 | 用途 |
| --- | --- |
| `url` | 本地文件或 HTTP(S) 媒体地址 |
| `headers` | 转发给 mpv 的额外 HTTP 请求头（`Authorization` 与 `X-Emby-Authorization` 不会被转发） |
| `userAgent` | 自定义 HTTP User-Agent |
| `forceSoftwareDecode` | 跳过硬解路径，强制软解 |
| `isDolbyVisionPlayback` | 提示管线当前流为 Dolby Vision |
| `videoQuality` | 渲染画质预设，见[画质](#画质) |
| `debandEnabled` | 开启去色带（deband） |
| `cacheConfiguration` | 内存缓冲设置，见[缓存](#缓存) |

`player.playbackView` 的显示模式跟随 `player.contentMode`，等比缩放（aspect-fit）与等比填充（aspect-fill）分别映射到 mpv 的 fit 与 fill。

设置 `MPVPlayer.delegate` 接收回调；所有方法都有默认空实现：

```swift
public protocol MPVPlayerDelegate: AnyObject {
    func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState)
    func player(_ player: MPVPlayer, didUpdateCurrentTime currentTime: TimeInterval, duration: TimeInterval)
    func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int)
    func player(_ player: MPVPlayer, didUpdateBufferedProgress progress: Int?)
    func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode)
    func player(_ player: MPVPlayer, didChangePictureInPictureActive isActive: Bool)
}
```

`MPVPlaybackState` 会报告 `buffering`、`readyToPlay`、`bufferFinished`、`paused`、`playedToTheEnd` 和 `error`。当媒体时长与 mpv 缓存位置同时可用时，`MPVPlayer.bufferedProgress` 和 `didUpdateBufferedProgress` 报告 0...100 的百分比；否则为 `nil`。

## 播放引擎

### 解码

硬解先尝试 `videotoolbox`，失败后降级到 `videotoolbox-copy`，首次播放仍失败再降级为软解。模拟器始终使用软解。在配置中设置 `forceSoftwareDecode: true` 可跳过硬解路径。当前解码模式通过 `didUpdateDecoderMode` 上报（`initializing`、`hardware`、`software`）。

### 画质

`MPVVideoQuality` 提供三档渲染预设：

- `.powerSaving` — 全部使用 bilinear 缩放器，关闭抖动与 sigmoid 放大。
- `.balanced`（默认）— lanczos 放大、mitchell 缩小。
- `.highQuality` — `ewa_lanczossharp` 放大并开启 sigmoid 放大、正确的缩小算法与抖动，细节保留最佳。

去色带通过 `updateVideoRenderOptions(debandEnabled:)` 开关，在 `.powerSaving` 档位下强制关闭。

### HDR 与 Dolby Vision

Metal 层根据目标屏幕的 EDR headroom，在 SDR 输出（`bgra8Unorm_srgb`，sRGB 色彩空间）与 EDR 输出（`rgba16Float`，extended linear sRGB）之间自动切换。色调映射完全交给 mpv，HDR 与 Dolby Vision 内容既不会被裁切也不会被二次映射。模拟器与 iOS 15 设备保持 SDR。

### Seek 与进度

`seek(to:autoPlay:)` 执行 mpv 的绝对精确 seek。目标位置会乐观发布——连续 seek 与遥控快进快退保持同步——mpv 拒绝命令时回滚。暂停状态下 seek 会刷新当前画面。时间与时长每秒轮询两次，经 `didUpdateCurrentTime` 回调。

### 缓冲

状态切换由一个纯函数状态机（`MPVBufferingStateMachine`）驱动，它观察 mpv 的 `paused-for-cache`、cache-buffering-state、idle 与播放结束属性，并为从不报告缓冲状态的流提供兜底计时器。

### 缓存

`MPVCacheConfiguration(isEnabled:duration:)` 配置 mpv 的 demuxer 内存缓冲，支持 10、30、60、120 秒时长（默认 30 秒）。

## 画中画

通过 `startPictureInPicture()`、`stopPictureInPicture()` 和 `togglePictureInPicture()` 使用画中画。内置快捷播放器只在点击画中画按钮后才进入画中画窗口，并会先激活播放音频会话。希望支持后台自动进入画中画的宿主可以设置 `allowsAutomaticPictureInPictureFromInline`；这需要声明 Audio、AirPlay 与画中画后台模式。

画中画使用视频通话内容源（video-call content source）：内嵌的 `MPVPlayerView` 本体会被移入系统窗口，退出时移回原位，mpv 继续通过自己的 Metal 管线渲染——字幕、色调映射、fit/fill 模式与完整帧率都原样保留，不涉及任何帧截图。

- 窗口形状跟随视频：内容尺寸按 MPV 上报的显示宽高比解析，变形视频不会被拉伸，内嵌容器的形状也不会泄漏到窗口里。
- 退出时播放器视图恢复到原来的内嵌层级，播放无缝继续。
- `isPictureInPictureSupported` 报告系统是否提供画中画（协调器是否已创建）；`isPictureInPictureActive` 反映当前状态，同样通过 `didChangePictureInPictureActive` 回调。

播放位置、倍速与快进快退处理会发布到锁屏与控制中心的 Now Playing 控件，详见[系统媒体控制](#系统媒体控制)。

## 系统媒体控制

内置协调器发布 `MPNowPlayingInfoCenter`——标题取自 URL 的最后一段路径，同时包含已播时间、倍速与时长（时长未知时标记为直播）——并在 `MPRemoteCommandCenter` 上注册播放、暂停、切换播放状态、快进快退（15 秒间隔）与 `changePlaybackPosition` 处理器。

自行管理 Remote Command Center 的宿主可以通过 `playerView.systemPlaybackControlsEnabled = false` 关闭。

## 客户端渲染字幕

未启用原始样式的 SRT 与 WebVTT 文件走框架字幕管线。`MPVSubtitleDocument` 处理 UTF-8、UTF-16 与 GB18030 文本，归一化内嵌 ASS 覆盖标签，并提供按时间查询 cue 的能力。内置的 `MPVDefaultSubtitleRenderer` 会自动安装：

```swift
player.loadClientSubtitle(from: subtitleURL) { success in
    print("Subtitle loaded:", success)
}
```

解析与时间轴留在框架内，应用可以提供自己的渲染器：

```swift
@MainActor
final class AppSubtitleRenderer: MPVSubtitleRenderer {
    let view = UIView()

    func render(_ presentation: MPVSubtitlePresentation) {
        // 用应用自己的 UI 渲染 presentation.cues。
    }

    func clear() {
        // 移除当前字幕。
    }
}

player.useClientSubtitleRenderer(AppSubtitleRenderer())
```

## 字幕字体

MPVPlayerKit 内置 Noto 作为默认字幕字体。应用可以为当前播放器实例注册本地字体文件；字体不会被打进包里：

```swift
try player.setSubtitleFont(from: fontFileURL)

switch player.currentSubtitleFontCapability {
case .noSubtitle:
    break
case .unsupported:
    // SUP/PGS/VobSub 等图像字幕无法使用字体。
    break
case .supported:
    break
}

player.resetSubtitleFont()
```

当 URL 不是本地字体文件或注册失败时，`setSubtitleFont(from:)` 抛出 `MPVSubtitleFontError`。同样的 API 与能力属性也可通过 `MPVQuickPlayerViewController` 使用；自定义字幕渲染器可以从 presentation 中读取 `MPVSubtitleStyle.fontName`。

`MPVQuickPlayerViewController` 通过公开的 `player` 使用同一条管线，因此其外挂 SRT/VTT 选择器无需应用侧字幕图层即可工作。

## 快捷播放器界面

不需要自定义控制层的应用可以直接使用：

```swift
let playerViewController = MPVQuickPlayerViewController(
    url: videoURL,
    forceLandscape: true
)
present(playerViewController, animated: true)
```

视图出现后自动开始播放，除非把 `autoplay` 设为 `false`。快捷界面提供播放/暂停、seek、时间显示、进出画中画窗口的画中画按钮、视频/音频/字幕轨道选择、外挂字幕加载与取消、字幕延迟与样式预设、倍速、画质、去色带、内存缓冲设置、fit/fill 显示模式、解码与缓冲状态、强制横屏控制，以及居中加载指示器。紧凑控制栏使用系统图标并带无障碍标签。宿主 App 仅声明竖屏时强制横屏同样可用：系统级场景旋转不可用时，快捷播放器自行旋转其内容。

播放器可见时也可以切换横屏锁定：

```swift
playerViewController.setForceLandscape(true)
```

iOS 16 及以上通过场景几何更新完成旋转；iOS 15 直接强制方向。宿主 App 只声明竖屏时，快捷播放器会自行旋转内容——presented 视图控制器同步旋转（弹窗除外）——强制横屏依然可用。

### 手势

单击切换顶栏与底栏控制层的显隐。内置三个全屏滑动手势：

- **横向拖动** — 刮擦进度。满屏宽度的拖动覆盖媒体时长的 10%（钳制在 60–600 秒）；松手时才真正执行 seek，HUD 显示方向、目标时间与进度条。
- **左半屏纵向拖动** — 屏幕亮度，HUD 显示百分比。
- **右半屏纵向拖动** — 系统音量，通过隐藏的 `MPVolumeView` 调节。

宿主 App 自己持有某项交互时，可以单独关闭对应手势：

```swift
playerViewController.gestureOptions = [.seeking, .volume]
```

`MPVQuickPlayerGestureOptions` 是一个 `OptionSet`，包含 `.seeking`、`.brightness`、`.volume` 与 `.all`（默认）。空集时只保留单击。

### 编程式设置

也可以通过 `setPlaybackRate`（钳制在 0.25...4.0）、`setVideoQuality`、`setDebandEnabled`、`setCacheConfiguration`、`setSubtitleDelay`（钳制在 ±60 秒）与 `setSubtitleStyle` 以编程方式修改设置。`MPVCacheConfiguration` 支持 10、30、60、120 秒内存缓冲时长。快捷播放器的缓存设置会持久化为 App 本地全局偏好，并被后续的快捷播放器实例复用。底层的 `player` 保持公开，可直接调用 `MPVPlayer` 的全部操作。

该界面是可选的；`MPVPlayer` 在运行时不依赖它。

## Objective-C 桥接

`MPVPlayerView` 通过 `@objc` 成员把完整能力面暴露给 Objective-C，供在其上构建自有播放引擎的宿主使用——包括通过 Objective-C 运行时加载类、用 `NSDictionary` 传参驱动的宿主：

- 配置与播放：`configure(_:)`（URL、headers、userAgent、解码、画质、deband 与缓存选项）、`play()`、`pause()`、`stop()`、`seek(_:)`、`updatePlayRate(_:)`
- 轨道与字幕：`mediaTracks(_:)`、`selectTrack(_:)`、`loadSubtitle(_:)`、`cancelSubtitleLoad(_:)`、`setSubtitleVisible(_:)`、`updateSubtitleStyle(_:)`、`updateSubtitleDelay(_:)`、`setSubtitleFontFromURL(_:)`、`resetSubtitleFontFromBridge()`、`currentSubtitleText()`
- 渲染与布局：`playerContentModeRawValue`、`prepareLayoutTransition(_:)`、`refreshLayout(_:)`、`beginDisplayGeometryTransition()`、`endDisplayGeometryTransition()`
- 画中画：`isPictureInPictureSupported`、`isPictureInPictureActive`、`startPictureInPicture()`、`stopPictureInPicture()`、`togglePictureInPicture()`、`allowsAutomaticPictureInPictureFromInline`
- 系统媒体控制：`systemPlaybackControlsEnabled`

状态变化同时以 `NSNotification` 广播：`MPVPlayerViewDidChangeState`、`MPVPlayerViewDidUpdateTime`、`MPVPlayerViewDidUpdateBufferingProgress`、`MPVPlayerViewDidUpdateBufferedProgress`、`MPVPlayerViewDidUpdateDecoderMode`、`MPVPlayerViewDidLoadSubtitle`、`MPVPlayerViewDidCompleteSeek` 与 `MPVPlayerViewDidChangePictureInPicture`。

## Demo

打开 `Demo/MPVPlayerKitDemo.xcodeproj` 并运行 `MPVPlayerKitDemo` scheme。Demo 以本地 Swift Package 方式引用本仓库，并用公开的 HLS 样例启动快捷播放器。要测试带自定义音轨或字幕轨道的媒体，替换 `Demo/MPVPlayerKitDemo/AppDelegate.swift` 中的 `sampleURL`。

## 说明

- MPVKit 锁定在 `1.0.0` 版本，以保证原生运行时及其传递的二进制依赖可复现。
- 包以动态库形式分发，使 MPVKit 的原生运行时与 App 的其他媒体依赖保持隔离。
- 内置 Noto 字体用于一致的多语言字幕渲染，其原始许可文件位于 `Resources` 下。
- 暂未包含：循环播放、长按倍速手势、双击手势、锁定屏幕手势、截图/录制 API，以及播放器级音量 API——快捷播放器的音量手势调节的是系统音量。

## 许可

本包源码基于 MIT 许可发布。MPVKit 是 LGPL-3.0 依赖，其原生库有各自的分发要求；发布前请自行审阅相关条款。内置字体保留其各自的 OFL 许可。
