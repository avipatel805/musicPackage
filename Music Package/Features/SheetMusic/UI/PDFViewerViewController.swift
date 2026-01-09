import UIKit
import PDFKit
import ARKit
import simd

final class PDFViewerViewController: UIViewController, ARSessionDelegate, UIGestureRecognizerDelegate {

    private let pdfURL: URL
    private let pdfView = PDFView(frame: .zero)
    
    private let annotationOverlay = PDFAnnotationOverlayView()
    private let annotationToolbar = PDFAnnotationToolbarView()
    private var annotationsDirty = false

    private let arSession = ARSession()
    private let detector = GestureDetector()
    private var pageTurnSettings = PageTurnSettingsStore.shared.load()

    // MARK: - Page turn gating
    private var wasSelectedGestureActive = false
    private var lastPageTurnTime: TimeInterval = 0
    private let pageTurnCooldown: TimeInterval = 0.8

    // MARK: - Tilt baseline calibration
    private var rollBaseline: Float? = nil
    private var rollBaselineSum: Float = 0
    private var rollBaselineCount: Int = 0
    private let rollBaselineSamplesNeeded: Int = 30

    // MARK: - Performance mode
    private var chromeTimer: Timer?
    private var chromeHidden = false
    



    init(pdfURL: URL) {
        self.pdfURL = pdfURL
        super.init(nibName: nil, bundle: nil)
        self.title = pdfURL.deletingPathExtension().lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func applyZoomLimits() {
        // This is the “fit to screen” scale for the current bounds
        let fit = pdfView.scaleFactorForSizeToFit

        // Prevent zooming out smaller than “fit”
        pdfView.minScaleFactor = fit

        // Reasonable zoom-in limit (tweak as you like)
        pdfView.maxScaleFactor = max(fit * 4.0, 4.0)

        // Clamp current scale if already below fit
        if pdfView.scaleFactor < fit {
            pdfView.scaleFactor = fit
        }
    }

    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyZoomLimits()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.tintColor = MPStyle.accentColor

        // PDF setup: left/right swiping
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .black
        view.addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // --- Annotation overlay (draw on top of PDF) ---
        annotationOverlay.translatesAutoresizingMaskIntoConstraints = false
        annotationOverlay.pdfView = pdfView
        annotationOverlay.isUserInteractionEnabled = true
        annotationOverlay.tool = .none
        annotationOverlay.updatePreviewStyle()
        view.addSubview(annotationOverlay)

        NSLayoutConstraint.activate([
            annotationOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            annotationOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            annotationOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            annotationOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor)
        ])

        // --- Annotation toolbar (hidden by default) ---
        annotationToolbar.translatesAutoresizingMaskIntoConstraints = false
        annotationToolbar.alpha = 0
        annotationToolbar.isHidden = true
        view.addSubview(annotationToolbar)

