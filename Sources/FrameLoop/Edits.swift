@preconcurrency import AVFoundation
import FrameLoopKit

/// Turns an edit list into something AVFoundation plays: the file itself when nothing was cut, otherwise a composition
/// that points into the original files. Nothing is copied or re-encoded.
nonisolated enum EditBuilder {
    @concurrent
    static func build(sources: [EditSource], edits: EditList) async throws -> (asset: AVAsset, videoComposition: AVVideoComposition?) {
        if edits.pieces.count == 1, let piece = edits.pieces.first, piece.start < 0.001,
           abs(piece.end - sources[piece.source].duration) < 0.001 {
            return (sources[piece.source].asset, nil)
        }
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var spans: [(range: CMTimeRange, source: EditSource)] = []
        for piece in edits.pieces {
            let source = sources[piece.source]
            let range = CMTimeRange(start: time(piece.start), duration: time(piece.duration))
            try await composition.insertTimeRange(range, of: source.asset, at: cursor)
            spans.append((CMTimeRange(start: cursor, duration: range.duration), source))
            cursor = cursor + range.duration
        }
        guard let first = spans.first?.source else { throw MediaError.noFrames }
        let sizes = Set(spans.map { "\($0.source.displaySize.width)x\($0.source.displaySize.height)" })
        guard let track = try await composition.loadTracks(withMediaType: .video).first else { throw MediaError.noVideo }
        guard sizes.count > 1 else {
            track.preferredTransform = first.transform
            return (composition, nil)
        }
        // Different picture sizes: scale each piece to fit the first clip's size.
        let render = first.displaySize
        var instructions: [AVVideoCompositionInstruction] = []
        for span in spans {
            let size = span.source.displaySize
            let scale = min(render.width / size.width, render.height / size.height)
            let transform = span.source.transform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (render.width - size.width * scale) / 2,
                                                 y: (render.height - size.height * scale) / 2))
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layer.setTransform(transform, at: .zero)
            var instruction = AVVideoCompositionInstruction.Configuration()
            instruction.timeRange = span.range
            instruction.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layer)]
            instructions.append(AVVideoCompositionInstruction(configuration: instruction))
        }
        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = render
        configuration.frameDuration = CMTime(seconds: 1 / max(first.frameRate, 1), preferredTimescale: 60_000)
        configuration.instructions = instructions
        let videoComposition = AVVideoComposition(configuration: configuration)
        return (composition, videoComposition)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 90_000)
    }
}
