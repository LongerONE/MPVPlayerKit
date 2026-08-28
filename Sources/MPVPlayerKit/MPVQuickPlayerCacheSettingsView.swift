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
    private let diskSwitch = UISwitch()
    private let durationStack = UIStackView()
    private let directoryLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let safeAreaGuide = UILayoutGuide()
    private var safeAreaLeadingConstraint: NSLayoutConstraint!
    private var safeAreaTrailingConstraint: NSLayoutConstraint!
    private var safeAreaTopConstraint: NSLayoutConstraint!
    private var safeAreaBottomConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
    private var configuration: MPVCacheConfiguration
    private var durationButtons: [UIButton] = []

    private static let cardWidth: CGFloat = 320
    private static let cardHeight: CGFloat = 430

    var onChange: ((MPVCacheConfiguration) -> Void)?
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
        diskSwitch.isOn = configuration.isDiskCacheEnabled
        let isEnabled = configuration.isEnabled
        durationStack.isUserInteractionEnabled = isEnabled
        durationStack.alpha = isEnabled ? 1 : 0.45
        diskSwitch.isEnabled = isEnabled
        directoryLabel.alpha = isEnabled && configuration.isDiskCacheEnabled ? 1 : 0.45
        durationButtons.forEach { button in
            let duration = button.tag == 0 ? 10.0 : button.tag == 1 ? 30.0 : button.tag == 2 ? 60.0 : button.tag == 3 ? 300.0 : 1800.0
            button.isEnabled = isEnabled
            let image = abs(duration - configuration.duration) < 0.001
                ? UIImage(systemName: "checkmark")
                : nil
            button.setImage(image, for: .normal)
        }
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
        configureSwitch(diskSwitch, title: "cache.disk")
        directoryLabel.text = mpvLocalized("cache.directory")
        directoryLabel.font = .preferredFont(forTextStyle: .caption1)
        directoryLabel.adjustsFontForContentSizeCategory = true
        directoryLabel.textColor = .secondaryLabel
        directoryLabel.numberOfLines = 0

        let durationHeading = UILabel()
        durationHeading.text = mpvLocalized("cache.duration")
        durationHeading.font = .preferredFont(forTextStyle: .body)
        durationHeading.adjustsFontForContentSizeCategory = true
        durationHeading.textColor = .label

        durationStack.axis = .vertical
        durationStack.spacing = 2
        durationStack.alignment = .fill
        MPVCacheConfiguration.availableDurations.enumerated().forEach { index, duration in
            let button = UIButton(type: .system)
            button.tag = index
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.setTitle(self.durationTitle(for: duration), for: .normal)
            button.setTitleColor(.label, for: .normal)
            button.tintColor = .label
            button.accessibilityIdentifier = "MPVQuickPlayer.cacheDuration.\(Int(duration))"
            button.addTarget(self, action: #selector(durationChanged(_:)), for: .touchUpInside)
            durationStack.addArrangedSubview(button)
            durationButtons.append(button)
        }

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.alignment = .fill
        contentStack.addArrangedSubview(makeSwitchRow(title: mpvLocalized("cache.enabled"), switchView: cacheSwitch))
        contentStack.addArrangedSubview(durationHeading)
        contentStack.addArrangedSubview(durationStack)
        contentStack.addArrangedSubview(makeSwitchRow(title: mpvLocalized("cache.disk"), switchView: diskSwitch))
        contentStack.addArrangedSubview(directoryLabel)

        scrollView.showsVerticalScrollIndicator = true
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
        diskSwitch.addTarget(self, action: #selector(diskSwitchChanged(_:)), for: .valueChanged)
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

    private func durationTitle(for duration: TimeInterval) -> String {
        switch duration {
        case 10: return mpvLocalized("cache.duration.10")
        case 30: return mpvLocalized("cache.duration.30")
        case 60: return mpvLocalized("cache.duration.60")
        case 300: return mpvLocalized("cache.duration.300")
        default: return mpvLocalized("cache.duration.1800")
        }
    }

    @objc private func cacheSwitchChanged(_ sender: UISwitch) {
        var updated = configuration
        updated.isEnabled = sender.isOn
        onChange?(updated)
    }

    @objc private func diskSwitchChanged(_ sender: UISwitch) {
        var updated = configuration
        updated.isDiskCacheEnabled = sender.isOn
        onChange?(updated)
    }

    @objc private func durationChanged(_ sender: UIButton) {
        guard MPVCacheConfiguration.availableDurations.indices.contains(sender.tag) else { return }
        var updated = configuration
        updated.duration = MPVCacheConfiguration.availableDurations[sender.tag]
        onChange?(updated)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }
}
