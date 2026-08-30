import UIKit

@MainActor
final class MPVQuickPlayerCacheSettingsView: UIView {
    private let backdropButton = UIButton(type: .custom)
    private let cardView = UIView()
    private let effectView = UIVisualEffectView()
    private let titleLabel = UILabel()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let cacheSwitch = UISwitch()
    private let durationButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let safeAreaGuide = UILayoutGuide()
    private var safeAreaLeadingConstraint: NSLayoutConstraint!
    private var safeAreaTrailingConstraint: NSLayoutConstraint!
    private var safeAreaTopConstraint: NSLayoutConstraint!
    private var safeAreaBottomConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
    private var configuration: MPVCacheConfiguration

    private static let cardWidth: CGFloat = 320
    private static let cardHeight: CGFloat = 250

    var onChange: ((MPVCacheConfiguration) -> Void)?
    var onDurationTap: ((UIView) -> Void)?
    var onDismiss: (() -> Void)?

    init(configuration: MPVCacheConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        configureViews()
        configureLayout()
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        backdropButton.alpha = 0
        cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.backdropButton.alpha = 1
            self.cardView.transform = .identity
        }
    }

    func updatePlayerSafeAreaInsets(_ insets: UIEdgeInsets) {
        safeAreaLeadingConstraint.constant = insets.left
        safeAreaTrailingConstraint.constant = -insets.right
        safeAreaTopConstraint.constant = insets.top
        safeAreaBottomConstraint.constant = -insets.bottom
    }

    func update(configuration: MPVCacheConfiguration) {
        self.configuration = configuration
        cacheSwitch.isOn = configuration.isEnabled
        let isEnabled = configuration.isEnabled
        durationButton.isEnabled = isEnabled
        durationButton.alpha = isEnabled ? 1 : 0.45
        durationButton.setTitle(Self.durationTitle(for: configuration.duration), for: .normal)
        durationButton.accessibilityValue = Self.durationTitle(for: configuration.duration)
    }

    func dismiss(animated: Bool) {
        let finish = { [weak self] in
            guard let self else { return }
            removeFromSuperview()
            onDismiss?()
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            self.backdropButton.alpha = 0
            self.cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        } completion: { _ in finish() }
    }

    private func configureViews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        accessibilityViewIsModal = true
        accessibilityIdentifier = "MPVQuickPlayer.cacheSettings"

        backdropButton.translatesAutoresizingMaskIntoConstraints = false
        backdropButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        backdropButton.accessibilityLabel = mpvLocalized("common.cancel")
        backdropButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        addSubview(backdropButton)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .clear
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        addSubview(cardView)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.layer.cornerRadius = 18
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
        cardView.addSubview(effectView)
        if #available(iOS 26.0, *) {
            effectView.effect = UIGlassEffect(style: .regular)
        } else {
            effectView.effect = UIBlurEffect(style: .systemMaterial)
        }

        titleLabel.text = mpvLocalized("cache.title")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        effectView.contentView.addSubview(titleLabel)

        configureSwitch(cacheSwitch, title: "cache.enabled")
        durationButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        durationButton.titleLabel?.adjustsFontForContentSizeCategory = true
        durationButton.setTitleColor(.label, for: .normal)
        durationButton.tintColor = .label
        durationButton.accessibilityIdentifier = "MPVQuickPlayer.cacheDuration"
        durationButton.addTarget(self, action: #selector(durationTapped(_:)), for: .touchUpInside)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.alignment = .fill
        contentStack.addArrangedSubview(makeSwitchRow(title: mpvLocalized("cache.enabled"), switchView: cacheSwitch))
        contentStack.addArrangedSubview(makeDurationRow())

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        effectView.contentView.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        cancelButton.setTitle(mpvLocalized("common.cancel"), for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        effectView.contentView.addSubview(cancelButton)

        cacheSwitch.addTarget(self, action: #selector(cacheSwitchChanged(_:)), for: .valueChanged)
    }

    private func configureLayout() {
        addLayoutGuide(safeAreaGuide)
        let contentView = effectView.contentView
        cardHeightConstraint = cardView.heightAnchor.constraint(equalToConstant: Self.cardHeight)
        cardHeightConstraint.priority = .defaultHigh
        safeAreaLeadingConstraint = safeAreaGuide.leadingAnchor.constraint(equalTo: leadingAnchor)
        safeAreaTrailingConstraint = safeAreaGuide.trailingAnchor.constraint(equalTo: trailingAnchor)
        safeAreaTopConstraint = safeAreaGuide.topAnchor.constraint(equalTo: topAnchor)
        safeAreaBottomConstraint = safeAreaGuide.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            backdropButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropButton.topAnchor.constraint(equalTo: topAnchor),
            backdropButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.centerXAnchor.constraint(equalTo: safeAreaGuide.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: safeAreaGuide.centerYAnchor),
            cardView.widthAnchor.constraint(equalToConstant: Self.cardWidth),
            cardView.widthAnchor.constraint(lessThanOrEqualTo: safeAreaGuide.widthAnchor, constant: -32),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: safeAreaGuide.topAnchor, constant: 16),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaGuide.bottomAnchor, constant: -16),
            cardHeightConstraint,
            effectView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: cardView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            safeAreaLeadingConstraint,
            safeAreaTrailingConstraint,
            safeAreaTopConstraint,
            safeAreaBottomConstraint,
        ])
    }

    private func configureSwitch(_ switchView: UISwitch, title: String) {
        switchView.onTintColor = .systemBlue
        switchView.accessibilityLabel = mpvLocalized(title)
    }

    private func makeSwitchRow(title: String, switchView: UISwitch) -> UIView {
        let row = UIView()
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        row.addSubview(label)
        row.addSubview(switchView)
        label.translatesAutoresizingMaskIntoConstraints = false
        switchView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            switchView.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            switchView.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            switchView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func makeDurationRow() -> UIView {
        let row = UIView()
        let label = UILabel()
        label.text = mpvLocalized("cache.duration")
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        row.addSubview(label)
        row.addSubview(durationButton)
        label.translatesAutoresizingMaskIntoConstraints = false
        durationButton.translatesAutoresizingMaskIntoConstraints = false
        durationButton.contentHorizontalAlignment = .right
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            durationButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            durationButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            durationButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    static func durationTitle(for duration: TimeInterval) -> String {
        switch duration {
        case 10: return mpvLocalized("cache.duration.10")
        case 30: return mpvLocalized("cache.duration.30")
        case 60: return mpvLocalized("cache.duration.60")
        case 120: return mpvLocalized("cache.duration.120")
        default: return mpvLocalized("cache.duration.30")
        }
    }

    @objc private func cacheSwitchChanged(_ sender: UISwitch) {
        var updated = configuration
        updated.isEnabled = sender.isOn
        onChange?(updated)
    }

    @objc private func durationTapped(_ sender: UIButton) {
        onDurationTap?(sender)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }
}
