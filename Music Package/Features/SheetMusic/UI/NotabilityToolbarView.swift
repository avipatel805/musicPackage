import UIKit

final class NotabilityToolbarView: UIView {

    enum Tool: Int { case pen, highlighter, eraser }

    struct State {
        var tool: Tool = .pen
        var color: UIColor = .systemBlue
        var thickness: CGFloat = 2.5
    }

    var onChange: ((State) -> Void)?
    private(set) var state = State() { didSet { onChange?(state) } }

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let toolStack = UIStackView()
    private let colorStack = UIStackView()

    private let penBtn = UIButton(type: .system)
    private let hlBtn  = UIButton(type: .system)
    private let erBtn  = UIButton(type: .system)

    private var colorButtons: [UIButton] = []
    private let colors: [UIColor] = [
        .systemYellow, .systemBlue, .systemRed, .systemPurple, .brown, .systemGreen, .systemTeal, .white
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        applySelectedStates()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        layer.cornerRadius = 16
        clipsToBounds = false

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 10)

        blur.layer.cornerRadius = 16
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        toolStack.axis = .horizontal
        toolStack.spacing = 14
        toolStack.alignment = .center

        configureToolButton(penBtn, systemName: "pencil.tip", tag: Tool.pen.rawValue)
        configureToolButton(hlBtn, systemName: "highlighter", tag: Tool.highlighter.rawValue)
        configureToolButton(erBtn, systemName: "eraser", tag: Tool.eraser.rawValue)

        toolStack.addArrangedSubview(penBtn)
        toolStack.addArrangedSubview(hlBtn)
        toolStack.addArrangedSubview(erBtn)

        colorStack.axis = .horizontal
        colorStack.spacing = 12
        colorStack.alignment = .center

        colors.forEach { c in
            let b = UIButton(type: .system)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            b.layer.cornerRadius = 11
            b.backgroundColor = c
            b.layer.borderWidth = 2
            b.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
            b.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            colorButtons.append(b)
            colorStack.addArrangedSubview(b)
        }

        let main = UIStackView(arrangedSubviews: [toolStack, colorStack])
        main.axis = .vertical
        main.spacing = 10
        main.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(main)

        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 10),
            main.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -10),
            main.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 12),
            main.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -12),
        ])

        setSelectedColorRing(for: state.color)
    }

    private func configureToolButton(_ b: UIButton, systemName: String, tag: Int) {
        b.tag = tag
        b.setImage(UIImage(systemName: systemName), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        b.layer.cornerRadius = 12
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addTarget(self, action: #selector(toolTapped(_:)), for: .touchUpInside)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(toolLongPress(_:)))
        b.addGestureRecognizer(lp)
    }

    private func applySelectedStates() {
        [penBtn, hlBtn, erBtn].forEach { $0.backgroundColor = UIColor.white.withAlphaComponent(0.10) }
        switch state.tool {
        case .pen: penBtn.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        case .highlighter: hlBtn.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        case .eraser: erBtn.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        }
    }

    @objc private func toolTapped(_ sender: UIButton) {
        guard let t = Tool(rawValue: sender.tag) else { return }
        state.tool = t
        applySelectedStates()
    }

    @objc private func toolLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let next: CGFloat
        if state.thickness < 4 { next = 6 }
        else if state.thickness < 8 { next = 10 }
        else { next = 2.5 }
        state.thickness = next
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func colorTapped(_ sender: UIButton) {
        guard let c = sender.backgroundColor else { return }
        state.color = c
        setSelectedColorRing(for: c)
    }

    private func setSelectedColorRing(for color: UIColor) {
        for b in colorButtons {
            b.layer.borderColor = (b.backgroundColor == color)
            ? UIColor.white.withAlphaComponent(0.85).cgColor
            : UIColor.white.withAlphaComponent(0.15).cgColor
        }
    }
}

