import SwiftUI

enum SidebarItem: Hashable {
    case editor, options, profile(UUID)
}

// MARK: - Hauptfenster

struct ContentView: View {
    @EnvironmentObject var store: DockStore
    @State private var selection: SidebarItem? = .editor
    @State private var showNewProfile = false
    @State private var profileToDelete: DockProfile?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Dock") {
                    Label("Anordnung", systemImage: "dock.rectangle").tag(SidebarItem.editor)
                    Label("Optionen", systemImage: "slider.horizontal.3").tag(SidebarItem.options)
                }
                Section("Profile") {
                    ForEach(store.profiles) { p in
                        HStack {
                            Label(p.name, systemImage: "square.stack.3d.up")
                            Spacer()
                            if let hk = p.hotkey {
                                Text(hk.display).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if p.locked {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            }
                            if store.activeProfileID == p.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .tag(SidebarItem.profile(p.id))
                        .contextMenu {
                            Button("Auf Dock anwenden") { store.applyProfile(p) }
                            Button("Exportieren …") { store.exportProfile(p.id) }
                            Divider()
                            Button("Löschen …", role: .destructive) { profileToDelete = p }
                        }
                    }
                    .onMove { store.moveProfiles(from: $0, to: $1) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { showNewProfile = true } label: {
                        Label("Neues Profil", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        if let p = store.importProfile() { selection = .profile(p.id) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Profil importieren")
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            Group {
                switch selection {
                case .options: OptionsView()
                case .profile(let id): ProfileDetailView(profileID: id, selection: $selection)
                default: EditorView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if store.hasChanges { ChangesBar() }
            }
        }
        .confirmationDialog("Profil „\(profileToDelete?.name ?? "")“ löschen?",
                            isPresented: Binding(get: { profileToDelete != nil },
                                                 set: { if !$0 { profileToDelete = nil } })) {
            Button("Löschen", role: .destructive) {
                if let p = profileToDelete {
                    store.deleteProfile(p.id)
                    if selection == .profile(p.id) { selection = .editor }
                }
                profileToDelete = nil
            }
        } message: {
            if profileToDelete?.locked == true {
                Text("Das Profil ist gesperrt (z. B. dein Backup). Löschen lässt sich nicht rückgängig machen.")
            }
        }
        .sheet(isPresented: $showNewProfile) {
            NewProfileSheet { name in
                let p = store.saveProfile(name: name)
                selection = .profile(p.id)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Label(t.text, systemImage: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(t.isError ? .orange : .green)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(.regularMaterial))
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
        .sheet(item: $store.folderRequest) { req in
            NewFolderSheet(request: req)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !store.hasChanges { store.reload() }
        }
    }
}

struct ChangesBar: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nicht angewendete Änderungen")
                if store.savesIntoActiveProfile, let p = store.editorProfile {
                    Text("Wird auch in Profil „\(p.name)“ gespeichert").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Verwerfen") { store.reload() }
            Button("Auf Dock anwenden") { store.apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Dock-Vorschau

struct DockPreview: View {
    let apps: [DockItem]
    let others: [DockItem]
    var iconSize: CGFloat = 44
    /// Gesetzt → beim Überfahren erscheint ein ✕ zum Entfernen
    var onRemove: ((DockItem.ID) -> Void)? = nil
    @State private var hovered: DockItem.ID?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(apps) { tile($0) }
            if !others.isEmpty {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: iconSize * 0.8).padding(.horizontal, 6)
            }
            ForEach(others) { tile($0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func tile(_ item: DockItem) -> some View {
        tileContent(item)
            .overlay(alignment: .topLeading) {
                if let onRemove, hovered == item.id {
                    Button { onRemove(item.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    .help("Aus dem Dock entfernen")
                }
            }
            .onHover { inside in
                if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
            }
    }

    @ViewBuilder
    private func tileContent(_ item: DockItem) -> some View {
        if item.isSpacer {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary.opacity(0.35))
                .frame(width: item.isSmallSpacer ? iconSize * 0.4 : iconSize, height: iconSize)
                .help(item.label)
        } else {
            Image(nsImage: IconCache.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .opacity(item.isMissing ? 0.3 : 1)
                .help(item.label)
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    @EnvironmentObject var store: DockStore
    @State private var isDropTarget = false
    @AppStorage("showLibrary") private var showLibrary = true

    var body: some View {
        VStack(spacing: 0) {
            DockPreview(apps: store.apps, others: store.others, onRemove: { store.remove(ids: [$0]) })
                .dropDestination(for: URL.self) { urls, _ in
                    store.add(urls: urls)
                    return !urls.isEmpty
                }
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            List(selection: $store.selection) {
                Section {
                    ForEach(store.apps) { DockItemRow(item: $0) }
                        .onMove { store.apps.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { store.apps.remove(atOffsets: $0) }
                } header: {
                    Text("Apps · \(store.apps.filter { !$0.isSpacer }.count)")
                }
                Section {
                    ForEach(store.others) { DockItemRow(item: $0) }
                        .onMove { store.others.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { store.others.remove(atOffsets: $0) }
                } header: {
                    HStack {
                        Text("Ordner & Dokumente · \(store.others.filter { !$0.isSpacer }.count)")
                        Spacer()
                        Button {
                            store.requestNewFolder()
                        } label: {
                            Label("Neuer Ordner", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
            .onDeleteCommand {
                store.remove(ids: store.selection)
                store.selection.removeAll()
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls: urls)
                return !urls.isEmpty
            } isTargeted: { isDropTarget = $0 }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                }
            }

            Text("Ziehen zum Sortieren · Maus über Eintrag → ⊖ entfernt · Apps markieren + ⌘N = neuer Ordner")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .navigationTitle("Anordnung")
        .navigationSubtitle(store.editorProfile.map {
            $0.locked ? String(localized: "Profil: \($0.name) (gesperrt)") : String(localized: "Profil: \($0.name)")
        } ?? "")
        .inspector(isPresented: $showLibrary) {
            AppLibraryView()
                .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showLibrary.toggle()
                } label: {
                    Label("Apps hinzufügen", systemImage: "square.grid.2x2")
                }
                .help("App-Bibliothek ein-/ausblenden")
            }
            ToolbarItemGroup {
                Button {
                    store.requestNewFolder()
                } label: {
                    Label("Neuer Ordner", systemImage: "folder.badge.plus")
                }
                .help("Neuer Ordner aus Apps (⌘N)")
                .keyboardShortcut("n")

                Menu {
                    Button("App …") { store.pickApps() }
                    Button("Ordner oder Dokument …") { store.pickFolders() }
                    Divider()
                    Button("Abstand") { store.addSpacer(small: false, after: store.selection.first) }
                    Button("Kleiner Abstand") { store.addSpacer(small: true, after: store.selection.first) }
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .help("Hinzufügen")

                Menu {
                    Button("Gruppen alphabetisch sortieren") { store.sortAlphabetically() }
                    Button("Duplikate entfernen") { store.removeDuplicates() }
                    Button("Fehlende Einträge entfernen (\(store.missingCount))") { store.removeMissing() }
                        .disabled(store.missingCount == 0)
                    Divider()
                    Button("Alle Abstände entfernen") { store.removeSpacers() }
                } label: {
                    Label("Aufräumen", systemImage: "wand.and.stars")
                }
                .help("Aufräumen")

                Button { store.reload() } label: {
                    Label("Neu laden", systemImage: "arrow.clockwise")
                }
                .help("Aktuelles Dock neu einlesen")
            }
        }
    }
}

struct DockItemRow: View {
    @EnvironmentObject var store: DockStore
    let item: DockItem
    @State private var hovering = false

    private var moveLabel: String {
        let n = store.selection.contains(item.id) ? store.selection.count : 1
        return n > 1 ? String(localized: "\(n) Apps in neuen Ordner …") : String(localized: "In neuen Ordner …")
    }

    var body: some View {
        HStack(spacing: 10) {
            if item.isSpacer {
                Image(systemName: "arrow.left.and.right")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: IconCache.icon(for: item))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .opacity(item.isMissing ? 0.4 : 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).foregroundStyle(item.isSpacer ? .secondary : .primary)
                if let url = item.url, !item.isSpacer {
                    Text(url.isFileURL ? url.path : url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if item.isMissing {
                Label("Fehlt", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(item.kind)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
            Button {
                store.remove(ids: [item.id])
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Aus dem Dock entfernen")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = item.url, url.isFileURL {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if item.isFolder {
                Menu("Anzeigen als") {
                    Button("Stapel") { store.update(item.id) { $0.setTileValue("displayas", 0) } }
                    Button("Ordner") { store.update(item.id) { $0.setTileValue("displayas", 1) } }
                }
                Menu("Inhalt zeigen als") {
                    Button("Automatisch") { store.update(item.id) { $0.setTileValue("showas", 0) } }
                    Button("Fächer") { store.update(item.id) { $0.setTileValue("showas", 1) } }
                    Button("Raster") { store.update(item.id) { $0.setTileValue("showas", 2) } }
                    Button("Liste") { store.update(item.id) { $0.setTileValue("showas", 3) } }
                }
                Menu("Sortieren nach") {
                    Button("Name") { store.update(item.id) { $0.setTileValue("arrangement", 1) } }
                    Button("Hinzugefügt") { store.update(item.id) { $0.setTileValue("arrangement", 2) } }
                    Button("Geändert") { store.update(item.id) { $0.setTileValue("arrangement", 3) } }
                    Button("Erstellt") { store.update(item.id) { $0.setTileValue("arrangement", 4) } }
                    Button("Art") { store.update(item.id) { $0.setTileValue("arrangement", 5) } }
                }
            }
            if item.isApp {
                Button(moveLabel) {
                    let sel = store.selection.contains(item.id)
                        ? (store.apps + store.others).filter { store.selection.contains($0.id) }
                        : [item]
                    store.requestNewFolder(with: sel)
                }
            }
            if item.isFolder {
                Button("Apps in diesen Ordner legen …") { store.addApps(toFolder: item) }
            }
            Button("Abstand dahinter einfügen") { store.addSpacer(small: false, after: item.id) }
            Divider()
            Button("Entfernen", role: .destructive) { store.remove(ids: [item.id]) }
        }
    }
}

// MARK: - Optionen

struct OptionsView: View {
    @EnvironmentObject var store: DockStore

    var body: some View {
        Form {
            Section("Darstellung") {
                LabeledContent("Größe") {
                    HStack {
                        Slider(value: $store.settings.tilesize, in: 16...128)
                        Text("\(Int(store.settings.tilesize)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Vergrößerung", isOn: $store.settings.magnification)
                LabeledContent("Vergrößerte Größe") {
                    HStack {
                        Slider(value: $store.settings.largesize, in: 16...128)
                        Text("\(Int(store.settings.largesize)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!store.settings.magnification)
                Picker("Position", selection: $store.settings.orientation) {
                    Text("Links").tag("left")
                    Text("Unten").tag("bottom")
                    Text("Rechts").tag("right")
                }
                .pickerStyle(.segmented)
            }
            Section("Verhalten") {
                Toggle("Dock automatisch ein- und ausblenden", isOn: $store.settings.autohide)
                Toggle("Zuletzt benutzte Apps im Dock anzeigen", isOn: $store.settings.showRecents)
                Toggle("Fenster in App-Symbol ablegen", isOn: $store.settings.minimizeToApp)
                Picker("Effekt beim Ablegen", selection: $store.settings.mineffect) {
                    Text("Trichter").tag("genie")
                    Text("Linear").tag("scale")
                }
            }
            Section("Profile im Dock") {
                Toggle(isOn: Binding(get: { store.switcherEnabled }, set: { store.setSwitcherEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("„Profile“-Stapel im Dock anzeigen")
                        Text("Ein Klick auf den Stapel zeigt alle Profile – ein Klick auf ein Profil wechselt sofort.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            AppBehaviorSection()
            Section {
                Text("Dock-Änderungen werden erst mit „Auf Dock anwenden“ (⌘S) übernommen. Dabei startet das Dock kurz neu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Optionen")
    }
}

// MARK: - Profil-Ansicht

struct ProfileDetailView: View {
    @EnvironmentObject var store: DockStore
    let profileID: UUID
    @Binding var selection: SidebarItem?
    @State private var confirmDelete = false
    @State private var confirmOverwrite = false
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private func commitName(_ id: UUID? = nil) {
        let id = id ?? profileID
        let original = store.profiles.first(where: { $0.id == id })?.name ?? ""
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if id == profileID { nameDraft = original }   // Leerer Name → alten wiederherstellen
        } else {
            store.renameProfile(id, to: trimmed)
        }
    }

    /// Erst beim Bestätigen / Verlassen speichern – nicht bei jedem Tastendruck
    private func nameField(_ p: DockProfile) -> some View {
        TextField("Name", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(.largeTitle.bold())
            .focused($nameFocused)
            .onSubmit { commitName() }
            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            .onAppear { nameDraft = p.name }
            .onChange(of: profileID) { old, new in
                commitName(old)
                nameDraft = store.profiles.first(where: { $0.id == new })?.name ?? ""
            }
            .onDisappear { commitName() }
    }

    var body: some View {
        if let p = store.profiles.first(where: { $0.id == profileID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField(p)

                    Text("\(p.appCount) Apps · \(p.otherCount) Ordner/Dokumente · erstellt \(p.created.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)

                    DockPreview(apps: p.apps, others: p.others, iconSize: 48)

                    Toggle(isOn: Binding(get: { p.locked }, set: { store.setLocked(p.id, $0) })) {
                        Text("Gesperrt – Änderungen im Editor nicht automatisch in dieses Profil speichern")
                    }

                    HotkeyPicker(profileID: p.id)

                    HStack {
                        Button {
                            store.applyProfile(p)
                        } label: {
                            Label("Auf Dock anwenden", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("Im Editor öffnen") {
                            store.openInEditor(p)
                            selection = .editor
                        }
                        .controlSize(.large)

                        Spacer()

                        Menu {
                            Button("Mit aktueller Anordnung überschreiben") { confirmOverwrite = true }
                            Button("Duplizieren") {
                                if let c = store.duplicateProfile(p.id) { selection = .profile(c.id) }
                            }
                            Button("Exportieren …") { store.exportProfile(p.id) }
                            Divider()
                            Button("Löschen", role: .destructive) { confirmDelete = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    if let s = p.settings {
                        GroupBox("Dock-Optionen in diesem Profil") {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                                GridRow { Text("Größe").foregroundStyle(.secondary); Text("\(Int(s.tilesize)) pt") }
                                GridRow { Text("Position").foregroundStyle(.secondary); Text(s.orientation == "left" ? "Links" : s.orientation == "right" ? "Rechts" : "Unten") }
                                GridRow { Text("Ausblenden").foregroundStyle(.secondary); Text(s.autohide ? "Automatisch" : "Nein") }
                                GridRow { Text("Vergrößerung").foregroundStyle(.secondary); Text(s.magnification ? "\(Int(s.largesize)) pt" : "Aus") }
                                GridRow { Text("Zuletzt benutzt").foregroundStyle(.secondary); Text(s.showRecents ? "Anzeigen" : "Ausblenden") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle(p.name)
            .confirmationDialog("Profil „\(p.name)“ löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) {
                    store.deleteProfile(p.id)
                    selection = .editor
                }
            }
            .confirmationDialog("Profil mit der aktuellen Anordnung im Editor überschreiben?", isPresented: $confirmOverwrite) {
                Button("Überschreiben") { store.updateProfile(p.id) }
            }
        } else {
            ContentUnavailableView("Profil nicht gefunden", systemImage: "questionmark.folder")
        }
    }
}

struct NewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Neues Profil").font(.title2.bold())
            Text("Speichert die aktuelle Anordnung und die Dock-Optionen als Profil – z. B. „Arbeit“, „Design“ oder „Freizeit“.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n)
        dismiss()
    }
}
