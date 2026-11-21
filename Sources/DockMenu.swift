import AppKit

/// Rechtsklick auf das Dock-Organizer-Symbol im Dock → Profile wechseln & speichern.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: DockStore { DockStore.shared }
    /// Verhindert App Nap – sonst reagieren Tastenkürzel im Hintergrund verzögert.
    private var activity: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Im Hintergrund-Modus gar nicht erst mit Dock-Symbol starten
        if AppBehavior.shared.runInBackground { NSApp.setActivationPolicy(.accessory) }
    }

    /// App erneut geöffnet (Finder, Spotlight, Launchpad), während sie im Hintergrund läuft → Fenster zeigen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppBehavior.shared.showMainWindow() }
        return true
    }

    /// Fenster schließen beendet die App nicht – Tastenkürzel und Menüleiste laufen weiter.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Globale Tastenkürzel für Dock-Profile")
    }

    /// Klick auf ein Profil im „Profile“-Stapel öffnet eine .dockprofile-Datei → Profil anwenden.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "dockprofile" {
            store.applyProfile(fromSwitcherFile: url)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let header = NSMenuItem(title: String(localized: "Profil wechseln"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for p in store.profiles {
            let item = NSMenuItem(title: p.name, action: #selector(applyProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.id
            item.state = store.activeProfileID == p.id ? .on : .off
            item.image = NSImage(systemSymbolName: p.locked ? "lock" : "square.stack.3d.up",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Aktuelles Dock ins aktive Profil speichern
        if let active = store.activeProfile {
            let save = NSMenuItem(title: active.locked
                                    ? String(localized: "„\(active.name)“ ist gesperrt")
                                    : String(localized: "Aktuelles Dock in „\(active.name)“ speichern"),
                                  action: active.locked ? nil : #selector(saveIntoActive), keyEquivalent: "")
            save.target = self
            save.isEnabled = !active.locked
            menu.addItem(save)
        }

        // In ein anderes Profil speichern
        let saveInto = NSMenuItem(title: String(localized: "Aktuelles Dock speichern in"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in store.profiles where !p.locked {
            let i = NSMenuItem(title: p.name, action: #selector(saveInto(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.id
            sub.addItem(i)
        }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        let newItem = NSMenuItem(title: String(localized: "Neues Profil …"), action: #selector(saveAsNew), keyEquivalent: "")
        newItem.target = self
        sub.addItem(newItem)
        saveInto.submenu = sub
        menu.addItem(saveInto)

        return menu
    }

    @objc private func applyProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let p = store.profiles.first(where: { $0.id == id }) else { return }
        store.applyProfile(p)
    }

    @objc private func saveIntoActive() {
        if let id = store.activeProfileID { store.saveRealDock(into: id) }
    }

    @objc private func saveInto(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { store.saveRealDock(into: id) }
    }

    @objc private func saveAsNew() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Neues Profil")
        alert.informativeText = String(localized: "Speichert das Dock, so wie es gerade aussieht, als neues Profil.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "z. B. Arbeit, Design, Freizeit")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Speichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.saveRealDockAsNewProfile(name: name)
    }
}
