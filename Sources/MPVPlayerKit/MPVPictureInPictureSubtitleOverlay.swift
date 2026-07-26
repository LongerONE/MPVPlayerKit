import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Subtitle appearance used when drawing into Picture in Picture frames.
///
/// The values mirror the MPV subtitle properties applied to the inline player,
/// so Picture in Picture keeps the size, colors and bottom margin of the
/// subtitles rendered inside ``MPVPlayerView``.
struct MPVPictureInPictureSubtitleStyle: Equatable, Sendable {
    /// MPV expresses subtitle sizes in pixels scaled to a 720 pixel high frame.
    static let referenceHeight: Double = 720

    var fontSize: Double = 38
    var bold = false
    var textColor = "#FFFFFFFF"
    var outlineSize: Double = 0
    var outlineColor = "#FF000000"
    var shadowOffset: Double = 0
    var backgroundColor = "#00000000"
    var marginY: Double = 34

    init() {}

    init(propertyValues: [String: String]) {
        fontSize = Self.double(propertyValues[MPVProperty.subtitleFontSize], fallback: 38)
        bold = propertyValues[MPVProperty.subtitleBold] == "yes"
        textColor = propertyValues[MPVProperty.subtitleColor] ?? "#FFFFFFFF"
        outlineSize = Self.double(propertyValues[MPVProperty.subtitleOutlineSize], fallback: 0)
        outlineColor = propertyValues[MPVProperty.subtitleOutlineColor] ?? "#FF000000"
        shadowOffset = Self.double(propertyValues[MPVProperty.subtitleShadowOffset], fallback: 0)
        backgroundColor = propertyValues[MPVProperty.subtitleBackColor] ?? "#00000000"
        marginY = Self.double(propertyValues[MPVProperty.subtitleMarginY], fallback: 34)
    }

    private static func double(_ value: String?, fallback: Double) -> Double {
        guard let value, let parsed = Double(value), parsed.isFinite else { return fallback }
        return parsed
    }
}

/// Pixel geometry of a subtitle line for one frame size.
struct MPVPictureInPictureSubtitleLayout: Equatable, Sendable {
    let pointSize: Double
    let outlineWidth: Double
    let shadowOffset: Double
    let bottomMargin: Double
    let maximumWidth: Double
    let maximumHeight: Double

    init(style: MPVPictureInPictureSubtitleStyle, frameWidth: Int, frameHeight: Int) {
        let height = Double(max(frameHeight, 1))
        let width = Double(max(frameWidth, 1))
        let scale = max(0.1, height / MPVPictureInPictureSubtitleStyle.referenceHeight)
        pointSize = min(max(style.fontSize * scale, 8), height * 0.25)
        outlineWidth = max(0, style.outlineSize * scale)
        shadowOffset = max(0, style.shadowOffset * scale)
        bottomMargin = min(max(style.marginY * scale, 0), height * 0.4)
        maximumWidth = max(16, width * 0.92)
        maximumHeight = max(pointSize, height * 0.5)
    }
}

/// Draws the current subtitle line into a captured Picture in Picture frame.
///
/// `screenshot-raw video` deliberately excludes subtitles: the modes that keep
/// them require a video output render pass, which is not available while the
/// Metal layer is not presenting. The text is drawn here instead so the
/// Picture in Picture window shows the same subtitles as the inline player.
///
/// Used serially from the frame processing queue.
final class MPVPictureInPictureSubtitleOverlay {
    private struct RasterKey: Equatable {
        let text: String
        let style: MPVPictureInPictureSubtitleStyle
        let layout: MPVPictureInPictureSubtitleLayout
    }

    private var rasterKey: RasterKey?
    private var raster: CGImage?
    private var fontCache: [Bool: CTFont] = [:]

