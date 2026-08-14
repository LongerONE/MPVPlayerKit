import UIKit

struct MPVQuickPlayerActionSheetOption {
    let title: String
    let isSelected: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        title: String,
        isSelected: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// A menu hosted by the player instead of a second view controller.
///
/// The menu is deliberately a view so it lives inside `contentView`. This means
/// that it receives the same orientation transform as the player before its
/// first frame is rendered, including the portrait-hosted manual landscape mode.
@MainActor
final class MPVQuickPlayerMenuView: UIView {
    private let titleText: String
    private let message: String?
    private let options: [MPVQuickPlayerActionSheetOption]
    private let cancelTitle: String
    private weak var sourceView: UIView?

    private let backdropButton = UIButton(type: .custom)
    private let cardView = UIView()
    private let effectView = UIVisualEffectView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let cancelButton = UIButton(type: .system)
    private let safeAreaGuide = UILayoutGuide()
    private var safeAreaLeadingConstraint: NSLayoutConstraint!
    private var safeAreaTrailingConstraint: NSLayoutConstraint!
    private var safeAreaTopConstraint: NSLayoutConstraint!
    private var safeAreaBottomConstraint: NSLayoutConstraint!
    private var cardCenterXConstraint: NSLayoutConstraint!
    private var cardCenterYConstraint: NSLayoutConstraint!
    private var sourceCenterXConstraint: NSLayoutConstraint!
    private var sourceTopConstraint: NSLayoutConstraint!
    private var sourceBottomConstraint: NSLayoutConstraint!
    private var isUsingSourceViewPositioning = false
    private var preferredCardWidthConstraint: NSLayoutConstraint!
    private var tableHeightConstraint: NSLayoutConstraint!
    private var lastMeasuredCardWidth: CGFloat = -1
    private var lastMeasuredTableHeight: CGFloat = -1
    private var playerSafeAreaInsets = UIEdgeInsets.zero

    private static let minimumCardWidth: CGFloat = 220
    private static let maximumCardWidth: CGFloat = 640
    private static let cardEdgeInset: CGFloat = 16
    private static let cardContentHorizontalInset: CGFloat = 40

    /// Called after the menu has been removed from the view hierarchy.
    var onDismiss: (() -> Void)?

    init(
        title: String,
        message: String?,
        options: [MPVQuickPlayerActionSheetOption],
        cancelTitle: String,
        sourceView: UIView? = nil
    ) {
        titleText = title
        self.message = message
        self.options = options
        self.cancelTitle = cancelTitle
        self.sourceView = sourceView
        super.init(frame: .zero)
        configureViews()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            backdropButton.alpha = 0
            cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            layoutIfNeeded()
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: {
                    // UIKit materializes Liquid Glass when the effect is set
                    // after the visual effect view enters the hierarchy.
                    self.installBackgroundEffect()
                    self.backdropButton.alpha = 1
                    self.cardView.transform = .identity
                }
            )
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSourceViewPositioning()
        updateCardWidthIfNeeded()
        updateTableHeightIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else {
            return
        }
        lastMeasuredCardWidth = -1
        setNeedsLayout()
    }

