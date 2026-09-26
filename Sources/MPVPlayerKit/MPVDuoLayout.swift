import CoreGraphics

enum MPVDuoLayout {
    struct Regions: Equatable {
        let media: CGRect
        let controls: CGRect
    }

    /// 没有实际分割区就不改变布局，包括普通 iPhone 的 regular 横屏。
    static func regions(in bounds: CGRect, divisions: [CGRect]) -> Regions? {
        for division in divisions {
            let cut = bounds.intersection(division)
            guard !cut.isNull, cut.width > 0, cut.height > 0 else { continue }
            let media: CGRect
            let controls: CGRect
            if cut.width > cut.height {
                media = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: cut.minY - bounds.minY)
                controls = CGRect(x: bounds.minX, y: cut.maxY, width: bounds.width, height: bounds.maxY - cut.maxY)
            } else {
                media = CGRect(x: bounds.minX, y: bounds.minY, width: cut.minX - bounds.minX, height: bounds.height)
                controls = CGRect(x: cut.maxX, y: bounds.minY, width: bounds.maxX - cut.maxX, height: bounds.height)
            }
            guard media.width > 0, media.height > 0, controls.width > 0, controls.height > 0 else { continue }
            return Regions(media: media, controls: controls)
        }
        return nil
    }
}
