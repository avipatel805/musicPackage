//
//  PDFLibrary.swift
//  Music Package
//
//  Created by Avi Patel on 12/19/25.
//

import Foundation

final class PDFLibrary {
    static let shared = PDFLibrary()
    private init() {}

    private let fm = FileManager.default

    private var documentsDir: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func listPDFs() -> [PDFItem] {
        let urls = (try? fm.contentsOfDirectory(
            at: documentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { PDFItem(url: $0) }
    }

    /// Imports a PDF into the app's Documents directory. Returns destination URL if successful.
    @discardableResult
    func importPDF(from sourceURL: URL) -> URL? {
        let needsSecurity = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsSecurity { sourceURL.stopAccessingSecurityScopedResource() } }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension

        var destURL = documentsDir.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while fm.fileExists(atPath: destURL.path) {
            destURL = documentsDir.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }

        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            return destURL
        } catch {
            // Fallback: read/write
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destURL, options: [.atomic])
                return destURL
            } catch {
                print("PDF import failed:", error.localizedDescription)
                return nil
            }
        }
    }

    func delete(_ item: PDFItem) {
        do { try fm.removeItem(at: item.url) }
        catch { print("Delete failed:", error.localizedDescription) }
    }
}
