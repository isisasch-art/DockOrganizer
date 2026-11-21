import SwiftUI
import UniformTypeIdentifiers

struct FolderRequest: Identifiable {
    let id = UUID()
    var preselected: [URL]
}

// MARK: - Ordner-Logik

extension DockStore {
    /// Hier landen alle Ordner, die der Dock Organizer anlegt.
    static var folderRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dock-Ordner", isDirectory: true)
    }

    /// Öffnet das „Neuer Ordner“-Sheet. Ohne Angabe werden die im Editor markierten Apps vorausgewählt.
    func requestNewFolder(with items: [DockItem]? = nil) {
        let source = items ?? (apps + others).filter { selection.contains($0.id) }
        let urls = source.compactMap { $0.url }.filter { $0.pathExtension == "app" }
        folderRequest = FolderRequest(preselected: urls)
    }

    /// Legt einen echten Ordner mit Finder-Aliassen der Apps an und fügt ihn rechts ins Dock ein.
    @discardableResult
    func createFolder(name: String, apps appURLs: [URL], removeFromDock: Bool,
                      displayAs: Int, showAs: Int) throws -> DockItem {
        let fm = FileManager.default
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var dir = Self.folderRoot.appendingPathComponent(safe, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = Self.folderRoot.appendingPathComponent("\(safe) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeAliases(appURLs, into: dir)

        if removeFromDock {
            let paths = Set(appURLs.map(\.standardizedFileURL.path))
            apps.removeAll { item in item.url.map { paths.contains($0.standardizedFileURL.path) } ?? false }
        }

        var folder = DockItem.folder(dir)
        folder.setTileValue("file-label", dir.lastPathComponent)
        folder.setTileValue("displayas", displayAs)
        folder.setTileValue("showas", showAs)
        others.append(folder)
        return folder
    }

    /// Apps (per Dateiauswahl) in einen bestehenden Dock-Ordner legen.
    func addApps(toFolder item: DockItem) {
        guard let dir = item.url else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "In Ordner legen")
        guard panel.runModal() == .OK else { return }
        do {
            try writeAliases(panel.urls, into: dir)
        } catch {
            showToast(String(localized: "Apps konnten nicht in den Ordner gelegt werden: \(error.localizedDescription)"), error: true)
        }
    }

    private func writeAliases(_ urls: [URL], into dir: URL) throws {
        for url in urls {
            let data = try url.bookmarkData(options: .suitableForBookmarkFile,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            var target = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n)")
                n += 1
            }
            try URL.writeBookmarkData(data, to: target)
        }
    }

    // MARK: Namensvorschlag aus App-Store-Kategorie

    private static let categoryNames: [String: String] = [
        "developer-tools": String(localized: "Entwicklung"), "productivity": String(localized: "Produktivität"),
        "graphics-design": String(localized: "Design"), "photography": String(localized: "Fotografie"),
        "video": String(localized: "Video"), "music": String(localized: "Musik"),
        "social-networking": String(localized: "Kommunikation"), "utilities": String(localized: "Dienstprogramme"),
        "business": String(localized: "Business"), "entertainment": String(localized: "Unterhaltung"),
        "education": String(localized: "Bildung"), "finance": String(localized: "Finanzen"),
        "news": String(localized: "News"), "reference": String(localized: "Nachschlagen"),
        "lifestyle": String(localized: "Lifestyle"), "travel": String(localized: "Reisen"),
        "weather": String(localized: "Wetter"), "healthcare-fitness": String(localized: "Gesundheit"),
        "sports": String(localized: "Sport"), "medical": String(localized: "Medizin"),
    ]

    static func suggestedName(for urls: [URL]) -> String? {
        let cats: [String] = urls.compactMap { url in
            guard let raw = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String else { return nil }
            let key = raw.replacingOccurrences(of: "public.app-category.", with: "")
            return key.hasSuffix("games") ? String(localized: "Spiele") : categoryNames[key]
        }
        let counts = Dictionary(cats.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }
}

// MARK: - Sheet „Neuer Ordner“

