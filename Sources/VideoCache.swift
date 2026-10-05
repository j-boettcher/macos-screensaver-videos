import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Lädt Videos von URLs herunter und spielt danach die lokale Kopie ab.
///
/// Jede URL wird als `<sha256>.<endung>` im Caches-Ordner des Bildschirmschoner-Containers
/// abgelegt. HLS-Streams werden mit einer leeren `<sha256>.stream`-Datei markiert und nie
/// heruntergeladen. Der Zustand liegt nur im Dateisystem, damit Vorschau und Vollbild-Instanzen
/// (ggf. in getrennten Prozessen) denselben Zwischenspeicher nutzen.
final class VideoCache: NSObject {
    static let shared = VideoCache()

    /// Wird (auf dem Main-Thread) bei Fortschritt, Abschluss oder Fehlern eines Downloads gesendet.
    static let didChangeNotification = Notification.Name("BCVideoSaverCacheDidChange")

    enum Status {
        case notCached
        case downloading(Double)
        case cached(Int64)
        case stream
        case failed(String)
    }

    let directory: URL

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // Nur auf dem Main-Thread verwenden.
    private var tasks: [URL: URLSessionDownloadTask] = [:]
    private var progressObservers: [URL: NSKeyValueObservation] = [:]
    private var failures: [URL: String] = [:]
    /// Zuordnung Dateiname → URL, um defekte Dateien ihrer URL zuordnen zu können.
    private var urlsByKey: [String: URL] = [:]

