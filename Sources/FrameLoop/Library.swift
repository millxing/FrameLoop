import FrameLoopKit
import Foundation
import Observation

/// The folder list in the sidebar: which shortcut is chosen and the videos in it.
@Observable
final class Library {
    var folderID: String
    private(set) var files: [URL] = []
    private(set) var isMissing = false

    init() {
        folderID = AppSettings.shared.folderSlots.first?.id ?? "movies"
    }

    var folder: FolderSlot? {
        AppSettings.shared.folderSlots.first { $0.id == folderID } ?? AppSettings.shared.folderSlots.first
    }

    func refresh() async {
        guard let folder else { return }
        let directory = URL(fileURLWithPath: folder.path, isDirectory: true)
        let result = await Self.list(directory)
        files = result?.map { directory.appending(path: $0) } ?? []
        isMissing = result == nil
    }

    @concurrent
    private static func list(_ directory: URL) async -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return MediaFormats.filter(names)
    }
}
