// swiftc Sources/MPVPlayerKit/MPVBackgroundHardwareDecode.swift Tests/check_background_hardware_decode.swift -o /tmp/mpv-hwdec-check && /tmp/mpv-hwdec-check
@main
struct BackgroundHardwareDecodeCheck {
    static func main() {
        var recovery = MPVBackgroundHardwareDecode()
        assert(recovery.take() == nil)
        for method in ["videotoolbox", "videotoolbox-copy"] {
            recovery.capture(current: method, forceSoftware: false, pictureInPicture: false)
            assert(recovery.take() == method)
            assert(recovery.take() == nil) // 宿主 play 与 active 通知只能恢复一次。
        }
        for method: String? in [nil, "", "no"] {
            recovery.capture(current: method, forceSoftware: false, pictureInPicture: false)
            assert(recovery.take() == nil)
        }
        recovery.capture(current: "videotoolbox", forceSoftware: true, pictureInPicture: false)
        assert(recovery.take() == nil)
        recovery.capture(current: "videotoolbox", forceSoftware: false, pictureInPicture: true)
        assert(recovery.take() == nil)
        recovery.capture(current: "videotoolbox", forceSoftware: false, pictureInPicture: false)
        recovery = MPVBackgroundHardwareDecode() // 停止/换片不继承旧句柄的恢复记录。
        assert(recovery.take() == nil)
        recovery.capture(current: "videotoolbox", forceSoftware: false, pictureInPicture: false)
        recovery.capture(current: "no", forceSoftware: false, pictureInPicture: false)
        assert(recovery.take() == nil)
        print("后台硬解恢复检查通过")
    }
}
