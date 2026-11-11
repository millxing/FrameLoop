import Foundation
import FrameLoopKit
import Observation

struct FolderSlot: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var path: String
}

/// Where the data lives: settings only, no database. APP_STORE (tests, snapshots) keeps everything in /tmp
/// and never touches the real settings.
enum Store {
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    /// Sample videos and exports for tests and snapshots.
    static let scratch = URL(fileURLWithPath: "/tmp/FrameLoop-scratch", isDirectory: true)
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Kind { case screenshot, mp4, gif }

    var folderSlots: [FolderSlot] { didSet { save() } }
    var screenshotDirectory: String { didSet { save() } }
    var exportDirectory: String { didSet { save() } }
    private(set) var screenshotCounter: Int
    private(set) var exportCounter: Int
    /// Settings reopens on the last tab. Not saved.
    var settingsTab: SettingsTab = .folders

    private struct Saved: Codable {
        var folderSlots: [FolderSlot]
        var screenshotDirectory: String
        var exportDirectory: String
        var screenshotCounter: Int
        var exportCounter: Int
    }

    private static let key = "settings.v1"

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func folder(_ id: String, _ label: String, _ name: String) -> FolderSlot {
            FolderSlot(id: id, label: label, path: home.appending(path: name).path)
        }
        var slots = [folder("movies", "Movies", "Movies"), folder("downloads", "Downloads", "Downloads"),
                     folder("desktop", "Desktop", "Desktop"), folder("documents", "Documents", "Documents"),
                     folder("pictures", "Pictures", "Pictures")]
        var shots = home.appending(path: "Pictures/FrameLoop Screenshots").path
        var exports = home.appending(path: "Movies/FrameLoop Exports").path
        var shotCounter = 1
        var exportCounter = 1
        if Store.isOverridden {
            slots[0].path = Store.scratch.appending(path: "videos").path
            shots = Store.scratch.appending(path: "screenshots").path
            exports = Store.scratch.appending(path: "exports").path
        } else if let data = UserDefaults.standard.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.folderSlots.count == 5 {
            slots = saved.folderSlots
            shots = saved.screenshotDirectory
            exports = saved.exportDirectory
            shotCounter = saved.screenshotCounter
            exportCounter = saved.exportCounter
        }
        folderSlots = slots
        screenshotDirectory = shots
        exportDirectory = exports
        screenshotCounter = shotCounter
        self.exportCounter = exportCounter
    }

    private func save() {
        guard !Store.isOverridden else { return }
        let saved = Saved(folderSlots: folderSlots, screenshotDirectory: screenshotDirectory,
                          exportDirectory: exportDirectory, screenshotCounter: screenshotCounter,
                          exportCounter: exportCounter)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Reserves the next free `ss########.png` or `loop########.mp4/.gif` in the save folder.
    func allocate(_ kind: Kind) throws -> URL {
        let isShot = kind == .screenshot
        let prefix = isShot ? "ss" : "loop"
        let ext = isShot ? "png" : kind == .gif ? "gif" : "mp4"
        let directory = URL(fileURLWithPath: isShot ? screenshotDirectory : exportDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var counter = FileCounter.next(saved: isShot ? screenshotCounter : exportCounter,
                                       fileNames: names, prefix: prefix, ext: ext)
        var url = directory.appending(path: FileCounter.fileName(prefix: prefix, counter: counter, ext: ext))
        while FileManager.default.fileExists(atPath: url.path), counter < 99_999_999 {
            counter += 1
            url = directory.appending(path: FileCounter.fileName(prefix: prefix, counter: counter, ext: ext))
        }
        if isShot { screenshotCounter = counter + 1 } else { exportCounter = counter + 1 }
        save()
        return url
    }
}
