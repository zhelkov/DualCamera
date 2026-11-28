import Foundation

/// Пресеты баланса белого.
enum WhiteBalancePreset: String, CaseIterable, Identifiable {
    case auto
    case daylight
    case cloudy
    case shade
    case fluorescent
    case tungsten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .daylight: return "Дневной"
        case .cloudy: return "Облачно"
        case .shade: return "Тень"
        case .fluorescent: return "Лампы"
        case .tungsten: return "Накаливания"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "A"
        case .daylight: return "Д"
        case .cloudy: return "О"
        case .shade: return "Т"
        case .fluorescent: return "Л"
        case .tungsten: return "Н"
        }
    }

    /// Цветовая температура в кельвинах; nil — автоматический режим.
    var temperature: Float? {
        switch self {
        case .auto: return nil
        case .daylight: return 5500
        case .cloudy: return 6500
        case .shade: return 7500
        case .fluorescent: return 4200
        case .tungsten: return 3200
        }
    }
}

/// Настройки изображения с ползунком.
enum ImageAdjustment: String, CaseIterable, Identifiable {
    case whiteBalance
    case temperature
    case iso
    case shutter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whiteBalance: return "ББ"
        case .temperature: return "Темп."
        case .iso: return "ISO"
        case .shutter: return "Выдержка"
        }
    }

    var systemImage: String {
        switch self {
        case .whiteBalance: return "sun.max"
        case .temperature: return "thermometer"
        case .iso: return "circle.lefthalf.filled"
        case .shutter: return "timer"
        }
    }
}
