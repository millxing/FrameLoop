import Foundation

/// A stretch of one source video that plays in the edited clip.
public struct EditPiece: Sendable, Equatable {
    public var source: Int
    public var start: Double
    public var end: Double

    public init(source: Int, start: Double, end: Double) {
        self.source = source
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// The edited clip as a list of source stretches, played one after another. The source files never change.
public struct EditList: Sendable, Equatable {
    public var pieces: [EditPiece]

    public init(pieces: [EditPiece]) {
        self.pieces = pieces
    }

    public var duration: Double { pieces.reduce(0) { $0 + $1.duration } }

    /// Anything shorter than this is a rounding crumb, not video.
    static let crumb = 0.0005

    /// Cuts the timeline span `from...to` out of the clip. Pieces it crosses are trimmed or split.
    public mutating func remove(from cutStart: Double, to cutEnd: Double) {
        guard cutEnd > cutStart else { return }
        var result: [EditPiece] = []
        var offset = 0.0
        for piece in pieces {
            let pieceEnd = offset + piece.duration
            if pieceEnd <= cutStart || offset >= cutEnd {
                result.append(piece)
            } else {
                if cutStart - offset > Self.crumb {
                    result.append(EditPiece(source: piece.source, start: piece.start, end: piece.start + (cutStart - offset)))
                }
                if pieceEnd - cutEnd > Self.crumb {
                    result.append(EditPiece(source: piece.source, start: piece.start + (cutEnd - offset), end: piece.end))
                }
            }
            offset = pieceEnd
        }
        pieces = result
    }

    /// The edited clip's frames, from each source's own frame list: every frame inside a piece, moved to its place on the timeline.
    public func frames(sourceFrames: [[FrameInfo]]) -> [FrameInfo] {
        var result: [FrameInfo] = []
        var cursor = 0.0
        for piece in pieces {
            for frame in sourceFrames[piece.source] where frame.pts >= piece.start - 1e-9 && frame.pts < piece.end - 1e-9 {
                result.append(FrameInfo(index: result.count, pts: cursor + frame.pts - piece.start, duration: frame.duration))
            }
            cursor += piece.duration
        }
        return result
    }

    public mutating func append(_ piece: EditPiece) {
        pieces.append(piece)
    }
}
