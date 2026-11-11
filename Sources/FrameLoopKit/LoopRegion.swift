import Foundation

public enum PlayDirection: Sendable, Equatable {
    case forward, backward
}

public enum LoopAction: Sendable, Equatable {
    case none
    /// Jump to this time and play in this direction.
    case jump(Double, PlayDirection)
}

/// Decides, from the current time, whether a looping segment must turn around or jump back.
public struct LoopRegion: Sendable {
    public var start: Double
    public var end: Double
    public var clipDuration: Double
    public var wraps: Bool
    public var pingPong: Bool
    /// How close to a boundary counts as reaching it.
    public var epsilon: Double

    public init(start: Double, end: Double, clipDuration: Double, wraps: Bool = false,
                pingPong: Bool = false, epsilon: Double = 0.004) {
        self.start = start
        self.end = end
        self.clipDuration = clipDuration
        self.wraps = wraps
        self.pingPong = pingPong
        self.epsilon = epsilon
    }

    public func action(time: Double, direction: PlayDirection) -> LoopAction {
        switch direction {
        case .backward:
            return time <= start + epsilon ? .jump(start, .forward) : .none
        case .forward:
            if wraps {
                if time >= clipDuration - epsilon { return .jump(0, .forward) }
                if time >= end - epsilon && time < start { return .jump(start, .forward) }
                return .none
            }
            guard time >= end - epsilon else { return .none }
            return pingPong ? .jump(end, .backward) : .jump(start, .forward)
        }
    }
}
