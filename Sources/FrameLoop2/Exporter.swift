@preconcurrency import AVFoundation
import CoreGraphics
import FrameLoop2Kit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportFormat: Sendable, CaseIterable {
    /// The default: the clip's own size and frame rate.
    case mp4Original
    case mp4Small
    case gif

    var title: String {
        switch self {
        case .mp4Original: "Export MP4 H.264 · original size and frame rate"
        case .mp4Small: "Export MP4 H.264 · 24 FPS · 768×512 (letterboxed)"
        case .gif: "Export animated GIF · 15 FPS · max 640 px wide"
        }
    }

    var jobTitle: String { self == .gif ? "Exporting GIF…" : "Exporting video…" }
}

/// Size, frame rate, and bit rate of one MP4 export.
nonisolated struct MP4Target: Sendable {
    var width: Int
    var height: Int
    var fps: Double
    var bitrate: Int

    static let small = MP4Target(width: 768, height: 512, fps: 24, bitrate: 8_000_000)

    /// The clip's own picture size and measured frame rate.
    static func original(of video: LoadedVideo) -> MP4Target {
        let size = ExportPlan.evenSize(width: video.width, height: video.height)
        return MP4Target(width: size.width, height: size.height, fps: max(1, video.frameRate),
                         bitrate: ExportPlan.bitrate(width: size.width, height: size.height))
    }
}

nonisolated enum ExportError: LocalizedError {
    case tooLong
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .tooLong: "This segment is too long for a GIF. Mark a shorter segment."
        case .writerFailed(let text): "Export failed: \(text)"
        }
    }
}

/// Stills, MP4s, and GIFs, all from one pipeline: pick source frames, draw them, write them.
nonisolated enum Exporter {
    static let gifFPS = 15.0
    static let gifMaxWidth = 640
    static let gifMaxFrames = 1_500

    private static func generator(for video: LoadedVideo) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: video.asset)
        generator.videoComposition = video.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return generator
    }

    private static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 90_000)
    }

    private static func mirrorIfNeeded(_ image: CGImage, _ mirrored: Bool) -> CGImage {
        guard mirrored, let context = CGContext(data: nil, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    @concurrent
    static func screenshot(video: LoadedVideo, frame: Int, mirrored: Bool, adjustments: Adjustments, to url: URL) async throws {
        let time = cmTime(video.frames[frame].seekTime)
        let image = try await generator(for: video).image(at: time).image
        let final = mirrorIfNeeded(PictureAdjuster.apply(adjustments, to: image), mirrored)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.writerFailed("cannot create \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, final, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.writerFailed("cannot write the PNG") }
    }

    @concurrent
    static func exportMP4(video: LoadedVideo, order: [Int], speed: Double, mirrored: Bool, adjustments: Adjustments,
                          target: MP4Target, to url: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let fps = target.fps
        let outputFrames = ExportPlan.outputFrames(order: order, durations: video.frames.map(\.duration),
                                                   speed: speed, fps: fps)
        let (width, height) = (target.width, target.height)
        let box = ExportPlan.letterbox(sourceWidth: video.width, sourceHeight: video.height,
                                       frameWidth: width, frameHeight: height)
        // Sound first: it is cut to the same frames, so a bad audio track fails before any video work.
        var audio = try await AudioExport.render(video: video, order: order, speed: speed).map(AudioFeeder.init)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: target.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioExport.sampleRate,
            AVNumberOfChannelsKey: Int(AudioExport.channelCount),
            AVEncoderBitRateKey: 192_000,
        ])
        if audio != nil { writer.add(audioInput) }
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "cannot start") }
        writer.startSession(atSourceTime: .zero)

        let images = generator(for: video)
        images.maximumSize = CGSize(width: box.width * 2, height: box.height * 2)
        var cachedIndex = -1
        var cachedImage: CGImage?
        do {
            for (tick, source) in outputFrames.enumerated() {
                try Task.checkCancellation()
                if source != cachedIndex {
                    cachedImage = PictureAdjuster.apply(adjustments, to: try await images.image(at: cmTime(video.frames[source].seekTime)).image)
                    cachedIndex = source
                }
                guard let image = cachedImage, let pool = adaptor.pixelBufferPool else { continue }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { continue }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.interpolationQuality = .high
                    // CoreGraphics counts y from the bottom.
                    let rect = CGRect(x: box.x, y: height - box.y - box.height, width: box.width, height: box.height)
                    if mirrored {
                        context.translateBy(x: rect.midX, y: 0)
                        context.scaleBy(x: -1, y: 1)
                        context.translateBy(x: -rect.midX, y: 0)
                    }
                    context.draw(image, in: rect)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                // The writer interleaves audio and video, so keep audio flowing a little ahead of the picture
                // or the video input would wait on it forever.
                var ahead = Double(tick) / fps + 0.5
                audio?.feed(audioInput, until: ahead)
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(4))
                    // The writer may hold the video back until audio is further along.
                    ahead += 0.25
                    audio?.feed(audioInput, until: ahead)
                }
                adaptor.append(buffer, withPresentationTime: cmTime(Double(tick) / fps))
                if tick % 6 == 0 { progress(Double(tick) / Double(outputFrames.count)) }
            }
            input.markAsFinished()
            while let remaining = audio, !remaining.isDone {
                try Task.checkCancellation()
                audio?.feed(audioInput, until: .infinity)
                if audio?.isDone == false { try await Task.sleep(for: .milliseconds(4)) }
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
            }
            progress(1)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @concurrent
    static func exportGIF(video: LoadedVideo, order: [Int], speed: Double, mirrored: Bool, adjustments: Adjustments, to url: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let outputFrames = ExportPlan.outputFrames(order: order, durations: video.frames.map(\.duration),
                                                   speed: speed, fps: gifFPS)
        guard outputFrames.count <= gifMaxFrames else { throw ExportError.tooLong }
        let size = ExportPlan.gifSize(sourceWidth: video.width, sourceHeight: video.height, maxWidth: gifMaxWidth)
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                                outputFrames.count, nil)
        else { throw ExportError.writerFailed("cannot create \(url.lastPathComponent)") }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let images = generator(for: video)
        images.maximumSize = CGSize(width: size.width, height: size.height)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFPS]] as CFDictionary
        var cachedIndex = -1
        var cachedImage: CGImage?
        do {
            for (tick, source) in outputFrames.enumerated() {
                try Task.checkCancellation()
                if source != cachedIndex {
                    let image = try await images.image(at: cmTime(video.frames[source].seekTime)).image
                    cachedImage = mirrorIfNeeded(PictureAdjuster.apply(adjustments, to: image), mirrored)
                    cachedIndex = source
                }
                if let image = cachedImage { CGImageDestinationAddImage(destination, image, frameProperties) }
                if tick % 4 == 0 { progress(Double(tick) / Double(outputFrames.count)) }
            }
            guard CGImageDestinationFinalize(destination) else { throw ExportError.writerFailed("cannot write the GIF") }
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
