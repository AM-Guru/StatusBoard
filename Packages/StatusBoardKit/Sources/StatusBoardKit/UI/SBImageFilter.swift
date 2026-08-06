import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// Core Image filter chains for image panels, using the TerminalWidget spec
/// syntax: `"sepia:70,blur:20,pixelate:10,grayscale,invert"`.
/// watchOS has no Core Image — images pass through unfiltered there.
public enum SBImageFilter {
    #if canImport(CoreImage)
    private static let context = CIContext()
    #endif

    public struct Step: Equatable {
        public var name: String
        public var amount: Double?
    }

    public static func parse(_ spec: String) -> [Step] {
        spec.split(separator: ",").compactMap { raw in
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces).lowercased(),
                  !name.isEmpty else { return nil }
            let amount = parts.count > 1 ? Double(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            return Step(name: name, amount: amount)
        }
    }

    /// Applies the chain and returns PNG data, or nil if the input isn't an
    /// image or no filter applies.
    public static func apply(_ spec: String, to data: Data) -> Data? {
        #if !canImport(CoreImage)
        return nil
        #else
        let steps = parse(spec)
        guard !steps.isEmpty, var image = CIImage(data: data) else { return nil }

        for step in steps {
            switch step.name {
            case "sepia":
                let filter = CIFilter.sepiaTone()
                filter.inputImage = image
                filter.intensity = Float(min(100, max(0, step.amount ?? 100)) / 100)
                image = filter.outputImage ?? image
            case "blur":
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = image.clampedToExtent()
                filter.radius = Float(min(100, max(0, step.amount ?? 10)))
                image = (filter.outputImage ?? image).cropped(to: image.extent)
            case "pixelate":
                let filter = CIFilter.pixellate()
                filter.inputImage = image
                filter.scale = Float(min(200, max(1, step.amount ?? 20)))
                image = filter.outputImage ?? image
            case "negative", "invert":
                let filter = CIFilter.colorInvert()
                filter.inputImage = image
                image = filter.outputImage ?? image
            case "grayscale", "greyscale":
                let filter = CIFilter.colorControls()
                filter.inputImage = image
                filter.saturation = 0
                image = filter.outputImage ?? image
            default:
                continue
            }
        }

        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        #if os(macOS)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
        #else
        return UIImage(cgImage: cgImage).pngData()
        #endif
        #endif
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
