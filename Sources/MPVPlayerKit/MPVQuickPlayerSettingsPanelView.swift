import UIKit

/// Overlay panels share safe-area updates and dismissal with the quick player.
@MainActor
protocol MPVQuickPlayerPanelOverlay: AnyObject {
    var onDismiss: (() -> Void)? { get set }
    func updatePlayerSafeAreaInsets(_ insets: UIEdgeInsets)
    func dismiss(animated: Bool)
}

/// Shared card chrome for secondary settings panels (picture / subtitle / cache).
@MainActor
class MPVQuickPlayerSettingsPanelView: UIView, MPVQuickPlayerPanelOverlay {
    let backdropButton = UIButton(type: .custom)
    let cardView = UIView()
    let effectView = UIVisualEffectView()
    let titleLabel = UILabel()
    let scrollView = UIScrollView()
    let contentStack = UIStackView()
    let cancelButton = UIButton(type: .system)
    private let safeAreaGuide = UILayoutGuide()
    private var safeAreaLeadingConstraint: NSLayoutConstraint!
    private var safeAreaTrailingConstraint: NSLayoutConstraint!
    private var safeAreaTopConstraint: NSLayoutConstraint!
    private var safeAreaBottomConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardMinHeightConstraint: NSLayoutConstraint!
    private var playerSafeAreaInsets = UIEdgeInsets.zero

    var onDismiss: (() -> Void)?

    class var cardWidth: CGFloat { 320 }
    class var cardHeight: CGFloat { 280 }
    class var minimumCardHeight: CGFloat { 240 }
    class var titleKey: String { "settings.title" }
    class var accessibilityIdentifierKey: String { "MPVQuickPlayer.settingsPanel" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureChrome()
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Subclasses build their rows into `contentStack`.
    func configureContent() {}

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

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCardMetrics()
    }

    func updatePlayerSafeAreaInsets(_ insets: UIEdgeInsets) {
        playerSafeAreaInsets = insets
        safeAreaLeadingConstraint.constant = insets.left
        safeAreaTrailingConstraint.constant = -insets.right
        safeAreaTopConstraint.constant = insets.top
        safeAreaBottomConstraint.constant = -insets.bottom
        updateCardMetrics()
    }

