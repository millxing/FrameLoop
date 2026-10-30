import Foundation

public enum PlaybackSpeed {
    public static let all: [Double] = [1, 0.75, 0.5, 0.25]

    public static func label(_ speed: Double) -> String {
        speed == 1 ? "1×" : String(format: "%g×", speed)
    }
}

public enum MediaFormats {
    public static let supported = ["mp4", "m4v", "mov", "mkv", "avi", "flv", "gif"]
    /// What AVFoundation opens without help.
    public static let native: Set<String> = ["mp4", "m4v", "mov"]

    public static func isSupported(_ url: URL) -> Bool {
        supported.contains(url.pathExtension.lowercased())
    }

    public static func isNative(_ url: URL) -> Bool {
        native.contains(url.pathExtension.lowercased())
    }

    /// Supported videos in a folder's file names, sorted ignoring case.
    public static func filter(_ names: [String]) -> [String] {
        names
            .filter { supported.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

public enum FileCounter {
    /// The next unused number: above the saved counter and above every `prefix########.ext` already in the folder.
    public static func next(saved: Int, fileNames: [String], prefix: String, ext: String) -> Int {
        var highest = 0
        let head = prefix
        let tail = "." + ext
        for name in fileNames where name.hasPrefix(head) && name.hasSuffix(tail) {
            let digits = name.dropFirst(head.count).dropLast(tail.count)
            if digits.count == 8, let number = Int(digits) { highest = max(highest, number) }
        }
        return max(1, saved, highest + 1)
    }

    public static func fileName(prefix: String, counter: Int, ext: String) -> String {
        prefix + String(format: "%08d", counter) + "." + ext
    }
}
