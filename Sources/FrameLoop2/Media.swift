@preconcurrency import AVFoundation
import FrameLoop2Kit

/// A video ready to play: the asset plus every frame's timing, read from the file's packets without decoding.
nonisolated struct LoadedVideo: Sendable {
    var url: URL
    var asset: AVAsset
    var frames: [FrameInfo]
    var width: Int
    var height: Int
    var duration: Double
    var hasAudio: Bool
    var frameRate: Double

    var summary: String {
        "\(width)×\(height) · \(String(format: "%g", (frameRate * 100).rounded() / 100)) fps"
    }
}

nonisolated enum MediaError: LocalizedError {
    case noVideo
    case noFrames
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file does not contain a readable video stream."
        case .noFrames: "No decodable video frames were found."
        case .unsupported(let name): "FrameLoop2 cannot open \(name)."
        }
    }
}

nonisolated enum MediaLoader {
    @concurrent
    static func load(url: URL) async throws -> LoadedVideo {
        let asset = AVURLAsset(url: url)
        return try await load(asset: asset, url: url)
    }

    @concurrent
    static func load(asset: AVAsset, url: URL) async throws -> LoadedVideo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.noVideo }
        let (naturalSize, nominalRate, transform, assetDuration) = try await (
            track.load(.naturalSize), track.load(.nominalFrameRate),
            track.load(.preferredTransform), asset.load(.duration))
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaError.noFrames }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time.isFinite { times.append(time) }
        }
        guard !times.isEmpty else { throw MediaError.noFrames }
        times.sort()

        let rate = nominalRate > 0 ? Double(nominalRate) : 30
        var deltas = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        deltas.sort()
        let typical = deltas.isEmpty ? 1 / rate : deltas[deltas.count / 2]
        var frames: [FrameInfo] = []
        frames.reserveCapacity(times.count)
        for (index, time) in times.enumerated() {
            let next = index + 1 < times.count ? times[index + 1] - time : typical
            frames.append(FrameInfo(index: index, pts: time, duration: next > 0 ? next : typical))
        }
        let size = naturalSize.applying(transform)
        let end = frames[frames.count - 1].end
        let duration = assetDuration.seconds.isFinite && assetDuration.seconds > 0 ? max(assetDuration.seconds, end) : end
        return LoadedVideo(url: url, asset: asset, frames: frames,
                           width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()),
                           duration: duration, hasAudio: hasAudio,
                           frameRate: frames.count > 1 ? Double(frames.count - 1) / (frames[frames.count - 1].pts - frames[0].pts) : rate)
    }
}
