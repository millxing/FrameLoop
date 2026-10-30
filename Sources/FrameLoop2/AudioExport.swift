@preconcurrency import AVFoundation
import FrameLoop2Kit

/// The sound for an MP4 export: the segment's audio cut to match the picture, reversed where the picture plays
/// backward, and stretched (pitch kept) where it plays slower.
nonisolated enum AudioExport {
    static let sampleRate = 44_100.0
    static let channelCount: AVAudioChannelCount = 2
    private static let chunk: AVAudioFrameCount = 4_096

    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false)!
    }

    /// Nil when the video has no sound.
    @concurrent
    static func render(video: LoadedVideo, order: [Int], speed: Double) async throws -> AVAudioPCMBuffer? {
        let tracks = try await video.asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        var parts: [AVAudioPCMBuffer] = []
        for run in ExportPlan.audioRuns(order: order, frames: video.frames) {
            try Task.checkCancellation()
            parts.append(try read(run, tracks: tracks, asset: video.asset))
        }
        let joined = join(parts)
        return abs(speed - 1) < 0.001 ? joined : try stretch(joined, speed: speed)
    }

    private static func read(_ run: AudioRun, tracks: [AVAssetTrack], asset: AVAsset) throws -> AVAudioPCMBuffer {
        let format = format
        let wanted = Int(max(1, ((run.end - run.start) * sampleRate).rounded()))
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted))!
        result.frameLength = AVAudioFrameCount(wanted)
        for channel in 0..<Int(channelCount) {
            result.floatChannelData![channel].update(repeating: 0, count: wanted)
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: run.start, preferredTimescale: 90_000),
                                       duration: CMTime(seconds: run.end - run.start, preferredTimescale: 90_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.writerFailed(reader.error?.localizedDescription ?? "cannot read the audio")
        }
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            piece.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                               into: piece.mutableAudioBufferList) == noErr
            else { continue }
            // Place by timestamp, so a reader that starts a little early or late still lines up.
            let place = Int(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - run.start) * sampleRate).rounded())
            let from = max(0, -place)
            let to = max(0, place)
            let length = min(count - from, wanted - to)
            guard length > 0 else { continue }
            for channel in 0..<Int(channelCount) {
                (result.floatChannelData![channel] + to).update(from: piece.floatChannelData![channel] + from, count: length)
            }
        }
        if reader.status == .failed {
            throw ExportError.writerFailed(reader.error?.localizedDescription ?? "cannot read the audio")
        }
        if run.reversed {
            for channel in 0..<Int(channelCount) {
                var samples = UnsafeMutableBufferPointer(start: result.floatChannelData![channel], count: wanted)
                samples.reverse()
            }
        }
        return result
    }

    private static func join(_ parts: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer {
        let total = parts.reduce(0) { $0 + Int($1.frameLength) }
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, total)))!
        result.frameLength = AVAudioFrameCount(total)
        var offset = 0
        for part in parts {
            for channel in 0..<Int(channelCount) {
                (result.floatChannelData![channel] + offset).update(from: part.floatChannelData![channel], count: Int(part.frameLength))
            }
            offset += Int(part.frameLength)
        }
        return result
    }

    /// Plays the audio through a time-pitch unit in offline mode: speed changes, pitch does not.
    private static func stretch(_ input: AVAudioPCMBuffer, speed: Double) throws -> AVAudioPCMBuffer {
        let format = input.format
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(speed)
        timePitch.pitch = 0
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        let expected = Int((Double(input.frameLength) / speed).rounded())
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, expected)))!
        let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)!
        var written = 0
        var stalls = 0
        while written < expected {
            try Task.checkCancellation()
            let wanted = min(Int(chunk), expected - written)
            switch try engine.renderOffline(AVAudioFrameCount(wanted), to: scratch) {
            case .success:
                let count = min(Int(scratch.frameLength), expected - written)
                for channel in 0..<Int(channelCount) {
                    (result.floatChannelData![channel] + written).update(from: scratch.floatChannelData![channel], count: count)
                }
                written += count
                stalls = 0
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalls += 1
                if stalls > 1_000 { throw ExportError.writerFailed("audio time stretch stalled") }
            case .error:
                throw ExportError.writerFailed("audio time stretch failed")
            @unknown default:
                throw ExportError.writerFailed("audio time stretch failed")
            }
        }
        result.frameLength = AVAudioFrameCount(written)
        return result
    }
}

/// Hands a rendered audio buffer to an asset writer input a chunk at a time, so it can be interleaved with the video.
nonisolated struct AudioFeeder {
    private let buffer: AVAudioPCMBuffer
    private let total: Int
    private var offset = 0
    private var finished = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
        total = Int(buffer.frameLength)
    }

    var isDone: Bool { offset >= total }

    /// Appends chunks that start before `time` (seconds) while the input accepts them. Finishes the input after the last chunk.
    mutating func feed(_ input: AVAssetWriterInput, until time: Double) {
        let format = buffer.format
        while !isDone, input.isReadyForMoreMediaData, Double(offset) / format.sampleRate <= time {
            let count = min(4_096, total - offset)
            let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            piece.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(format.channelCount) {
                piece.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + offset, count: count)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(format.sampleRate)),
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                       makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                       sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
                  let sample,
                  CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                                 blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                 flags: 0, bufferList: piece.audioBufferList) == noErr
            else {
                offset = total
                break
            }
            input.append(sample)
            offset += count
        }
        // The writer holds video back until every audio track has said it has no more, so say it at once.
        if isDone, !finished {
            input.markAsFinished()
            finished = true
        }
    }
}
