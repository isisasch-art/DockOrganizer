import AppKit

// MARK: - Zugriff auf die Dock-Einstellungen (com.apple.dock)

enum DockPrefs {
    static let domain = "com.apple.dock" as CFString

    static func sync() { CFPreferencesAppSynchronize(domain) }

    static func get(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value.map { $0 as AnyObject }, domain)
    }

    static func restartDock() {
        // Direkt das Signal senden – schneller als killall als eigenen Prozess zu starten.
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        if !docks.isEmpty {
            docks.forEach { kill($0.processIdentifier, SIGTERM) }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}

// MARK: - Ein Eintrag im Dock

struct DockItem: Identifiable {
    let id = UUID()
    var raw: [String: Any]

    var tileType: String { raw["tile-type"] as? String ?? "" }
    var tileData: [String: Any] { raw["tile-data"] as? [String: Any] ?? [:] }

    var isSpacer: Bool { tileType == "spacer-tile" || tileType == "small-spacer-tile" || tileType == "flex-spacer-tile" }
    var isSmallSpacer: Bool { tileType == "small-spacer-tile" }
    var isFolder: Bool { tileType == "directory-tile" }

    var url: URL? {
        let fd = (tileData["file-data"] ?? tileData["url"]) as? [String: Any]
        guard let s = fd?["_CFURLString"] as? String else { return nil }
        let type = (fd?["_CFURLStringType"] as? NSNumber)?.intValue ?? 15
        return type == 0 ? URL(fileURLWithPath: s) : URL(string: s)
    }

    var label: String {
        if isSpacer { return isSmallSpacer ? String(localized: "Kleiner Abstand") : String(localized: "Abstand") }
        if let l = tileData["file-label"] as? String, !l.isEmpty { return l }
        if let l = tileData["label"] as? String, !l.isEmpty { return l }
        return url?.deletingPathExtension().lastPathComponent ?? String(localized: "Unbekannt")
    }

    /// Nur zum Anzeigen (übersetzt); zum Prüfen `isApp`, `isFolder` usw. verwenden
    var kind: String {
        if isSpacer { return String(localized: "Abstand") }
        switch tileType {
        case "directory-tile": return String(localized: "Ordner")
        case "url-tile": return String(localized: "Link")
        default: return isApp ? String(localized: "App") : String(localized: "Dokument")
        }
    }

    var isApp: Bool { !isSpacer && !isFolder && tileType != "url-tile" && url?.pathExtension == "app" }

    var isMissing: Bool {
        guard let url, url.isFileURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    mutating func setTileValue(_ key: String, _ value: Any) {
        var td = tileData
        td[key] = value
        raw["tile-data"] = td
    }

    // Ordner-Optionen
    var showAs: Int { (tileData["showas"] as? NSNumber)?.intValue ?? 0 }       // 0 auto, 1 Fächer, 2 Raster, 3 Liste
    var displayAs: Int { (tileData["displayas"] as? NSNumber)?.intValue ?? 0 } // 0 Stapel, 1 Ordner
    var arrangement: Int { (tileData["arrangement"] as? NSNumber)?.intValue ?? 1 }

    // MARK: Fabriken

    private static func fileData(_ url: URL) -> [String: Any] {
        ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]
    }

    static func app(_ url: URL) -> DockItem {
        DockItem(raw: [
            "tile-type": "file-tile",
            "tile-data": ["file-data": fileData(url), "file-label": url.deletingPathExtension().lastPathComponent],
        ])
    }

    static func folder(_ url: URL) -> DockItem {
        let dirURL = URL(fileURLWithPath: url.path, isDirectory: true)
        return DockItem(raw: [
            "tile-type": "directory-tile",
            "tile-data": [
                "file-data": fileData(dirURL), "file-label": url.lastPathComponent,
                "file-type": 2, "arrangement": 1, "displayas": 0, "showas": 0,
            ],
        ])
    }

    static func document(_ url: URL) -> DockItem {
        DockItem(raw: [
            "tile-type": "file-tile",
            "tile-data": ["file-data": fileData(url), "file-label": url.lastPathComponent],
        ])
    }

    static func spacer(small: Bool) -> DockItem {
        DockItem(raw: ["tile-type": small ? "small-spacer-tile" : "spacer-tile", "tile-data": [String: Any]()])
    }
}

// MARK: - Dock-Optionen

struct DockSettings: Equatable {
    var autohide = false
    var tilesize: Double = 48
    var magnification = false
    var largesize: Double = 64
    var orientation = "bottom"
    var showRecents = true
    var minimizeToApp = false
    var mineffect = "genie"

    static let keys = ["autohide", "tilesize", "magnification", "largesize", "orientation",
                       "show-recents", "minimize-to-application", "mineffect"]

    init() {}

    init(dict: [String: Any]) {
        autohide = dict["autohide"] as? Bool ?? false
        tilesize = (dict["tilesize"] as? NSNumber)?.doubleValue ?? 48
        magnification = dict["magnification"] as? Bool ?? false
        largesize = (dict["largesize"] as? NSNumber)?.doubleValue ?? 64
        orientation = dict["orientation"] as? String ?? "bottom"
        showRecents = dict["show-recents"] as? Bool ?? true
        minimizeToApp = dict["minimize-to-application"] as? Bool ?? false
        mineffect = dict["mineffect"] as? String ?? "genie"
    }

    static func current() -> DockSettings {
        var d: [String: Any] = [:]
        for k in keys { if let v = DockPrefs.get(k) { d[k] = v } }
        return DockSettings(dict: d)
    }

    var dict: [String: Any] {
        ["autohide": autohide, "tilesize": tilesize, "magnification": magnification,
         "largesize": largesize, "orientation": orientation, "show-recents": showRecents,
         "minimize-to-application": minimizeToApp, "mineffect": mineffect]
    }
}

// MARK: - Profil (gespeicherte Dock-Anordnung)

struct DockProfile: Identifiable {
    var id = UUID()
    var name: String
    var apps: [DockItem]
    var others: [DockItem]
    var settings: DockSettings?
    var created = Date()
    /// Gesperrte Profile (z. B. das Backup) werden beim Anwenden nicht automatisch überschrieben.
    var locked = false
    /// Globales Tastenkürzel zum Anwenden
    var hotkey: Hotkey?

    var plist: [String: Any] {
        var d: [String: Any] = [
            "id": id.uuidString, "name": name, "created": created,
            "apps": apps.map(\.raw), "others": others.map(\.raw), "locked": locked,
        ]
        if let settings { d["settings"] = settings.dict }
        if let hotkey { d["hotkey"] = hotkey.plist }
        return d
    }

    init(name: String, apps: [DockItem], others: [DockItem], settings: DockSettings?) {
        self.name = name; self.apps = apps; self.others = others; self.settings = settings
    }

    init?(plist d: [String: Any]) {
        guard let name = d["name"] as? String, let apps = d["apps"] as? [[String: Any]] else { return nil }
        self.id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        self.name = name
        self.apps = apps.map { DockItem(raw: $0) }
        self.others = (d["others"] as? [[String: Any]] ?? []).map { DockItem(raw: $0) }
        self.settings = (d["settings"] as? [String: Any]).map(DockSettings.init(dict:))
        self.created = d["created"] as? Date ?? Date()
        self.locked = d["locked"] as? Bool ?? (name == "Original (Backup)")
        self.hotkey = Hotkey(plist: d["hotkey"])
    }

    var appCount: Int { apps.filter { !$0.isSpacer }.count }
    var otherCount: Int { others.filter { !$0.isSpacer }.count }
}

// MARK: - Icons

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: DockItem) -> NSImage {
        guard let url = item.url else {
            return NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        guard url.isFileURL else {
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        }
        if let i = cache[url.path] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = i
        return i
    }
}
