import UIKit

/// Общие генераторы тактильной отдачи. Их нужно держать живыми и готовить
/// заранее, иначе iOS не успевает проиграть отклик.
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let impactGenerator = UIImpactFeedbackGenerator(style: .light)

    static func selection() {
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
    }

    static func impact() {
        impactGenerator.prepare()
        impactGenerator.impactOccurred()
    }
}
