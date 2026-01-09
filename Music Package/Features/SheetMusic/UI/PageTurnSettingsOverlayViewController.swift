import UIKit

final class PageTurnSettingsSheetViewController: UIViewController {

    private var settings: PageTurnSettings
    private let onDone: (PageTurnSettings) -> Void

    // UI
    private let gestureButton = UIButton(type: .system)
    private let confidenceLabel = UILabel()
    private let slider = UISlider()
    private let performanceSwitch = UISwitch()
    private weak var recalibrateButton: UIButton?

    init(settings: PageTurnSettings, onDone: @escaping (PageTurnSettings) -> Void) {
        self.settings = settings
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 18
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.tintColor = MPStyle.accentColor
        title = "Page Turn"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done",
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])

        // Gesture row
        gestureButton.setTitle(settings.gesture.displayName, for: .normal)
        gestureButton.contentHorizontalAlignment = .right
        gestureButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        gestureButton.showsMenuAsPrimaryAction = true
        gestureButton.menu = buildGestureMenu()

        let gestureRow = makeRow(
            title: "Gesture",
            subtitle: "Choose what flips the page",
            rightAccessory: gestureButton
        )
        stack.addArrangedSubview(gestureRow)

        // Confidence row
        confidenceLabel.textAlignment = .right
        confidenceLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        confidenceLabel.text = "\(settings.confidence)"

        let confidenceRow = makeRow(
            title: "Confidence",
            subtitle: "Higher = harder to trigger",
            rightAccessory: confidenceLabel
        )
        stack.addArrangedSubview(confidenceRow)

        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = Float(settings.confidence)
        slider.tintColor = MPStyle.accentColor
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.settings.confidence = Int(self.slider.value.rounded())
            self.confidenceLabel.text = "\(self.settings.confidence)"
        }, for: .valueChanged)
        stack.addArrangedSubview(slider)

        // Performance mode row
        performanceSwitch.isOn = settings.performanceMode
        performanceSwitch.onTintColor = MPStyle.accentColor
        performanceSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.settings.performanceMode = self.performanceSwitch.isOn
        }, for: .valueChanged)

        let perfRow = makeRow(
            title: "Performance mode",
            subtitle: "Hide controls + keep screen awake",
            rightAccessory: performanceSwitch
        )
        stack.addArrangedSubview(perfRow)

        // Recalibrate (only for tilt)
        let recalibrate = UIButton(type: .system)
        recalibrate.setTitle("Recalibrate Head Tilt", for: .normal)
        recalibrate.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        recalibrate.contentHorizontalAlignment = .center
        recalibrate.layer.cornerRadius = 12
        recalibrate.backgroundColor = MPStyle.accentColor.withAlphaComponent(0.10)
        recalibrate.heightAnchor.constraint(equalToConstant: 44).isActive = true
        recalibrate.addTarget(self, action: #selector(recalibrateTapped), for: .touchUpInside)
        stack.addArrangedSubview(recalibrate)

        recalibrate.isHidden = !settings.gesture.isTilt
        self.recalibrateButton = recalibrate

        // Small note (optional but feels more “real app”)
        let note = UILabel()
        note.text = "Tip: In performance mode, tap center to show/hide controls."
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        stack.addArrangedSubview(note)
    }

    private func buildGestureMenu() -> UIMenu {
        let actions = PageTurnGesture.allCases.map { g in
            UIAction(title: g.displayName, state: (g == settings.gesture ? .on : .off)) { [weak self] _ in
                guard let self else { return }
                self.settings.gesture = g
                self.gestureButton.setTitle(g.displayName, for: .normal)
                self.gestureButton.menu = self.buildGestureMenu() // refresh checkmarks
                self.recalibrateButton?.isHidden = !g.isTilt
            }
        }
        return UIMenu(title: "", options: [.singleSelection], children: actions)
    }

    @objc private func recalibrateTapped() {
        NotificationCenter.default.post(name: .requestTiltRecalibration, object: nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func doneTapped() {
        onDone(settings)
        dismiss(animated: true)
    }
}

// MARK: - Row helper
private func makeRow(title: String, subtitle: String, rightAccessory: UIView?) -> UIView {
    let container = UIView()
    container.backgroundColor = .secondarySystemBackground
    container.layer.cornerRadius = 14
    container.translatesAutoresizingMaskIntoConstraints = false
    container.heightAnchor.constraint(equalToConstant: 60).isActive = true

    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    let subtitleLabel = UILabel()
    subtitleLabel.text = subtitle
    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(titleLabel)
    container.addSubview(subtitleLabel)

    NSLayoutConstraint.activate([
        titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
        titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),

        subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
        subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11)
    ])

    if let accessory = rightAccessory {
        accessory.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(accessory)

        NSLayoutConstraint.activate([
            accessory.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            accessory.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.trailingAnchor, constant: 12)
        ])
    }

    return container
}

