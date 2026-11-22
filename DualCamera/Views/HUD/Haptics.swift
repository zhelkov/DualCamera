import UIKit

/// Общие генераторы тактильной отдачи. Держим их живыми и готовим заранее:
/// без подготовки iOS не успевает проиграть отклик.
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)

    /// Вызывать при появлении экрана: прогревает моторы заранее.
    static func prepare() {
        selectionGenerator.prepare()
        lightGenerator.prepare()
        mediumGenerator.prepare()
    }

    /// Заметный отклик: «selection» на iPhone почти не ощущается,
    /// поэтому для кнопок используем лёгкий удар.
    static func selection() {
        lightGenerator.impactOccurred(intensity: 0.85)
        lightGenerator.prepare()
    }

    static func impact() {
        mediumGenerator.impactOccurred(intensity: 0.9)
        mediumGenerator.prepare()
    }

    /// Тестовый отклик, не зависящий от настроек приложения.
    static func test() {
        mediumGenerator.impactOccurred(intensity: 1)
    }
}
