import SwiftUI
import UIKit

struct FilterCarouselView: View {
    @Binding var selectedFilter: VideoFilter
    let hapticsEnabled: Bool
    @State private var scrollPosition: VideoFilter?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: HUDTheme.filterOptionSpacing) {
                    ForEach(VideoFilter.allCases) { filter in
                        Button {
                            if hapticsEnabled {
                                Haptics.selection()
                            }
                            withAnimation(.easeOut(duration: HUDTheme.filterSelectionDuration)) {
                                selectedFilter = filter
                            }
                        } label: {
                            FilterFlowerView(filter: filter)
                                .frame(width: HUDTheme.filterOptionSize,
                                       height: HUDTheme.filterOptionSize)
                                .overlay {
                                    RoundedRectangle(cornerRadius: HUDTheme.filterOptionCornerRadius)
                                        .stroke(selectedFilter == filter
                                                ? HUDTheme.yellow
                                                : .clear,
                                                lineWidth: HUDTheme.buttonBorderWidth)
                                }
                                .scaleEffect(selectedFilter == filter ? 1 : HUDTheme.filterInactiveScale)
                                .opacity(selectedFilter == filter ? 1 : HUDTheme.filterInactiveOpacity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(filter.title)
                        .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                        .id(filter)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, HUDTheme.filterCarouselVerticalInset)
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrollPosition, anchor: .center)
            .frame(width: HUDTheme.filterMenuWidth, height: HUDTheme.filterMenuHeight)
            .background(HUDTheme.glass, in: RoundedRectangle(cornerRadius: HUDTheme.filterMenuCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HUDTheme.filterMenuCornerRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: HUDTheme.buttonBorderWidth)
            }
            .overlay {
                RoundedRectangle(cornerRadius: HUDTheme.filterOptionCornerRadius)
                    .stroke(HUDTheme.yellow.opacity(0.22), lineWidth: HUDTheme.buttonBorderWidth)
                    .frame(width: HUDTheme.filterOptionSize + 4, height: HUDTheme.filterOptionSize + 4)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if selectedFilter != .noir {
                    LinearGradient(colors: [HUDTheme.glass.opacity(0), HUDTheme.glass],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: HUDTheme.filterHintHeight)
                        .clipShape(RoundedRectangle(cornerRadius: HUDTheme.filterMenuCornerRadius))
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                scrollPosition = selectedFilter
                proxy.scrollTo(selectedFilter, anchor: .center)
            }
            .onChange(of: selectedFilter) { _, filter in
                guard scrollPosition != filter else { return }
                scrollPosition = filter
                withAnimation(.easeOut(duration: HUDTheme.filterSelectionDuration)) {
                    proxy.scrollTo(filter, anchor: .center)
                }
            }
            .onChange(of: scrollPosition) { _, filter in
                guard let filter, filter != selectedFilter else { return }
                selectedFilter = filter
            }
            .accessibilityLabel("Фильтры камеры")
        }
    }
}

private struct FilterFlowerView: View {
    let filter: VideoFilter

    private var palette: [Color] {
        switch filter {
        case .original:
            return [.red, .orange, .yellow, .green, .cyan, .blue, .indigo, .purple]
        case .vivid:
            return [Color(red: 1, green: 0.18, blue: 0.33),
                    Color(red: 1, green: 0.58, blue: 0.05),
                    Color(red: 1, green: 0.82, blue: 0.04),
                    Color(red: 0.12, green: 0.84, blue: 0.32),
                    Color(red: 0.23, green: 0.82, blue: 1),
                    Color(red: 0.03, green: 0.44, blue: 1),
                    Color(red: 0.34, green: 0.32, blue: 0.95),
                    Color(red: 0.76, green: 0.28, blue: 0.95)]
        case .warm:
            return [Color(red: 1, green: 0.23, blue: 0.14), .orange,
                    Color(red: 1, green: 0.69, blue: 0), HUDTheme.yellow,
                    Color(red: 1, green: 0.55, blue: 0.47),
                    Color(red: 0.85, green: 0.47, blue: 0.27),
                    Color(red: 0.94, green: 0.66, blue: 0.29),
                    Color(red: 0.89, green: 0.36, blue: 0.42)]
        case .cool:
            return [Color(red: 0.85, green: 0.95, blue: 1),
                    Color(red: 0.44, green: 0.85, blue: 1),
                    Color(red: 0, green: 0.71, blue: 0.85),
                    Color(red: 0.18, green: 0.5, blue: 0.93),
                    Color(red: 0.42, green: 0.39, blue: 1),
                    Color(red: 0.61, green: 0.55, blue: 1),
                    Color(red: 0, green: 0.83, blue: 1),
                    Color(red: 0.5, green: 0.93, blue: 0.6)]
        case .dramatic:
            return [Color(red: 0.73, green: 0.11, blue: 0.11),
                    Color(red: 0.5, green: 0.11, blue: 0.11),
                    Color(red: 0.26, green: 0.22, blue: 0.79),
                    Color(red: 0.12, green: 0.23, blue: 0.54),
                    Color(red: 0.07, green: 0.09, blue: 0.15),
                    Color(red: 0.3, green: 0.11, blue: 0.59),
                    Color(red: 0.35, green: 0.11, blue: 0.53),
                    Color(red: 0.86, green: 0.15, blue: 0.15)]
        case .dramaticWarm:
            return [Color(red: 0.6, green: 0.2, blue: 0.07),
                    Color(red: 0.76, green: 0.25, blue: 0.05),
                    Color(red: 0.92, green: 0.35, blue: 0.05),
                    Color(red: 0.96, green: 0.62, blue: 0.04),
                    Color(red: 0.47, green: 0.21, blue: 0.06),
                    Color(red: 0.63, green: 0.38, blue: 0.03),
                    Color(red: 0.71, green: 0.33, blue: 0.04),
                    Color(red: 0.86, green: 0.15, blue: 0.15)]
        case .silver:
            return [Color(white: 0.9), Color(white: 0.82), Color(white: 0.62),
                    Color(white: 0.94), Color(white: 0.63), Color(white: 0.83),
                    Color(white: 0.45), Color(white: 0.92)]
        case .mono:
            return (0..<8).map { Color(white: 0.95 - Double($0) * 0.12) }
        case .noir:
            return (0..<8).map { Color(white: 0.98 - Double($0) * 0.13) }
        }
    }

    private var centerColor: Color {
        switch filter {
        case .original: return HUDTheme.yellow
        case .vivid: return .white
        case .warm: return Color(red: 1, green: 0.96, blue: 0.82)
        case .cool: return Color(red: 0.91, green: 0.98, blue: 1)
        case .dramatic: return Color(white: 0.96)
        case .dramaticWarm: return Color(red: 1, green: 0.91, blue: 0.56)
        case .silver: return Color(white: 0.8)
        case .mono, .noir: return .white
        }
    }

    var body: some View {
        ZStack {
            ForEach(0..<palette.count, id: \.self) { index in
                Capsule()
                    .fill(palette[index])
                    .frame(width: HUDTheme.filterPetalWidth,
                           height: HUDTheme.filterPetalHeight)
                    .offset(y: -HUDTheme.filterPetalOffset)
                    .rotationEffect(.degrees(Double(index) * HUDTheme.filterPetalRotation))
            }
            Circle()
                .fill(centerColor)
                .frame(width: HUDTheme.filterFlowerCenterSize,
                       height: HUDTheme.filterFlowerCenterSize)
        }
        .frame(width: HUDTheme.filterFlowerSize, height: HUDTheme.filterFlowerSize)
        .accessibilityHidden(true)
    }
}
