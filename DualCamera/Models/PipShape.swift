import Foundation
import CoreGraphics

/// Форма окна «картинка в картинке» (PiP).
enum PipShape: String, CaseIterable, Identifiable {
    case rectangle
    case square
    case circle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "Прямоугольник"
        case .square: return "Квадрат"
        case .circle: return "Круг"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .square: return "square"
        case .circle: return "circle"
        }
    }

    /// Соотношение сторон окна.
    var aspectRatio: CGFloat {
        switch self {
        case .rectangle: return 16.0 / 9.0
        case .square, .circle: return 1.0
        }
    }

    /// Радиус скругления для окна заданного размера.
    func cornerRadius(for size: CGSize) -> CGFloat {
        switch self {
        case .rectangle: return 16
        case .square: return 12
        case .circle: return size.width / 2
        }
    }
}
