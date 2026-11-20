import SwiftUI

struct SplitDividerView: View {
    let orientation: SplitOrientation
    let ratio: CGFloat
    let onRatioChanged: (CGFloat) -> Void

    @State private var dragStartRatio: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let isVerticalSplit = orientation == .vertical
            let handle = RoundedRectangle(cornerRadius: HUDTheme.splitHandleCornerRadius)
                .fill(HUDTheme.splitHandleFill)
                .frame(width: isVerticalSplit ? HUDTheme.splitHandleWidth : HUDTheme.splitHandleHeight,
                       height: isVerticalSplit ? HUDTheme.splitHandleHeight : HUDTheme.splitHandleWidth)
                .overlay {
                    RoundedRectangle(cornerRadius: HUDTheme.splitHandleCornerRadius)
                        .stroke(HUDTheme.splitHandleBorder, lineWidth: HUDTheme.buttonBorderWidth)
                }
                .shadow(color: HUDTheme.splitHandleShadow, radius: HUDTheme.splitHandleShadowRadius)
                .frame(width: HUDTheme.splitHandleHitSize, height: HUDTheme.splitHandleHitSize)
                .contentShape(Rectangle())
                .position(x: isVerticalSplit ? geometry.size.width / 2 : geometry.size.width * ratio,
                          y: isVerticalSplit ? geometry.size.height * ratio : geometry.size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStartRatio ?? ratio
                            dragStartRatio = start
                            let axisLength = isVerticalSplit ? geometry.size.height : geometry.size.width
                            guard axisLength > 0 else { return }
                            let translation = isVerticalSplit
                                ? value.translation.height
                                : value.translation.width
                            onRatioChanged(min(max(start + translation / axisLength,
                                                   SplitRatio.minimum),
                                               SplitRatio.maximum))
                        }
                        .onEnded { _ in dragStartRatio = nil }
                )
                .accessibilityElement()
                .accessibilityLabel("Граница между камерами")
                .accessibilityValue("\(Int(ratio * 100))%")
                .accessibilityAdjustableAction { direction in
                    let adjustment = direction == .increment
                        ? HUDTheme.splitRatioAccessibilityStep
                        : -HUDTheme.splitRatioAccessibilityStep
                    onRatioChanged(min(max(ratio + adjustment,
                                           SplitRatio.minimum),
                                       SplitRatio.maximum))
                }

            ZStack {
                Rectangle()
                    .fill(HUDTheme.splitDividerLine)
                    .frame(width: isVerticalSplit ? geometry.size.width : HUDTheme.splitDividerThickness,
                           height: isVerticalSplit ? HUDTheme.splitDividerThickness : geometry.size.height)
                    .position(x: isVerticalSplit ? geometry.size.width / 2 : geometry.size.width * ratio,
                              y: isVerticalSplit ? geometry.size.height * ratio : geometry.size.height / 2)
                handle
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