struct NewFolderSheet: View {
    @EnvironmentObject var store: DockStore
    @Environment(\.dismiss) private var dismiss
    let request: FolderRequest

    @State private var name = ""
    @State private var nameEdited = false
    @State private var candidates: [URL] = []
    @State private var chosen = Set<URL>()
    @State private var removeFromDock = true
    @State private var applyNow = true
    @State private var displayAs = 1   // Ordner
    @State private var showAs = 2      // Raster
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus").font(.title).foregroundStyle(Color.accentColor)
                TextField("Ordnername", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .focused($nameFocused)
                    .onChange(of: name) { _, _ in if nameFocused { nameEdited = true } }
                    .onSubmit(create)
            }

            HStack {
                Text("Apps auswählen · \(chosen.count) gewählt").font(.headline)
                Spacer()
                Button("Alle") { chosen = Set(candidates) }.disabled(chosen.count == candidates.count)
                Button("Keine") { chosen.removeAll() }.disabled(chosen.isEmpty)
                Button {
                    pickOtherApps()
                } label: {
                    Label("Andere App …", systemImage: "plus")
                }
            }
            .buttonStyle(.borderless)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(candidates, id: \.self) { url in
                        AppToggleTile(url: url, isOn: chosen.contains(url)) {
                            if chosen.contains(url) { chosen.remove(url) } else { chosen.insert(url) }
                        }
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            HStack(spacing: 20) {
                Picker("Anzeigen als", selection: $displayAs) {
                    Text("Ordner").tag(1)
                    Text("Stapel").tag(0)
                }
                .fixedSize()
                Picker("Inhalt", selection: $showAs) {
                    Text("Raster").tag(2)
                    Text("Liste").tag(3)
                    Text("Fächer").tag(1)
                    Text("Automatisch").tag(0)
                }
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Gewählte Apps aus dem Dock entfernen", isOn: $removeFromDock)
                Toggle("Sofort auf Dock anwenden", isOn: $applyNow)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if chosen.isEmpty {
                Text("Wähle mindestens eine App für den Ordner aus.").foregroundStyle(.secondary).font(.callout)
            }

            HStack {
                Text("Wird angelegt in ~/Dock-Ordner/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ordner erstellen", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(finalName.isEmpty || chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear(perform: setup)
        .onChange(of: chosen) { _, _ in updateSuggestion() }
    }

    private var finalName: String { name.trimmingCharacters(in: .whitespaces) }

    private func setup() {
        // Jede App nur einmal anbieten – steht sie doppelt im Dock, entstünden sonst zwei Aliasse
        var urls: [URL] = []
        for u in store.apps.compactMap(\.url) + request.preselected where u.pathExtension == "app" && !urls.contains(u) {
            urls.append(u)
        }
        candidates = urls
        chosen = Set(request.preselected)
        updateSuggestion()
        nameFocused = true
    }

    private func updateSuggestion() {
        guard !nameEdited else { return }
        name = DockStore.suggestedName(for: Array(chosen)) ?? (chosen.isEmpty ? "" : String(localized: "Neuer Ordner"))
    }

    private func pickOtherApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for u in panel.urls {
            if !candidates.contains(u) { candidates.append(u) }
            chosen.insert(u)
        }
    }

    private func create() {
        // Ohne gewählte App entstünde ein leerer Ordner (Enter im Namensfeld umgeht den gesperrten Knopf)
        guard !finalName.isEmpty, !chosen.isEmpty else { return }
        // Reihenfolge wie im Raster beibehalten
        let ordered = candidates.filter { chosen.contains($0) }
        do {
            try store.createFolder(name: finalName, apps: ordered, removeFromDock: removeFromDock,
                                   displayAs: displayAs, showAs: showAs)
            if applyNow { store.apply() }
            dismiss()
        } catch {
            self.error = String(localized: "Ordner konnte nicht erstellt werden: \(error.localizedDescription)")
        }
    }
}

struct AppToggleTile: View {
    let url: URL
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 80, height: 74)
            .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color.accentColor.opacity(0.18) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
