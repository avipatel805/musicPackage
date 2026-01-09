import SwiftUI
import UIKit

struct SheetMusicRootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: PDFLibraryViewController())
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
