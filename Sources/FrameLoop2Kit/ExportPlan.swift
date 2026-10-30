import Foundation

public struct Letterbox: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

public enum ExportPlan {
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

    /// GIFs keep their aspect ratio and never grow past `maxWidth`.
    public static func gifSize(sourceWidth: Int, sourceHeight: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (maxWidth, maxWidth) }
        let width = min(sourceWidth, maxWidth)
        let height = Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded())
        return (width, max(1, height))
    }
}
