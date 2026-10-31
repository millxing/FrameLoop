@preconcurrency import AVFoundation
import CoreImage
@preconcurrency import VideoToolbox

/// How much of the picture the upscaler works from.
nonisolated enum UpscaleQuality: Sendable {
    /// The whole picture goes through the model, which then enlarges it 4× and the result is averaged down to 2×.
    case best
    /// Half-size pictures go through the model, which enlarges them 4× straight to 2×. About four times quicker, but
    /// the model only sees half the detail.
    case fast
}

/// Apple's machine-learning video upscaler (VideoToolbox super resolution, macOS 26).
/// The system model only works at 4×, on pictures up to 1920×1080, so an export
/// upscales 4× and then averages down to a 2× result: a 1080p clip becomes 4K.
/// `UpscaleQuality.fast` feeds it half-size pictures instead, so no averaging is needed.
/// The model downloads once, the first time it is needed.
nonisolated final class FrameUpscaler {
    /// The only scale the system model supports.
    static let modelFactor = 4
    /// The size the exported picture grows by.
    static let outputFactor = 2
    static let maxWidth = 1920
    static let maxHeight = 1080

    enum UpscaleError: LocalizedError {
        case unsupported
        case tooLarge
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: "This Mac cannot upscale video."
            case .tooLarge: "Upscaling works on videos up to \(FrameUpscaler.maxWidth)×\(FrameUpscaler.maxHeight)."
            case .failed(let text): "Upscaling failed: \(text)"
            }
        }
    }

    /// Why a clip of this size cannot be upscaled, or nil when it can.
    static func problem(width: Int, height: Int) -> UpscaleError? {
        guard VTSuperResolutionScalerConfiguration.isSupported,
              VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(modelFactor) else { return .unsupported }
        return width <= maxWidth && height <= maxHeight ? nil : .tooLarge
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let configuration: VTSuperResolutionScalerConfiguration
    private let processor = VTFrameProcessor()
    private let context = CIContext(options: [.workingColorSpace: FrameUpscaler.colorSpace, .workingFormat: CIFormat.RGBAh.rawValue])
    private let width: Int
    private let height: Int
    private var sources: [CVPixelBuffer] = []
    private var outputs: [CVPixelBuffer] = []
    private var turn = 0
    private var previous: (source: VTFrameProcessorFrame, output: VTFrameProcessorFrame)?
    private var started = false

    init(width sourceWidth: Int, height sourceHeight: Int, quality: UpscaleQuality) throws {
        if let problem = Self.problem(width: sourceWidth, height: sourceHeight) { throw problem }
        // What the model sees: the picture itself, or half of it (kept even, as video sizes are).
        let width = quality == .fast ? max(2, (sourceWidth / 4) * 2) : sourceWidth
        let height = quality == .fast ? max(2, (sourceHeight / 4) * 2) : sourceHeight
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: Self.modelFactor, inputType: .video,
            usePrecomputedFlow: false, qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision)
        else { throw UpscaleError.tooLarge }
        self.configuration = configuration
        self.width = width
        self.height = height
    }

    deinit {
        if started { processor.endSession() }
    }

    /// Downloads the model when the Mac does not have it yet, reporting 0...1.
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let configuration = configuration
        if configuration.configurationModelStatus != .ready {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await configuration.downloadConfigurationModel() }
                group.addTask {
                    while !Task.isCancelled {
                        progress(Double(configuration.configurationModelPercentageAvailable))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }
        guard configuration.configurationModelStatus == .ready else { throw UpscaleError.failed("the model did not download") }
        try processor.startSession(configuration: configuration)
        started = true
        // Two of each, so the previous frame and its result stay intact while the next one is made.
        for _ in 0..<2 {
            sources.append(try makeBuffer(width: width, height: height, attributes: configuration.sourcePixelBufferAttributes))
            outputs.append(try makeBuffer(width: width * Self.modelFactor, height: height * Self.modelFactor,
                                          attributes: configuration.destinationPixelBufferAttributes))
        }
    }

    private func makeBuffer(width: Int, height: Int, attributes: [String: any Sendable]) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let format = configuration.supportedPixelFormats.first ?? kCVPixelFormatType_64RGBAHalf
        let status = CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw UpscaleError.failed("not enough memory (\(status))") }
        return buffer
    }

    /// Upscales one picture, returning a buffer valid until the second call after this one.
    /// `sequential` says this picture follows the last one in time, so the model can use the last one's detail.
    func upscale(_ image: CIImage, at time: CMTime, sequential: Bool) async throws -> CVPixelBuffer {
        let source = sources[turn % 2]
        let output = outputs[turn % 2]
        turn += 1
        var fitted = image
        if Int(image.extent.width) != width || Int(image.extent.height) != height {
            fitted = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                             y: CGFloat(height) / image.extent.height))
        }
        context.render(fitted, to: source, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: Self.colorSpace)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
              let outputFrame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time)
        else { throw UpscaleError.failed("cannot wrap a frame") }
        let follow = sequential ? previous : nil
        guard let parameters = VTSuperResolutionScalerParameters(
            sourceFrame: sourceFrame, previousFrame: follow?.source, previousOutputFrame: follow?.output,
            opticalFlow: nil, submissionMode: follow == nil ? .random : .sequential, destinationFrame: outputFrame)
        else { throw UpscaleError.failed("cannot set up a frame") }
        let processor = processor
        let failure: Error? = await withCheckedContinuation { continuation in
            processor.process(parameters: parameters) { _, error in continuation.resume(returning: error) }
        }
        if let failure { throw UpscaleError.failed(failure.localizedDescription) }
        previous = (sourceFrame, outputFrame)
        return output
    }

    /// Averages an upscaled buffer down into an output buffer of the export's size.
    func render(_ upscaled: CVPixelBuffer, into buffer: CVPixelBuffer, width: Int, height: Int) {
        let image = CIImage(cvPixelBuffer: upscaled, options: [.colorSpace: Self.colorSpace])
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                             y: CGFloat(height) / image.extent.height))
        context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: Self.colorSpace)
    }
}
