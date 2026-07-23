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
    public let view = UIView()
    private let label = UILabel()
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
        let widthScale = max(hostBounds.width, 320) / 1080
        let fontSize = max(8, CGFloat(style.fontSize) * widthScale)
        let font = style.bold
            ? UIFont.boldSystemFont(ofSize: fontSize)
            : UIFont.systemFont(ofSize: fontSize)
        let outlineSize = max(0, CGFloat(style.outlineSize) * widthScale)
        let strokeWidth = outlineSize > 0 ? -(outlineSize / fontSize * 100) : 0
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(mpvHex: style.textColor, fallback: .white),
            .strokeColor: UIColor(mpvHex: style.outlineColor, fallback: .black),
            .strokeWidth: strokeWidth,
            .backgroundColor: UIColor(mpvHex: style.backgroundColor, fallback: .clear),
            .paragraphStyle: paragraph,
        ])
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = style.shadowOffset > 0 ? 0.85 : 0
        label.layer.shadowRadius = CGFloat(style.shadowOffset)
        label.layer.shadowOffset = CGSize(width: 0, height: CGFloat(style.shadowOffset))
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
