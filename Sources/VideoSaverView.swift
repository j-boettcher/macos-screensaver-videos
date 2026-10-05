import AVFoundation
import ScreenSaver

@objc(VideoSaverView)
final class VideoSaverView: ScreenSaverView {
    private let prefs = Preferences()
    private let playerLayer = AVPlayerLayer()
    private let messageLayer = CATextLayer()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var library: VideoLibrary?
    private var playlist: [URL] = []
    private var nextIndex = 0
    private var consecutiveFailures = 0
    private var failedItems: Set<ObjectIdentifier> = []
    /// Wird bei jedem Neuaufbau erhöht, damit verspätete Meldungen alter Videos ignoriert werden.
    private var generation = 0

    private var endObserver: NSObjectProtocol?
    private var itemObserver: NSKeyValueObservation?
    private var looperObserver: NSKeyValueObservation?
    private var loopCountObserver: NSKeyValueObservation?
    private var statusObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var configController: ConfigureSheetController?
    /// Bildschirm, für den die aktuelle Wiedergabe aufgebaut wurde.
    private var playbackScreenID: String?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUpLayers()
        animationTimeInterval = 1.0

        // Seit macOS 14 ruft legacyScreenSaver stopAnimation() nicht mehr
        // zuverlässig auf, die Instanz bleibt im Hintergrund aktiv.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenSaverWillStop(_:)),
            name: NSNotification.Name("com.apple.screensaver.willstop"),
            object: nil
        )

        // Rückfallebene, falls die Vorschau weder startAnimation() noch
        // viewDidMoveToWindow() mit Fenster erhält.
        if isPreviewInstance {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startPreviewIfNeeded()
            }
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLayers()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - ScreenSaverView

    override func startAnimation() {
        super.startAnimation()
        if player == nil {
            setUpPlayback()
        }
        player?.play()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // Vorschau wurde ausgeblendet (z. B. Systemeinstellungen geschlossen): Ressourcen freigeben.
            if isPreviewInstance {
                tearDownPlayback()
            }
            return
        }
        if isPreviewInstance {
            // Beim erneuten Öffnen der Systemeinstellungen ruft macOS 14+ für die
            // Vorschau oft kein startAnimation() auf – das Bild bliebe schwarz.
            startPreviewIfNeeded()
        } else if player != nil || !messageLayer.isHidden, screenIdentifier != playbackScreenID {
            // Der Bildschirm steht oft erst fest, wenn die Ansicht im Fenster liegt.
            reloadPlayback()
        }
    }

    private func startPreviewIfNeeded() {
        guard isPreviewInstance, player == nil else { return }
        setUpPlayback()
        player?.play()
    }

    override func stopAnimation() {
        super.stopAnimation()
        player?.pause()
    }

    override func animateOneFrame() {
        // Die Wiedergabe läuft über AVPlayerLayer, hier ist nichts zu zeichnen.
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        // Immer dasselbe Fenster zurückgeben; legacyScreenSaver fragt die Eigenschaft
        // mehrfach ab und kommt mit ständig neuen Fenstern nicht zurecht.
        if let configController {
            configController.loadValues()
            return configController.window
        }
        let controller = ConfigureSheetController(preferences: prefs) { [weak self] in
            self?.reloadPlayback()
        }
        configController = controller
        return controller.window
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        layoutMessage()
        CATransaction.commit()
    }

    // MARK: - Layers

    private func setUpLayers() {
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        playerLayer.frame = bounds
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = prefs.scaling.videoGravity
        root.addSublayer(playerLayer)

        messageLayer.alignmentMode = .center
        messageLayer.isWrapped = true
        messageLayer.foregroundColor = NSColor(white: 1, alpha: 0.7).cgColor
        messageLayer.font = NSFont.systemFont(ofSize: 0, weight: .medium)
        messageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        messageLayer.isHidden = true
        root.addSublayer(messageLayer)
    }

    private func showMessage(_ text: String) {
        messageLayer.string = text
        messageLayer.isHidden = false
        layoutMessage()
    }

    private func layoutMessage() {
        let fontSize = max(10, min(28, bounds.width / 40))
        messageLayer.fontSize = fontSize
        let height = fontSize * 6
        messageLayer.frame = CGRect(
            x: bounds.width * 0.1,
            y: (bounds.height - height) / 2,
            width: bounds.width * 0.8,
            height: height
        )
    }

    // MARK: - Wiedergabe

    private func reloadPlayback() {
        let wasPlaying = isAnimating
        tearDownPlayback()
        setUpPlayback()
        if wasPlaying || isPreviewInstance {
            player?.play()
        }
    }

    /// Die Vorschau in den Systemeinstellungen ist klein; isPreview ist seit macOS 14 nicht immer korrekt.
    private var isPreviewInstance: Bool {
        isPreview || bounds.width <= 600
    }

    private var screenIdentifier: String? {
        isPreviewInstance ? nil : window?.screen?.stableIdentifier
    }

    private var currentSources: [VideoSource] {
        guard isPreviewInstance else { return prefs.sources(forScreen: screenIdentifier) }
        // Vorschau: Standardliste, sonst die erste eigene Bildschirmliste.
        if !prefs.sources.isEmpty { return prefs.sources }
        return prefs.screenSources.values.first { !$0.isEmpty } ?? []
    }

    private func setUpPlayback() {
        playbackScreenID = screenIdentifier
        let sources = currentSources
        let library = VideoLibrary(sources: sources, includeSubfolders: prefs.includeSubfolders)
        self.library = library
        playlist = prefs.shuffle ? library.videoURLs.shuffled() : library.videoURLs
        nextIndex = 0
        consecutiveFailures = 0
        failedItems = []
        generation += 1

        guard !playlist.isEmpty else {
            showMessage(sources.isEmpty
                ? "Keine Videos ausgewählt.\nUnter „Optionen…“ Videos oder Ordner hinzufügen."
                : "In den ausgewählten Quellen wurden keine Videos gefunden.")
            return
        }
        messageLayer.isHidden = true

        let player = AVQueuePlayer()
        player.isMuted = isPreviewInstance || prefs.muted
        player.volume = prefs.volume
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        self.player = player

        playerLayer.videoGravity = prefs.scaling.videoGravity
        playerLayer.player = player

        if playlist.count == 1 {
            // Ein einzelnes Video lückenlos wiederholen.
            let source = playlist[0]
            let playbackURL = playbackURL(for: source)
            let template = AVPlayerItem(url: playbackURL)
            let looper = AVPlayerLooper(player: player, templateItem: template)
            self.looper = looper
            checkDecodable(template) { [weak self] error in self?.playbackFailed(error, url: playbackURL) }
            looperObserver = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                DispatchQueue.main.async { self?.playbackFailed(looper.error, url: playbackURL) }
            }
            if VideoCache.isRemote(playbackURL), prefs.cacheRemoteVideos {
                // Wird noch gestreamt: nach Abschluss des Downloads am Ende eines
                // Durchlaufs auf die lokale Kopie wechseln.
                loopCountObserver = looper.observe(\.loopCount, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self, VideoCache.shared.cachedFile(for: source) != nil else { return }
                        self.reloadPlayback()
                    }
                }
            }
            return
        }

        player.actionAtItemEnd = .advance
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem,
                  self.player?.items().contains(item) == true else { return }
            self.consecutiveFailures = 0
        }
        // Die Warteschlange immer mit dem aktuellen und dem nächsten Video gefüllt halten,
        // damit der Übergang ohne Ladepause erfolgt. Defekte Videos überspringt AVQueuePlayer selbst.
        itemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fillQueue() }
        }
    }

    private func fillQueue() {
        guard let player else { return }
        for _ in 0..<2 where self.player != nil && player.items().count < 2 {
            enqueueNext()
        }
        if player.timeControlStatus == .paused, isAnimating || isPreviewInstance {
            player.play()
        }
    }

    /// AVPlayer meldet bei nicht dekodierbaren Codecs (z. B. AV1 ohne Hardware-Decoder)
    /// keinen Fehler, sondern zeigt nur ein schwarzes Bild. Daher vorab prüfen.
    private func checkDecodable(_ item: AVPlayerItem, onFailure: @escaping (Error) -> Void) {
        let asset = item.asset
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var decodable = !tracks.isEmpty
                for track in tracks where try await !track.load(.isDecodable) {
                    decodable = false
                }
                guard !decodable else { return }
                let reason = tracks.isEmpty
                    ? "Die Datei enthält keine Videospur."
                    : "Der Videocodec wird auf diesem Mac nicht unterstützt."
                let error = NSError(domain: "BCVideoSaver", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: reason,
                    NSLocalizedFailureReasonErrorKey: reason,
                ])
                await MainActor.run { onFailure(error) }
            } catch {
                // Ladefehler meldet der Player selbst über item.status.
            }
        }
    }

    private func itemFailed(_ item: AVPlayerItem, error: Error?, generation: Int) {
        // Meldungen aus einer früheren Wiedergabe ignorieren, jedes Video nur einmal zählen.
        guard let player, generation == self.generation,
              failedItems.insert(ObjectIdentifier(item)).inserted else { return }
        NSLog("BCVideoSaver: Video konnte nicht abgespielt werden (\((item.asset as? AVURLAsset)?.url.absoluteString ?? "?")): \(error?.localizedDescription ?? "unbekannter Fehler")")
        statusObservers[ObjectIdentifier(item)] = nil
        VideoCache.shared.invalidate((item.asset as? AVURLAsset)?.url)
        consecutiveFailures += 1
        if consecutiveFailures >= playlist.count {
            playbackFailed(error)
            return
        }
        if player.currentItem === item {
            player.advanceToNextItem()
        } else if player.items().contains(where: { $0 === item }) {
            player.remove(item)
        }
        fillQueue()
    }

    private func playbackFailed(_ error: Error?, url: URL? = nil) {
        guard player != nil else { return }
        VideoCache.shared.invalidate(url)
        NSLog("BCVideoSaver: Wiedergabe abgebrochen: \(error?.localizedDescription ?? "unbekannter Fehler")")
        tearDownPlayback()
        var text = "Die ausgewählten Videos konnten nicht abgespielt werden."
        if let error = error as NSError? {
            text += "\n\(error.localizedFailureReason ?? error.localizedDescription)"
        }
        text += "\nUnterstützt: MP4/MOV mit H.264, HEVC oder ProRes (AV1 erst ab M3-Chip)."
        showMessage(text)
    }

    private func enqueueNext() {
        guard let player, !playlist.isEmpty else { return }
        if nextIndex >= playlist.count {
            nextIndex = 0
            if prefs.shuffle {
                let last = playlist.last
                playlist.shuffle()
                // Dasselbe Video nicht zweimal hintereinander zeigen.
                if playlist.count > 1, playlist.first == last {
                    playlist.swapAt(0, playlist.count - 1)
                }
            }
        }
        let item = AVPlayerItem(url: playbackURL(for: playlist[nextIndex]))
        nextIndex += 1
        let generation = generation
        statusObservers[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.itemFailed(item, error: item.error, generation: generation) }
        }
        checkDecodable(item) { [weak self] error in self?.itemFailed(item, error: error, generation: generation) }
        // Beobachter abgespielter Videos aufräumen.
        let queued = Set(player.items().map(ObjectIdentifier.init))
        statusObservers = statusObservers.filter { queued.contains($0.key) || $0.key == ObjectIdentifier(item) }
        player.insert(item, after: nil)
    }

    /// Lokale Kopie aus dem Zwischenspeicher verwenden, sofern vorhanden.
    private func playbackURL(for url: URL) -> URL {
        prefs.cacheRemoteVideos ? VideoCache.shared.playableURL(for: url) : url
    }

    private func tearDownPlayback() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        itemObserver = nil
        looperObserver = nil
        loopCountObserver = nil
        statusObservers.removeAll()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        playerLayer.player = nil
        player = nil
        library = nil
    }

    @objc private func screenSaverWillStop(_ note: Notification) {
        // Die Vorschau in den Systemeinstellungen nicht anfassen. isPreview ist seit
        // macOS 14 nicht immer korrekt, daher zusätzlich an der Größe erkennen.
        guard !isPreviewInstance else { return }
        // Vollbild-Instanz freigeben, sie wird von macOS oft nicht mehr beendet.
        // Bei erneutem Start baut startAnimation() die Wiedergabe neu auf.
        tearDownPlayback()
    }
}
