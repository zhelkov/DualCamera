import SwiftUI

struct SettingsSheetView: View {
    @Bindable var settings: CameraSettings
    let isRecording: Bool
    let hasImportedMedia: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            grabber
            heading
            ScrollView {
                settingsControls
                .disabled(isRecording)
                .toggleStyle(.switch)
                .tint(HUDTheme.yellow)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, HUDTheme.settingsHorizontalPadding)
        .background(HUDTheme.settingsBackground)
        .preferredColorScheme(.dark)
    }

    private var grabber: some View {
        Capsule()
            .fill(HUDTheme.settingsGrabber)
            .frame(width: HUDTheme.settingsGrabberWidth,
                   height: HUDTheme.settingsGrabberHeight)
            .padding(.top, HUDTheme.settingsTopPadding)
            .padding(.bottom, HUDTheme.settingsHeadingSpacing)
    }

    private var heading: some View {
        HStack {
            Text("Настройки")
                .font(.system(size: HUDTheme.settingsTitleFontSize, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: HUDTheme.settingsCloseIconSize, weight: .medium))
                    .foregroundStyle(HUDTheme.settingsSecondaryText)
                    .frame(width: HUDTheme.settingsCloseButtonSize,
                           height: HUDTheme.settingsCloseButtonSize)
                    .background(HUDTheme.settingsCloseFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть настройки")
        }
        .padding(.bottom, HUDTheme.settingsGroupSpacing)
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: HUDTheme.settingsGroupSpacing) {
            aspectRatioGroup
            resolutionGroup
            frameRateGroup
            audioQualityGroup
            Toggle("Стабилизация", isOn: $settings.stabilizationEnabled)
            teleprompterControls
            Toggle("Дата и время на экране", isOn: $settings.dateTimeEnabled)
            Toggle("Показать сетку", isOn: $settings.gridEnabled)
            Toggle("Тактильная отдача", isOn: $settings.hapticsEnabled)
        }
        .padding(.bottom, HUDTheme.settingsBottomPadding)
    }

    private var aspectRatioGroup: some View {
        optionGroup("Формат кадра") {
            HStack(spacing: HUDTheme.settingsOptionSpacing) {
                ForEach(CaptureAspectRatio.allCases, id: \.id) { value in
                    optionButton(value.title, isSelected: settings.aspectRatio == value) {
                        settings.aspectRatio = value
                    }
                }
            }
        }
    }

    private var resolutionGroup: some View {
        optionGroup("Режим видео") {
            HStack(spacing: HUDTheme.settingsOptionSpacing) {
                ForEach(VideoResolution.allCases, id: \.id) { value in
                    optionButton(value.rawValue, isSelected: settings.resolution == value) {
                        settings.resolution = value
                    }
                }
            }
        }
    }

    private var frameRateGroup: some View {
        optionGroup("Частота кадров") {
            HStack(spacing: HUDTheme.settingsOptionSpacing) {
                ForEach([VideoFrameRate.fps30, .fps24, .fps60], id: \.id) { value in
                    optionButton(value.title, isSelected: settings.frameRate == value) {
                        settings.frameRate = value
                    }
                }
            }
        }
    }

    private var audioQualityGroup: some View {
        optionGroup("Качество звука") {
            VStack(alignment: .leading, spacing: HUDTheme.settingsHintSpacing) {
                HStack(spacing: HUDTheme.settingsOptionSpacing) {
                    ForEach(AudioRecordingQuality.allCases, id: \.id) { value in
                        optionButton(value.title,
                                     isSelected: settings.audioQuality == value,
                                     isEnabled: !(hasImportedMedia && value == .appleLossless)) {
                            settings.audioQuality = value
                        }
                    }
                }
                if hasImportedMedia {
                    Text("Apple Lossless недоступен при записи с импортированным видео.")
                        .font(.system(size: HUDTheme.settingsHintFontSize))
                        .foregroundStyle(HUDTheme.settingsSecondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var teleprompterControls: some View {
        Toggle("Телесуфлёр", isOn: $settings.teleprompterEnabled)
        if settings.teleprompterEnabled {
            TextField("Текст для телесуфлёра", text: $settings.teleprompterText, axis: .vertical)
                .lineLimit(HUDTheme.teleprompterMinimumLines...HUDTheme.teleprompterMaximumLines)
                .padding(HUDTheme.settingsTextFieldPadding)
                .background(HUDTheme.settingsTextFieldFill,
                            in: RoundedRectangle(cornerRadius: HUDTheme.settingsTextFieldCornerRadius))
        }
    }

    private func optionGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: HUDTheme.settingsLabelSpacing) {
            Text(title)
                .font(.system(size: HUDTheme.settingsLabelFontSize, weight: .medium))
                .foregroundStyle(HUDTheme.settingsSecondaryText)
                .padding(.leading, HUDTheme.settingsLabelLeadingPadding)
            content()
                .padding(HUDTheme.settingsOptionsPadding)
                .background(HUDTheme.settingsOptionsFill,
                            in: RoundedRectangle(cornerRadius: HUDTheme.settingsOptionsCornerRadius))
        }
    }

    private func optionButton(_ title: String,
                              isSelected: Bool,
                              isEnabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: HUDTheme.settingsOptionFontSize, weight: .medium))
                .foregroundStyle(isSelected ? HUDTheme.yellow : HUDTheme.settingsOptionText)
                .frame(maxWidth: .infinity, minHeight: HUDTheme.settingsOptionHeight)
                .padding(.horizontal, HUDTheme.settingsOptionHorizontalPadding)
                .background {
                    RoundedRectangle(cornerRadius: HUDTheme.settingsOptionCornerRadius)
                        .fill(isSelected ? HUDTheme.settingsSelectedFill : .clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: HUDTheme.settingsOptionCornerRadius)
                                .stroke(isSelected ? HUDTheme.settingsSelectedBorder : .clear,
                                        lineWidth: HUDTheme.buttonBorderWidth)
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
