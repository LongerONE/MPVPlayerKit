import UIKit

public struct MPVSubtitlePresentation: Equatable, Sendable {
    public let cues: [MPVSubtitleCue]
    public let style: MPVSubtitleStyle

    public init(cues: [MPVSubtitleCue], style: MPVSubtitleStyle) {
        self.cues = cues
        self.style = style
    }
}

@MainActor
public protocol MPVSubtitleRenderer: AnyObject {
    var view: UIView { get }
    func render(_ presentation: MPVSubtitlePresentation)
    func clear()
}

@MainActor
public final class MPVDefaultSubtitleRenderer: MPVSubtitleRenderer {
    private static let shadowOpacity: Float = 0.6

    public let view = UIView()
    private let label = MPVSubtitleLabel()
    private var bottomConstraint: NSLayoutConstraint!

    public init() {
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        label.numberOfLines = 0
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        bottomConstraint = label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -34)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomConstraint,
        ])
    }

    public func render(_ presentation: MPVSubtitlePresentation) {
        guard presentation.cues.isEmpty == false else {
            clear()
            return
        }
        let style = presentation.style
        let text = presentation.cues.map(\.text).joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let hostBounds = view.superview?.bounds ?? view.bounds
        let widthScale = max(hostBounds.height, 180) / 720
        let fontSize = max(8, CGFloat(style.fontSize) * widthScale)
        let font = subtitleFont(named: style.fontName, size: fontSize, bold: style.bold)
        let outlineSize = max(0, CGFloat(style.outlineSize) * widthScale)
        let fillColor = UIColor(mpvHex: style.textColor, fallback: .white)
        let syntheticBold = style.bold && !font.fontDescriptor.symbolicTraits.contains(.traitBold)
        label.outlineWidth = outlineSize
        label.outlineColor = UIColor(mpvHex: style.outlineColor, fallback: .black)
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: fillColor,
            .strokeColor: fillColor,
            .strokeWidth: syntheticBold ? -3 : 0,
            .backgroundColor: UIColor(mpvHex: style.backgroundColor, fallback: .clear),
            .paragraphStyle: paragraph,
        ])
        label.layer.shadowColor = UIColor(mpvHex: style.shadowColor, fallback: .black).cgColor
        let showsShadow = style.shadowOffset > 0 || style.shadowRadius > 0
        label.layer.shadowOpacity = showsShadow ? Self.shadowOpacity : 0
        label.layer.shadowRadius = CGFloat(style.shadowRadius)
        label.layer.shadowOffset = showsShadow
            ? CGSize(width: 0, height: CGFloat(style.shadowOffset))
            : .zero
        let heightScale = max(hostBounds.height, 180) / 720
        updateBottomOffset(Double(CGFloat(style.bottomOffset) * heightScale))
        label.isHidden = false
    }

    public func clear() {
        label.attributedText = nil
        label.isHidden = true
    }

    private func updateBottomOffset(_ offset: Double) {
        bottomConstraint.constant = -CGFloat(offset)
    }

    private func subtitleFont(named name: String?, size: CGFloat, bold: Bool) -> UIFont {
        guard let name, let baseFont = UIFont(name: name, size: size) else {
            return bold
                ? UIFont.systemFont(ofSize: size, weight: .heavy)
                : UIFont.systemFont(ofSize: size)
        }
        guard bold,
              let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

@MainActor
private final class MPVSubtitleLabel: UILabel {
    var outlineWidth: CGFloat = 0
    var outlineColor: UIColor = .black

    override func drawText(in rect: CGRect) {
        guard let original = attributedText, outlineWidth > 0 else {
            super.drawText(in: rect)
            return
        }
        let outline = NSMutableAttributedString(attributedString: original)
        let fullRange = NSRange(location: 0, length: outline.length)
        original.enumerateAttributes(in: fullRange) { attributes, range, _ in
            guard let font = attributes[.font] as? UIFont else { return }
            let boldWidth = abs((attributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0)
            outline.addAttributes([
                .strokeColor: outlineColor,
                .strokeWidth: outlineWidth * 200 / font.pointSize + boldWidth,
                .foregroundColor: outlineColor,
            ], range: range)
        }
        // CoreText 的复合 fill/stroke 会让描边覆盖细笔画；先画轮廓，再覆盖完整填充。
        attributedText = outline
        super.drawText(in: rect)
        attributedText = original
        super.drawText(in: rect)
    }
}

@MainActor
final class MPVSubtitlePresentationController {
    private weak var hostView: UIView?
    private(set) var renderer: any MPVSubtitleRenderer
    private var document: MPVSubtitleDocument?
    private var lastPresentation: MPVSubtitlePresentation?
    var isVisible = true
    var delay: TimeInterval = 0
    var style = MPVSubtitleStyle.defaultStyle
    var hasSelection: Bool { document != nil }

    init(renderer: any MPVSubtitleRenderer = MPVDefaultSubtitleRenderer()) {
        self.renderer = renderer
    }

    func install(in hostView: UIView) {
        self.hostView = hostView
        installRendererView()
    }

    func useRenderer(_ renderer: any MPVSubtitleRenderer) {
        self.renderer.view.removeFromSuperview()
        self.renderer = renderer
        installRendererView()
        lastPresentation = nil
        update(at: 0, force: true)
    }

    func select(_ document: MPVSubtitleDocument?) {
        self.document = document
        lastPresentation = nil
        if document == nil { renderer.clear() }
    }

    func update(at currentTime: TimeInterval, force: Bool = false) {
        let cues = isVisible
            ? document?.cues(at: currentTime - delay) ?? []
            : []
        let presentation = MPVSubtitlePresentation(cues: cues, style: style)
        guard force || presentation != lastPresentation else { return }
        lastPresentation = presentation
        renderer.render(presentation)
    }

    func clear() {
        document = nil
        lastPresentation = nil
        renderer.clear()
    }

    private func installRendererView() {
        guard let hostView else { return }
        let rendererView = renderer.view
        rendererView.removeFromSuperview()
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(rendererView)
        NSLayoutConstraint.activate([
            rendererView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            rendererView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            rendererView.topAnchor.constraint(equalTo: hostView.topAnchor),
            rendererView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
    }
}

private extension UIColor {
    convenience init(mpvHex value: String, fallback: UIColor) {
        let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6 || clean.count == 8,
              let raw = UInt64(clean, radix: 16) else {
            self.init(cgColor: fallback.cgColor)
            return
        }
        let hasAlpha = clean.count == 8
        let alpha = hasAlpha ? CGFloat((raw >> 24) & 0xFF) / 255 : 1
        let red = CGFloat((raw >> 16) & 0xFF) / 255
        let green = CGFloat((raw >> 8) & 0xFF) / 255
        let blue = CGFloat(raw & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
