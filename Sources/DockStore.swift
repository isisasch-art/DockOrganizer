import AppKit
import UniformTypeIdentifiers
import os

let dockLog = Logger(subsystem: "local.dockorganizer", category: "dock")

@MainActor
final class DockStore: ObservableObject {
    static let shared = DockStore()

    @Published var apps: [DockItem] = [] { didSet { track() } }
    @Published var others: [DockItem] = [] { didSet { track() } }
    @Published var settings = DockSettings() { didSet { if settings != oldValue { track() } } }
    @Published var profiles: [DockProfile] = []
    @Published var hasChanges = false
    @Published var activeProfileID: UUID? {
        didSet {
            UserDefaults.standard.set(activeProfileID?.uuidString, forKey: "activeProfile")
            syncSwitcherFiles()
        }
    }

    /// Auswahl im Editor (geteilt, damit Kontextmenüs mehrere Einträge kennen)
    @Published var selection = Set<DockItem.ID>()
    /// Gesetzt → Sheet „Neuer Ordner“ wird angezeigt
    @Published var folderRequest: FolderRequest?
    /// Kurze Rückmeldung unten im Fenster
    @Published var toast: Toast?

    private var tracking = true
    /// Stand, der gerade wirklich im Dock ist – „Änderungen“ = Abweichung davon.
    private var baselineItems = ""
    private var baselineSettings = DockSettings()

