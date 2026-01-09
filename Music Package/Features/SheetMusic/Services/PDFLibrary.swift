import Foundation
import PDFKit
import UIKit

@MainActor
final class PDFLibrary: ObservableObject {
    @Published private(set) var items: [PDFItem] = []

    private let fm = FileManager.default
    private let folderName = "ImportedPDFs"

    private var thumbCache: [URL: UIImage] = [:]

    init() {
        reload()
    }

    private var folderURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent(folderName, isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func reload() {
        let folder = folderURL
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

        let mapped: [PDFItem] = pdfs.map { url in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return PDFItem(url: url, createdAt: created)
        }
        .sorted(by: { $0.createdAt > $1.createdAt })

        self.items = mapped
    }

    func importPDFs(_ urls: [URL]) {
        let destFolder = folderURL

        for src in urls {
            let base = src.deletingPathExtension().lastPathComponent
            var dest = destFolder.appendingPathComponent(base).appendingPathExtension("pdf")

            var i = 2
            while fm.fileExists(atPath: dest.path) {
                dest = destFolder.appendingPathComponent("\(base) \(i)").appendingPathExtension("pdf")
                i += 1
            }

            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }

            do {
                try fm.copyItem(at: src, to: dest)
            } catch {
                // fallback for providers that dislike copyItem
                if let data = try? Data(contentsOf: src) {
                    try? data.write(to: dest)
                }
            }
        }

        // Clear thumbnails for new imports
        thumbCache.removeAll()
        reload()
    }

    func thumbnail(for url: URL, targetWidth: CGFloat = 900) -> UIImage? {
        if let cached = thumbCache[url] { return cached }
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }

        let pageRect = page.bounds(for: .mediaBox)
        let scale = targetWidth / max(pageRect.width, 1)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }

        thumbCache[url] = img
        return img
    }
}

