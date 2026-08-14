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

@MainActor
final class MPVQuickPlayerActionSheetViewController: UIViewController {
    private let titleText: String
    private let message: String?
    private let options: [MPVQuickPlayerActionSheetOption]
    private let cancelTitle: String

    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let cancelButton = UIButton(type: .system)

    init(
        title: String,
        message: String?,
        options: [MPVQuickPlayerActionSheetOption],
        cancelTitle: String
    ) {
        titleText = title
        self.message = message
        self.options = options
        self.cancelTitle = cancelTitle
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
        configureViews()
        configureLayout()
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.55)

        cardView.backgroundColor = .secondarySystemBackground
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        view.addSubview(cardView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.text = titleText
        cardView.addSubview(titleLabel)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        cardView.addSubview(messageLabel)

        tableView.backgroundColor = .clear
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.estimatedRowHeight = 54
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.optionCellIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        cardView.addSubview(tableView)

        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.setTitle(cancelTitle, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cardView.addSubview(cancelButton)
    }

    private func configureLayout() {
        [cardView, titleLabel, messageLabel, tableView, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let guide = view.safeAreaLayoutGuide
        let preferredCardWidth = cardView.widthAnchor.constraint(
            equalTo: guide.widthAnchor,
            multiplier: 0.88
        )
        preferredCardWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            preferredCardWidth,
            cardView.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 16),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -16),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(
                equalTo: message == nil ? titleLabel.bottomAnchor : messageLabel.bottomAnchor,
                constant: 12
            ),
            tableView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            tableView.heightAnchor.constraint(lessThanOrEqualToConstant: 240),
            tableView.heightAnchor.constraint(equalToConstant: options.isEmpty ? 0 : 180),

            cancelButton.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    private static let optionCellIdentifier = "MPVQuickPlayerActionSheetOption"
}

extension MPVQuickPlayerActionSheetViewController: UITableViewDataSource, UITableViewDelegate {
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
