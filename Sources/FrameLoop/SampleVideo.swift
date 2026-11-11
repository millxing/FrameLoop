@preconcurrency import AVFoundation
import AppKit

/// Test clips for self-tests and snapshots: a moving gradient with the frame number on it.
enum SampleVideo {
    @MainActor
    static func make(at url: URL, frames: Int = 90, fps: Int32 = 30, width: Int = 640, height: Int = 360, sound: Bool = true) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        // A tone that rises from 400 to 1200 Hz over the clip, so tests can tell forward from backward and fast from slow.
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        var feeder = sound ? AudioFeeder(sweep(seconds: Double(frames) / Double(fps))) : nil
        if feeder != nil { writer.add(audioInput) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            var ahead = Double(index) / Double(fps) + 0.5
            feeder?.feed(audioInput, until: ahead)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
                ahead += 0.25
                feeder?.feed(audioInput, until: ahead)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let progress = CGFloat(index) / CGFloat(max(1, frames - 1))
            let colors = [CGColor(red: 0.10 + 0.5 * progress, green: 0.25, blue: 0.55 - 0.3 * progress, alpha: 1),
                          CGColor(red: 0.02, green: 0.05 + 0.3 * progress, blue: 0.12, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            // A square that moves right, so a mirrored picture is obvious.
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 40 + progress * CGFloat(width - 140), y: CGFloat(height) / 2 - 30, width: 60, height: 60))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text = NSAttributedString(string: String(format: "%03d", index), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white,
            ])
            text.draw(at: CGPoint(x: 28, y: CGFloat(height) - 100))
            NSGraphicsContext.restoreGraphicsState()
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        input.markAsFinished()
        while feeder?.isDone == false {
            feeder?.feed(audioInput, until: .infinity)
            if feeder?.isDone == false { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? MediaError.noFrames }
    }

    nonisolated private static func sweep(seconds: Double) -> AVAudioPCMBuffer {
        let rate = 44_100.0
        let count = Int(seconds * rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.floatChannelData![0]
        for n in 0..<count {
            let t = Double(n) / rate
            samples[n] = Float(0.5 * sin(2 * .pi * (400 * t + 400 * t * t / seconds)))
        }
        return buffer
    }

    /// The clips in the sample folder, made once per run.
    @MainActor
    static func prepare() async throws -> URL {
        let directory = Store.scratch.appending(path: "videos", directoryHint: .isDirectory)
        let main = directory.appending(path: "bouncing-square.mp4")
        try await make(at: main)
        try await make(at: directory.appending(path: "short-clip.mp4"), frames: 48, fps: 24, width: 480, height: 480)
        return main
    }
}
