import UIKit
import UniformTypeIdentifiers

final class PDFLibraryViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let library: PDFLibrary
    private var items: [PDFItem] = []

    init(library: PDFLibrary = .shared) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
        self.title = "Sheet Music"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Import",
            style: .plain,
            target: self,
            action: #selector(importTapped)
        )

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        reloadLibrary()
    }

    private func reloadLibrary() {
        items = library.listPDFs()
        tableView.reloadData()
    }

    @objc private func importTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }
}

extension PDFLibraryViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.isEmpty ? 1 : items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)

        if items.isEmpty {
            var cfg = cell.defaultContentConfiguration()
            cfg.text = "No PDFs yet"
            cfg.secondaryText = "Tap Import to add sheet music"
            cfg.textProperties.color = .secondaryLabel
            cfg.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = cfg
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }

        let item = items[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = item.displayName
        cfg.secondaryText = item.fileName
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !items.isEmpty else { return }
        tableView.deselectRow(at: indexPath, animated: true)

        let item = items[indexPath.row]
        let vc = PDFViewerViewController(pdfURL: item.url)
        navigationController?.pushViewController(vc, animated: true)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !items.isEmpty
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, !items.isEmpty else { return }
        let item = items[indexPath.row]
        library.delete(item)
        reloadLibrary()
    }
}

extension PDFLibraryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls { _ = library.importPDF(from: url) }
        reloadLibrary()
    }
}

