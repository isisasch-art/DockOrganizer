import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

private let hotkeyLog = Logger(subsystem: "local.dockorganizer", category: "hotkeys")

// MARK: - Tastenkombination

struct Hotkey: Equatable, Hashable {
    /// Virtueller Tastencode (kVK_…)
    var keyCode: UInt32
    /// Carbon-Modifier (cmdKey, optionKey, controlKey, shiftKey)
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var plist: [String: Any] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers)] }

    init?(plist: Any?) {
        guard let d = plist as? [String: Any],
              let k = (d["keyCode"] as? NSNumber)?.uint32Value,
              let m = (d["modifiers"] as? NSNumber)?.uint32Value
        else { return nil }
        self.init(keyCode: k, modifiers: m)
    }

    var isFunctionKey: Bool { Self.functionKeys[Int(keyCode)] != nil }

    /// Braucht ⌃, ⌥ oder ⌘ – außer bei F-Tasten.
    var isValid: Bool {
        isFunctionKey || modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// Nur ⌘ (ggf. mit ⇧) – kollidiert leicht mit Befehlen in Apps.
    var looksLikeAppShortcut: Bool {
        !isFunctionKey && modifiers & UInt32(controlKey | optionKey) == 0
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    // MARK: Tastennamen

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: String(localized: "Leertaste"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func keyName(_ code: UInt32) -> String {
        if let s = functionKeys[Int(code)] ?? specialKeys[Int(code)] { return s }
        // Zeichen gemäß aktueller Tastaturbelegung
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

// MARK: - Globale Tastenkürzel

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private static let signature: OSType = 0x444F_4B4F // 'DOKO'
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: UUID] = [:]
    private var handlerInstalled = false
    private var suspended = false
    private var current: [(UUID, Hotkey)] = []

    /// Alle Profil-Kürzel neu registrieren.
    func register(_ profiles: [DockProfile]) {
        current = profiles.compactMap { p in p.hotkey.map { (p.id, $0) } }
        guard !suspended else { return }
        installHandlerIfNeeded()
        unregisterAll()
        for (i, (id, hk)) in current.enumerated() {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: Self.signature, id: UInt32(i + 1))
            let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
            hotkeyLog.notice("register \(hk.display, privacy: .public) status=\(status)")
            if status == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = id
            }
        }
    }

    /// Während der Aufnahme eines neuen Kürzels dürfen die bestehenden nicht auslösen.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        register(DockStore.shared.profiles)
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotkeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        hotkeyLog.notice("handler installed status=\(installStatus)")
    }

    private func fire(_ id: UInt32) {
        hotkeyLog.notice("fired id=\(id) known=\(self.actions[id] != nil)")
        let store = DockStore.shared
        guard let pid = actions[id], let p = store.profiles.first(where: { $0.id == pid }) else { return }
        if p.id == store.activeProfileID && !store.hasChanges {
            HUD.shared.show(p.name, subtitle: String(localized: "ist bereits aktiv"), symbol: "checkmark.circle")
            return
        }
        store.applyProfile(p)
        HUD.shared.show(p.name, subtitle: String(localized: "Profil wird angewendet"), symbol: "square.stack.3d.up")
    }

    // MARK: Belegung prüfen

    enum Conflict: Equatable {
        case profile(String), system, otherApp
        var text: String {
            switch self {
            case .profile(let n): return String(localized: "Schon für Profil „\(n)“ vergeben")
            case .system: return String(localized: "Von macOS belegt (Systemeinstellungen → Tastatur → Tastaturkurzbefehle)")
            case .otherApp: return String(localized: "Von einer anderen App belegt")
            }
        }
    }

    func conflict(for hk: Hotkey, excluding profileID: UUID?) -> Conflict? {
        if let other = DockStore.shared.profiles.first(where: { $0.id != profileID && $0.hotkey == hk }) {
            return .profile(other.name)
        }
        if systemHotkeys().contains(hk) { return .system }
        // Schon von uns selbst registriert (gleiches Profil) → frei
        if current.contains(where: { $0.1 == hk }) { return nil }
        // Probe-Registrierung: schlägt fehl, wenn eine andere App das Kürzel exklusiv belegt
        var ref: EventHotKeyRef?
        let probe = EventHotKeyID(signature: Self.signature, id: 9999)
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, probe, GetEventDispatcherTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr ? nil : .otherApp
    }

    /// Freie Vorschläge, z. B. ⌃⌥1 … ⌃⌥9
    func suggestions(for profileID: UUID, limit: Int = 6) -> [Hotkey] {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let modSets = [controlKey | optionKey, controlKey | optionKey | cmdKey, optionKey | cmdKey, controlKey | shiftKey]
        let profiles = DockStore.shared.profiles
        // Bevorzugt die Ziffer passend zur Position des Profils in der Liste
        let pos = profiles.firstIndex(where: { $0.id == profileID }) ?? 0
        let orderedDigits = Array(digits[min(pos, digits.count - 1)...]) + Array(digits[..<min(pos, digits.count - 1)])
        var result: [Hotkey] = []
        for mods in modSets {
            for d in orderedDigits {
                let hk = Hotkey(keyCode: UInt32(d), modifiers: UInt32(mods))
                if profiles.first(where: { $0.id == profileID })?.hotkey == hk { continue }
                if conflict(for: hk, excluding: profileID) == nil { result.append(hk) }
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// Aktivierte Kurzbefehle aus Systemeinstellungen → Tastatur
    private func systemHotkeys() -> Set<Hotkey> {
        guard let dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
                as? [String: Any] else { return [] }
        var set = Set<Hotkey>()
        for case let entry as [String: Any] in dict.values {
            guard (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false),
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [NSNumber], params.count >= 3
            else { continue }
            let code = params[1].intValue
            guard code != 65535 else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(params[2].intValue))
            var m: UInt32 = 0
            if flags.contains(.control) { m |= UInt32(controlKey) }
            if flags.contains(.option) { m |= UInt32(optionKey) }
            if flags.contains(.shift) { m |= UInt32(shiftKey) }
            if flags.contains(.command) { m |= UInt32(cmdKey) }
            set.insert(Hotkey(keyCode: UInt32(code), modifiers: m))
        }
        return set
    }
}

// MARK: - Auswahlfeld in den Profiloptionen

struct HotkeyPicker: View {
    @EnvironmentObject var store: DockStore
    let profileID: UUID
    @State private var suggestions: [Hotkey] = []
    @State private var recording = false

    private var hotkey: Hotkey? { store.profiles.first { $0.id == profileID }?.hotkey }

    var body: some View {
        HStack(spacing: 10) {
            Text("Tastenkürzel")
            Menu {
                if !suggestions.isEmpty {
                    Section("Freie Vorschläge") {
                        ForEach(suggestions, id: \.self) { hk in
                            Button(hk.display) { store.setHotkey(profileID, hk) }
                        }
                    }
                }
                Button("Eigenes Kürzel aufnehmen …") { recording = true }
                if hotkey != nil {
                    Divider()
                    Button("Kein Tastenkürzel") { store.setHotkey(profileID, nil) }
                }
            } label: {
                Text(hotkey?.display ?? String(localized: "Kein Tastenkürzel"))
                    .monospaced()
            }
            .fixedSize()
            Text("wendet das Profil von überall aus an")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: profileID) { refresh() }
        .onChange(of: store.profiles.map(\.hotkey)) { refresh() }
        .popover(isPresented: $recording, arrowEdge: .bottom) {
            HotkeyRecorder(profileID: profileID) { hk in
                recording = false
                if let hk { store.setHotkey(profileID, hk) }
            }
            .environmentObject(store)
        }
    }

    private func refresh() {
        suggestions = HotkeyManager.shared.suggestions(for: profileID)
    }
}

private struct HotkeyRecorder: View {
    @EnvironmentObject var store: DockStore
    let profileID: UUID
    let done: (Hotkey?) -> Void
    @State private var candidate: Hotkey?
    @State private var message: String?
    @State private var isWarning = false
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 12) {
            Text("Drücke die gewünschte Tastenkombination")
                .font(.headline)
            Text(candidate?.display ?? "…")
                .font(.system(size: 28, weight: .medium).monospaced())
                .frame(minWidth: 160, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            if let message {
                Label(message, systemImage: isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(isWarning ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Mit ⌃, ⌥ oder ⌘ kombinieren · ⎋ bricht ab")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Abbrechen") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") { done(candidate) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidate == nil || (message != nil && !isWarning))
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            HotkeyManager.shared.suspend()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    done(nil); return nil
                }
                if (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)),
                   event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    return event // „Übernehmen“
                }
                if let hk = Hotkey(event: event) { check(hk) }
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            HotkeyManager.shared.resume()
        }
    }

    private func check(_ hk: Hotkey) {
        candidate = hk
        isWarning = false
        if !hk.isValid {
            message = String(localized: "Bitte mit ⌃, ⌥ oder ⌘ kombinieren")
        } else if let c = HotkeyManager.shared.conflict(for: hk, excluding: profileID) {
            message = c.text
        } else if hk.looksLikeAppShortcut {
            message = String(localized: "Nur mit ⌘ – überdeckt dann gleichnamige Befehle in allen Apps")
            isWarning = true
        } else {
            message = nil
        }
    }
}
