import Foundation

public struct Letterbox: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

/// A stretch of source time the export plays in one direction.
public struct AudioRun: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var reversed: Bool

    public init(start: Double, end: Double, reversed: Bool) {
        self.start = start
        self.end = end
        self.reversed = reversed
    }
}

public enum ExportPlan {
    /// Splits the frame order into runs of consecutive frames, forward or backward, so audio can be cut and reversed to match.
    public static func audioRuns(order: [Int], frames: [FrameInfo]) -> [AudioRun] {
        var runs: [AudioRun] = []
        var first = 0
        while first < order.count {
            var last = first
            if first + 1 < order.count, order[first + 1] == order[first] - 1 {
                while last + 1 < order.count, order[last + 1] == order[last] - 1 { last += 1 }
                runs.append(AudioRun(start: frames[order[last]].pts, end: frames[order[first]].end, reversed: true))
            } else {
                while last + 1 < order.count, order[last + 1] == order[last] + 1 { last += 1 }
                runs.append(AudioRun(start: frames[order[first]].pts, end: frames[order[last]].end, reversed: false))
            }
            first = last + 1
        }
        return runs
    }

    /// Source frame to show at each output tick. Each frame lasts its own
    /// duration divided by `speed`, so slow motion repeats frames.
    public static func outputFrames(order: [Int], durations: [Double], speed: Double, fps: Double) -> [Int] {
        guard !order.isEmpty, speed > 0, fps > 0 else { return [] }
        let lengths = order.map { max(durations[$0], 0.0001) / speed }
        let total = lengths.reduce(0, +)
        let ticks = max(1, Int((total * fps).rounded()))
        var result: [Int] = []
        result.reserveCapacity(ticks)
        var position = 0
        var boundary = lengths[0]
        for tick in 0..<ticks {
            let time = Double(tick) / fps
            while time >= boundary && position < order.count - 1 {
                position += 1
                boundary += lengths[position]
            }
            result.append(order[position])
        }
        return result
    }

    /// The picture fitted inside the frame without cropping, centred, with even sizes.
    public static func letterbox(sourceWidth: Int, sourceHeight: Int, frameWidth: Int, frameHeight: Int) -> Letterbox {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return Letterbox(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }
        let scale = min(Double(frameWidth) / Double(sourceWidth), Double(frameHeight) / Double(sourceHeight))
        let width = max(2, Int((Double(sourceWidth) * scale).rounded()) / 2 * 2)
        let height = max(2, Int((Double(sourceHeight) * scale).rounded()) / 2 * 2)
        return Letterbox(x: (frameWidth - width) / 2, y: (frameHeight - height) / 2, width: width, height: height)
    }

    /// The source picture size rounded down to even numbers, as H.264 needs.
    public static func evenSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(2, width / 2 * 2), max(2, height / 2 * 2))
    }

    /// Bits per second for an export that keeps the source size: more pixels get more bits, within 8 to 55 Mbit/s.
    public static func bitrate(width: Int, height: Int) -> Int {
        max(8_000_000, min(55_000_000, Int((Double(width) * Double(height) * 6.63).rounded())))
    }

    /// GIFs keep their aspect ratio and never grow past `maxWidth`.
    public static func gifSize(sourceWidth: Int, sourceHeight: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (maxWidth, maxWidth) }
        let width = min(sourceWidth, maxWidth)
        let height = Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded())
        return (width, max(1, height))
    }
}
