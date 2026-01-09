import SwiftUI

struct SheetMusicRootView: View {
    @StateObject private var library = PDFLibrary()
    @State private var searchText: String = ""
    @State private var showingImporter = false
    @State private var selected: PDFItem?

    private var filtered: [PDFItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return library.items }
        return library.items.filter { $0.displayName.lowercased().contains(q.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.05, green: 0.06, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {

                    // Search bar
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.primary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                    // Title + New
                    HStack {
                        Text("All PDFs")
                            .font(.system(size: 44, weight: .bold, design: .serif))
                            .foregroundStyle(.white)

                        Spacer()

                        Button {
                            showingImporter = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                Text("New")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 18)

                    // Grid of cards
                    ScrollView {
                        let cols = [GridItem(.adaptive(minimum: 240), spacing: 18)]
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(filtered) { item in
                                PDFCardView(item: item, thumbnail: library.thumbnail(for: item.url))
                                    .onTapGesture { selected = item }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // future settings
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .fullScreenCover(item: $selected) { item in
                PDFViewerHost(url: item.url)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showingImporter) {
                PDFImportPicker { urls in
                    library.importPDFs(urls)
                }
            }
        }
        .tint(.blue)
    }
}

struct PDFViewerHost: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> PDFViewerViewController {
        PDFViewerViewController(pdfURL: url)
    }
    func updateUIViewController(_ uiViewController: PDFViewerViewController, context: Context) {}
}

