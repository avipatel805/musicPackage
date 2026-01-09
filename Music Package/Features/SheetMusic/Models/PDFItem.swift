//
//  PDFItem.swift
//  Music Package
//
//  Created by Avi Patel on 12/19/25.
//

import Foundation

struct PDFItem: Identifiable, Equatable {
    let url: URL

    var id: String { url.path } // stable identifier
    var fileName: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}
