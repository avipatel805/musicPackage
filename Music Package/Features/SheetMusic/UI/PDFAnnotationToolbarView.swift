import UIKit

final class PDFAnnotationToolbarView: UIView {

    struct State {
        var tool: PDFAnnotationOverlayView.Tool = .none
        var color: UIColor = .systemIndigo
        var width: CGFloat = 2.5
        var pencilOnly: Bool = true
    }

    var onChange: ((State) -> Void)?

    private var state = State() {
        didSet { onChange?(state) }
    }

    private let toolSeg = UISegmentedControl(items: ["Off", "Pen", "HL", "Erase"])
    private let widthSlider = UISlider()
    private let colorButton = UIButton(type: .system)
    private let pencilOnlySwitch = UISwitch()
    private let pencilOnlyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
        layer.cornerRadius = 14
        clipsToBounds = true

        toolSeg.selectedSegmentIndex = 0
        toolSeg.addTarget(self, action: #selector(toolChanged), for: .valueChanged)

        widthSlider.minimumValue = 1
        widthSlider.maximumValue = 14
        widthSlider.value = Float(state.width)
        widthSlider.addTarget(self, action: #selector(widthChanged), for: .valueChanged)

        colorButton.setTitle("Color", for: .normal)
        colorButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        colorButton.addTarget(self, action: #selector(colorTapped), for: .touchUpInside)

        pencilOnlyLabel.text = "Pencil only"
        pencilOnlyLabel.font = .systemFont(ofSize: 12)
        pencilOnlyLabel.textColor = .secondaryLabel

        pencilOnlySwitch.isOn = state.pencilOnly
        pencilOnlySwitch.addTarget(self, action: #selector(pencilOnlyChanged), for: .valueChanged)

        let row1 = UIStackView(arrangedSubviews: [toolSeg])
        row1.axis = .vertical

        let row2 = UIStackView(arrangedSubviews: [UILabel.makeCaption("Thickness"), widthSlider, colorButton])
        row2.axis = .horizontal
        row2.alignment = .center
        row2.spacing = 10

        let row3 = UIStackView(arrangedSubviews: [pencilOnlyLabel, pencilOnlySwitch, UIView()])
        row3.axis = .horizontal
        row3.alignment = .center
        row3.spacing = 10

        let stack = UIStackView(arrangedSubviews: [row1, row2, row3])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toolChanged() {
        switch toolSeg.selectedSegmentIndex {
        case 1: state.tool = .pen
        case 2: state.tool = .highlighter
        case 3: state.tool = .eraser
        default: state.tool = .none
        }
    }

    @objc private func widthChanged() {
        state.width = CGFloat(widthSlider.value)
    }

    @objc private func pencilOnlyChanged() {
        state.pencilOnly = pencilOnlySwitch.isOn
    }

    @objc private func colorTapped() {
        // simple palette
        let colors: [(String, UIColor)] = [
            ("Indigo", .systemIndigo),
            ("Blue", .systemBlue),
            ("Red", .systemRed),
            ("Green", .systemGreen),
            ("Yellow", .systemYellow),
            ("White", .white)
        ]

        let ac = UIAlertController(title: "Ink Color", message: nil, preferredStyle: .actionSheet)
        for (name, c) in colors {
            ac.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                self?.state.color = c
            })
        }
        ac.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // Find top controller to present
        if let vc = self.findViewController() {
            vc.present(ac, animated: true)
        }
    }
}

private extension UILabel {
    static func makeCaption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabel
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }
}

private extension UIView {
    func findViewController() -> UIViewController? {
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc }
            r = next
        }
        return nil
    }
}

