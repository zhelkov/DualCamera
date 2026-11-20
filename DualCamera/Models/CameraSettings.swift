import Foundation
import Observation

enum CaptureAspectRatio: String, CaseIterable, Identifiable, Hashable {
    case portrait916 = "9:16"
    case fourThree = "4:3"
    case square = "1:1"

    var id: String { rawValue }

    var portraitRatio: CGFloat {
        switch self {
        case .portrait916: return 9.0 / 16.0
        case .fourThree: return 3.0 / 4.0
        case .square: return 1
        }
    }

    func ratio(isPortrait: Bool) -> CGFloat {
        isPortrait ? portraitRatio : 1 / portraitRatio
    }
}

enum VideoResolution: String, CaseIterable, Identifiable, Hashable {
    case p720 = "720p"
    case p1080 = "1080p"
    case uhd4k = "4K"

    var id: String { rawValue }

    var longEdge: CGFloat {
        switch self {
        case .p720: return 1280
        case .p1080: return 1920
        case .uhd4k: return 3840
        }
    }

    var shortEdge: CGFloat { longEdge * 9 / 16 }

    var landscapeCaptureTarget: CGSize {
        CGSize(width: longEdge, height: longEdge * 9 / 16)
    }
}

enum VideoFrameRate: Int, CaseIterable, Identifiable, Hashable {
    case fps30 = 30
    case fps24 = 24
    case fps60 = 60

    var id: Int { rawValue }

    var title: String { "\(rawValue) FPS" }
}

enum AudioRecordingQuality: String, CaseIterable, Identifiable, Hashable {
    case aac
    case appleLossless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aac: return "AAC"
        case .appleLossless: return "Apple Lossless"
        }
    }
}

struct CameraSettingsSnapshot: Equatable {
    var aspectRatio: CaptureAspectRatio = .portrait916
    var resolution: VideoResolution = .p1080
    var frameRate: VideoFrameRate = .fps30
    var audioQuality: AudioRecordingQuality = .aac
    var stabilizationEnabled = true
    var teleprompterEnabled = false
    var teleprompterText = ""
    var dateTimeEnabled = false
    var gridEnabled = false
    var hapticsEnabled = true

    static let defaults = Self()

    func outputSize(isPortrait: Bool) -> CGSize {
        let ratio = aspectRatio.ratio(isPortrait: isPortrait)
        let baseWidth = isPortrait ? resolution.shortEdge : resolution.longEdge
        let baseHeight = isPortrait ? resolution.longEdge : resolution.shortEdge
        let baseRatio = baseWidth / baseHeight
        let width: CGFloat
        let height: CGFloat
        if ratio < baseRatio {
            width = baseHeight * ratio
            height = baseHeight
        } else {
            width = baseWidth
            height = baseWidth / ratio
        }
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }
}

@Observable
final class CameraSettings {
    private enum Key {
        static let aspectRatio = "cameraSettings.aspectRatio"
        static let resolution = "cameraSettings.resolution"
        static let frameRate = "cameraSettings.frameRate"
        static let audioQuality = "cameraSettings.audioQuality"
        static let stabilization = "cameraSettings.stabilization"
        static let teleprompter = "cameraSettings.teleprompter"
        static let teleprompterText = "cameraSettings.teleprompterText"
        static let dateTime = "cameraSettings.dateTime"
        static let grid = "cameraSettings.grid"
        static let haptics = "cameraSettings.haptics"
    }

    private let defaults: UserDefaults

    var aspectRatio: CaptureAspectRatio { didSet { defaults.set(aspectRatio.rawValue, forKey: Key.aspectRatio) } }
    var resolution: VideoResolution { didSet { defaults.set(resolution.rawValue, forKey: Key.resolution) } }
    var frameRate: VideoFrameRate { didSet { defaults.set(frameRate.rawValue, forKey: Key.frameRate) } }
    var audioQuality: AudioRecordingQuality { didSet { defaults.set(audioQuality.rawValue, forKey: Key.audioQuality) } }
    var stabilizationEnabled: Bool { didSet { defaults.set(stabilizationEnabled, forKey: Key.stabilization) } }
    var teleprompterEnabled: Bool { didSet { defaults.set(teleprompterEnabled, forKey: Key.teleprompter) } }
    var teleprompterText: String { didSet { defaults.set(teleprompterText, forKey: Key.teleprompterText) } }
    var dateTimeEnabled: Bool { didSet { defaults.set(dateTimeEnabled, forKey: Key.dateTime) } }
    var gridEnabled: Bool { didSet { defaults.set(gridEnabled, forKey: Key.grid) } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aspectRatio = CaptureAspectRatio(rawValue: defaults.string(forKey: Key.aspectRatio) ?? "") ?? .portrait916
        resolution = VideoResolution(rawValue: defaults.string(forKey: Key.resolution) ?? "") ?? .p1080
        frameRate = VideoFrameRate(rawValue: defaults.integer(forKey: Key.frameRate)) ?? .fps30
        audioQuality = AudioRecordingQuality(rawValue: defaults.string(forKey: Key.audioQuality) ?? "") ?? .aac
        stabilizationEnabled = defaults.object(forKey: Key.stabilization) as? Bool ?? true
        teleprompterEnabled = defaults.bool(forKey: Key.teleprompter)
        teleprompterText = defaults.string(forKey: Key.teleprompterText) ?? ""
        dateTimeEnabled = defaults.bool(forKey: Key.dateTime)
        gridEnabled = defaults.bool(forKey: Key.grid)
        hapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
    }

    var snapshot: CameraSettingsSnapshot {
        CameraSettingsSnapshot(aspectRatio: aspectRatio,
                               resolution: resolution,
                               frameRate: frameRate,
                               audioQuality: audioQuality,
                               stabilizationEnabled: stabilizationEnabled,
                               teleprompterEnabled: teleprompterEnabled,
                               teleprompterText: teleprompterText,
                               dateTimeEnabled: dateTimeEnabled,
                               gridEnabled: gridEnabled,
                               hapticsEnabled: hapticsEnabled)
    }
}
