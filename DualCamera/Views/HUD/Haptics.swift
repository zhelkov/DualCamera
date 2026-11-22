import UIKit

/// Общие генераторы тактильной отдачи. Держим их живыми и готовим заранее:
/// без подготовки iOS не успевает проиграть отклик.
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let impactGenerator = UIImpactFeedbackGenerator(style: .light)

    /// Вызывать при появлении экрана: прогревает моторы заранее.
    static func prepare() {
        selectionGenerator.prepare()
        impactGenerator.prepare()
    }

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func impact() {
        impactGenerator.impactOccurred()
        impactGenerator.prepare()
    }
}
