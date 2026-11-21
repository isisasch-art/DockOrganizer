import AppKit
import ServiceManagement
import SwiftUI

/// Autostart bei der Anmeldung und „Im Hintergrund ausführen“ (kein Dock-Symbol, nur Menüleiste).
@MainActor
final class AppBehavior: ObservableObject {
    static let shared = AppBehavior()

    @Published private(set) var launchAtLogin = false
    /// Autostart ist angemeldet, muss aber in den Systemeinstellungen noch erlaubt werden.
    @Published private(set) var needsApproval = false
    @Published var runInBackground: Bool {
        didSet {
            UserDefaults.standard.set(runInBackground, forKey: "runInBackground")
            updateActivationPolicy()
        }
    }

    /// Öffnet das Hauptfenster (wird vom Fenster selbst gesetzt, da nur SwiftUI es neu anlegen kann).
    var openMainWindow: (() -> Void)?
    /// Beim Start im Hintergrund-Modus das Fenster einmal gleich wieder schließen.
    private var hideWindowOnLaunch: Bool

    private init() {
        let bg = UserDefaults.standard.bool(forKey: "runInBackground")
        runInBackground = bg
        hideWindowOnLaunch = bg
        refresh()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Erst nach dem Schließen zählen, ob noch ein Fenster offen ist
            DispatchQueue.main.async { MainActor.assumeIsolated { AppBehavior.shared.updateActivationPolicy() } }
        }
    }

    // MARK: Autostart

    func refresh() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let text = on ? String(localized: "Autostart konnte nicht eingeschaltet werden: \(error.localizedDescription)")
                          : String(localized: "Autostart konnte nicht ausgeschaltet werden: \(error.localizedDescription)")
            DockStore.shared.showToast(text, error: true)
        }
        refresh()
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: Hintergrund

    private var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Ohne offenes Fenster im Hintergrund-Modus kein Dock-Symbol; mit Fenster normal (Menüs, ⌘-Tab).
    func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = runInBackground && !mainWindowVisible ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Vom Hauptfenster beim Erscheinen aufgerufen. Gibt true zurück, wenn es sich gleich wieder schließen soll.
    func mainWindowAppeared(open: @escaping () -> Void) -> Bool {
        openMainWindow = open
        if hideWindowOnLaunch {
            hideWindowOnLaunch = false
            return true
        }
        updateActivationPolicy()
        return false
    }

    func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Abschnitt in den Optionen

struct AppBehaviorSection: View {
    @EnvironmentObject var behavior: AppBehavior

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { behavior.launchAtLogin }, set: { behavior.setLaunchAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bei der Anmeldung automatisch starten")
                    if behavior.needsApproval {
                        HStack(spacing: 4) {
                            Text("Muss noch in den Systemeinstellungen erlaubt werden.")
                            Button("Öffnen") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.link)
                        }
                        .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Toggle(isOn: $behavior.runInBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Im Hintergrund ausführen")
                    Text("Kein Symbol im Dock, startet ohne Fenster. Bedienung über das Menüleisten-Symbol; Tastenkürzel funktionieren weiter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("App")
        } footer: {
            Text("Diese beiden Einstellungen gelten sofort.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { behavior.refresh() }
    }
}
