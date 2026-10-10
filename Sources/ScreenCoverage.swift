import AppKit
import os

/// Workaround für einen macOS-Fehler (seit macOS 14): Muss legacyScreenSaver beim Start des
/// Bildschirmschoners erst gestartet werden, legt macOS gelegentlich für einen Bildschirm keine
/// Instanz an – dieser bleibt dann schwarz. Beendet sich der Prozess, startet macOS ihn sofort
/// neu und fordert dabei alle Bildschirme erneut an. Fehlt einige Sekunden nach dem Start ein
/// Bildschirm, beendet sich der Prozess deshalb einmal selbst.
enum ScreenCoverage {
    /// Vollbild-Instanzen des laufenden Bildschirmschoners in diesem Prozess.
    private static let active = NSHashTable<NSView>.weakObjects()
    private static var checkScheduled = false
    private static let checkDelay: TimeInterval = 5
    /// Fehlt ein Bildschirm auch so kurz nach einem Neustart noch, hilft ein weiterer nicht.
    private static let restartInterval: TimeInterval = 60

    static func didStart(_ view: NSView) {
        active.add(view)
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) {
            checkScheduled = false
            check()
        }
    }

    static func didStop(_ view: NSView) {
        active.remove(view)
    }

    private static func check() {
        let views = active.allObjects
        guard !views.isEmpty else { return }  // Bildschirmschoner schon wieder beendet

        let prefs = Preferences()
        let covered = Set(views.compactMap { $0.window?.screen?.stableIdentifier })
        var uncoverable = Set(prefs.uncoverableScreens)
        if !uncoverable.isDisjoint(with: covered) {
            uncoverable.subtract(covered)
            prefs.uncoverableScreens = Array(uncoverable)
        }

        let missing = NSScreen.screens.compactMap(\.stableIdentifier)
            .filter { !covered.contains($0) && !uncoverable.contains($0) }
        guard views.count < NSScreen.screens.count, !missing.isEmpty else { return }

        // Die Hintergrundbild-Einstellungen zeigen eine Live-Vorschau auf nur einem Bildschirm.
        // Diese Instanzen laufen im selben Prozess und dürfen nicht beendet werden.
        let settingsOpen = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.apple.systempreferences" }
        guard !settingsOpen else { return }

        if let last = prefs.lastScreenRestart, Date().timeIntervalSince(last) < restartInterval {
            Logger.saver.notice("Auch nach Neustart keine Instanz für \(missing, privacy: .public) – macOS zeigt dort keinen Bildschirmschoner")
            prefs.uncoverableScreens = Array(uncoverable.union(missing))
            prefs.synchronize()
            return
        }
        Logger.saver.notice("macOS hat für \(missing, privacy: .public) keine Instanz angelegt – starte legacyScreenSaver neu")
        prefs.lastScreenRestart = Date()
        prefs.synchronize()
        exit(0)
    }
}
