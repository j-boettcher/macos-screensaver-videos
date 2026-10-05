import AppKit
import UniformTypeIdentifiers

/// Einstellungsfenster, das in den Systemeinstellungen unter „Optionen…“ erscheint.
final class ConfigureSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow

    private let prefs: Preferences
    private let onSave: () -> Void
    private var generalSources: [VideoSource] = []
    private var screenSources: [String: [VideoSource]] = [:]
    /// nil = Standardliste für alle Bildschirme ohne eigene Liste.
    private var selectedScreenID: String?

    /// Liste, die gerade in der Tabelle bearbeitet wird.
    private var sources: [VideoSource] {
        get {
            guard let selectedScreenID else { return generalSources }
            return screenSources[selectedScreenID] ?? []
        }
        set {
            if let selectedScreenID {
                screenSources[selectedScreenID] = newValue
            } else {
                generalSources = newValue
            }
            updateTargetTitles()
        }
    }

    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "Entfernen", target: nil, action: nil)
    private let shuffleCheckbox = NSButton(checkboxWithTitle: "Zufällige Reihenfolge", target: nil, action: nil)
    private let subfolderCheckbox = NSButton(checkboxWithTitle: "Unterordner einbeziehen", target: nil, action: nil)
    private let muteCheckbox = NSButton(checkboxWithTitle: "Ton aus", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let scalingPopup = NSPopUpButton()
    private let urlField = NSTextField()
    private let targetPopup = NSPopUpButton()
    private let targetHint = NSTextField(wrappingLabelWithString: "")
    private let cacheCheckbox = NSButton(checkboxWithTitle: "URL-Videos zwischenspeichern (offline verfügbar)", target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(labelWithString: "")
    private let clearCacheButton = NSButton(title: "Leeren", target: nil, action: nil)
    private var cacheObserver: NSObjectProtocol?

    init(preferences: Preferences, onSave: @escaping () -> Void) {
        prefs = preferences
        self.onSave = onSave
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildUI()
        loadValues()
        cacheObserver = NotificationCenter.default.addObserver(
            forName: VideoCache.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCacheStatus()
        }
    }

    deinit {
        if let cacheObserver {
            NotificationCenter.default.removeObserver(cacheObserver)
        }
    }

    // MARK: - UI

    private func buildUI() {
        let title = NSTextField(labelWithString: "Video-Bildschirmschoner")
        title.font = .boldSystemFont(ofSize: 15)

        let hint = NSTextField(wrappingLabelWithString:
            "Wähle Videodateien oder Ordner aus (MP4, MOV, M4V …). Auch Stream-URLs (z. B. HLS .m3u8) sind möglich.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        let targetRow = NSStackView(views: [NSTextField(labelWithString: "Quellen für:"), targetPopup])
        targetHint.textColor = .secondaryLabelColor
        targetHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.title = "Quellen"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 160).isActive = true

        let addFilesButton = NSButton(title: "Videos/Ordner hinzufügen…", target: self, action: #selector(addFiles))
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        let sourceButtons = NSStackView(views: [addFilesButton, NSView(), removeButton])
        sourceButtons.orientation = .horizontal

        // URL direkt im Fenster eingeben – verschachtelte Sheets (NSAlert) machen
        // im Bildschirmschoner-Prozess Probleme.
        urlField.placeholderString = "https://example.com/video.mp4"
        urlField.target = self
        urlField.action = #selector(addURL)
        let addURLButton = NSButton(title: "URL hinzufügen", target: self, action: #selector(addURL))
        let urlRow = NSStackView(views: [urlField, addURLButton])
        urlRow.orientation = .horizontal

        cacheStatusLabel.textColor = .secondaryLabelColor
        cacheStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cacheCheckbox.target = self
        cacheCheckbox.action = #selector(cacheToggled)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearCache)
        clearCacheButton.controlSize = .small
        let cacheStatusRow = NSStackView(views: [cacheStatusLabel, clearCacheButton])
        cacheStatusRow.spacing = 8
        let cacheRow = NSStackView(views: [cacheCheckbox, cacheStatusRow])
        cacheRow.orientation = .vertical
        cacheRow.alignment = .leading
        cacheRow.spacing = 2
        cacheStatusRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        for scaling in VideoScaling.allCases {
            scalingPopup.addItem(withTitle: scaling.title)
            scalingPopup.lastItem?.tag = scaling.rawValue
        }
        let scalingRow = NSStackView(views: [NSTextField(labelWithString: "Skalierung:"), scalingPopup])

        muteCheckbox.target = self
        muteCheckbox.action = #selector(muteChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let volumeRow = NSStackView(views: [muteCheckbox, NSTextField(labelWithString: "Lautstärke:"), volumeSlider])
        volumeRow.spacing = 12

        let cancelButton = NSButton(title: "Abbrechen", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let okButton = NSButton(title: "OK", target: self, action: #selector(save))
        okButton.keyEquivalent = "\r"
        let version = Bundle(for: Self.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let dialogButtons = NSStackView(views: [versionLabel, NSView(), cancelButton, okButton])
        dialogButtons.orientation = .horizontal

        let stack = NSStackView(views: [
            title, hint, targetRow, targetHint, scrollView, sourceButtons, urlRow,
            shuffleCheckbox, subfolderCheckbox, cacheRow, scalingRow, volumeRow,
            dialogButtons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: hint)
        stack.setCustomSpacing(4, after: targetRow)
        stack.setCustomSpacing(16, after: urlRow)
        stack.setCustomSpacing(20, after: volumeRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in [hint, targetHint, scrollView, sourceButtons, urlRow, dialogButtons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    /// Lädt die gespeicherten Werte neu, z. B. wenn das Fenster erneut geöffnet wird.
    func loadValues() {
        generalSources = prefs.sources
        screenSources = prefs.screenSources
        selectedScreenID = nil
        rebuildTargetPopup()
        urlField.stringValue = ""
        shuffleCheckbox.state = prefs.shuffle ? .on : .off
        subfolderCheckbox.state = prefs.includeSubfolders ? .on : .off
        muteCheckbox.state = prefs.muted ? .on : .off
        volumeSlider.floatValue = prefs.volume
        volumeSlider.isEnabled = !prefs.muted
        scalingPopup.selectItem(withTag: prefs.scaling.rawValue)
        cacheCheckbox.state = prefs.cacheRemoteVideos ? .on : .off
        updateCacheStatus()
        tableView.reloadData()
        updateRemoveButton()
    }

    // MARK: - Bildschirme

    private struct ScreenTarget {
        let id: String
        let name: String
        let connected: Bool
    }

    /// Angeschlossene Bildschirme plus getrennte Bildschirme, für die eine eigene Liste existiert.
    private func screenTargets() -> [ScreenTarget] {
        var targets: [ScreenTarget] = []
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let id = screen.stableIdentifier else { continue }
            var name = screen.localizedName
            if index == 0 { name += " (Hauptbildschirm)" }
            targets.append(ScreenTarget(id: id, name: name, connected: true))
        }
        let known = prefs.screenNames
        for (id, list) in screenSources where !list.isEmpty && !targets.contains(where: { $0.id == id }) {
            targets.append(ScreenTarget(id: id, name: known[id] ?? "Unbekannter Bildschirm", connected: false))
        }
        return targets
    }

    private func rebuildTargetPopup() {
        targetPopup.removeAllItems()
        targetPopup.addItem(withTitle: "")
        targetPopup.lastItem?.representedObject = nil
        for target in screenTargets() {
            targetPopup.addItem(withTitle: "")
            targetPopup.lastItem?.representedObject = target
        }
        let index = targetPopup.itemArray.firstIndex {
            ($0.representedObject as? ScreenTarget)?.id == selectedScreenID
        } ?? 0
        targetPopup.selectItem(at: index)
        updateTargetTitles()
    }

    private func updateTargetTitles() {
        for item in targetPopup.itemArray {
            guard let target = item.representedObject as? ScreenTarget else {
                item.title = "Alle Bildschirme (Standard)"
                continue
            }
            let count = screenSources[target.id]?.count ?? 0
            var title = target.name
            if !target.connected { title += " – nicht verbunden" }
            title += count == 0 ? " – Standard" : " – eigene Liste (\(count))"
            item.title = title
        }
        if selectedScreenID == nil {
            targetHint.stringValue = "Gilt für alle Bildschirme ohne eigene Liste und für die Vorschau."
        } else {
            targetHint.stringValue = "Eigene Videos nur für diesen Bildschirm. Leer lassen, um die Standardliste zu verwenden."
        }
    }

    // MARK: - Zwischenspeicher

    private func updateCacheStatus() {
        let cache = VideoCache.shared
        let usage = cache.usage()
        var text = usage.count == 0
            ? "Zwischenspeicher leer"
            : "Zwischenspeicher: \(usage.count) Video\(usage.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))"
        if cache.activeDownloads > 0 {
            text += " · \(cache.activeDownloads) wird geladen"
        }
        cacheStatusLabel.stringValue = text
        clearCacheButton.isEnabled = usage.count > 0 || cache.activeDownloads > 0

        // Status der URL-Zeilen aktualisieren, ohne die Auswahl zu verlieren.
        let remoteRows = IndexSet(sources.indices.filter { sources[$0].kind == .remote })
        if !remoteRows.isEmpty {
            tableView.reloadData(forRowIndexes: remoteRows, columnIndexes: IndexSet(integer: 0))
        }
    }

    @objc private func cacheToggled() {
        updateCacheStatus()
    }

    @objc private func clearCache() {
        VideoCache.shared.clear()
    }

    private func cacheStatusText(for source: VideoSource) -> String {
        guard source.kind == .remote, let url = URL(string: source.location) else { return "" }
        switch VideoCache.shared.status(for: url) {
        case .stream:
            return "Stream (live)"
        case .downloading(let fraction):
            return "lädt \(Int(fraction * 100)) %"
        case .cached(let bytes):
            return "offline · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        case .failed:
            return "Fehler"
        case .notCached:
            return cacheCheckbox.state == .on ? "wird bei OK geladen" : "Stream"
        }
    }

    @objc private func targetChanged() {
        selectedScreenID = (targetPopup.selectedItem?.representedObject as? ScreenTarget)?.id
        updateTargetTitles()
        tableView.deselectAll(nil)
        tableView.reloadData()
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Aktionen

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .folder]
        panel.prompt = "Hinzufügen"
        panel.message = "Videodateien oder Ordner mit Videos auswählen"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let existing = Set(self.sources.map(\.location))
            let added = panel.urls.map(VideoSource.local).filter { !existing.contains($0.location) }
            self.sources.append(contentsOf: added)
            self.tableView.reloadData()
        }
    }

    @objc private func addURL() {
        let text = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            NSSound.beep()
            return
        }
        if !sources.contains(where: { $0.location == url.absoluteString }) {
            sources.append(.remote(url))
            tableView.reloadData()
        }
        urlField.stringValue = ""
    }

    @objc private func removeSelected() {
        for index in tableView.selectedRowIndexes.reversed() {
            sources.remove(at: index)
        }
        tableView.reloadData()
        updateRemoveButton()
    }

    @objc private func muteChanged() {
        volumeSlider.isEnabled = muteCheckbox.state == .off
    }

    @objc private func save() {
        // Return im URL-Feld löst auch „OK“ aus – die eingetippte URL nicht verlieren.
        if !urlField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            addURL()
        }
        prefs.sources = generalSources
        prefs.screenSources = screenSources.filter { !$0.value.isEmpty }
        var names = prefs.screenNames
        for target in screenTargets() where target.connected {
            names[target.id] = target.name.replacingOccurrences(of: " (Hauptbildschirm)", with: "")
        }
        prefs.screenNames = names
        prefs.shuffle = shuffleCheckbox.state == .on
        prefs.includeSubfolders = subfolderCheckbox.state == .on
        prefs.muted = muteCheckbox.state == .on
        prefs.volume = volumeSlider.floatValue
        prefs.scaling = VideoScaling(rawValue: scalingPopup.selectedTag()) ?? .fill
        prefs.cacheRemoteVideos = cacheCheckbox.state == .on
        prefs.synchronize()

        // Nicht mehr verwendete Videos entfernen, fehlende im Hintergrund laden.
        let remoteURLs = prefs.allRemoteURLs
        VideoCache.shared.prune(keeping: remoteURLs)
        if prefs.cacheRemoteVideos {
            VideoCache.shared.prefetch(remoteURLs)
        }
        close()
        // Erst nach dem Schließen des Sheets die Wiedergabe neu aufbauen.
        DispatchQueue.main.async { [onSave] in onSave() }
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        window.makeFirstResponder(nil)
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else if let parent = NSApp.windows.first(where: { $0.attachedSheet === window }) {
            parent.endSheet(window)
        } else {
            // Fallback, falls das Fenster nicht als Sheet angezeigt wurde.
            window.orderOut(nil)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        sources.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let source = sources[row]
        let identifier = NSUserInterfaceItemIdentifier("SourceCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SourceCellView ?? makeCell(identifier)
        cell.statusField.stringValue = cacheStatusText(for: source)
        if case .failed(let message) = URL(string: source.location).map(VideoCache.shared.status(for:)) {
            cell.statusField.toolTip = message
        } else {
            cell.statusField.toolTip = nil
        }

        switch source.kind {
        case .remote:
            cell.textField?.stringValue = source.location
            cell.imageView?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "URL")
        case .folder:
            cell.textField?.stringValue = (source.location as NSString).abbreviatingWithTildeInPath
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Ordner")
        case .file:
            cell.textField?.stringValue = (source.location as NSString).abbreviatingWithTildeInPath
            cell.imageView?.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Video")
        }
        cell.toolTip = source.location
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> SourceCellView {
        let cell = SourceCellView()
        cell.identifier = identifier
        let statusField = cell.statusField
        statusField.textColor = .secondaryLabelColor
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.alignment = .right
        statusField.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(statusField)

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: statusField.leadingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            statusField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            statusField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Tabellenzeile mit zusätzlichem Status (z. B. Download-Fortschritt) am rechten Rand.
private final class SourceCellView: NSTableCellView {
    let statusField = NSTextField(labelWithString: "")
}
