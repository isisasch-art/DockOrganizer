# Dock Organizer

Eine macOS-App, mit der du dein Dock ordnest und zwischen verschiedenen Anordnungen („Profilen“) wechselst, zum Beispiel *Arbeit*, *Kommunikation* oder *Fotos*. Ein Wechsel geht per Tastenkürzel, über die Menüleiste oder über einen Stapel im Dock.

> [!WARNING]
> **Testversion.** Dock Organizer ist noch in Entwicklung und nicht ausgiebig getestet. Die App schreibt direkt in die Dock-Einstellungen von macOS (`com.apple.dock`) und startet das Dock bei jeder Änderung neu.
> Beim ersten Start wird deine aktuelle Anordnung automatisch als gesperrtes Profil **„Original (Backup)“** gespeichert. Darüber kommst du jederzeit zurück. Lösche dieses Profil nicht, solange du die App testest.

## Funktionen

**Dock bearbeiten**
- Apps, Ordner, Dokumente und Abstände hinzufügen, entfernen und per Ziehen sortieren
- Seitenleiste mit allen installierten Apps zum schnellen Hinzufügen
- Aufräumen: alphabetisch sortieren (innerhalb der durch Abstände getrennten Gruppen), Duplikate, fehlende Einträge oder alle Abstände entfernen
- Neue Dock-Ordner aus markierten Apps anlegen; die App schlägt einen Namen anhand der App-Kategorie vor. Die Ordner liegen in `~/Dock-Ordner/` und enthalten Aliasse der Apps
- Dock-Optionen: Größe, Vergrößerung, Position, automatisches Ausblenden, zuletzt benutzte Apps, Effekt beim Ablegen
- Änderungen werden erst mit **„Auf Dock anwenden“ (⌘S)** übernommen. Die Leiste „Nicht angewendete Änderungen“ erscheint nur, wenn sich der Editor wirklich vom Dock unterscheidet

**Profile**
- Beliebig viele Anordnungen samt Dock-Optionen als Profil speichern
- Wechseln per **globalem Tastenkürzel** (z. B. ⌃⌥1 … ⌃⌥9), über das **Menüleisten-Symbol**, das Rechtsklick-Menü am App-Symbol oder einen **„Profile“-Stapel** im Dock
- Beim Wechsel per Tastenkürzel erscheint sofort eine Einblendung mit dem Profilnamen
- Profile sperren, duplizieren, umbenennen, exportieren und importieren (`.plist`)
- Nach jedem Wechsel prüft die App, ob das Dock alles übernommen hat, und schreibt bei Bedarf automatisch ein zweites Mal

**App**
- Bei der Anmeldung automatisch starten
- Im Hintergrund ausführen: kein Symbol im Dock, nur das Menüleisten-Symbol; Tastenkürzel funktionieren weiter
- Oberfläche auf Deutsch und Englisch; die App folgt der Systemsprache

## Download

