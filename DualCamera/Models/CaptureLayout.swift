import Foundation

/// Раскладка превью и итоговой склейки двух снимков.
enum CaptureLayout: String, CaseIterable, Identifiable {
    /// Две камеры друг под другом (сплит-экран).
    case splitScreen
    /// Основная камера на весь экран, вторая — маленьким окном (PiP).
    case pip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .splitScreen: return "Сплит"
        case .pip: return "Картинка в картинке"
        }
    }

    var systemImage: String {
        switch self {
        case .splitScreen: return "rectangle.split.2x1"
        case .pip: return "pip"
        }
    }
}
