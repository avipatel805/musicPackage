import Foundation

struct PDFItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let displayName: String
    let createdAt: Date

    init(url: URL, createdAt: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.displayName = url.deletingPathExtension().lastPathComponent
        self.createdAt = createdAt
    }
}