    func draw(
        text: String,
        style: MPVPictureInPictureSubtitleStyle,
        in pixelBuffer: CVPixelBuffer
    ) {
        let line = Self.normalizedText(text)
        guard line.isEmpty == false else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }
        let layout = MPVPictureInPictureSubtitleLayout(
            style: style,
            frameWidth: width,
            frameHeight: height
        )
        guard let image = rasterImage(text: line, style: style, layout: layout),
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                      | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return }

        let destination = CGRect(
            x: ((Double(width) - Double(image.width)) / 2).rounded(),
            y: layout.bottomMargin.rounded(),
            width: Double(image.width),
            height: Double(image.height)
        )
        context.draw(image, in: destination)
    }

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rasterImage(
        text: String,
        style: MPVPictureInPictureSubtitleStyle,
        layout: MPVPictureInPictureSubtitleLayout
    ) -> CGImage? {
        let key = RasterKey(text: text, style: style, layout: layout)
        if key == rasterKey, let raster { return raster }
        let image = makeRasterImage(text: text, style: style, layout: layout)
        rasterKey = image == nil ? nil : key
        raster = image
        return image
    }

    private func makeRasterImage(
        text: String,
        style: MPVPictureInPictureSubtitleStyle,
        layout: MPVPictureInPictureSubtitleLayout
    ) -> CGImage? {
        let attributedText = NSAttributedString(
            string: text,
            attributes: attributes(style: style, layout: layout)
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let padding = (layout.outlineWidth + layout.shadowOffset + 2).rounded(.up)
        let textWidth = max(1, layout.maximumWidth - 2 * padding)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: textWidth, height: layout.maximumHeight),
            nil
        )
        let rasterWidth = Int(layout.maximumWidth.rounded(.up))
        let rasterHeight = Int((suggestedSize.height + 2 * padding).rounded(.up))
        guard rasterWidth > 0, rasterHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: rasterWidth,
                  height: rasterHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return nil }

        let textRect = CGRect(
            x: padding,
            y: padding,
            width: textWidth,
            height: max(1, suggestedSize.height)
        )
        if let background = Self.color(style.backgroundColor), background.alpha > 0.001 {
            context.setFillColor(background)
            context.fill(textRect.insetBy(dx: -padding / 2, dy: -padding / 2))
        }
        if layout.shadowOffset > 0 {
            context.setShadow(
                offset: CGSize(width: 0, height: -layout.shadowOffset),
                blur: layout.shadowOffset,
                color: CGColor(gray: 0, alpha: 0.85)
            )
        }
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(),
            CGPath(rect: textRect, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    private func attributes(
        style: MPVPictureInPictureSubtitleStyle,
        layout: MPVPictureInPictureSubtitleLayout
    ) -> [NSAttributedString.Key: Any] {
        var alignment = CTTextAlignment.center
        let paragraphStyle = withUnsafePointer(to: &alignment) { alignmentPointer in
            let settings = [
                CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: UnsafeRawPointer(alignmentPointer)
                ),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                font(pointSize: layout.pointSize, bold: style.bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                Self.color(style.textColor) ?? CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
        // Outline only when the player style asks for one. A minimum outline
        // would make Picture in Picture text look bolder than the inline player.
        guard layout.outlineWidth > 0 else { return attributes }
        attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
            Self.color(style.outlineColor) ?? CGColor(gray: 0, alpha: 1)
        attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
            -(layout.outlineWidth / max(layout.pointSize, 1) * 100)
        return attributes
    }

    private func font(pointSize: Double, bold: Bool) -> CTFont {
        if let cached = fontCache[bold], abs(CTFontGetSize(cached) - pointSize) < 0.01 {
            return cached
        }
        let font = Self.makeFont(pointSize: pointSize, bold: bold)
        fontCache[bold] = font
        return font
    }

    private static func makeFont(pointSize: Double, bold: Bool) -> CTFont {
        if let descriptor = bundledFontDescriptor(bold: bold) {
            return CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
        }
        return CTFontCreateWithName(
            (bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString,
            pointSize,
            nil
        )
    }

    /// The inline player renders subtitles with the bundled Noto fonts. Reuse
    /// them so Picture in Picture keeps the same glyphs and metrics.
    private static func bundledFontDescriptor(bold: Bool) -> CTFontDescriptor? {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle(for: MPVPlayerView.self)
        #endif
        let resources = bold
            ? [("NotoSansCJK-Bold", "ttc"), ("NotoSansSC-Regular", "otf")]
            : [("NotoSansSC-Regular", "otf"), ("NotoSansCJK-Regular", "ttc")]
        for (name, fileExtension) in resources {
            guard let url = resourceBundle.url(forResource: name, withExtension: fileExtension),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                      as? [CTFontDescriptor],
                  let descriptor = descriptors.first
            else { continue }
            return descriptor
        }
        return nil
    }

    /// MPV colors use the `#AARRGGBB` form, with `#RRGGBB` treated as opaque.
    static func color(_ value: String) -> CGColor? {
        let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6 || clean.count == 8, let raw = UInt64(clean, radix: 16) else {
            return nil
        }
        let alpha = clean.count == 8 ? CGFloat((raw >> 24) & 0xFF) / 255 : 1
        return CGColor(
            srgbRed: CGFloat((raw >> 16) & 0xFF) / 255,
            green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255,
            alpha: alpha
        )
    }
}