    /// Keeps the card visible on short (landscape) heights: preferred size when
    /// it fits, otherwise shrink to the safe-area box instead of collapsing.
    private func updateCardMetrics() {
        let horizontalMargin: CGFloat = 32
        let verticalMargin: CGFloat = 32
        let availableWidth = max(
            0,
            bounds.width - playerSafeAreaInsets.left - playerSafeAreaInsets.right - horizontalMargin
        )
        let availableHeight = max(
            0,
            bounds.height - playerSafeAreaInsets.top - playerSafeAreaInsets.bottom - verticalMargin
        )
        let preferredWidth = type(of: self).cardWidth
        if availableWidth > 0 {
            cardWidthConstraint.constant = min(preferredWidth, availableWidth)
        } else {
            cardWidthConstraint.constant = preferredWidth
        }
        let preferredHeight = type(of: self).cardHeight
        let minimumHeight = type(of: self).minimumCardHeight
        if availableHeight >= preferredHeight {
            cardHeightConstraint.constant = preferredHeight
        } else {
            cardHeightConstraint.constant = max(minimumHeight, availableHeight)
        }
        cardMinHeightConstraint.constant = min(minimumHeight, cardHeightConstraint.constant)
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

    private func configureChrome() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        accessibilityViewIsModal = true
        accessibilityIdentifier = type(of: self).accessibilityIdentifierKey

        backdropButton.translatesAutoresizingMaskIntoConstraints = false
        backdropButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        backdropButton.accessibilityLabel = mpvLocalized("common.cancel")
        backdropButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
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

        titleLabel.text = mpvLocalized(type(of: self).titleKey)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        effectView.contentView.addSubview(titleLabel)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.alignment = .fill
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        effectView.contentView.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        cancelButton.setTitle(mpvLocalized("common.cancel"), for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        effectView.contentView.addSubview(cancelButton)

        configureLayout()
    }

    private func configureLayout() {
        addLayoutGuide(safeAreaGuide)
        let contentView = effectView.contentView
        // Required height/width: the old .defaultHigh preferred height was dropped
        // whenever the landscape safe-area box was shorter than the card, and the
        // scroll view then collapsed to a sliver.
        cardHeightConstraint = cardView.heightAnchor.constraint(
            equalToConstant: type(of: self).cardHeight
        )
        cardMinHeightConstraint = cardView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: type(of: self).minimumCardHeight
        )
        cardWidthConstraint = cardView.widthAnchor.constraint(
            equalToConstant: type(of: self).cardWidth
        )
        safeAreaLeadingConstraint = safeAreaGuide.leadingAnchor.constraint(equalTo: leadingAnchor)
        safeAreaTrailingConstraint = safeAreaGuide.trailingAnchor.constraint(equalTo: trailingAnchor)
        safeAreaTopConstraint = safeAreaGuide.topAnchor.constraint(equalTo: topAnchor)
        safeAreaBottomConstraint = safeAreaGuide.bottomAnchor.constraint(equalTo: bottomAnchor)
        let cardTopConstraint = cardView.topAnchor.constraint(
            greaterThanOrEqualTo: safeAreaGuide.topAnchor,
            constant: 16
        )
        let cardBottomConstraint = cardView.bottomAnchor.constraint(
            lessThanOrEqualTo: safeAreaGuide.bottomAnchor,
            constant: -16
        )
        cardTopConstraint.priority = .defaultHigh
        cardBottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdropButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropButton.topAnchor.constraint(equalTo: topAnchor),
            backdropButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.centerXAnchor.constraint(equalTo: safeAreaGuide.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: safeAreaGuide.centerYAnchor),
            cardWidthConstraint,
            cardView.widthAnchor.constraint(
                lessThanOrEqualTo: safeAreaGuide.widthAnchor,
                constant: -32
            ),
            cardTopConstraint,
            cardBottomConstraint,
            cardHeightConstraint,
            cardMinHeightConstraint,
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
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

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    // MARK: - Row builders

    func makeSwitchRow(title: String, switchView: UISwitch) -> UIView {
        switchView.onTintColor = .systemBlue
        switchView.accessibilityLabel = title
        let row = UIView()
        let label = makeRowLabel(title)
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

    func makeSegmentRow(title: String, segmentedControl: UISegmentedControl) -> UIView {
        let row = UIView()
        let label = makeRowLabel(title)
        row.addSubview(label)
        row.addSubview(segmentedControl)
        label.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            segmentedControl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            segmentedControl.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            segmentedControl.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            segmentedControl.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
        ])
        return row
    }

    func makeStepperRow(
        title: String,
        valueLabel: UILabel,
        stepper: UIStepper
    ) -> UIView {
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = .label
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        stepper.stepValue = 1
        let row = UIView()
        let label = makeRowLabel(title)
        row.addSubview(label)
        row.addSubview(valueLabel)
        row.addSubview(stepper)
        label.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        stepper.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stepper.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
            stepper.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stepper.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func makeValueButtonRow(title: String, button: UIButton) -> UIView {
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(.label, for: .normal)
        button.tintColor = .label
        button.contentHorizontalAlignment = .right
        let row = UIView()
        let label = makeRowLabel(title)
        row.addSubview(label)
        row.addSubview(button)
        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func makeTrailingButtonRow(title: String, button: UIButton) -> UIView {
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(.systemBlue, for: .normal)
        button.contentHorizontalAlignment = .right
        let row = UIView()
        let label = makeRowLabel(title)
        row.addSubview(label)
        row.addSubview(button)
        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func makeRowLabel(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }
}
