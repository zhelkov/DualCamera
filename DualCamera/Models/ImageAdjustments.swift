import Foundation

/// Пресеты баланса белого.
enum WhiteBalancePreset: String, CaseIterable, Identifiable {
    case auto
    case daylight
    case shade
    case cloudy
    case tungsten
    case fluorescent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .daylight: return "Дневной свет"
        case .shade: return "Тень"
        case .cloudy: return "Облачно"
        case .tungsten: return "Лампа накаливания"
        case .fluorescent: return "Люминесцентная лампа"
        }
    }

    /// Значок без подписи, как в макете.
    var systemImage: String? {
        switch self {
        case .auto: return nil
        case .daylight: return "sun.max.fill"
        case .shade: return "house.fill"
        case .cloudy: return "cloud.fill"
        case .tungsten: return "lightbulb.fill"
        case .fluorescent: return "light.max"
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
    case iso
    case shutter

    var id: String { rawValue }

    /// Короткая подпись на кнопке.
    func buttonTitle(shutter: String) -> String {
        switch self {
        case .whiteBalance: return "WB"
        case .iso: return "ISO"
        case .shutter: return shutter
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .whiteBalance: return "Баланс белого"
        case .iso: return "Светочувствительность"
        case .shutter: return "Выдержка"
        }
    }
}