    /// Updates the safe area in the already-rotated `contentView` coordinate space.
    func updatePlayerSafeAreaInsets(_ insets: UIEdgeInsets) {
        guard playerSafeAreaInsets != insets else { return }
        playerSafeAreaInsets = insets
        safeAreaLeadingConstraint.constant = insets.left
        safeAreaTrailingConstraint.constant = -insets.right
        safeAreaTopConstraint.constant = insets.top
        safeAreaBottomConstraint.constant = -insets.bottom
        updateTableHeightIfNeeded()
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        guard superview != nil else {
            onDismiss?()
            completion?()
            return
        }
        let finish = { [weak self] in
            guard let self else { return }
            removeFromSuperview()
            onDismiss?()
            completion?()
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                self.backdropButton.alpha = 0
                self.cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            },
            completion: { _ in finish() }
        )
    }

    private func configureViews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        accessibilityViewIsModal = true
        accessibilityIdentifier = "MPVQuickPlayer.menu"

        backdropButton.translatesAutoresizingMaskIntoConstraints = false
        backdropButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        backdropButton.accessibilityLabel = mpvLocalized("common.cancel")
        backdropButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        addSubview(backdropButton)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .clear
        cardView.accessibilityIdentifier = "MPVQuickPlayer.menu.card"
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        addSubview(cardView)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.layer.cornerRadius = 18
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
        cardView.addSubview(effectView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = titleText
        effectView.contentView.addSubview(titleLabel)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        effectView.contentView.addSubview(messageLabel)

        tableView.backgroundColor = .clear
        tableView.alwaysBounceVertical = false
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.estimatedRowHeight = 54
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.optionCellIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        effectView.contentView.addSubview(tableView)

        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.setTitle(cancelTitle, for: .normal)
        cancelButton.accessibilityIdentifier = "MPVQuickPlayer.menu.cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        effectView.contentView.addSubview(cancelButton)
    }

    private func configureLayout() {
        [backdropButton, cardView, effectView, titleLabel, messageLabel, tableView, cancelButton]
            .forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addLayoutGuide(safeAreaGuide)
        let contentView = effectView.contentView
        preferredCardWidthConstraint = cardView.widthAnchor.constraint(
            equalToConstant: Self.minimumCardWidth
        )
        preferredCardWidthConstraint.priority = .defaultHigh
        tableHeightConstraint = tableView.heightAnchor.constraint(
            equalToConstant: options.isEmpty ? 0 : 54
        )
        tableHeightConstraint.priority = .required

        cardCenterXConstraint = cardView.centerXAnchor.constraint(equalTo: safeAreaGuide.centerXAnchor)
        cardCenterYConstraint = cardView.centerYAnchor.constraint(equalTo: safeAreaGuide.centerYAnchor)
        cardCenterXConstraint.priority = .required
        cardCenterYConstraint.priority = .required

        // The source constraints are enabled only in regular width. Their high
        // priority keeps the menu near the source view, while the safe-area
        // constraints below remain required and clamp the card when there is
        // not enough room near an edge.
        sourceCenterXConstraint = cardView.centerXAnchor.constraint(equalTo: leadingAnchor)
        sourceTopConstraint = cardView.topAnchor.constraint(equalTo: topAnchor)
        sourceBottomConstraint = cardView.bottomAnchor.constraint(equalTo: topAnchor)
        sourceCenterXConstraint.priority = .defaultHigh
        sourceTopConstraint.priority = .defaultHigh
        sourceBottomConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backdropButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropButton.topAnchor.constraint(equalTo: topAnchor),
            backdropButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            cardCenterXConstraint,
            cardCenterYConstraint,
            cardView.leadingAnchor.constraint(
                greaterThanOrEqualTo: safeAreaGuide.leadingAnchor,
                constant: Self.cardEdgeInset
            ),
            cardView.trailingAnchor.constraint(
                lessThanOrEqualTo: safeAreaGuide.trailingAnchor,
                constant: -Self.cardEdgeInset
            ),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumCardWidth),
            preferredCardWidthConstraint,
            cardView.topAnchor.constraint(
                greaterThanOrEqualTo: safeAreaGuide.topAnchor,
                constant: Self.cardEdgeInset
            ),
            cardView.bottomAnchor.constraint(
                lessThanOrEqualTo: safeAreaGuide.bottomAnchor,
                constant: -Self.cardEdgeInset
            ),
            cardView.heightAnchor.constraint(lessThanOrEqualTo: safeAreaGuide.heightAnchor, constant: -32),

            effectView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: cardView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(
                equalTo: message == nil ? titleLabel.bottomAnchor : messageLabel.bottomAnchor,
                constant: 12
            ),
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableHeightConstraint,

            cancelButton.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        safeAreaLeadingConstraint = safeAreaGuide.leadingAnchor.constraint(equalTo: leadingAnchor)
        safeAreaTrailingConstraint = safeAreaGuide.trailingAnchor.constraint(equalTo: trailingAnchor)
        safeAreaTopConstraint = safeAreaGuide.topAnchor.constraint(equalTo: topAnchor)
        safeAreaBottomConstraint = safeAreaGuide.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            safeAreaLeadingConstraint,
            safeAreaTrailingConstraint,
            safeAreaTopConstraint,
            safeAreaBottomConstraint,
        ])
    }

    private func updateCardWidthIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let availableWidth = max(
            bounds.width - playerSafeAreaInsets.left - playerSafeAreaInsets.right - Self.cardEdgeInset * 2,
            0
        )
        let maximumWidth = min(Self.maximumCardWidth, availableWidth)
        guard maximumWidth > 0 else { return }

        let titleWidth = measuredWidth(of: titleText, font: titleLabel.font)
            + Self.cardContentHorizontalInset
        let messageWidth = measuredWidth(of: message, font: messageLabel.font)
            + Self.cardContentHorizontalInset
        let optionWidth = (options.map { option in
            measuredWidth(of: option.title, font: UIFont.preferredFont(forTextStyle: .body))
        }.max() ?? 0) + 48
        let cancelWidth = cancelButton.intrinsicContentSize.width + 32
        let contentWidth = max(titleWidth, messageWidth, optionWidth, cancelWidth)
        let cardWidth = min(
            max(contentWidth, Self.minimumCardWidth),
            maximumWidth
        )

        guard abs(cardWidth - lastMeasuredCardWidth) > 0.5 else { return }
        lastMeasuredCardWidth = cardWidth
        preferredCardWidthConstraint.constant = cardWidth
    }

    private func measuredWidth(of text: String?, font: UIFont) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func updateSourceViewPositioning() {
        guard let sourceView,
              sourceView.superview != nil,
              bounds.width >= 600,
              bounds.height > 0
        else {
            guard isUsingSourceViewPositioning else { return }
            isUsingSourceViewPositioning = false
            sourceCenterXConstraint.isActive = false
            sourceTopConstraint.isActive = false
            sourceBottomConstraint.isActive = false
            cardCenterXConstraint.priority = .required
            cardCenterYConstraint.priority = .required
            return
        }

        let sourceRect = sourceView.convert(sourceView.bounds, to: self)
        sourceCenterXConstraint.constant = sourceRect.midX
        sourceTopConstraint.constant = sourceRect.maxY + 8
        sourceBottomConstraint.constant = sourceRect.minY - 8
        sourceCenterXConstraint.isActive = true
        sourceTopConstraint.isActive = sourceRect.midY <= bounds.midY
        sourceBottomConstraint.isActive = sourceRect.midY > bounds.midY
        cardCenterXConstraint.priority = .defaultLow
        cardCenterYConstraint.priority = .defaultLow
        isUsingSourceViewPositioning = true
    }

    private func updateTableHeightIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        tableView.layoutIfNeeded()
        let cardContentWidth = max(cardView.bounds.width - Self.cardContentHorizontalInset, 1)
        let headerHeight = titleLabel.systemLayoutSizeFitting(
            CGSize(width: cardContentWidth, height: .greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let messageHeight = message == nil ? 0 : messageLabel.systemLayoutSizeFitting(
            CGSize(width: cardContentWidth, height: .greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height + 8
        let minimumTableHeight: CGFloat = options.isEmpty ? 0 : 54
        let fixedHeight = headerHeight + messageHeight + 18 + 12 + 8 + minimumTableHeight + 10
        let availableHeight = max(
            bounds.height - playerSafeAreaInsets.top - playerSafeAreaInsets.bottom - 32,
            0
        )
        let maximumTableHeight = max(0, availableHeight - fixedHeight)
        let contentHeight = tableView.contentSize.height
        let measuredHeight = min(
            max(contentHeight, minimumTableHeight),
            maximumTableHeight
        )
        guard abs(measuredHeight - lastMeasuredTableHeight) > 0.5 else { return }
        lastMeasuredTableHeight = measuredHeight
        tableHeightConstraint.constant = measuredHeight
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    private static let optionCellIdentifier = "MPVQuickPlayerActionSheetOption"

    private func installBackgroundEffect() {
        if #available(iOS 26.0, *) {
            effectView.effect = UIGlassEffect(style: .regular)
        } else {
            effectView.effect = UIBlurEffect(style: .systemMaterial)
        }
    }
}

extension MPVQuickPlayerMenuView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let option = options[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: Self.optionCellIdentifier,
            for: indexPath
        )
        var content = UIListContentConfiguration.cell()
        content.text = option.title
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 0
        content.textProperties.lineBreakMode = .byWordWrapping
        content.textProperties.color = option.isDestructive ? .systemRed : .label
        cell.contentConfiguration = content
        cell.accessoryType = option.isSelected ? .checkmark : .none
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let action = options[indexPath.row].action
        dismiss(animated: true, completion: action)
    }
}

/// Compatibility wrapper for clients/tests that used the old controller type.
/// Runtime player menus use `MPVQuickPlayerMenuView` directly.
@MainActor
final class MPVQuickPlayerActionSheetViewController: UIViewController {
    private let menuView: MPVQuickPlayerMenuView

    init(
        title: String,
        message: String?,
        options: [MPVQuickPlayerActionSheetOption],
        cancelTitle: String
    ) {
        menuView = MPVQuickPlayerMenuView(
            title: title,
            message: message,
            options: options,
            cancelTitle: cancelTitle
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(menuView)
        NSLayoutConstraint.activate([
            menuView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            menuView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            menuView.topAnchor.constraint(equalTo: view.topAnchor),
            menuView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
