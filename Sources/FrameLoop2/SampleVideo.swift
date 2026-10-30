@preconcurrency import AVFoundation
import AppKit

/// Test clips for self-tests and snapshots: a moving gradient with the frame number on it.
enum SampleVideo {
    @MainActor
    static func make(at url: URL, frames: Int = 90, fps: Int32 = 30, width: Int = 640, height: Int = 360) async throws {
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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
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
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? MediaError.noFrames }
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
