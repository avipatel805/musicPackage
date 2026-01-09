import UIKit
import PDFKit

final class PDFViewerViewController: UIViewController, UIGestureRecognizerDelegate {

    private let pdfURL: URL
    private let pdfView = PDFView(frame: .zero)

    // Annotation engine
    private let annotationOverlay = PDFAnnotationOverlayView()

    // Floating toolbar
    private let floatingToolbar = NotabilityToolbarView()

    // Floating back chevron (blurred pill)
    private let backButtonBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let backButton = UIButton(type: .system)

    // Floating hamburger (blurred pill)
    private let menuButtonBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let menuButton = UIButton(type: .system)

    // Settings overlay
    private let settingsOverlay = UIView()
    private let settingsCardBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let gesturePicker = UIPickerView()
    private let confidenceSlider = UISlider()
    private let confidenceValueLabel = UILabel()
    private let calibrateButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    // ✅ We'll keep a reference so we can filter taps (outside only)
    private lazy var overlayDismissTap: UITapGestureRecognizer = {
        let gr = UITapGestureRecognizer(target: self, action: #selector(closeSettings))
        gr.cancelsTouchesInView = false
        gr.delegate = self
        return gr
    }()

    // Tap recognizer on root view (reliable)
    private lazy var chromeTapRecognizer: UITapGestureRecognizer = {
        let gr = UITapGestureRecognizer(target: self, action: #selector(handleTapZones(_:)))
        gr.delegate = self
        gr.cancelsTouchesInView = false
        return gr
    }()

    // Your existing gesture detector
    private let detector = GestureDetector()

    // ARKit driver that produces BlendInput for detector
    private let faceDriver = FaceTrackingDriver()

    // Saving
    private var annotationsDirty = false

    // Chrome (auto-hide)
    private var chromeHidden = false
    private var chromeTimer: Timer?

    // Gesture turning controls
    private var lastTurnTime: CFTimeInterval = 0
    private let turnCooldown: CFTimeInterval = 0.75
    private var wasGestureActiveLastFrame = false

    init(pdfURL: URL) {
        self.pdfURL = pdfURL
        super.init(nibName: nil, bundle: nil)
        self.title = pdfURL.deletingPathExtension().lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Settings storage

    private var selectedGesture: PageTurnGesture {
        get {
            if let raw = UserDefaults.standard.string(forKey: "PageTurnSelectedGesture"),
               let g = PageTurnGesture(rawValue: raw) {
                return g
            }
            return .blink
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "PageTurnSelectedGesture")
            updateCalibrateButtonVisibility()
        }
    }

    private var confidence: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "PageTurnConfidence")
            return v == 0 ? 70 : max(0, min(100, v))
        }
        set {
            UserDefaults.standard.set(max(0, min(100, newValue)), forKey: "PageTurnConfidence")
        }
    }

    private func recalibrateTiltIfNeeded() {
        if selectedGesture.isTilt {
            faceDriver.calibrateRollBaseline()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.tintColor = .systemBlue

        // PDF setup
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .black
        view.addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Tap handler (top reveal chrome + page zones)
        view.addGestureRecognizer(chromeTapRecognizer)

        // Annotation overlay on top
        annotationOverlay.translatesAutoresizingMaskIntoConstraints = false
        annotationOverlay.pdfView = pdfView
        annotationOverlay.tool = .pen
        annotationOverlay.pencilOnly = true
        annotationOverlay.strokeColor = .systemBlue
        annotationOverlay.strokeWidth = 2.5
        annotationOverlay.updatePreviewStyle()
        view.addSubview(annotationOverlay)

        NSLayoutConstraint.activate([
            annotationOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            annotationOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            annotationOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            annotationOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor)
        ])

        // Floating toolbar
        floatingToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(floatingToolbar)

        NSLayoutConstraint.activate([
            floatingToolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            floatingToolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        floatingToolbar.onChange = { [weak self] st in
            guard let self else { return }
            switch st.tool {
            case .pen:
                self.annotationOverlay.tool = .pen
                self.annotationOverlay.strokeColor = st.color
                self.annotationOverlay.strokeWidth = st.thickness
            case .highlighter:
                self.annotationOverlay.tool = .highlighter
                self.annotationOverlay.strokeColor = st.color
                self.annotationOverlay.strokeWidth = max(st.thickness, 6)
            case .eraser:
                self.annotationOverlay.tool = .eraser
            }
            self.annotationOverlay.updatePreviewStyle()
        }

        configureFloatingBackButton()
        configureFloatingMenuButton()
        configureSettingsOverlay()

        loadPDF()

        NotificationCenter.default.addObserver(self, selector: #selector(markAnnotationsDirty),
                                               name: .pdfDidChangeAnnotations, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        // AR inputs -> GestureDetector -> page turns
        faceDriver.onInput = { [weak self] input in
            self?.processFaceInput(input)
        }

        // Start visible, then hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.scheduleChromeHideIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        faceDriver.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyZoomLimits()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        faceDriver.stop()
        saveAnnotationsIfNeeded()
        chromeTimer?.invalidate()
        chromeTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Face input processing

    private func processFaceInput(_ input: BlendInput) {
        // If the settings overlay is open, don't flip pages.
        if !settingsOverlay.isHidden { return }

        _ = detector.update(with: input, confidence: confidence)

        let g = selectedGesture
        let isActiveNow = detector.isActive(g)

        // Edge-trigger so holding gesture doesn't spam flips
        let justActivated = isActiveNow && !wasGestureActiveLastFrame
        wasGestureActiveLastFrame = isActiveNow
        guard justActivated else { return }

        let now = CACurrentMediaTime()
        guard now - lastTurnTime > turnCooldown else { return }
        lastTurnTime = now

        DispatchQueue.main.async { [weak self] in
            self?.performPageTurn(for: g)
        }
    }

    private func performPageTurn(for g: PageTurnGesture) {
        pdfView.goToNextPage(nil)
        scheduleChromeHideIfNeeded()
    }

    // MARK: - Back button (blur pill + micro-polish)

    @objc private func backButtonDown() {
        UIView.animate(withDuration: 0.1) { self.backButtonBlur.transform = CGAffineTransform(scaleX: 0.94, y: 0.94) }
    }

    @objc private func backButtonUp() {
        UIView.animate(withDuration: 0.1) { self.backButtonBlur.transform = .identity }
    }

    private func configureFloatingBackButton() {
        backButtonBlur.translatesAutoresizingMaskIntoConstraints = false
        backButtonBlur.layer.cornerRadius = 20
        backButtonBlur.clipsToBounds = true
        backButtonBlur.layer.shadowColor = UIColor.black.cgColor
        backButtonBlur.layer.shadowOpacity = 0.35
        backButtonBlur.layer.shadowRadius = 18
        backButtonBlur.layer.shadowOffset = CGSize(width: 0, height: 10)
        backButtonBlur.layer.masksToBounds = false
        view.addSubview(backButtonBlur)

        NSLayoutConstraint.activate([
            backButtonBlur.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            backButtonBlur.centerYAnchor.constraint(equalTo: floatingToolbar.centerYAnchor),
            backButtonBlur.widthAnchor.constraint(equalToConstant: 40),
            backButtonBlur.heightAnchor.constraint(equalToConstant: 40)
        ])

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.addTarget(self, action: #selector(dismissToLibrary), for: .touchUpInside)
        backButton.addTarget(self, action: #selector(backButtonDown), for: .touchDown)
        backButton.addTarget(self, action: #selector(backButtonUp), for: [.touchUpInside, .touchCancel, .touchUpOutside])
        backButtonBlur.contentView.addSubview(backButton)

        NSLayoutConstraint.activate([
            backButton.centerXAnchor.constraint(equalTo: backButtonBlur.contentView.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: backButtonBlur.contentView.centerYAnchor)
        ])
    }

    @objc private func dismissToLibrary() {
        saveAnnotationsIfNeeded()
        dismiss(animated: true)
    }

    // MARK: - Menu button (blur pill)

    private func configureFloatingMenuButton() {
        menuButtonBlur.translatesAutoresizingMaskIntoConstraints = false
        menuButtonBlur.layer.cornerRadius = 20
        menuButtonBlur.clipsToBounds = true
        menuButtonBlur.layer.shadowColor = UIColor.black.cgColor
        menuButtonBlur.layer.shadowOpacity = 0.35
        menuButtonBlur.layer.shadowRadius = 18
        menuButtonBlur.layer.shadowOffset = CGSize(width: 0, height: 10)
        menuButtonBlur.layer.masksToBounds = false
        view.addSubview(menuButtonBlur)

        NSLayoutConstraint.activate([
            menuButtonBlur.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            menuButtonBlur.centerYAnchor.constraint(equalTo: floatingToolbar.centerYAnchor),
            menuButtonBlur.widthAnchor.constraint(equalToConstant: 40),
            menuButtonBlur.heightAnchor.constraint(equalToConstant: 40)
        ])

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.setImage(UIImage(systemName: "line.3.horizontal"), for: .normal)
        menuButton.tintColor = .white
        menuButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        menuButtonBlur.contentView.addSubview(menuButton)

        NSLayoutConstraint.activate([
            menuButton.centerXAnchor.constraint(equalTo: menuButtonBlur.contentView.centerXAnchor),
            menuButton.centerYAnchor.constraint(equalTo: menuButtonBlur.contentView.centerYAnchor)
        ])
    }

    // MARK: - Settings overlay UI

    private func configureSettingsOverlay() {
        settingsOverlay.translatesAutoresizingMaskIntoConstraints = false
        settingsOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        settingsOverlay.isHidden = true
        settingsOverlay.alpha = 0
        view.addSubview(settingsOverlay)

        NSLayoutConstraint.activate([
            settingsOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            settingsOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settingsOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // ✅ Tap outside to close (delegate filters inside-card taps)
        settingsOverlay.addGestureRecognizer(overlayDismissTap)

        // Card
        settingsCardBlur.translatesAutoresizingMaskIntoConstraints = false
        settingsCardBlur.layer.cornerRadius = 16
        settingsCardBlur.clipsToBounds = true
        settingsOverlay.addSubview(settingsCardBlur)

        NSLayoutConstraint.activate([
            settingsCardBlur.trailingAnchor.constraint(equalTo: settingsOverlay.trailingAnchor, constant: -14),
            settingsCardBlur.topAnchor.constraint(equalTo: floatingToolbar.bottomAnchor, constant: 10),
            settingsCardBlur.widthAnchor.constraint(equalToConstant: 290)
        ])

        // Content inside card
        let content = settingsCardBlur.contentView

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Page Turn"
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white

        let gestureLabel = UILabel()
        gestureLabel.translatesAutoresizingMaskIntoConstraints = false
        gestureLabel.text = "Gesture"
        gestureLabel.font = .systemFont(ofSize: 13, weight: .medium)
        gestureLabel.textColor = UIColor.white.withAlphaComponent(0.9)

        gesturePicker.translatesAutoresizingMaskIntoConstraints = false
        gesturePicker.dataSource = self
        gesturePicker.delegate = self

        let confLabel = UILabel()
        confLabel.translatesAutoresizingMaskIntoConstraints = false
        confLabel.text = "Confidence"
        confLabel.font = .systemFont(ofSize: 13, weight: .medium)
        confLabel.textColor = UIColor.white.withAlphaComponent(0.9)

        confidenceSlider.translatesAutoresizingMaskIntoConstraints = false
        confidenceSlider.minimumValue = 0
        confidenceSlider.maximumValue = 100
        confidenceSlider.value = Float(confidence)
        confidenceSlider.addTarget(self, action: #selector(confidenceChanged(_:)), for: .valueChanged)

        confidenceValueLabel.translatesAutoresizingMaskIntoConstraints = false
        confidenceValueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        confidenceValueLabel.textColor = .white
        confidenceValueLabel.textAlignment = .right
        confidenceValueLabel.text = "\(confidence)"

        calibrateButton.translatesAutoresizingMaskIntoConstraints = false
        calibrateButton.setTitle("Calibrate Tilt", for: .normal)
        calibrateButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        calibrateButton.tintColor = .white
        calibrateButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        calibrateButton.layer.cornerRadius = 10
        calibrateButton.addTarget(self, action: #selector(calibrateTiltPressed), for: .touchUpInside)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        doneButton.tintColor = .white
        doneButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        doneButton.layer.cornerRadius = 10
        doneButton.addTarget(self, action: #selector(closeSettings), for: .touchUpInside)

        content.addSubview(title)
        content.addSubview(gestureLabel)
        content.addSubview(gesturePicker)
        content.addSubview(confLabel)
        content.addSubview(confidenceSlider)
        content.addSubview(confidenceValueLabel)
        content.addSubview(calibrateButton)
        content.addSubview(doneButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            gestureLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            gestureLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            gestureLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            gesturePicker.topAnchor.constraint(equalTo: gestureLabel.bottomAnchor, constant: 6),
            gesturePicker.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            gesturePicker.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            gesturePicker.heightAnchor.constraint(equalToConstant: 120),

            confLabel.topAnchor.constraint(equalTo: gesturePicker.bottomAnchor, constant: 8),
            confLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            confidenceValueLabel.centerYAnchor.constraint(equalTo: confLabel.centerYAnchor),
            confidenceValueLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            confidenceValueLabel.widthAnchor.constraint(equalToConstant: 44),

            confidenceSlider.topAnchor.constraint(equalTo: confLabel.bottomAnchor, constant: 8),
            confidenceSlider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            confidenceSlider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            calibrateButton.topAnchor.constraint(equalTo: confidenceSlider.bottomAnchor, constant: 12),
            calibrateButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            calibrateButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            calibrateButton.heightAnchor.constraint(equalToConstant: 40),

            doneButton.topAnchor.constraint(equalTo: calibrateButton.bottomAnchor, constant: 10),
            doneButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            doneButton.heightAnchor.constraint(equalToConstant: 40),
            doneButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        // Set picker to current selection
        if let idx = PageTurnGesture.allCases.firstIndex(of: selectedGesture) {
            gesturePicker.selectRow(idx, inComponent: 0, animated: false)
        }

        updateCalibrateButtonVisibility()
    }

    private func updateCalibrateButtonVisibility() {
        // Show only when tilt is selected (you asked specifically for headroll calibration)
        calibrateButton.isHidden = !selectedGesture.isTilt
    }

    @objc private func openSettings() {
        setChromeHidden(false, animated: true)
        scheduleChromeHideIfNeeded()

        // refresh UI from stored settings
        confidenceSlider.value = Float(confidence)
        confidenceValueLabel.text = "\(confidence)"
        if let idx = PageTurnGesture.allCases.firstIndex(of: selectedGesture) {
            gesturePicker.selectRow(idx, inComponent: 0, animated: false)
        }
        updateCalibrateButtonVisibility()

        settingsOverlay.isHidden = false
        settingsOverlay.alpha = 0
        UIView.animate(withDuration: 0.18) { self.settingsOverlay.alpha = 1 }
    }

    @objc private func closeSettings() {
        UIView.animate(withDuration: 0.18, animations: {
            self.settingsOverlay.alpha = 0
        }, completion: { _ in
            self.settingsOverlay.isHidden = true
            self.recalibrateTiltIfNeeded()
            self.scheduleChromeHideIfNeeded()
        })
    }

    @objc private func calibrateTiltPressed() {
        faceDriver.calibrateRollBaseline()

        // Quick visual feedback
        UIView.animate(withDuration: 0.08, animations: {
            self.calibrateButton.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }, completion: { _ in
            UIView.animate(withDuration: 0.12) {
                self.calibrateButton.transform = .identity
            }
        })
    }

    @objc private func confidenceChanged(_ sender: UISlider) {
        let v = Int(sender.value.rounded())
        confidence = v
        confidenceValueLabel.text = "\(v)"
    }

    // MARK: - PDF

    private func loadPDF() {
        guard let doc = PDFDocument(url: pdfURL) else { return }
        pdfView.document = doc
        pdfView.goToFirstPage(nil)
        applyZoomLimits()
    }

    private func applyZoomLimits() {
        let fit = pdfView.scaleFactorForSizeToFit
        pdfView.minScaleFactor = fit
        pdfView.maxScaleFactor = max(fit * 4.0, 4.0)
        if pdfView.scaleFactor < fit { pdfView.scaleFactor = fit }
    }

    // MARK: - Tap zones + Chrome reveal

    @objc private func handleTapZones(_ gr: UITapGestureRecognizer) {
        // If settings are open, ignore taps here (overlay handles its own taps)
        if !settingsOverlay.isHidden { return }

        let p = gr.location(in: view)
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }

        // Zone definitions
        let zoneWidth = w * 0.15          // 15% width
        let zoneTopY  = h * 0.25          // bottom 75% => starts at 25% from top

        let inBottomBand = p.y >= zoneTopY
        let inLeftZone   = inBottomBand && p.x <= zoneWidth
        let inRightZone  = inBottomBand && p.x >= (w - zoneWidth)

        if inLeftZone {
            // Back
            pdfView.goToPreviousPage(nil)
            scheduleChromeHideIfNeeded()
            return
        }

        if inRightZone {
            // Next
            pdfView.goToNextPage(nil)
            scheduleChromeHideIfNeeded()
            return
        }

        // Remaining area: show chrome (toolbar + hamburger + chevron)
        setChromeHidden(false, animated: true)
        scheduleChromeHideIfNeeded()
    }


    // MARK: - Gesture recognizer delegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// ✅ Key fix: only dismiss settings when tapping OUTSIDE the card
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === overlayDismissTap {
            let p = touch.location(in: settingsOverlay)
            return !settingsCardBlur.frame.contains(p) // allow dismiss only outside card
        }
        return true
    }

    // MARK: - Chrome auto-hide

    private func toggleChrome() {
        setChromeHidden(!chromeHidden, animated: true)
        if !chromeHidden { scheduleChromeHideIfNeeded() }
    }

    private func scheduleChromeHideIfNeeded() {
        chromeTimer?.invalidate()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.setChromeHidden(true, animated: true)
        }
    }

    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        chromeHidden = hidden
        let apply = {
            self.navigationController?.setNavigationBarHidden(true, animated: false)
            self.floatingToolbar.alpha = hidden ? 0 : 1
            self.backButtonBlur.alpha = hidden ? 0 : 1
            self.menuButtonBlur.alpha = hidden ? 0 : 1
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - Save annotations

    @objc private func markAnnotationsDirty() {
        annotationsDirty = true
    }

    @objc private func appWillResignActive() {
        saveAnnotationsIfNeeded()
    }

    private func saveAnnotationsIfNeeded() {
        guard annotationsDirty else { return }
        guard let doc = pdfView.document else { return }
        if doc.write(to: pdfURL) {
            annotationsDirty = false
        }
    }
}

// MARK: - UIPickerView

extension PDFViewerViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        PageTurnGesture.allCases.count
    }

    func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
        34
    }

    func pickerView(_ pickerView: UIPickerView,
                    attributedTitleForRow row: Int,
                    forComponent component: Int) -> NSAttributedString? {
        let g = PageTurnGesture.allCases[row]
        return NSAttributedString(string: g.displayName, attributes: [
            .foregroundColor: UIColor.white
        ])
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        selectedGesture = PageTurnGesture.allCases[row]
    }
}

