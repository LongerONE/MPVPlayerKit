/// MPV 队列上的一次性恢复记录；只恢复后台前实际成功使用的 VideoToolbox。
struct MPVBackgroundHardwareDecode {
    private var method: String?

    mutating func capture(current: String?, forceSoftware: Bool, pictureInPicture: Bool) {
        method = nil
        guard !forceSoftware, !pictureInPicture,
              current == "videotoolbox" || current == "videotoolbox-copy" else { return }
        method = current
    }

    mutating func take() -> String? {
        defer { method = nil }
        return method
    }
}
