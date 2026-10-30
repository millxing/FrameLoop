@preconcurrency import AVFoundation
import CoreImage
import FrameLoop2Kit

/// Applies the brightness, contrast, saturation, exposure, and hue controls with Core Image,
/// to the live picture (as layer filters) and to exported frames.
nonisolated enum PictureAdjuster {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// The filter chain for the controls. Empty when everything is neutral.
    static func filters(_ adjustments: Adjustments) -> [CIFilter] {
        var chain: [CIFilter] = []
        if adjustments.exposure != 0, let filter = CIFilter(name: "CIExposureAdjust", parameters: ["inputEV": adjustments.exposure]) {
            chain.append(filter)
        }
        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1,
           let filter = CIFilter(name: "CIColorControls", parameters: [
               "inputBrightness": adjustments.brightness,
               "inputContrast": adjustments.contrast,
               "inputSaturation": adjustments.saturation,
           ]) {
            chain.append(filter)
        }
        if adjustments.hue != 0, let filter = CIFilter(name: "CIHueAdjust", parameters: ["inputAngle": adjustments.hue * .pi / 180]) {
            chain.append(filter)
        }
        return chain
    }

    /// The frame with the controls applied. The same image when they are neutral.
    static func apply(_ adjustments: Adjustments, to image: CGImage) -> CGImage {
        guard !adjustments.isNeutral else { return image }
        let output = apply(adjustments, mirrored: false, to: CIImage(cgImage: image))
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                     format: .BGRA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? image
    }

    /// The picture with the controls applied, and turned left to right when `mirrored`.
    static func apply(_ adjustments: Adjustments, mirrored: Bool, to image: CIImage) -> CIImage {
        var output = image
        for filter in filters(adjustments) {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let next = filter.outputImage { output = next }
        }
        guard mirrored else { return output.cropped(to: image.extent) }
        // x becomes (2 × left edge + width) − x, so the picture stays where it is and turns around its centre line.
        let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.minX * 2 + image.extent.width, ty: 0)
        return output.transformed(by: flip).cropped(to: image.extent)
    }

    /// A video composition that mirrors and adjusts every frame as AVFoundation decodes it, for the player and for tests.
    static func composition(for asset: AVAsset, adjustments: Adjustments, mirrored: Bool) async throws -> AVVideoComposition {
        try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            AVCIImageFilteringResult(resultImage: apply(adjustments, mirrored: mirrored, to: parameters.sourceImage), ciContext: nil)
        }
    }
}