    init() {
        activeProfileID = UserDefaults.standard.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:))
        reload()
        loadProfiles()
        if profiles.isEmpty {
            let p = saveProfile(name: "Original (Backup)")
            setLocked(p.id, true)
        }
        HotkeyManager.shared.register(profiles)
    }

    /// Leiste „Nicht angewendete Änderungen“ nur zeigen, wenn sich der Editor wirklich vom Dock unterscheidet
    /// (nicht schon, wenn etwas verschoben und wieder zurückgeschoben oder ein identisches Profil geöffnet wurde).
    private func track() {
        guard tracking else { return }
        let changed = itemsFingerprint() != baselineItems || settings != baselineSettings
        if hasChanges != changed { hasChanges = changed }
    }

    private func markAsInDock() {
        baselineItems = itemsFingerprint()
        baselineSettings = settings
        hasChanges = false
    }

    /// Alles, was beim Anwenden zählt – ohne den „Profile“-Stapel, der separat verwaltet wird.
    private func itemsFingerprint() -> String {
        func fp(_ item: DockItem) -> String {
            [Self.signature(item), item.label, "\(item.displayAs)", "\(item.showAs)", "\(item.arrangement)"]
                .joined(separator: "|")
        }
        return apps.map(fp).joined(separator: "\n") + "\n--\n"
            + others.filter { !isSwitcherTile($0) }.map(fp).joined(separator: "\n")
    }

    private func untracked(_ f: () -> Void) {
        tracking = false
        f()
        tracking = true
    }

    // MARK: - Dock lesen / schreiben

    func reload() {
        DockPrefs.sync()
        untracked {
            apps = (DockPrefs.get("persistent-apps") as? [[String: Any]] ?? []).map { DockItem(raw: $0) }
            others = (DockPrefs.get("persistent-others") as? [[String: Any]] ?? []).map { DockItem(raw: $0) }
            settings = DockSettings.current()
        }
        markAsInDock()
        openedProfileID = nil
    }

    var activeProfile: DockProfile? { profiles.first { $0.id == activeProfileID } }

    /// Profil, dessen Inhalt gerade im Editor steht („Im Editor öffnen“) – sonst das aktive.
    @Published private(set) var openedProfileID: UUID?
    var editorProfile: DockProfile? { profiles.first { $0.id == (openedProfileID ?? activeProfileID) } }

    /// Wird beim Anwenden in dieses Profil gespeichert?
    var savesIntoActiveProfile: Bool { editorProfile.map { !$0.locked } ?? false }

    func showToast(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toast = t
        // Fehler auch ohne offenes Fenster sichtbar machen (z. B. nach Wechsel per Tastenkürzel)
        if error && !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            HUD.shared.show(String(localized: "Dock nicht vollständig übernommen"),
                            subtitle: String(localized: "Bitte erneut anwenden"),
                            symbol: "exclamationmark.triangle")
        }
        // Fehler (mit Liste fehlender Einträge) länger stehen lassen
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 8 : 3)) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    func apply(message: String? = nil, saveIntoProfile: Bool = true) {
        let target = editorProfile
        let msg = message ?? (savesIntoActiveProfile ? String(localized: "Dock aktualisiert · gespeichert in „\(target!.name)“")
                                                     : String(localized: "Dock aktualisiert"))
        // Genau das, was ins Dock geschrieben wird (inkl. „Profile“-Stapel) – danach wird dagegen geprüft.
        let writeApps = apps.map(\.raw)
        let writeOthers = othersForWriting().map(\.raw)
        let writeSettings = settings.dict
        markAsInDock()
        // Jeder Wechsel bekommt eine Nummer – Prüfungen älterer Wechsel brechen dann ab,
        // statt ihren (veralteten) Stand noch einmal ins Dock zu schreiben.
        applyGeneration += 1
        // Zuerst das Dock – Profil speichern, Stapel-Dateien etc. erst danach.
        writeAndVerify(apps: writeApps, others: writeOthers, settings: writeSettings, message: msg,
                       attempt: 1, generation: applyGeneration)
        // Ins Profil speichern, dessen Inhalt im Editor stand – nicht in ein anderes, gerade aktives.
        if saveIntoProfile, savesIntoActiveProfile, let id = target?.id { updateProfile(id) }
        if let opened = openedProfileID {
            openedProfileID = nil
            activeProfileID = opened   // Das Dock zeigt jetzt dieses Profil
        }
    }

    private func writeToDock(apps: [[String: Any]], others: [[String: Any]], settings: [String: Any]) {
        DockPrefs.set("persistent-apps", apps)
        DockPrefs.set("persistent-others", others)
        for (k, v) in settings { DockPrefs.set(k, v) }
        DockPrefs.sync()
        restartDock()
    }

    private var applyGeneration = 0
    private var lastRestart = Date.distantPast
    private var pendingRestart: DispatchWorkItem?
    /// Mindestabstand zwischen zwei Dock-Neustarts – das Dock braucht so lange zum Hochfahren.
    private static let restartGap: TimeInterval = 1.0

    /// Dock neu starten – bei schnell aufeinanderfolgenden Wechseln zusammengefasst.
    /// Wird das Dock beendet, während es noch hochfährt, schreibt es teils seinen alten Stand zurück.
    /// Die Einstellungen sind schon geschrieben; der verzögerte Neustart liest dann den neuesten Stand.
    func restartDock() {
        let wait = Self.restartGap - Date().timeIntervalSince(lastRestart)
        guard wait > 0 else {
            pendingRestart?.cancel()
            pendingRestart = nil
            lastRestart = Date()
            DockPrefs.restartDock()
            return
        }
        guard pendingRestart == nil else { return }   // Ein Neustart ist schon geplant
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.lastRestart = Date()
            DockPrefs.restartDock()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Schreibt, startet das Dock neu und prüft danach. Das Dock speichert beim Beenden manchmal
    /// seinen alten Stand zurück – dann wird automatisch noch einmal geschrieben.
    private func writeAndVerify(apps: [[String: Any]], others: [[String: Any]], settings: [String: Any],
                                message: String, attempt: Int, generation: Int) {
        writeToDock(apps: apps, others: others, settings: settings)
        let expectedApps = apps.map { DockItem(raw: $0) }.map(Self.signature)
        let expectedOthers = others.map { DockItem(raw: $0) }.map(Self.signature)

        func check(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Inzwischen neu angewendet oder im Editor geändert → diese Prüfung ist veraltet
                guard let self, self.applyGeneration == generation, !self.hasChanges else { return }
                // Neustart noch nicht passiert (zusammengefasst) → etwas später prüfen
                if self.pendingRestart != nil { check(remaining); return }
                self.reload()
                let ok = self.apps.map(Self.signature) == expectedApps
                    && self.others.map(Self.signature) == expectedOthers
                if ok {
                    self.showToast(message)
                } else if remaining > 0 {
                    check(remaining - 1)          // Dock braucht evtl. noch etwas länger
                } else if attempt < 2 {
                    self.writeAndVerify(apps: apps, others: others, settings: settings,
                                        message: message, attempt: attempt + 1, generation: generation)
                } else {
                    let missing = Set(expectedApps + expectedOthers)
                        .subtracting(self.apps.map(Self.signature) + self.others.map(Self.signature))
                    let names = (apps + others).map { DockItem(raw: $0) }
                        .filter { missing.contains(Self.signature($0)) }.map(\.label)
                    let detail = names.isEmpty ? "" : " " + String(localized: "Fehlt: \(names.prefix(3).joined(separator: ", "))")
                        + (names.count > 3 ? " …" : "")
                    self.showToast(String(localized: "Das Dock hat die Änderung nicht vollständig übernommen – bitte erneut anwenden.")
                                   + detail, error: true)
                }
            }
        }
        check(2)
    }

    /// Vergleichswert eines Eintrags – unabhängig von GUIDs, die das Dock beim Neustart ergänzt.
    private static func signature(_ item: DockItem) -> String {
        item.tileType + "|" + (item.url?.standardizedFileURL.path ?? item.label)
    }

    func setAutohideNow(_ on: Bool) {
        untracked { settings.autohide = on }
        baselineSettings.autohide = on   // geht direkt ins Dock → keine offene Änderung
        DockPrefs.set("autohide", on)
        DockPrefs.sync()
        restartDock()
    }

    // MARK: - Bearbeiten

    func add(urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let path = url.standardizedFileURL.path
            if url.pathExtension == "app" {
                guard !apps.contains(where: { $0.url?.standardizedFileURL.path == path }) else { continue }
                apps.append(.app(url))
            } else {
                // Ordner und Dokumente wie Apps nur einmal
                guard !others.contains(where: { $0.url?.standardizedFileURL.path == path }) else { continue }
                // Pakete (z. B. Keynote- oder Pages-Dokumente) sind technisch Ordner, gehören aber als Dokument ins Dock
                let isFolder = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
                others.append(isFolder ? .folder(url) : .document(url))
            }
        }
    }

    func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Hinzufügen")
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Hinzufügen")
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func addSpacer(small: Bool, after id: DockItem.ID? = nil) {
        let s = DockItem.spacer(small: small)
        if let id, let i = apps.firstIndex(where: { $0.id == id }) {
            apps.insert(s, at: i + 1)
        } else if let id, let i = others.firstIndex(where: { $0.id == id }) {
            others.insert(s, at: i + 1)
        } else {
            apps.append(s)
        }
    }

    func remove(ids: Set<DockItem.ID>) {
        guard !ids.isEmpty else { return }
        apps.removeAll { ids.contains($0.id) }
        others.removeAll { ids.contains($0.id) }
    }

    func update(_ id: DockItem.ID, _ change: (inout DockItem) -> Void) {
        if let i = apps.firstIndex(where: { $0.id == id }) { change(&apps[i]) }
        else if let i = others.firstIndex(where: { $0.id == id }) { change(&others[i]) }
    }

    /// Sortiert alphabetisch – aber nur innerhalb der durch Abstände getrennten Gruppen.
    func sortAlphabetically() {
        func sortGroups(_ items: [DockItem]) -> [DockItem] {
            var result: [DockItem] = [], group: [DockItem] = []
            let sorter: (DockItem, DockItem) -> Bool = { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            for item in items {
                if item.isSpacer {
                    result += group.sorted(by: sorter); result.append(item); group = []
                } else {
                    group.append(item)
                }
            }
            return result + group.sorted(by: sorter)
        }
        apps = sortGroups(apps)
        others = sortGroups(others)
    }

    func removeDuplicates() {
        func dedupe(_ items: [DockItem]) -> [DockItem] {
            var seen = Set<String>()
            return items.filter { item in
                guard let p = item.url?.standardizedFileURL.absoluteString else { return true }
                return seen.insert(p).inserted
            }
        }
        apps = dedupe(apps)
        others = dedupe(others)
    }

    func removeMissing() {
        apps.removeAll(where: \.isMissing)
        others.removeAll(where: \.isMissing)
    }

    func removeSpacers() {
        apps.removeAll(where: \.isSpacer)
        others.removeAll(where: \.isSpacer)
    }

    var missingCount: Int { (apps + others).filter(\.isMissing).count }

    // MARK: - Profile

    private var profilesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockOrganizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.plist")
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let arr = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return }
        profiles = arr.compactMap(DockProfile.init(plist:))
    }

    private func saveProfiles() {
        if let data = try? PropertyListSerialization.data(fromPropertyList: profiles.map(\.plist), format: .binary, options: 0) {
            try? data.write(to: profilesURL, options: .atomic)
        }
        syncSwitcherFiles()
        HotkeyManager.shared.register(profiles)
    }

    @discardableResult
    func saveProfile(name: String) -> DockProfile {
        let p = DockProfile(name: name, apps: apps, others: others, settings: settings)
        profiles.append(p)
        saveProfiles()
        activeProfileID = p.id
        return p
    }

    func updateProfile(_ id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].apps = apps
        profiles[i].others = others
        profiles[i].settings = settings
        saveProfiles()
    }

    func renameProfile(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].name != name else { return }
        profiles[i].name = name
        saveProfiles()
    }

    func duplicateProfile(_ id: UUID) -> DockProfile? {
        guard let p = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = DockProfile(name: String(localized: "\(p.name) Kopie"), apps: p.apps, others: p.others, settings: p.settings)
        copy.created = Date()
        profiles.append(copy)
        saveProfiles()
        return copy
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        if openedProfileID == id { openedProfileID = nil }
        saveProfiles()
    }

    // MARK: Echtes Dock (so wie es gerade auf dem Bildschirm ist) ins Profil übernehmen

    private func realDockSnapshot() -> (apps: [DockItem], others: [DockItem], settings: DockSettings) {
        DockPrefs.sync()
        return ((DockPrefs.get("persistent-apps") as? [[String: Any]] ?? []).map { DockItem(raw: $0) },
                (DockPrefs.get("persistent-others") as? [[String: Any]] ?? []).map { DockItem(raw: $0) },
                DockSettings.current())
    }

    func saveRealDock(into id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), !profiles[i].locked else { return }
        let snap = realDockSnapshot()
        profiles[i].apps = snap.apps
        profiles[i].others = snap.others
        profiles[i].settings = snap.settings
        saveProfiles()
        activeProfileID = id
        if !hasChanges { reload() }
        showToast(String(localized: "Aktuelles Dock in „\(profiles[i].name)“ gespeichert"))
    }

    func saveRealDockAsNewProfile(name: String) {
        let snap = realDockSnapshot()
        let p = DockProfile(name: name, apps: snap.apps, others: snap.others, settings: snap.settings)
        profiles.append(p)
        saveProfiles()
        activeProfileID = p.id
        if !hasChanges { reload() }
        showToast(String(localized: "Profil „\(name)“ angelegt"))
    }

    func moveProfiles(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        saveProfiles()
    }

    func loadIntoEditor(_ p: DockProfile) {
        apps = p.apps.map { DockItem(raw: $0.raw) }
        others = p.others.map { DockItem(raw: $0.raw) }
        if let s = p.settings { settings = s }
    }

    /// Profil zum Bearbeiten in den Editor holen – Anwenden speichert dann in genau dieses Profil.
    func openInEditor(_ p: DockProfile) {
        loadIntoEditor(p)
        openedProfileID = p.id
    }

    func applyProfile(_ p: DockProfile) {
        let start = Date()
        openedProfileID = nil
        // Editor-Stand setzen, ohne dass activeProfileID schon Dateien anfasst
        untracked { loadIntoEditor(p) }
        // Das Profil selbst ist schon der gespeicherte Stand → nicht zurückschreiben
        apply(message: String(localized: "Profil „\(p.name)“ angewendet"), saveIntoProfile: false)
        dockLog.notice("Profil \(p.name, privacy: .public): Dock neu gestartet nach \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        activeProfileID = p.id
    }

    func setHotkey(_ id: UUID, _ hotkey: Hotkey?) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let hotkey {
            // Ein Kürzel gehört immer nur einem Profil
            for j in profiles.indices where profiles[j].hotkey == hotkey { profiles[j].hotkey = nil }
        }
        profiles[i].hotkey = hotkey
        saveProfiles()
        if let hotkey { showToast(String(localized: "\(hotkey.display) wendet jetzt „\(profiles[i].name)“ an")) }
    }

    func setLocked(_ id: UUID, _ locked: Bool) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].locked = locked
        saveProfiles()
    }

    func exportProfile(_ id: UUID) {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "\(p.name).plist"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? PropertyListSerialization.data(fromPropertyList: p.plist, format: .xml, options: 0)
        else { return }
        try? data.write(to: url)
    }

    @discardableResult
    func importProfile() -> DockProfile? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var p = DockProfile(plist: d)
        else { return nil }
        p.id = UUID()
        p.locked = false
        p.hotkey = nil
        profiles.append(p)
        saveProfiles()
        return p
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}
