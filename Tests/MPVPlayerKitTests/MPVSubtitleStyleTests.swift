import XCTest
import UIKit
import AVFoundation
import CoreText
@testable import MPVPlayerKit

final class MPVSubtitleStyleTests: XCTestCase {
    @MainActor
    func testLiveEpisodeCustomFontOutline() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let configuration = directory.appendingPathComponent("subtitle-live.json")
        guard FileManager.default.fileExists(atPath: configuration.path) else {
            throw XCTSkip("真实片源验证需在宿主 Documents 提供私有播放配置")
        }
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configuration))
        let url = try XCTUnwrap(values["url"])
        CTFontManagerRegisterFontsForURL(directory.appendingPathComponent("validation-font.ttf") as CFURL, .process, nil)
        XCTAssertNotNil(UIFont(name: "LXGWWenKai-Regular", size: 64))
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let player = MPVPlayerView(frame: controller.view.bounds)
        player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(player)
        player.configure(["url": url, "forceSoftwareDecode": true, "diagnosticsEnabled": false])
        player.play()
        defer { player.stop(); window.isHidden = true }
        for _ in 0..<200 where player.currentTime < 0.1 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThan(player.currentTime, 0)
        let subtitle = try XCTUnwrap(player.mediaTracks(["mediaType": "sub"]).compactMap { $0 as? [String: Any] }.first {
            ($0["name"] as? String)?.contains("Simplified") == true
        })
        player.selectTrack(["trackID": try XCTUnwrap(subtitle["trackID"]), "mediaType": "sub",
            "usesNativeSubtitleRendering": true, "usesOriginalStyle": false])
        _ = player.seek(["time": 120, "autoPlay": true])
        for _ in 0..<150 where player.currentTime < 119 { try await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<150 where player.decodedSubtitleText?.isEmpty != false { try await Task.sleep(for: .milliseconds(100)) }
        player.pause()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(player.decodedSubtitleText?.isEmpty ?? true)
        for bold in [false, true] {
            player.updateSubtitleStyle(["fontName": "LXGWWenKai-Regular", "fontSize": 64,
                "bold": bold, "outlineSize": 5, "outlineColor": "#FF000000", "textColor": "#FFFFFFFF", "bottomOffset": 250])
            controller.view.layoutIfNeeded()
            player.layoutIfNeeded()
            player.clientSubtitleRenderer.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let label = try XCTUnwrap(player.clientSubtitleRenderer.view.subviews.compactMap { $0 as? UILabel }.first)
            print("字幕验证 text=\(label.text ?? "nil") frame=\(label.frame) host=\(player.bounds) font=\(String(describing: label.attributedText?.attribute(.font, at: 0, effectiveRange: nil)))")
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: directory.appendingPathComponent("live-outline-\(bold ? "bold" : "regular").png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = "幸运女神-S1E1-\(bold ? "加粗" : "常规")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testRealMPVDecodedTextShadowWhilePaused() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let video = directory.appendingPathComponent("shadow-fixture.mp4")
        if !FileManager.default.fileExists(atPath: video.path) {
            try await makeShadowVideo(at: video)
        }
        let subtitle = directory.appendingPathComponent("shadow-fixture.srt")
        try "1\n00:00:00,000 --> 00:00:08,000\nClear subtitle · 阴影扩散\n\n2\n00:00:09,000 --> 00:00:12,000\nSecond cue".write(to: subtitle, atomically: true, encoding: .utf8)
        let view = MPVPlayerView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        view.configure(["url": video.absoluteString, "forceSoftwareDecode": true, "diagnosticsEnabled": false])
        view.play()
        defer { view.stop(); window.isHidden = true }
        for _ in 0..<100 where view.currentTime < 0.1 { try await Task.sleep(for: .milliseconds(100)) }
        view.loadSubtitle(["requestID": "real-shadow", "url": subtitle.absoluteString, "usesOriginalStyle": false])
        for _ in 0..<100 where view.decodedSubtitleText?.isEmpty != false { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(view.decodedSubtitleText, "Clear subtitle · 阴影扩散")
        view.pause()
        view.updateSubtitleStyle(["fontSize": 64, "shadowOffset": 4, "shadowRadius": 0, "shadowColor": "#FF000000"])
        let label = try XCTUnwrap(view.clientSubtitleRenderer.view.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(label.layer.shadowRadius, 0)
        let originalText = label.attributedText?.string
        window.layoutIfNeeded()
        view.layoutIfNeeded()
        view.clientSubtitleRenderer.view.layoutIfNeeded()
        XCTAssertFalse(label.isHidden)
        XCTAssertGreaterThan(label.bounds.width, 0)
        XCTAssertGreaterThan(label.bounds.height, 0)
        let sharp = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        try sharp.pngData()?.write(to: directory.appendingPathComponent("shadow-radius-0.png"))
        view.updateSubtitleStyle(["fontSize": 64, "shadowOffset": 4, "shadowRadius": 14, "shadowColor": "#FF000000"])
        XCTAssertEqual(label.layer.shadowRadius, 14)
        XCTAssertEqual(label.attributedText?.string, originalText)
        let soft = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        try soft.pngData()?.write(to: directory.appendingPathComponent("shadow-radius-14.png"))
        let transfer = MPVPlayerViewWeakTransfer(view)
        let nativeVisible: Bool? = await withCheckedContinuation { continuation in
            view.queue.async { continuation.resume(returning: transfer.value?.getFlag(MPVProperty.subtitleVisibility)) }
        }
        XCTAssertEqual(nativeVisible, false)
        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: view))
        let pipContainer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        controller.view.addSubview(pipContainer)
        XCTAssertTrue(placement.movePlayer(to: pipContainer))
        pipContainer.layoutIfNeeded()
        XCTAssertTrue(view.clientSubtitleRenderer.view.isDescendant(of: pipContainer))
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.attributedText?.string, originalText)
        XCTAssertTrue(placement.restorePlayer())
        view.setSubtitleVisible(["visible": false])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(label.isHidden)
        view.setSubtitleVisible(["visible": true])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(label.attributedText?.string, originalText)
        view.updateSubtitleDelay(NSNumber(value: 10))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(label.isHidden)
        view.updateSubtitleDelay(0)
        _ = view.seek(["time": 9.5, "autoPlay": false])
        for _ in 0..<50 where view.decodedSubtitleText != "Second cue" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(label.attributedText?.string, "Second cue")
        _ = view.seek(["time": 1, "autoPlay": false])
        for _ in 0..<50 where view.decodedSubtitleText != originalText { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(label.attributedText?.string, originalText)
        let ass = directory.appendingPathComponent("shadow-original.ass")
        try "[Script Info]\nScriptType: v4.00+\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:12.00,Default,,0,0,0,,Original ASS".write(to: ass, atomically: true, encoding: .utf8)
        view.loadSubtitle(["requestID": "original-ass", "url": ass.absoluteString, "usesOriginalStyle": true])
        for _ in 0..<50 where view.decodedSubtitleText != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(view.decodedSubtitleText)
        XCTAssertTrue(label.isHidden)
        view.loadSubtitle(["requestID": "back-to-srt", "url": subtitle.absoluteString, "usesOriginalStyle": false])
        for _ in 0..<50 where view.decodedSubtitleText != originalText { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(label.attributedText?.string, originalText)
    }

    @MainActor
    func testOutlinePreservesFillAndSyntheticBoldExpandsOriginalFont() throws {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)
        func pixels(outline: Double, bold: Bool) throws -> Int {
            renderer.render(MPVSubtitlePresentation(
                cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Outline 字形")],
                style: MPVSubtitleStyle(fontSize: 64, fontName: "Papyrus", bold: bold,
                    outlineSize: outline, outlineColor: "#FF000000")
            ))
            renderer.view.layoutIfNeeded()
            let label = try XCTUnwrap(renderer.view.subviews.compactMap { $0 as? UILabel }.first)
            let font = try XCTUnwrap(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            XCTAssertEqual(font.familyName, UIFont(name: "Papyrus", size: 64)?.familyName)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: renderer.view.bounds, format: format).image { context in
                renderer.view.layer.render(in: context.cgContext)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cgImage.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            var white = 0
            for y in 0..<cgImage.height {
                for x in 0..<cgImage.width {
                    let offset = y * cgImage.bytesPerRow + x * 4
                    if bytes[offset] > 220 && bytes[offset + 1] > 220 && bytes[offset + 2] > 220 { white += 1 }
                }
            }
            return white
        }
        let plain = try pixels(outline: 0, bold: false)
        let outlined = try pixels(outline: 5, bold: false)
        let bold = try pixels(outline: 5, bold: true)
        XCTAssertGreaterThan(plain, 100)
        XCTAssertGreaterThanOrEqual(outlined, Int(Double(plain) * 0.98))
        XCTAssertGreaterThan(bold, Int(Double(outlined) * 1.1))
    }

    @MainActor
    private func makeShadowVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB,
            nil, &optionalBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<24 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testBoldSubtitleUsesHeavierBundledFont() {
        XCTAssertEqual(MPVSubtitleFont.name(isBold: false), MPVSubtitleFont.regular)
        XCTAssertEqual(MPVSubtitleFont.name(isBold: true), MPVSubtitleFont.bold)
        XCTAssertEqual(MPVSubtitleFont.bold, "NotoSansCJKjp-Bold")
    }

    func testDecodedTextRoutingKeepsOriginalASSAndImagesNative() {
        for codec in ["subrip", "srt", "webvtt", "text", "mov_text"] {
            XCTAssertTrue(MPVPlayerView.supportsDecodedSubtitleText(codec: codec, usesOriginalStyle: false))
            XCTAssertFalse(MPVPlayerView.supportsDecodedSubtitleText(codec: codec, usesOriginalStyle: true))
        }
        for codec in ["ass", "ssa", "hdmv_pgs_subtitle", "dvd_subtitle", "unknown"] {
            XCTAssertFalse(MPVPlayerView.supportsDecodedSubtitleText(codec: codec, usesOriginalStyle: false))
        }
        XCTAssertFalse(MPVPlayerView.supportsDecodedSubtitleText(codec: nil, usesOriginalStyle: false))
    }

    func testImageSubtitleCodecRecognizesSUP() {
        XCTAssertTrue(MPVPlayerView.isImageSubtitleCodec("sup"))
        XCTAssertTrue(MPVPlayerView.isImageSubtitleCodec("hdmv_pgs_subtitle"))
        XCTAssertFalse(MPVPlayerView.isImageSubtitleCodec("subrip"))
    }

    func testShadowRadiusDefaultsClampsAndBridges() {
        XCTAssertEqual(MPVSubtitleStyle().shadowRadius, 0)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: -1).shadowRadius, 0)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: 21).shadowRadius, 20)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: .nan).shadowRadius, 0)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: .infinity).shadowRadius, 0)
        let style = MPVSubtitleStyle(shadowRadius: 8)
        XCTAssertEqual(style.bridgeDictionary["shadowRadius"] as? Double, 8)
        XCTAssertNotEqual(style, MPVSubtitleStyle())
    }

    @MainActor
    func testShadowSliderAppliesStrengthAndRestoresLegacyOffset() {
        let panel = MPVQuickPlayerSubtitleSettingsView(frame: .zero)
        guard let slider = panel.contentStack.arrangedSubviews
            .flatMap({ $0.subviews }).compactMap({ $0 as? UISlider }).first else {
            return XCTFail("Subtitle settings should contain a shadow slider")
        }
        panel.update(style: MPVSubtitleStyle(shadowRadius: 6), delay: 0)
        var changedStyle: MPVSubtitleStyle?
        panel.onStyleChange = { changedStyle = $0 }
        slider.value = 50
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 6)
        XCTAssertEqual(changedStyle?.shadowOffset, 2)
        XCTAssertEqual(changedStyle?.shadowColor, "#93000000")
        slider.value = 100
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 6)
        XCTAssertEqual(changedStyle?.shadowOffset, 4)
        XCTAssertEqual(changedStyle?.shadowColor, "#FF000000")
        slider.value = 0
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 6)
        XCTAssertEqual(changedStyle?.shadowOffset, 0)
        XCTAssertEqual(changedStyle?.shadowColor, "#00000000")
        panel.update(style: MPVSubtitleStyle(shadowRadius: 6), delay: 0)
        XCTAssertEqual(slider.value, 0)
        panel.update(style: MPVSubtitleStyle(shadowOffset: 1), delay: 0)
        XCTAssertEqual(slider.value, 25)
        let radius = panel.contentStack.arrangedSubviews.flatMap { $0.subviews }
            .compactMap { $0 as? UISlider }.first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleShadowRadius" }!
        radius.value = 7.3
        radius.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 7.5)
        XCTAssertEqual(changedStyle?.shadowOffset, 1)
        radius.value = 0
        radius.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowOffset, 1)
        XCTAssertEqual(changedStyle?.shadowRadius, 0)
        XCTAssertTrue(radius.isContinuous)
        panel.isShadowRadiusEditable = false
        XCTAssertFalse(radius.isEnabled)
    }

    @MainActor
    func testRendererAppliesShadowRadiusWithExistingOpacity() {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 2, shadowRadius: 4)
        ))
        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("Renderer should create a subtitle label")
        }
        XCTAssertEqual(label.layer.shadowRadius, 4)
        XCTAssertEqual(label.layer.shadowOpacity, 0.6)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 0, height: 2))
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 2, shadowRadius: 12.5)
        ))
        XCTAssertEqual(label.layer.shadowRadius, 12.5)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 0, height: 2))
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 2, shadowRadius: 0)
        ))
        XCTAssertEqual(label.layer.shadowRadius, 0)
        XCTAssertEqual(label.layer.shadowOpacity, 0.6)
    }

    func testSubtitleStyleCarriesCustomFontName() {
        let style = MPVSubtitleStyle(fontName: "Example-Regular")
        XCTAssertEqual(style.fontName, "Example-Regular")
        XCTAssertEqual(style.bridgeDictionary["fontName"] as? String, "Example-Regular")
    }

    func testSubtitleStyleResolvesShadowColorForCurrentAndLegacyDictionaries() {
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(
                from: ["shadowColor": "#FF112233", "backgroundColor": "#00000000"],
                shadowOffset: 2
            ),
            "#FF112233"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(
                from: ["backgroundColor": "#80010203"],
                shadowOffset: 2
            ),
            "#80010203"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(
                from: ["backgroundColor": "#00010203"],
                shadowOffset: 2
            ),
            "#FF000000"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(from: [:], shadowOffset: 0),
            "#FF000000"
        )
    }

    @MainActor
    func testNativeSubtitleStyleAlwaysResetsGlyphBlur() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = UnsafeTransfer(value: playerView)
        playerView.updateSubtitleStyle([
            "shadowOffset": 2,
            "shadowBlur": 8,
        ])

        let blurValue: String? = await withCheckedContinuation { continuation in
            playerView.queue.async {
                continuation.resume(
                    returning: transfer.value.subtitleStyleValues[MPVProperty.subtitleBlur]
                )
            }
        }
        XCTAssertEqual(blurValue, "0.000")
    }

    @MainActor
    func testDefaultSubtitleRendererSeparatesShadowAndBackgroundColors() {
        let renderer = MPVDefaultSubtitleRenderer()
        let style = MPVSubtitleStyle(
            shadowOffset: 2,
            backgroundColor: "#80010203",
            shadowColor: "#FF102030"
        )
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: style
        ))

        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first,
              let shadowCGColor = label.layer.shadowColor,
              let backgroundColor = label.attributedText?.attribute(
                  .backgroundColor,
                  at: 0,
                  effectiveRange: nil
              ) as? UIColor else {
            return XCTFail("Renderer should apply both subtitle colors")
        }
        assertColor(UIColor(cgColor: shadowCGColor), red: 0x10, green: 0x20, blue: 0x30, alpha: 0xFF)
        assertColor(backgroundColor, red: 0x01, green: 0x02, blue: 0x03, alpha: 0x80)
        XCTAssertEqual(label.layer.shadowOpacity, 0.6)
        XCTAssertEqual(label.layer.shadowRadius, 0)
    }

    @MainActor
    func testDefaultSubtitleRendererUsesOffsetWithoutBlurRadius() {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 10)
        ))

        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("Renderer should create a subtitle label")
        }
        XCTAssertEqual(label.layer.shadowRadius, 0)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 0, height: 10))
    }

    @MainActor
    func testDefaultSubtitleRendererClearsShadowLayerWhenDisabled() {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 0)
        ))

        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("Renderer should create a subtitle label")
        }
        XCTAssertEqual(label.layer.shadowOpacity, 0)
        XCTAssertEqual(label.layer.shadowRadius, 0)
        XCTAssertEqual(label.layer.shadowOffset, .zero)
    }

    private func assertColor(
        _ color: UIColor,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var actualAlpha: CGFloat = 0
        XCTAssertTrue(
            color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha),
            file: file,
            line: line
        )
        XCTAssertEqual(actualRed, CGFloat(red) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualGreen, CGFloat(green) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualBlue, CGFloat(blue) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualAlpha, CGFloat(alpha) / 255, accuracy: 0.001, file: file, line: line)
    }
}

private struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
}
