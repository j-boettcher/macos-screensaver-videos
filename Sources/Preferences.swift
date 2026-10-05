import AVFoundation
import ScreenSaver
import UniformTypeIdentifiers

enum VideoScaling: Int, CaseIterable {
    case fill = 0     // Bildschirm füllen, Ränder werden abgeschnitten
    case fit = 1      // Ganzes Video sichtbar, ggf. schwarze Balken
    case stretch = 2  // Auf Bildschirmgröße verzerren

    var title: String {
        switch self {
        case .fill: return "Füllen (zuschneiden)"
        case .fit: return "Einpassen"
        case .stretch: return "Strecken"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

struct VideoSource: Codable, Equatable {
    enum Kind: String, Codable {
        case file, folder, remote
    }

    var kind: Kind
    /// Dateipfad (lokal) bzw. URL-String (remote).
    var location: String
    /// Security-Scoped-Bookmark für lokale Dateien/Ordner.
    var bookmark: Data?

    static func local(_ url: URL) -> VideoSource {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return VideoSource(kind: isDirectory ? .folder : .file, location: url.path, bookmark: bookmark)
    }

    static func remote(_ url: URL) -> VideoSource {
        VideoSource(kind: .remote, location: url.absoluteString, bookmark: nil)
    }
}

final class Preferences {
    static let moduleName = "com.bc.VideoSaver"

    private enum Key {
        static let sources = "sources"
        static let shuffle = "shuffle"
        static let muted = "muted"
        static let volume = "volume"
        static let scaling = "scaling"
        static let includeSubfolders = "includeSubfolders"
        static let screenSources = "screenSources"
        static let screenNames = "screenNames"
        static let cacheRemoteVideos = "cacheRemoteVideos"
    }

    private let defaults: UserDefaults

    init() {
        defaults = ScreenSaverDefaults(forModuleWithName: Self.moduleName) ?? .standard
        defaults.register(defaults: [
            Key.shuffle: true,
            Key.muted: true,
            Key.volume: 0.5,
            Key.scaling: VideoScaling.fill.rawValue,
            Key.includeSubfolders: true,
            Key.cacheRemoteVideos: true,
        ])
    }

    var sources: [VideoSource] {
        get {
            guard let data = defaults.data(forKey: Key.sources) else { return [] }
            return (try? JSONDecoder().decode([VideoSource].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.sources) }
    }

    /// Eigene Quellen pro Bildschirm, Schlüssel ist `NSScreen.stableIdentifier`.
    var screenSources: [String: [VideoSource]] {
        get {
            guard let data = defaults.data(forKey: Key.screenSources) else { return [:] }
            return (try? JSONDecoder().decode([String: [VideoSource]].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.screenSources) }
    }

    /// Zuletzt bekannte Namen der Bildschirme, um auch getrennte Bildschirme anzeigen zu können.
    var screenNames: [String: String] {
        get { defaults.dictionary(forKey: Key.screenNames) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.screenNames) }
    }

    /// Quellen für einen Bildschirm; ohne eigene Liste gilt die Standardliste.
    func sources(forScreen identifier: String?) -> [VideoSource] {
        if let identifier, let own = screenSources[identifier], !own.isEmpty {
            return own
        }
        return sources
    }

    /// URL-Videos herunterladen und lokal abspielen (siehe `VideoCache`).
    var cacheRemoteVideos: Bool {
        get { defaults.bool(forKey: Key.cacheRemoteVideos) }
        set { defaults.set(newValue, forKey: Key.cacheRemoteVideos) }
    }

    /// Alle URL-Quellen aus der Standardliste und den Bildschirmlisten.
    var allRemoteURLs: [URL] {
        (sources + screenSources.values.flatMap { $0 })
            .filter { $0.kind == .remote }
            .compactMap { URL(string: $0.location) }
    }

    var shuffle: Bool {
        get { defaults.bool(forKey: Key.shuffle) }
        set { defaults.set(newValue, forKey: Key.shuffle) }
    }

    var muted: Bool {
        get { defaults.bool(forKey: Key.muted) }
        set { defaults.set(newValue, forKey: Key.muted) }
    }

    var volume: Float {
        get { defaults.float(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }

    var scaling: VideoScaling {
        get { VideoScaling(rawValue: defaults.integer(forKey: Key.scaling)) ?? .fill }
        set { defaults.set(newValue.rawValue, forKey: Key.scaling) }
    }

    var includeSubfolders: Bool {
        get { defaults.bool(forKey: Key.includeSubfolders) }
        set { defaults.set(newValue, forKey: Key.includeSubfolders) }
    }

    func synchronize() {
        defaults.synchronize()
    }
}

extension NSScreen {
    /// Stabile Kennung des Bildschirms (bleibt über Neustarts und Neuverbinden gleich).
    var stableIdentifier: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Löst die gespeicherten Quellen in abspielbare URLs auf und hält die
/// Security-Scoped-Zugriffe offen, solange die Instanz lebt.
final class VideoLibrary {
    private(set) var videoURLs: [URL] = []
    private var scopedURLs: [URL] = []

    init(sources: [VideoSource], includeSubfolders: Bool) {
        for source in sources {
            switch source.kind {
            case .remote:
                if let url = URL(string: source.location) {
                    videoURLs.append(url)
                }
            case .file:
                videoURLs.append(resolve(source))
            case .folder:
                videoURLs.append(contentsOf: Self.videos(in: resolve(source), recursive: includeSubfolders))
            }
        }
    }

    deinit {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    private func resolve(_ source: VideoSource) -> URL {
        if let bookmark = source.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if url.startAccessingSecurityScopedResource() {
                    scopedURLs.append(url)
                }
                return url
            }
        }
        // Fallback: legacyScreenSaver darf das Dateisystem ohnehin lesend nutzen.
        return URL(fileURLWithPath: source.location)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    private static func videos(in folder: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false
            if isFile && isVideo(url) {
                result.append(url)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
