import CoreImage
import CoreImage.CIFilterBuiltins

enum VideoFilter: String, CaseIterable, Identifiable, Hashable {
    static let previewMaxDimension: CGFloat = 960

    case original
    case vivid
    case warm
    case cool
    case dramatic
    case dramaticWarm = "dramatic-warm"
    case silver
    case mono
    case noir

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Оригинал"
        case .vivid: return "Яркий"
        case .warm: return "Яркий тёплый"
        case .cool: return "Яркий прохладный"
        case .dramatic: return "Эффектный"
        case .dramaticWarm: return "Эффектный тёплый"
        case .silver: return "Серебряный"
        case .mono: return "Чёрно-белый"
        case .noir: return "Нуар"
        }
    }

    func applying(to image: CIImage) throws -> CIImage {
        var output = image

        switch self {
        case .original:
            break
        case .vivid:
            output = try colorControls(output, saturation: 1.35, contrast: 1.06)
        case .warm:
            output = try colorControls(output, saturation: 1.28)
            output = try sepia(output, intensity: 0.16)
            output = try hue(output, degrees: -8)
        case .cool:
            output = try colorControls(output, saturation: 1.22, brightness: 0.03)
            output = try hue(output, degrees: 10)
        case .dramatic:
            output = try colorControls(output, saturation: 0.92, contrast: 1.2)
        case .dramaticWarm:
            output = try colorControls(output, saturation: 1.08, contrast: 1.18)
            output = try sepia(output, intensity: 0.12)
        case .silver:
            output = try colorControls(output, saturation: 0.55, contrast: 1.12, brightness: 0.06)
        case .mono:
            output = try colorControls(output, saturation: 0)
        case .noir:
            output = try colorControls(output, saturation: 0, contrast: 1.5, brightness: -0.08)
        }

        return output.cropped(to: image.extent)
    }

    private func colorControls(_ image: CIImage,
                               saturation: Float = 1,
                               contrast: Float = 1,
                               brightness: Float = 0) throws -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = saturation
        filter.contrast = contrast
        filter.brightness = brightness
        guard let output = filter.outputImage else { throw CameraError.filterProcessingFailed }
        return output
    }

    private func sepia(_ image: CIImage, intensity: Float) throws -> CIImage {
        let filter = CIFilter.sepiaTone()
        filter.inputImage = image
        filter.intensity = intensity
        guard let output = filter.outputImage else { throw CameraError.filterProcessingFailed }
        return output
    }

    private func hue(_ image: CIImage, degrees: Float) throws -> CIImage {
        let filter = CIFilter.hueAdjust()
        filter.inputImage = image
        filter.angle = degrees * .pi / 180
        guard let output = filter.outputImage else { throw CameraError.filterProcessingFailed }
        return output
    }
}

enum VideoFilterTarget: String, Equatable {
    case primary
    case secondary
}

struct VideoFilterKeyframe {
    let time: TimeInterval
    let filter: VideoFilter
    let target: VideoFilterTarget
}