        NSLayoutConstraint.activate([
            annotationToolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            annotationToolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            annotationToolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

        annotationToolbar.onChange = { [weak self] st in
            guard let self else { return }
            self.annotationOverlay.tool = st.tool
            self.annotationOverlay.strokeColor = st.color
            self.annotationOverlay.strokeWidth = st.width
            self.annotationOverlay.pencilOnly = st.pencilOnly
            self.annotationOverlay.updatePreviewStyle()
        }


        // Only keep a settings button in the nav bar (tap zones handle paging)
        let settings = UIBarButtonItem(
            image: UIImage(systemName: "slider.horizontal.3"),
            style: .plain,
            target: self,
            action: #selector(openSettings)
        )
        navigationItem.rightBarButtonItem = settings
        
        let annotate = UIBarButtonItem(
            image: UIImage(systemName: "pencil.tip"),
            style: .plain,
            target: self,
            action: #selector(toggleAnnotateUI)
        )
        navigationItem.leftBarButtonItem = annotate


        // Tap zones: single tap on PDF view
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapZones(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false // don’t kill PDFKit interactions
        pdfView.addGestureRecognizer(tap)

        loadPDF()

        // AR session delegate
        arSession.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(handleTiltRecalibrationRequest),
                                               name: .requestTiltRecalibration, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(markAnnotationsDirty),
                                               name: .pdfDidChangeAnnotations, object: nil)

    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        applyPerformanceModeUI(animated: false)
        startFaceTrackingIfAvailable()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        saveAnnotationsIfNeeded()

        chromeTimer?.invalidate()
        chromeTimer = nil

        UIApplication.shared.isIdleTimerDisabled = false
        navigationController?.setNavigationBarHidden(false, animated: false)

        arSession.pause()
    }


    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var prefersStatusBarHidden: Bool {
        // If you want status bar hidden in performance mode when chrome is hidden:
        pageTurnSettings.performanceMode && chromeHidden
    }

    private func loadPDF() {
        guard let doc = PDFDocument(url: pdfURL) else {
            let alert = UIAlertController(title: "Couldn't open PDF",
                                          message: "The file may be corrupted.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        pdfView.document = doc
        pdfView.goToFirstPage(nil)
        
        applyZoomLimits()
    }

    private func startFaceTrackingIfAvailable() {
        guard ARFaceTrackingConfiguration.isSupported else { return }

        // Reset gating + calibration when we (re)start
        wasSelectedGestureActive = false
        lastPageTurnTime = 0
        resetTiltBaseline()

        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func applyPerformanceModeUI(animated: Bool) {
        UIApplication.shared.isIdleTimerDisabled = pageTurnSettings.performanceMode

        if pageTurnSettings.performanceMode {
            scheduleChromeHide()
        } else {
            chromeHidden = false
            navigationController?.setNavigationBarHidden(false, animated: animated)
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func scheduleChromeHide() {
        chromeTimer?.invalidate()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.setChromeHidden(true, animated: true)
        }
    }

    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        chromeHidden = hidden
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Tap zones + chrome toggle

    @objc private func handleTapZones(_ gr: UITapGestureRecognizer) {
        let point = gr.location(in: pdfView)
        let w = pdfView.bounds.width
        guard w > 0 else { return }

        let x = point.x
        let leftEdge = w / 3.0
        let rightEdge = 2.0 * w / 3.0

        if x < leftEdge {
            // Left third: prev
            prevPage()
            if pageTurnSettings.performanceMode { scheduleChromeHide() }
        } else if x > rightEdge {
            // Right third: next
            nextPage()
            if pageTurnSettings.performanceMode { scheduleChromeHide() }
        } else {
            // Middle third: toggle controls (performance mode)
            guard pageTurnSettings.performanceMode else { return }
            setChromeHidden(!chromeHidden, animated: true)
            if !chromeHidden { scheduleChromeHide() }
        }
    }

    // Allow simultaneous recognition so PDFKit scroll/zoom isn’t broken.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func prevPage() { pdfView.goToPreviousPage(nil) }
    private func nextPage() { pdfView.goToNextPage(nil) }

    // MARK: - Settings sheet

    @objc private func openSettings() {
        let sheet = PageTurnSettingsSheetViewController(settings: pageTurnSettings) { [weak self] newSettings in
            guard let self else { return }

            self.pageTurnSettings = newSettings
            PageTurnSettingsStore.shared.save(newSettings)

            // Reset gating so we don't instantly trigger on a held gesture
            self.wasSelectedGestureActive = false
            self.lastPageTurnTime = 0

            // Apply performance mode immediately
            self.applyPerformanceModeUI(animated: true)

            // If tilt is selected, recalibrate after closing
            if newSettings.gesture.isTilt {
                NotificationCenter.default.post(name: .requestTiltRecalibration, object: nil)
            }
        }

        let nav = UINavigationController(rootViewController: sheet)
        nav.view.tintColor = MPStyle.accentColor
        present(nav, animated: true)
    }

    @objc private func handleTiltRecalibrationRequest() {
        resetTiltBaseline()
    }

    private func resetTiltBaseline() {
        rollBaseline = nil
        rollBaselineSum = 0
        rollBaselineCount = 0
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        let b = faceAnchor.blendShapes

        let rawRoll = computeFaceRollRelativeToScreen(faceAnchor: faceAnchor, in: session)
        let roll = calibratedRoll(fromRaw: rawRoll)

        let input = BlendInput(
            jawOpen: b[.jawOpen]?.floatValue ?? 0,
            eyeBlinkLeft: b[.eyeBlinkLeft]?.floatValue ?? 0,
            eyeBlinkRight: b[.eyeBlinkRight]?.floatValue ?? 0,
            mouthSmileL: b[.mouthSmileLeft]?.floatValue ?? 0,
            mouthSmileR: b[.mouthSmileRight]?.floatValue ?? 0,
            browInnerUp: b[.browInnerUp]?.floatValue ?? 0,
            cheekPuff: b[.cheekPuff]?.floatValue ?? 0,
            tongueOut: b[.tongueOut]?.floatValue ?? 0,
            headRoll: roll
        )

        _ = detector.update(with: input, confidence: pageTurnSettings.confidence)

        let selected = pageTurnSettings.gesture
        let isActive = detector.isActive(selected)

        let now = CACurrentMediaTime()
        let cooledDown = (now - lastPageTurnTime) >= pageTurnCooldown
        
        if annotationOverlay.tool != .none { return }

        if isActive && !wasSelectedGestureActive && cooledDown {
            lastPageTurnTime = now
            DispatchQueue.main.async { [weak self] in
                self?.performPageTurn(for: selected)
                if self?.pageTurnSettings.performanceMode == true {
                    self?.scheduleChromeHide()
                }
            }
        }

        wasSelectedGestureActive = isActive
    }

    private func performPageTurn(for gesture: PageTurnGesture) {
        switch gesture {
        case .headTiltLeft:
            prevPage()
        case .headTiltRight:
            nextPage()
        default:
            nextPage()
        }
    }

    // MARK: - Roll + baseline

    private func calibratedRoll(fromRaw raw: Float) -> Float {
        if let baseline = rollBaseline {
            return normalizeRadians(raw - baseline)
        }

        rollBaselineSum += raw
        rollBaselineCount += 1
        if rollBaselineCount >= rollBaselineSamplesNeeded {
            rollBaseline = rollBaselineSum / Float(rollBaselineCount)
        }
        return 0
    }

    private func normalizeRadians(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }

    private func computeFaceRollRelativeToScreen(faceAnchor: ARFaceAnchor, in session: ARSession) -> Float {
        guard let frame = session.currentFrame else { return 0 }

        let faceInCamera = simd_mul(simd_inverse(frame.camera.transform), faceAnchor.transform)

        // Face "up" axis in camera coordinates (local +Y)
        let cols = faceInCamera.columns
        let faceUp = simd_normalize(simd_float3(cols.1.x, cols.1.y, cols.1.z))

        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait

        let screenUp: simd_float3
        let screenRight: simd_float3

        switch orientation {
        case .portrait:
            screenUp = simd_float3(0, 1, 0)
            screenRight = simd_float3(1, 0, 0)
        case .portraitUpsideDown:
            screenUp = simd_float3(0, -1, 0)
            screenRight = simd_float3(-1, 0, 0)
        case .landscapeLeft:
            screenUp = simd_float3(1, 0, 0)
            screenRight = simd_float3(0, -1, 0)
        case .landscapeRight:
            screenUp = simd_float3(-1, 0, 0)
            screenRight = simd_float3(0, 1, 0)
        default:
            screenUp = simd_float3(0, 1, 0)
            screenRight = simd_float3(1, 0, 0)
        }

        let u = screenUp
        let v = screenRight
        let projected = simd_normalize(u * simd_dot(faceUp, u) + v * simd_dot(faceUp, v))

        return atan2(simd_dot(projected, v), simd_dot(projected, u))
    }
    
    @objc private func toggleAnnotateUI() {
        let show = annotationToolbar.isHidden
        if show {
            annotationToolbar.isHidden = false
            UIView.animate(withDuration: 0.18) { self.annotationToolbar.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.18, animations: { self.annotationToolbar.alpha = 0 }) { _ in
                self.annotationToolbar.isHidden = true
                self.annotationOverlay.tool = .none
                self.annotationOverlay.updatePreviewStyle()
            }
        }
    }

    @objc private func markAnnotationsDirty() {
        annotationsDirty = true
    }

    private func saveAnnotationsIfNeeded() {
        guard annotationsDirty else { return }
        guard let doc = pdfView.document else { return }

        let ok = doc.write(to: pdfURL)
        if ok { annotationsDirty = false }
    }

    @objc private func appWillResignActive() {
        saveAnnotationsIfNeeded()
    }

}