**[⬇ Dock Organizer herunterladen](https://github.com/isisasch-art/DockOrganizer/releases)**: beim neuesten Eintrag unter *Assets* die Datei `DockOrganizer-1.0.zip` laden.

- macOS 14 (Sonoma) oder neuer
- läuft auf Apple Silicon und Intel-Macs

### Installieren

1. ZIP doppelklicken und **Dock Organizer** in den Ordner **Programme** ziehen.
2. Die App einmal per Doppelklick öffnen. macOS meldet, dass die App nicht geöffnet werden kann bzw. nicht überprüft wurde. Mit **Fertig** bzw. **OK** schließen, *nicht* „In den Papierkorb legen“.
3. **Systemeinstellungen → Datenschutz & Sicherheit** öffnen, ganz nach unten scrollen und bei „Dock Organizer wurde blockiert …“ auf **Dennoch öffnen** klicken. Mit deinem Passwort oder Touch ID bestätigen.
4. Ab jetzt startet die App normal.

> [!NOTE]
> **Warum die Warnung?** Diese Testversion ist nicht mit einem Apple-Entwicklerzertifikat signiert und nicht von Apple beglaubigt (notarisiert). macOS blockiert solche Apps beim ersten Start. Der Quellcode liegt vollständig in diesem Repository. Wer der heruntergeladenen Datei nicht traut, baut die App selbst (siehe unten).
>
> Alternative zu Schritt 2 und 3 im Terminal:
> ```bash
> xattr -dr com.apple.quarantine "/Applications/Dock Organizer.app"
> ```

## Selbst bauen

Voraussetzung: Xcode bzw. die Xcode Command Line Tools (Swift 5.9 oder neuer, `actool` für das App-Symbol).

```bash
git clone https://github.com/isisasch-art/DockOrganizer.git
```

```bash
cd DockOrganizer
```

```bash
./build.sh
```

Das Skript:
1. baut die App im Release-Modus, universell für Apple Silicon und Intel,
2. erzeugt `build/Dock Organizer.app` samt Symbol,
3. signiert sie: mit einem „Developer ID Application“-Zertifikat, falls eins im Schlüsselbund liegt, sonst nur ad hoc (auf anderen Macs blockiert macOS sie dann beim ersten Start, siehe „Installieren“),
4. legt `build/DockOrganizer-1.0.zip` an,
5. **beendet eine laufende Dock-Organizer-Instanz und ersetzt `/Applications/Dock Organizer.app`**.

Mit `NOTARIZE=1 ./build.sh` wird die App zusätzlich bei Apple notarisiert. Dafür sind ein Developer-ID-Zertifikat und einmalig `xcrun notarytool store-credentials` nötig (siehe Kommentar in `build.sh`).

## Erste Schritte

1. Dock Organizer aus dem Ordner *Programme* starten. Dein aktuelles Dock wird als „Original (Backup)“ gesichert.
2. Unter **Anordnung** das Dock nach Wunsch umbauen und mit **⌘S** anwenden. Das Dock startet dabei kurz neu.
3. Mit **„Neues Profil“** (unten in der Seitenleiste) die Anordnung als Profil speichern.
4. Im Profil unter **Tastenkürzel** ein Kürzel wählen. Die App schlägt freie Kombinationen vor und warnt vor Kürzeln, die schon belegt sind.
5. Optional unter **Optionen → App** Autostart und den Hintergrund-Modus einschalten.

## Wo die Daten liegen

| Was | Ort |
|---|---|
| Profile | `~/Library/Application Support/DockOrganizer/profiles.plist` |
| Dateien für den „Profile“-Stapel | `~/Library/Application Support/DockOrganizer/Profile/` |
| Angelegte Dock-Ordner | `~/Dock-Ordner/` |
| App-Einstellungen | `defaults read local.dockorganizer` |

## Bekannte Einschränkungen

- **Jeder Wechsel startet das Dock neu.** macOS übernimmt geänderte Dock-Einträge nur nach einem Neustart des Docks. Das dauert je nach Mac und Symbolgröße etwa 0,5 bis 2 Sekunden. Bei sehr schnellen Wechseln hintereinander fasst die App die Neustarts zusammen (höchstens einer pro Sekunde).
- Meldungen im App-Fenster erscheinen nur, wenn das Fenster offen ist. Ohne offenes Fenster gibt es die Einblendung nur beim Tastenkürzel und bei Fehlern.
- Der Autostart nutzt die Anmeldeobjekte von macOS (`SMAppService`). Mit einer nur ad hoc signierten App ist er noch nicht getestet.

## Zurück zum ursprünglichen Dock

- In der App das Profil **„Original (Backup)“** auswählen und **„Auf Dock anwenden“** klicken, oder
- macOS-Standard-Dock wiederherstellen (setzt *alle* Dock-Einstellungen zurück):

```bash
defaults delete com.apple.dock && killall Dock
```

## Fehler melden

Fehler und Ideen bitte als [Issue](https://github.com/isisasch-art/DockOrganizer/issues) melden. Hilfreich sind die macOS-Version, was du gemacht hast und, wenn möglich, das Protokoll der App:

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "local.dockorganizer"' --style compact
```
