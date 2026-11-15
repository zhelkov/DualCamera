import SwiftUI
import AVKit
import Photos

/// Экран результата записи: показывает объединённое видео, которое сохраняется автоматически.
struct MergedVideoView: View {
    let videoURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saveErrorMessage: String?
    @State private var saveStatus = "Сохраняем видео в Фото…"
    @State private var isSaving = true
    @State private var didStartSaving = false
    @State private var videoDiagnostics = "Читаю временные метки видео…"

    var body: some View {
        NavigationStack {
            VStack {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 320)
                        .padding()
                        .overlay(alignment: .top) {
                            Text(videoDiagnostics)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .lineLimit(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                        }
                } else {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 320)
                        .padding()
                }

                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Image(systemName: saveErrorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    Text(saveStatus)
                        .font(.subheadline)
                }
                .padding()

                if saveErrorMessage != nil {
                    Button("Повторить сохранение") {
                        save()
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom)
                }
            }
            .navigationTitle("Видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onAppear {
                player = AVPlayer(url: videoURL)
                inspectVideoTracks()
                guard !didStartSaving else { return }
                didStartSaving = true
                save()
            }
            .onDisappear {
                player?.pause()
            }
            .alert("Ошибка сохранения", isPresented: saveErrorBinding) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )
    }

    private func inspectVideoTracks() {
        let url = videoURL
        DispatchQueue.global(qos: .utility).async {
            let diagnostics = Self.readVideoDiagnostics(url: url) { progress in
                DispatchQueue.main.async {
                    self.videoDiagnostics = progress
                }
            }
            DispatchQueue.main.async {
                self.videoDiagnostics = diagnostics
            }
        }
    }

    private static func readVideoDiagnostics(url: URL,
                                             progress: @escaping (String) -> Void) -> String {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            return "Видеодорожка не найдена"
        }

        let videoRangeDuration = videoTrack.timeRange.duration.seconds
        let frameRate = videoTrack.nominalFrameRate
        var fullFrameRateIntent = "недоступен"
        if #available(iOS 18.0, *) {
            let metadata = asset.metadata(forFormat: .quickTimeMetadata)
            let intentItem = metadata.first {
                $0.identifier == .quickTimeMetadataFullFrameRatePlaybackIntent
            }
            fullFrameRateIntent = intentItem?.stringValue ?? "отсутствует"
        }
        var frameCount = 0
        var firstPTS: CMTime?
        var lastPTS: CMTime?
        var previousPTS: CMTime?
        var minStep = Double.greatestFiniteMagnitude
        var maxStep = 0.0
        var totalStep = 0.0
        var positiveStepCount = 0
        var longSteps = 0

        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            guard reader.canAdd(output) else { return "Не удалось прочитать видеокадры" }
            reader.add(output)
            guard reader.startReading() else {
                return "Не удалось начать чтение временных меток видео"
            }

            while let sampleBuffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard pts.isValid, pts.seconds.isFinite else { continue }
                frameCount += 1
                if firstPTS == nil { firstPTS = pts }
                if let previousPTS {
                    let step = CMTimeSubtract(pts, previousPTS).seconds
                    if step > 0, step.isFinite {
                        minStep = min(minStep, step)
                        maxStep = max(maxStep, step)
                        totalStep += step
                        positiveStepCount += 1
                        if step > 0.05 { longSteps += 1 }
                    }
                }
                previousPTS = pts
                lastPTS = pts
                if frameCount.isMultiple(of: 300) {
                    let span = firstPTS.flatMap { start in
                        lastPTS.map { CMTimeSubtract($0, start).seconds }
                    } ?? 0
                    let spanText = String(format: "%.2f", span)
                    progress("Читаю кадры: \(frameCount), диапазон PTS: \(spanText) с")
                }
            }

            if reader.status == .failed {
                return "Ошибка чтения кадров: \(reader.error?.localizedDescription ?? "неизвестная ошибка")"
            }
        } catch {
            return "Не удалось прочитать временные метки видео: \(error.localizedDescription)"
        }

        let ptsSpan: Double
        if let firstPTS, let lastPTS {
            ptsSpan = CMTimeSubtract(lastPTS, firstPTS).seconds
        } else {
            ptsSpan = 0
        }
        let averageStep = positiveStepCount > 0 ? totalStep / Double(positiveStepCount) : 0
        let minStepValue = minStep.isFinite ? minStep : 0
        let audioDuration = asset.tracks(withMediaType: .audio).first?.timeRange.duration.seconds ?? 0

        return String(
            format: "Видео: %.2f с · PTS %.2f с · %d кадров · шаг %.3f/%.3f/%.3f с · >0.05 с: %d · FPS %.1f · FullFrameRateIntent: %@ · звук %.2f с",
            videoRangeDuration,
            ptsSpan,
            frameCount,
            minStepValue,
            averageStep,
            maxStep,
            longSteps,
            frameRate,
            fullFrameRateIntent,
            audioDuration
        )
    }

    private func save() {
        isSaving = true
        saveErrorMessage = nil
        saveStatus = "Сохраняем видео в Фото…"

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    saveStatus = "Нет доступа к Фото"
                    saveErrorMessage = "Разрешите приложению добавлять видео в медиатеку в настройках iPhone."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        isSaving = false
                        saveStatus = "Видео сохранено в Фото"
                    } else {
                        isSaving = false
                        saveStatus = "Не удалось сохранить видео"
                        saveErrorMessage = error?.localizedDescription ?? "Не удалось сохранить видео."
                    }
                }
            }
        }
    }
}
