import SwiftUI
import UIKit
import Observation

/// Цвет кисти и фигур.
enum DrawColor: String, CaseIterable, Identifiable {
    case white, black, red, blue, green, yellow

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white: return .white
        case .black: return .black
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .yellow: return .yellow
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .yellow: return .yellow
        }
    }
}

/// Инструмент рисования.
enum ToolMode: String, CaseIterable, Identifiable {
    case pen, rectangle, arrow, select

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen: return "pencil"
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .select: return "cursorarrow.motionlines"
        }
    }
}

/// Один элемент рисунка. Координаты и размеры — нормализованные (0...1),
/// толщина линии — доля ширины холста.
struct DrawingElement: Identifiable {
    let id = UUID()
    var kind: Kind
    var color: DrawColor
    var lineWidth: CGFloat

    enum Kind {
        case stroke(points: [CGPoint])
        case rectangle(rect: CGRect)
        case arrow(from: CGPoint, to: CGPoint)
    }

    var boundingBox: CGRect {
        switch kind {
        case .stroke(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .rectangle(let rect):
            return rect
        case .arrow(let from, let to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        }
    }
}

/// Хранит элементы рисунка и настройки инструмента.
@Observable
final class DrawingEngine {
    /// Готовые элементы.
    var elements: [DrawingElement] = []
    /// Включён ли режим рисования.
    var isDrawingEnabled = false
    /// Выбранный инструмент.
    var toolMode: ToolMode = .pen
    /// Выбранный цвет.
    var selectedColor: DrawColor = .white
    /// Толщина кисти в пунктах (на холсте превью).
    var brushWidth: CGFloat = 6

    /// Элемент, который создаётся прямо сейчас (черновик).
    private(set) var draftElement: DrawingElement?
    /// Идёт ли жест перетаскивания.
    private(set) var isDragging = false
    /// Выбранный элемент (для перемещения/изменения размера).
    private(set) var selectedElementID: UUID?

    private enum DragMode { case none, move, resize }
    private var dragMode: DragMode = .none
    private var dragStartPoint: CGPoint = .zero
    private var dragStartElement: DrawingElement?

    var selectedElement: DrawingElement? {
        guard let id = selectedElementID else { return nil }
        return elements.first { $0.id == id }
    }

    func normalizedWidth(canvasSize: CGSize) -> CGFloat {
        canvasSize.width > 0 ? brushWidth / canvasSize.width : 0.005
    }

    // MARK: - Жест: начало

    func begin(at point: CGPoint, canvasSize: CGSize) {
        isDragging = true
        switch toolMode {
        case .pen:
            draftElement = make(.stroke(points: [point]), canvasSize: canvasSize)
        case .rectangle:
            draftElement = make(.rectangle(rect: CGRect(origin: point, size: .zero)), canvasSize: canvasSize)
        case .arrow:
            draftElement = make(.arrow(from: point, to: point), canvasSize: canvasSize)
        case .select:
            beginSelectDrag(at: point, canvasSize: canvasSize)
        }
    }

    // MARK: - Жест: продолжение

    func update(at point: CGPoint) {
        switch toolMode {
        case .pen:
            guard var el = draftElement, case .stroke(let points) = el.kind else { return }
            el.kind = .stroke(points: points + [point])
            draftElement = el
        case .rectangle:
            guard var el = draftElement, case .rectangle(let rect) = el.kind else { return }
            el.kind = .rectangle(rect: rect(from: rect.origin, to: point))
            draftElement = el
        case .arrow:
            guard var el = draftElement, case .arrow(let from, _) = el.kind else { return }
            el.kind = .arrow(from: from, to: point)
            draftElement = el
        case .select:
            updateSelectDrag(to: point)
        }
    }

    // MARK: - Жест: конец

    func end(canvasSize: CGSize) {
        isDragging = false
        switch toolMode {
        case .pen:
            if let el = draftElement, case .stroke(let points) = el.kind, points.count > 1 {
                elements.append(el)
            }
        case .rectangle, .arrow:
            if let el = draftElement, el.boundingBox.width > 0.005 || el.boundingBox.height > 0.005 {
                elements.append(el)
            }
        case .select:
            dragMode = .none
            dragStartElement = nil
        }
        draftElement = nil
    }

    // MARK: - Выбор/перемещение/изменение размера

    private func beginSelectDrag(at point: CGPoint, canvasSize: CGSize) {
        if let selected = selectedElement, isNearResizeHandle(point, of: selected, canvasSize: canvasSize) {
            dragMode = .resize
            dragStartPoint = point
            dragStartElement = selected
        } else if let hit = hitTest(point, canvasSize: canvasSize) {
            selectedElementID = hit.id
            dragMode = .move
            dragStartPoint = point
            dragStartElement = hit
        } else {
            selectedElementID = nil
            dragMode = .none
        }
    }

    private func updateSelectDrag(to point: CGPoint) {
        guard let id = selectedElementID, let snapshot = dragStartElement else { return }
        var updated = snapshot
        switch dragMode {
        case .move:
            updated.kind = translated(snapshot.kind, by: CGPoint(x: point.x - dragStartPoint.x,
                                                                  y: point.y - dragStartPoint.y))
        case .resize:
            switch snapshot.kind {
            case .rectangle(let rect):
                updated.kind = .rectangle(rect: rect(from: rect.origin, to: point))
            case .arrow(let from, _):
                updated.kind = .arrow(from: from, to: point)
            case .stroke:
                break
            }
        case .none:
            break
        }
        if let index = elements.firstIndex(where: { $0.id == id }) {
            elements[index] = updated
        }
    }

    // MARK: - Вспомогательные

    private func make(_ kind: DrawingElement.Kind, canvasSize: CGSize) -> DrawingElement {
        DrawingElement(kind: kind, color: selectedColor, lineWidth: normalizedWidth(canvasSize: canvasSize))
    }

    private func rect(from origin: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
               width: abs(point.x - origin.x), height: abs(point.y - origin.y))
    }

    private func translated(_ kind: DrawingElement.Kind, by delta: CGPoint) -> DrawingElement.Kind {
        switch kind {
        case .stroke(let points):
            return .stroke(points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) })
        case .rectangle(let rect):
            return .rectangle(rect: rect.offsetBy(dx: delta.x, dy: delta.y))
        case .arrow(let from, let to):
            return .arrow(from: CGPoint(x: from.x + delta.x, y: from.y + delta.y),
                          to: CGPoint(x: to.x + delta.x, y: to.y + delta.y))
        }
    }

    private func hitTest(_ point: CGPoint, canvasSize: CGSize) -> DrawingElement? {
        let tolerance = 24 / max(canvasSize.width, 1)
        for element in elements.reversed() {
            if element.boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return element
            }
        }
        return nil
    }

    private func isNearResizeHandle(_ point: CGPoint, of element: DrawingElement, canvasSize: CGSize) -> Bool {
        let box = element.boundingBox
        let handle = CGPoint(x: box.maxX, y: box.maxY)
        let tolerance = 28 / max(canvasSize.width, 1)
        return abs(point.x - handle.x) <= tolerance && abs(point.y - handle.y) <= tolerance
    }

    // MARK: - Отмена и очистка

    func undo() {
        if !elements.isEmpty { elements.removeLast() }
        selectedElementID = nil
    }

    func clear() {
        elements.removeAll()
        draftElement = nil
        selectedElementID = nil
    }
}
