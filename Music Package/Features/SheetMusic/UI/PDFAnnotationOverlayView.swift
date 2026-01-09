import UIKit
import PDFKit

final class PDFAnnotationOverlayView: UIView {

    enum Tool {
        case pen
        case highlighter
        case eraser
        case none
    }

    weak var pdfView: PDFView?

    var tool: Tool = .none
    var strokeColor: UIColor = .systemIndigo
    var strokeWidth: CGFloat = 2.5
    var pencilOnly: Bool = true

    // Current stroke (in view coordinates)
    private var currentPoints: [CGPoint] = []
    private var currentTouchIsPencil = false

    // Preview layer
    private let previewLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear

        previewLayer.fillColor = UIColor.clear.cgColor
        previewLayer.strokeColor = strokeColor.cgColor
        previewLayer.lineWidth = strokeWidth
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updatePreviewStyle() {
        switch tool {
        case .pen:
            previewLayer.strokeColor = strokeColor.cgColor
            previewLayer.lineWidth = strokeWidth
            previewLayer.opacity = 1.0
        case .highlighter:
            previewLayer.strokeColor = strokeColor.withAlphaComponent(0.35).cgColor
            previewLayer.lineWidth = max(strokeWidth, 6.0)
            previewLayer.opacity = 1.0
        case .eraser:
            previewLayer.strokeColor = UIColor.clear.cgColor
            previewLayer.opacity = 0.0
        case .none:
            previewLayer.strokeColor = UIColor.clear.cgColor
            previewLayer.opacity = 0.0
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tool != .none else { return }
        guard let t = touches.first else { return }

        currentTouchIsPencil = (t.type == .pencil)

        if pencilOnly && !currentTouchIsPencil {
            // Let PDFView handle finger gestures (pan/zoom/swipe)
            return
        }

        let p = t.location(in: self)
        currentPoints = [p]
        updatePreviewPath()

        // If erasing, erase immediately at the first point
        if tool == .eraser { erase(at: p) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tool != .none else { return }
        guard let t = touches.first else { return }

        if pencilOnly && t.type != .pencil { return }

        let p = t.location(in: self)

        if tool == .eraser {
            erase(at: p)
            return
        }

        currentPoints.append(p)
        updatePreviewPath()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tool != .none else { return }
        guard let t = touches.first else { return }

        if pencilOnly && t.type != .pencil { return }

        if tool == .eraser {
            clearPreview()
            return
        }

        // Convert stroke to PDF ink annotation
        commitInkAnnotation()
        clearPreview()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        clearPreview()
    }

    // MARK: - Preview path

    private func updatePreviewPath() {
        let path = UIBezierPath()
        guard let first = currentPoints.first else {
            previewLayer.path = nil
            return
        }
        path.move(to: first)
        for p in currentPoints.dropFirst() { path.addLine(to: p) }
        previewLayer.path = path.cgPath
    }

    private func clearPreview() {
        currentPoints.removeAll()
        previewLayer.path = nil
    }

    // MARK: - Commit annotation

    private func commitInkAnnotation() {
        guard let pdfView, let doc = pdfView.document else { return }
        guard currentPoints.count >= 2 else { return }

        // Determine which page the stroke belongs to (use first point)
        let viewPoint = currentPoints[0]

        guard
            let page = pdfView.page(for: viewPoint, nearest: true),
            let pagePoint = pdfView.convert(viewPoint, to: page) as CGPoint?
        else { return }

        // Build ink paths in page coordinates. We convert each point to page coords.
        let inkPath = UIBezierPath()
        let firstPagePoint = pdfView.convert(currentPoints[0], to: page)
        inkPath.move(to: firstPagePoint)
        for p in currentPoints.dropFirst() {
            inkPath.addLine(to: pdfView.convert(p, to: page))
        }

        // Annotation bounds: tight bounding box around path (in page coords)
        let bounds = inkPath.bounds.insetBy(dx: -strokeWidth * 2, dy: -strokeWidth * 2)

        let ann = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ann.add(inkPath)

        switch tool {
        case .pen:
            ann.color = strokeColor // full opacity
            let border = PDFBorder()
            border.lineWidth = strokeWidth
            ann.border = border

        case .highlighter:
            ann.color = strokeColor.withAlphaComponent(0.35) // transparency here
            let border = PDFBorder()
            border.lineWidth = max(strokeWidth, 6.0)
            ann.border = border

        default:
            break
        }


        page.addAnnotation(ann)

        // If user is zoomed/panned, ask PDFView to refresh
        pdfView.setNeedsDisplay()

        // Keep doc “dirty” for your controller to save later
        NotificationCenter.default.post(name: .pdfDidChangeAnnotations, object: doc)
        _ = pagePoint // avoid warning in some builds
    }

    // MARK: - Eraser

    private func erase(at viewPoint: CGPoint) {
        guard let pdfView else { return }
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }

        let pagePoint = pdfView.convert(viewPoint, to: page)

        // Find annotations under point (simple hit-test)
        // PDFAnnotation doesn't provide a direct hit test; bounding-box check works well for ink/highlight.
        let toRemove = page.annotations.filter { $0.bounds.insetBy(dx: -6, dy: -6).contains(pagePoint) }

        guard !toRemove.isEmpty else { return }
        toRemove.forEach { page.removeAnnotation($0) }

        pdfView.setNeedsDisplay()
        if let doc = pdfView.document {
            NotificationCenter.default.post(name: .pdfDidChangeAnnotations, object: doc)
        }
    }
}

extension Notification.Name {
    static let pdfDidChangeAnnotations = Notification.Name("pdfDidChangeAnnotations")
}

