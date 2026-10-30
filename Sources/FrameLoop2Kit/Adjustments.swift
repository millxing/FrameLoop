import Foundation

/// Picture controls for viewing and exporting. Each value has a neutral point that leaves the picture unchanged.
public struct Adjustments: Sendable, Equatable {
    /// -1...1, neutral 0.
    public var brightness = 0.0
    /// 0...2, neutral 1.
    public var contrast = 1.0
    /// 0...2, neutral 1. 0 is black and white.
    public var saturation = 1.0
    /// -2...2 stops, neutral 0.
    public var exposure = 0.0
    /// -180...180 degrees, neutral 0.
    public var hue = 0.0

    public init() {}

    public var isNeutral: Bool { self == Adjustments() }
}