    private override init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent(Preferences.moduleName, isDirectory: true)
            .appendingPathComponent("VideoCache", isDirectory: true)
        super.init()
    }

    // MARK: - Abfragen

    static func isRemote(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func isPlaylist(_ url: URL) -> Bool {
        ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
    }

    /// Lokale Kopie, falls vorhanden – sonst die Original-URL. Fehlt die Kopie,
    /// wird der Download angestoßen und bis dahin gestreamt.
    func playableURL(for url: URL) -> URL {
        guard Self.isRemote(url) else { return url }
        urlsByKey[Self.key(for: url)] = url
        if let local = cachedFile(for: url) {
            return local
        }
        download(url)
        return url
    }

    func cachedFile(for url: URL) -> URL? {
        files(for: url).first { $0.pathExtension != "stream" }
    }

    func status(for url: URL) -> Status {
        if let task = tasks[url] {
            return .downloading(task.progress.fractionCompleted)
        }
        let files = files(for: url)
        if let file = files.first(where: { $0.pathExtension != "stream" }) {
            return .cached(Self.size(of: file))
        }
        if Self.isPlaylist(url) || !files.isEmpty {
            return .stream
        }
        if let failure = failures[url] {
            return .failed(failure)
        }
        return .notCached
    }

    /// Belegter Speicher und Anzahl gespeicherter Videos.
    func usage() -> (bytes: Int64, count: Int) {
        let videos = allFiles().filter { $0.pathExtension != "stream" }
        return (videos.reduce(0) { $0 + Self.size(of: $1) }, videos.count)
    }

    var activeDownloads: Int { tasks.count }

    // MARK: - Downloads

    /// Startet den Download, falls nötig. Nach einem Fehler wird es im selben Prozess
    /// nur mit `retry` erneut versucht, damit defekte URLs nicht endlos geladen werden.
    func download(_ url: URL, retry: Bool = false) {
        guard Self.isRemote(url), !Self.isPlaylist(url), tasks[url] == nil, files(for: url).isEmpty,
              retry || failures[url] == nil else { return }
        failures[url] = nil

        let key = Self.key(for: url)
        let directory = directory
        let task = session.downloadTask(with: url) { [weak self] location, response, error in
            // Läuft im Hintergrund; die temporäre Datei muss hier verschoben werden.
            var failure: String?
            if let error {
                failure = (error as NSError).code == NSURLErrorCancelled ? nil : error.localizedDescription
            } else if let location, let response {
                failure = Self.store(location, response: response, url: url, key: key, in: directory)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks[url] = nil
                self.progressObservers[url] = nil
                if let failure {
                    self.failures[url] = failure
                    NSLog("BCVideoSaver: Download fehlgeschlagen (\(url.absoluteString)): \(failure)")
                }
                self.notify(url)
            }
        }
        tasks[url] = task
        var lastReported = -1.0
        progressObservers[url] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            // Höchstens in 1-%-Schritten melden.
            let value = (progress.fractionCompleted * 100).rounded()
            guard value != lastReported else { return }
            lastReported = value
            DispatchQueue.main.async { self?.notify(url) }
        }
        task.resume()
        notify(url)
    }

    /// Lädt alle noch fehlenden Videos und versucht fehlgeschlagene erneut.
    func prefetch(_ urls: [URL]) {
        urls.forEach { download($0, retry: true) }
    }

    /// Entfernt eine zwischengespeicherte Datei, die sich nicht abspielen ließ.
    func invalidate(_ file: URL?) {
        guard let file, file.isFileURL,
              file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: file)
        let key = file.deletingPathExtension().lastPathComponent
        if let url = urlsByKey[key] {
            failures[url] = "Gespeicherte Datei ließ sich nicht abspielen"
        }
        NSLog("BCVideoSaver: Defekte Datei aus dem Zwischenspeicher entfernt: \(file.lastPathComponent)")
        notify(nil)
    }

    /// Entfernt Dateien und Downloads von URLs, die in keiner Liste mehr vorkommen.
    func prune(keeping urls: [URL]) {
        let keep = Set(urls.map(Self.key))
        for (url, task) in tasks where !keep.contains(Self.key(for: url)) {
            task.cancel()
            tasks[url] = nil
            progressObservers[url] = nil
        }
        for file in allFiles() where !keep.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        notify(nil)
    }

    func clear() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        progressObservers.removeAll()
        failures.removeAll()
        try? FileManager.default.removeItem(at: directory)
        notify(nil)
    }

    // MARK: - Intern

    private func notify(_ url: URL?) {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: url.map { ["url": $0] })
    }

    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func files(for url: URL) -> [URL] {
        let key = Self.key(for: url)
        return allFiles().filter { $0.deletingPathExtension().lastPathComponent == key }
    }

    private func allFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.pathExtension != "part" }
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Verschiebt die heruntergeladene Datei in den Zwischenspeicher. Gibt eine Fehlermeldung zurück.
    private static func store(_ location: URL, response: URLResponse, url: URL, key: String, in directory: URL) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return "Server antwortet mit Status \(http.statusCode)"
        }
        let mimeType = response.mimeType?.lowercased() ?? ""
        if mimeType.contains("mpegurl") {
            // HLS-Playlist ohne .m3u8-Endung: als Stream merken, nicht speichern.
            fileManager.createFile(atPath: directory.appendingPathComponent("\(key).stream").path, contents: nil)
            return nil
        }
        if mimeType.hasPrefix("text/") || mimeType.contains("html") {
            return "Die URL liefert kein Video (\(mimeType))"
        }

        let destination = directory.appendingPathComponent("\(key).\(fileExtension(for: url, mimeType: mimeType))")
        // Erst unter temporärem Namen ablegen und dann umbenennen, damit nie
        // eine halbe Datei abgespielt wird.
        let partial = directory.appendingPathComponent("\(key).\(UUID().uuidString).part")
        do {
            try fileManager.moveItem(at: location, to: partial)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            return nil
        } catch {
            try? fileManager.removeItem(at: partial)
            return error.localizedDescription
        }
    }

    private static func fileExtension(for url: URL, mimeType: String) -> String {
        let pathExtension = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: pathExtension), type.conforms(to: .movie) {
            return pathExtension
        }
        if let type = UTType(mimeType: mimeType), type.conforms(to: .movie),
           let preferred = type.preferredFilenameExtension {
            return preferred
        }
        return "mp4"
    }
}
