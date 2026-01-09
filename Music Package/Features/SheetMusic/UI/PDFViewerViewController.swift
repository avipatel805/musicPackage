import UIKit
import PDFKit

final class PDFViewerViewController: UIViewController, UIGestureRecognizerDelegate {

    private let pdfURL: URL
    private let pdfView = PDFView(frame: .zero)

    // Annotation engine (your existing overlay)
    private let annotationOverlay = PDFAnnotationOverlayView()

    // Floating Notability-like toolbar
    private let floatingToolbar = NotabilityToolbarView()

    // Floating back chevron (blurred pill)
    private let backButtonBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let backButton = UIButton(type: .system)

    // ✅ Tap recognizer should be on the top-level view (not PDFView),
    // because PDFKit can swallow taps when it's handling selection/scroll.
    private lazy var chromeTapRecognizer: UITapGestureRecognizer = {
        let gr = UITapGestureRecognizer(target: self, action: #selector(handleTapZones(_:)))
        gr.delegate = self
        gr.cancelsTouchesInView = false
        return gr
    }()

    // Saving
    private var annotationsDirty = false

    // Chrome (auto-hide)
    private var chromeHidden = false
    private var chromeTimer: Timer?

    init(pdfURL: URL) {
        self.pdfURL = pdfURL
        super.init(nibName: nil, bundle: nil)
        self.title = pdfURL.deletingPathExtension().lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

        // ✅ Add tap recognizer to the controller's root view (reliable)
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

        // Floating toolbar (Notability style)
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

        // Floating back button (aligned to toolbar height)
        configureFloatingBackButton()

        loadPDF()

        NotificationCenter.default.addObserver(self, selector: #selector(markAnnotationsDirty),
                                               name: .pdfDidChangeAnnotations, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        // Start with chrome visible, then auto-hide shortly after opening
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.scheduleChromeHideIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyZoomLimits()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveAnnotationsIfNeeded()
        chromeTimer?.invalidate()
        chromeTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Back button micro-polish

    @objc private func backButtonDown() {
        UIView.animate(withDuration: 0.1) {
            self.backButtonBlur.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
    }

    @objc private func backButtonUp() {
        UIView.animate(withDuration: 0.1) {
            self.backButtonBlur.transform = .identity
        }
    }

    private func configureFloatingBackButton() {
        backButtonBlur.translatesAutoresizingMaskIntoConstraints = false
        backButtonBlur.layer.cornerRadius = 20
        backButtonBlur.clipsToBounds = true

        // Shadow (matches toolbar)
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

        // Chevron button inside blur
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.addTarget(self, action: #selector(dismissToLibrary), for: .touchUpInside)

        // Micro-polish (press animation)
        backButton.addTarget(self, action: #selector(backButtonDown), for: .touchDown)
        backButton.addTarget(self, action: #selector(backButtonUp),
                             for: [.touchUpInside, .touchCancel, .touchUpOutside])

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

    // MARK: - PDF

    private func loadPDF() {
        guard let doc = PDFDocument(url: pdfURL) else { return }
        pdfView.document = doc
        pdfView.goToFirstPage(nil)
        applyZoomLimits()
    }

    // Prevent infinite zoom-out: min zoom = fit-to-screen
    private func applyZoomLimits() {
        let fit = pdfView.scaleFactorForSizeToFit
        pdfView.minScaleFactor = fit
        pdfView.maxScaleFactor = max(fit * 4.0, 4.0)
        if pdfView.scaleFactor < fit { pdfView.scaleFactor = fit }
    }

    // MARK: - Tap zones + Chrome reveal

    @objc private func handleTapZones(_ gr: UITapGestureRecognizer) {
        let p = gr.location(in: view) // ✅ use root view coordinates
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }

        // Any interaction counts as activity
        // (so if chrome is already visible, it stays up a bit longer)
        if !chromeHidden {
            scheduleChromeHideIfNeeded()
        }

        // 🔝 Top reveal zone (tap near top to show controls)
        let topRevealHeight = h * 0.22
        if p.y < topRevealHeight {
            setChromeHidden(false, animated: true)
            scheduleChromeHideIfNeeded()
            return
        }

        // Page turn zones (only apply if tap is within the PDF view area)
        // Translate tap point into pdfView space
        let pInPDF = gr.location(in: pdfView)
        let pdfW = pdfView.bounds.width
        let pdfH = pdfView.bounds.height
        guard pdfW > 0, pdfH > 0 else { return }

        let left = pdfW / 3.0
        let right = 2.0 * pdfW / 3.0

        if pInPDF.x < left {
            pdfView.goToPreviousPage(nil)
            scheduleChromeHideIfNeeded()
        } else if pInPDF.x > right {
            pdfView.goToNextPage(nil)
            scheduleChromeHideIfNeeded()
        } else {
            toggleChrome()
        }
    }

    // ✅ Make our tap recognizer work alongside PDFKit’s internal recognizers
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // ✅ Give our tap priority when PDFKit has competing taps
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // If PDFKit has internal tap recognizers, we still want ours to fire.
        // Returning false means we don't require others to fail.
        return false
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
            self.navigationController?.setNavigationBarHidden(true, animated: false) // keep real nav hidden
            self.floatingToolbar.alpha = hidden ? 0 : 1
            self.backButtonBlur.alpha = hidden ? 0 : 1
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

