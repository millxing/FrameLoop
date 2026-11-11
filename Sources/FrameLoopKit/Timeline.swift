import Foundation

/// One stretch of a track's edit list: media from `sourceStart` to `sourceEnd` plays from `targetStart` on.
/// Files often start with a short empty edit, or skip the first packets, so packet times are not play times.
public struct MediaSegment: Sendable, Equatable {
    public var sourceStart: Double
    public var sourceEnd: Double
    public var targetStart: Double

    public init(sourceStart: Double, sourceEnd: Double, targetStart: Double) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.targetStart = targetStart
    }

    /// Packet times turned into play times. Packets outside every segment are never shown, so they are dropped.
    /// No segments means no edit list: the times are returned as they are.
    public static func playTimes(of times: [Double], segments: [MediaSegment]) -> [Double] {
        guard !segments.isEmpty else { return times }
        let slack = 0.0005
        return times.compactMap { time in
            segments.first { time >= $0.sourceStart - slack && time < $0.sourceEnd - slack }
                .map { $0.targetStart + max(0, time - $0.sourceStart) }
        }
    }
}

/// One video frame: its index in presentation order, when it appears, how long it stays.
public struct FrameInfo: Sendable, Equatable {
    public var index: Int
    public var pts: Double
    public var duration: Double

    public init(index: Int, pts: Double, duration: Double) {
        self.index = index
        self.pts = pts
        self.duration = duration
    }

    public var end: Double { pts + duration }
    /// Where to seek to show exactly this frame: the middle of its interval, so timestamp rounding never lands on a neighbour.
    public var seekTime: Double { pts + duration * 0.5 }
}

/// The marked segment. `endFrame == nil` means only the start is set.
/// An end before the start wraps around the end of the clip.
public struct Segment: Sendable, Equatable {
    public var startFrame: Int
    public var endFrame: Int?

    public init(startFrame: Int, endFrame: Int? = nil) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    public var isComplete: Bool { endFrame != nil }
}

public enum Timeline {
    public static func clampFrame(_ index: Int, frameCount: Int) -> Int {
        max(0, min(max(0, frameCount - 1), index))
    }

    /// The frame showing at `time`: the last frame whose start is at or before it.
    public static func frameAtTime(_ frames: [FrameInfo], time: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        var low = 0
        var high = frames.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if frames[middle].pts <= time { low = middle + 1 } else { high = middle - 1 }
        }
        return clampFrame(high, frameCount: frames.count)
    }

    /// Frame ranges the segment covers, in play order. An end before the start gives two ranges.
    public static func segmentRanges(_ segment: Segment, frameCount: Int) -> [ClosedRange<Int>] {
        guard let endFrame = segment.endFrame, frameCount > 0 else { return [] }
        let start = clampFrame(segment.startFrame, frameCount: frameCount)
        let end = clampFrame(endFrame, frameCount: frameCount)
        return start <= end ? [start...end] : [start...(frameCount - 1), 0...end]
    }

    public static func segmentFrameCount(_ segment: Segment, frameCount: Int) -> Int {
        segmentRanges(segment, frameCount: frameCount).reduce(0) { $0 + $1.count }
    }

    /// What is left after cutting the segment out.
    public static func remainingRanges(_ segment: Segment, frameCount: Int) -> [ClosedRange<Int>] {
        guard frameCount > 0 else { return [] }
        let removed = segmentRanges(segment, frameCount: frameCount)
        switch removed.count {
        case 0:
            return [0...(frameCount - 1)]
        case 2:
            let headEnd = removed[1].upperBound
            let tailStart = removed[0].lowerBound
            return headEnd + 1 <= tailStart - 1 ? [(headEnd + 1)...(tailStart - 1)] : []
        default:
            let range = removed[0]
            var kept: [ClosedRange<Int>] = []
            if range.lowerBound > 0 { kept.append(0...(range.lowerBound - 1)) }
            if range.upperBound < frameCount - 1 { kept.append((range.upperBound + 1)...(frameCount - 1)) }
            return kept
        }
    }

    /// 0...n-1, then n-2...1, so repeating the sequence never shows a frame twice in a row.
    public static func pingPongOrder(_ forward: [Int]) -> [Int] {
        forward.count < 3 ? forward : forward + forward[1..<(forward.count - 1)].reversed()
    }

    /// 01:05.250, or 01:02:03.250 from one hour up.
    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let whole = Int(seconds)
        let milliseconds = Int((seconds - Double(whole)) * 1000)
        let hours = whole / 3600
        let minutes = (whole / 60) % 60
        let secs = whole % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
            : String(format: "%02d:%02d.%03d", minutes, secs, milliseconds)
    }
}
