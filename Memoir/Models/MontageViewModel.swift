//
//  MontageViewModel.swift
//  Snap Second
//
//  Business logic and state management for MontageView
//

import Foundation
import SwiftUI
import AVFoundation

struct MontageExportAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

enum MontageExportFailureKind: Equatable {
    case sessionCreationFailed
    case stalled
    case timedOut
    case failed
    case cancelled
    case buildFailure
}

enum MontageExportCancellationReason: String {
    case stalled
    case timedOut
    case userCancelled

    var failureKind: MontageExportFailureKind {
        switch self {
        case .stalled:
            return .stalled
        case .timedOut:
            return .timedOut
        case .userCancelled:
            return .cancelled
        }
    }
}

struct MontageExportFailurePresentation: Equatable {
    let title: String
    let message: String
}

struct MontageExportFailureLogContext {
    let projectName: String
    let projectID: UUID
    let range: DateInterval
    let orientation: Orientation
    let exportQuality: ExportQuality
    let contentMode: ContentMode
    let outputURL: URL?
    let presetName: String
    let outputFileType: AVFileType
    let renderSize: CGSize?
    let compositionDuration: TimeInterval?
    let sessionStatus: AVAssetExportSession.Status?
    let progress: Float?
}

private final class MontageExportRuntimeState {
    var cancellationReason: MontageExportCancellationReason?
}

enum MontageExportDiagnostics {
    static func presentation(
        for kind: MontageExportFailureKind,
        error: NSError?
    ) -> MontageExportFailurePresentation {
        let title = "Export Failed"

        switch kind {
        case .sessionCreationFailed:
            return .init(title: title, message: "Couldn’t start the export.")
        case .stalled:
            return .init(title: title, message: "Export stopped making progress and was cancelled.")
        case .timedOut:
            return .init(title: title, message: "Export took too long and timed out.")
        case .failed:
            if let detail = shortDetail(from: error) {
                return .init(title: title, message: "Export failed: \(detail)")
            }
            return .init(title: title, message: "Export failed before the video could be created.")
        case .cancelled, .buildFailure:
            if let detail = shortDetail(from: error) {
                return .init(title: title, message: "Export failed before the video could be created. \(detail)")
            }
            return .init(title: title, message: "Export failed before the video could be created.")
        }
    }

    static func shortDetail(from error: NSError?) -> String? {
        guard let error else { return nil }

        let candidates = [
            error.localizedFailureReason,
            error.localizedDescription,
            error.localizedRecoverySuggestion
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return trimmed
        }

        return nil
    }

    static func logMessage(
        for kind: MontageExportFailureKind,
        error: NSError?,
        context: MontageExportFailureLogContext
    ) -> String {
        let rangeSummary = "\(iso8601(context.range.start)) -> \(iso8601(context.range.end))"
        let renderSizeSummary: String = {
            guard let renderSize = context.renderSize else { return "nil" }
            return "\(Int(renderSize.width))x\(Int(renderSize.height))"
        }()
        let durationSummary: String = {
            guard let compositionDuration = context.compositionDuration else { return "nil" }
            return String(format: "%.2fs", compositionDuration)
        }()
        let statusSummary = context.sessionStatus.map(statusName) ?? "nil"
        let progressSummary = context.progress.map { String(format: "%.3f", $0) } ?? "nil"
        let outputName = context.outputURL?.lastPathComponent ?? "nil"
        let outputPath = context.outputURL?.path ?? "nil"

        var lines = [
            "[MontageExport] failure=\(failureName(kind))",
            "[MontageExport] project=\"\(context.projectName)\" id=\(context.projectID.uuidString)",
            "[MontageExport] range=\(rangeSummary)",
            "[MontageExport] orientation=\(orientationName(context.orientation)) quality=\(context.exportQuality.rawValue) contentMode=\(contentModeName(context.contentMode))",
            "[MontageExport] preset=\(context.presetName) fileType=\(context.outputFileType.rawValue)",
            "[MontageExport] outputName=\(outputName)",
            "[MontageExport] outputPath=\(outputPath)",
            "[MontageExport] renderSize=\(renderSizeSummary) compositionDuration=\(durationSummary)",
            "[MontageExport] sessionStatus=\(statusSummary) progress=\(progressSummary)"
        ]

        if let error {
            lines.append("[MontageExport] errorDomain=\(error.domain) code=\(error.code)")
            lines.append("[MontageExport] errorDescription=\(error.localizedDescription)")
            if let reason = sanitized(error.localizedFailureReason) {
                lines.append("[MontageExport] failureReason=\(reason)")
            }
            if let suggestion = sanitized(error.localizedRecoverySuggestion) {
                lines.append("[MontageExport] recoverySuggestion=\(suggestion)")
            }
        } else {
            lines.append("[MontageExport] error=nil")
        }

        return lines.joined(separator: "\n")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func orientationName(_ orientation: Orientation) -> String {
        switch orientation {
        case .v916:
            return "v916"
        case .s11:
            return "s11"
        case .h169:
            return "h169"
        }
    }

    private static func contentModeName(_ contentMode: ContentMode) -> String {
        switch contentMode {
        case .fit:
            return "fit"
        case .fill:
            return "fill"
        }
    }

    private static func failureName(_ kind: MontageExportFailureKind) -> String {
        switch kind {
        case .sessionCreationFailed:
            return "session_creation_failed"
        case .stalled:
            return "stalled"
        case .timedOut:
            return "timed_out"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        case .buildFailure:
            return "build_failure"
        }
    }

    private static func statusName(_ status: AVAssetExportSession.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .waiting:
            return "waiting"
        case .exporting:
            return "exporting"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown_default"
        }
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func smoothedMontageExportProgress(
    actualProgress: Float,
    elapsed: TimeInterval
) -> Float {
    let clampedActual = min(max(actualProgress, 0), 1)
    let elapsedFloor = 0.04 + 0.78 * (1 - exp(-elapsed / 24))
    let displayFloor = min(Float(elapsedFloor), 0.82)

    if clampedActual >= 0.97 {
        return clampedActual
    }

    return min(max(clampedActual, displayFloor), 0.96)
}

// MARK: - Montage Rebuilding Logic

extension MontageView {

    /// Debounce interval for rebuild requests (in nanoseconds)
    /// This prevents rapid successive calls from triggering multiple rebuilds
    private static let rebuildDebounceNanos: UInt64 = 150_000_000  // 150ms

    @MainActor
    func beginRebuildWithSpinner() {
        savePrefs()
        rebuildTask?.cancel()

        // Block UI & pause playback immediately
        isRebuildingPreview = true
        if let p = player {
            p.pause()
        }

        // Debounce: wait briefly before starting rebuild to batch rapid changes
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: Self.rebuildDebounceNanos)
            guard !Task.isCancelled else { return }
            await rebuildMontage()
        }
    }

    /// Triggers a rebuild without debounce - use for user-initiated actions like range selection
    @MainActor
    func beginRebuildImmediate() {
        savePrefs()
        rebuildTask?.cancel()

        isRebuildingPreview = true
        if let p = player {
            p.pause()
        }

        rebuildTask = Task { await rebuildMontage() }
    }

    @MainActor
    func rebuildMontage() async {
        // 0) Query clips for the selected range; if empty, keep the empty UI
        let clipsNow = ClipStore.shared.clips(from: range.start, to: range.end, in: project)

        currentClipCount = clipsNow.count

        guard !clipsNow.isEmpty else {
            isEmpty = true
            player = nil
            overlayLayer = nil
            overlayKey &+= 1
            isRebuildingPreview = false
            return
        }
        isEmpty = false

        // 1) Build off main thread
        do {
            let svc = MontageService(project: project)

            // Pick the render size from current orientation
            let target = exportSize
            let customText = previewCustomCaptionText
            let showDateCaption = isDateCaptionsOn
            let showAnyCaptions = showDateCaption || customText != nil
            let customTuple = customText.map { (text: $0, anchor: bottomRowAnchor) }

            let (comp, vc, mix) = try await svc.makeVideo(
                for: range,
                backgroundMusicURL: effectiveMusicURL,
                musicVol: musicFloat,
                videoVol: videoFloat,
                musicStartTime: musicStartTime,
                musicDuration: musicDuration,
                showCaptions: showAnyCaptions,
                customCaption: customTuple,
                dateCaptionAnchor: bottomRowAnchor,
                showBranding: brandingOn,
                endCardSeconds: 2.0,
                mode: .preview,
                targetSize: target,
                contentMode: (contentMode == .fit ? .fit : .fill),
                captionColor: effectiveCaptionUIColorForCurrentMode(),
                captionFontVariant: {
                    if case .custom = captionMode { return .system }
                    return captionFont
                }(),
                captionPointSize: CGFloat(captionFontSize),
                filter: selectedFilter,
                backgroundColor: backgroundUIColor,
                playbackSpeed: speed,

            )

            // Preview overlay mirrors export visuals
            let dayClips = await svc.clips(in: range)
            let overlay = await svc.makePreviewOverlay(
                renderSize: vc.renderSize,
                clips: dayClips,
                showCaptions: showDateCaption,
                customCaption: nil,
                dateCaptionAnchor: bottomRowAnchor,
                showBranding: brandingOn,
                endCardSeconds: 2.0,
                compositionDuration: comp.duration,
                filter: selectedFilter,
                captionColor: effectiveCaptionUIColorForCurrentMode(),
                captionFontVariant: captionFont,
                captionPointSize: CGFloat(captionFontSize),
                playbackSpeed: speed,

            )

            // 3) Install on main
            await MainActor.run {
                let item = AVPlayerItem(asset: comp)
                item.videoComposition = vc
                if let mix { item.audioMix = mix }

                // Install the new player item
                if let existing = player {
                    existing.replaceCurrentItem(with: item)
                } else {
                    player = AVPlayer(playerItem: item)
                }

                CATransaction.begin()
                CATransaction.setDisableActions(true)

                // Clear animations on the OLD overlay so it doesn't cross-fade
                overlayLayer?.removeAllAnimations()

                // Install the NEW overlay
                baseOverlayLayer = overlay
                overlayLayer = baseOverlayLayer

                // Size/scale if needed
                if let ol = overlayLayer {
                    ol.contentsScale = UIScreen.main.scale
                }

                overlayKey &+= 1
                isRebuildingPreview = false
                CATransaction.commit()

                composition = comp
                videoComposition = vc
                audioMix = mix

                // Sync timeline items after rebuild
                syncTimelineItems()
            }
        } catch {
            await MainActor.run {
                isRebuildingPreview = false
            }
        }
    }


}

// MARK: - Export Logic

extension MontageView {

    @MainActor
    func exportAndShare() async {
        if !isPro && hasProFeatureEnabled {
            paywall.present()
            return
        }

        isExporting = true
        exportProg = 0
        exportURL = nil
        shareSheetURL = nil
        exportErrorAlert = nil
        exportStatusMessage = nil
        isSavingExport = false
        cancelExportAction = nil

        let presetName = AVAssetExportPresetHighestQuality
        let outputFileType: AVFileType = .mp4
        let runtimeState = MontageExportRuntimeState()
        var outputURL: URL?
        var renderSize: CGSize?
        var compositionDuration: TimeInterval?

        func failureContext(
            status: AVAssetExportSession.Status? = nil,
            progress: Float? = nil
        ) -> MontageExportFailureLogContext {
            MontageExportFailureLogContext(
                projectName: project.name,
                projectID: project.id,
                range: range,
                orientation: orientation,
                exportQuality: exportQuality,
                contentMode: contentMode,
                outputURL: outputURL,
                presetName: presetName,
                outputFileType: outputFileType,
                renderSize: renderSize,
                compositionDuration: compositionDuration,
                sessionStatus: status,
                progress: progress
            )
        }

        do {
            let customText = previewCustomCaptionText
            let showDateCaption = isDateCaptionsOn
            let showAnyCaptions = showDateCaption || customText != nil
            let customTuple = customText.map { (text: $0, anchor: bottomRowAnchor) }

            let (comp, vc, mix) = try await MontageService(project: project)
                .makeVideo(
                    for: range,
                    backgroundMusicURL: effectiveMusicURL,
                    musicVol: musicFloat,
                    videoVol: videoFloat,
                    musicStartTime: musicStartTime,
                    musicDuration: musicDuration,
                    showCaptions: showAnyCaptions,
                    customCaption: customTuple,
                    dateCaptionAnchor: bottomRowAnchor,
                    showBranding: (isPro ? brandingOn : true),
                    endCardSeconds: 2.0,
                    mode: .export,
                    targetSize: exportSize,
                    contentMode: (contentMode == .fit ? .fit : .fill),
                    captionColor: effectiveCaptionUIColorForCurrentMode(),
                    captionFontVariant: captionFont,
                    captionPointSize: CGFloat(captionFontSize),
                    filter: selectedFilter,
                    backgroundColor: backgroundUIColor,
                    playbackSpeed: speed,

                )


            // Sanitize project name for filesystem use
            let safeName = project.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
                .replacingOccurrences(of: " ", with: "_")

            // Unique filename avoids collisions
            let filename = "\(safeName.isEmpty ? "SnapSecond" : safeName)-\(UUID().uuidString).mp4"
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
            outputURL = tmp
            renderSize = vc.renderSize
            compositionDuration = comp.duration.seconds

            guard let session = AVAssetExportSession(asset: comp, presetName: presetName) else {
                isExporting = false
                handleMontageExportFailure(
                    kind: .sessionCreationFailed,
                    error: nil,
                    context: failureContext()
                )
                return
            }

            session.outputURL = tmp
            session.outputFileType = outputFileType
            session.shouldOptimizeForNetworkUse = true
            session.videoComposition = vc
            session.audioMix = mix
            session.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            cancelExportAction = {
                runtimeState.cancellationReason = .userCancelled
                session.cancelExport()
            }

            // Progress ticker with stall detection
            var lastActualProgress: Float = 0
            var stallCount = 0
            let maxStallSeconds = 60 // Cancel if no progress for 60 seconds
            let exportStartTime = Date()

            let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
                let actualProgress = session.progress
                let elapsed = Date().timeIntervalSince(exportStartTime)
                exportProg = smoothedMontageExportProgress(
                    actualProgress: actualProgress,
                    elapsed: elapsed
                )

                // Detect stalled export
                if actualProgress == lastActualProgress && session.status == .exporting {
                    stallCount += 1
                } else {
                    stallCount = 0
                    lastActualProgress = actualProgress
                }

                // Cancel if stalled for too long (60 seconds = 600 ticks at 0.1s)
                if stallCount >= maxStallSeconds * 10 {
                    runtimeState.cancellationReason = .stalled
                    session.cancelExport()
                    t.invalidate()
                }

                if session.status != .exporting { t.invalidate() }
            }

            // Export with 5-minute absolute timeout
            let exportTimeoutSeconds: UInt64 = 5 * 60
            let didComplete = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { cont in
                        session.exportAsynchronously { cont.resume(returning: true) }
                    }
                }

                group.addTask {
                    try? await Task.sleep(nanoseconds: exportTimeoutSeconds * 1_000_000_000)
                    return false
                }

                // Return the first result (either export completes or timeout)
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }

            progressTimer.invalidate()
            cancelExportAction = nil

            if !didComplete && session.status == .exporting {
                runtimeState.cancellationReason = .timedOut
                session.cancelExport()
            }

            isExporting = false
            exportProg = session.status == .completed ? 1 : max(
                session.progress,
                smoothedMontageExportProgress(
                    actualProgress: session.progress,
                    elapsed: Date().timeIntervalSince(exportStartTime)
                )
            )

            if session.status == .completed {
                exportURL = tmp

                // Track montage export for review prompt
                ReviewManager.shared.recordMontageExport()
            } else {
                if runtimeState.cancellationReason == .userCancelled && session.status == .cancelled {
                    exportProg = 0
                    dismissExportOverlay()
                    return
                }

                let failureKind: MontageExportFailureKind = {
                    switch session.status {
                    case .failed:
                        return .failed
                    case .cancelled:
                        return runtimeState.cancellationReason?.failureKind ?? .cancelled
                    case .exporting where runtimeState.cancellationReason != nil:
                        return runtimeState.cancellationReason?.failureKind ?? .cancelled
                    default:
                        return .cancelled
                    }
                }()

                isExporting = false
                handleMontageExportFailure(
                    kind: failureKind,
                    error: session.error as NSError?,
                    context: failureContext(status: session.status, progress: session.progress)
                )
            }
        } catch {
            isExporting = false
            handleMontageExportFailure(
                kind: .buildFailure,
                error: error as NSError,
                context: failureContext()
            )
        }
    }

    @MainActor
    private func handleMontageExportFailure(
        kind: MontageExportFailureKind,
        error: NSError?,
        context: MontageExportFailureLogContext
    ) {
        let presentation = MontageExportDiagnostics.presentation(for: kind, error: error)
        exportErrorAlert = MontageExportAlert(title: presentation.title, message: presentation.message)
        print(MontageExportDiagnostics.logMessage(for: kind, error: error, context: context))
    }
}
// MARK: - Range Selection Helpers

extension MontageView {

    func choosePreset(_ preset: Preset) {
        let cal = Calendar.current
        let now = Date()
        let start: Date

        switch preset {
        case .week:
            start = cal.date(byAdding: .day, value: -7, to: now)!
            rangeLabel = "Past Week"
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            start = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1))!
            let formatter = DateFormatter()
            formatter.dateFormat = "LLLL"
            rangeLabel = formatter.string(from: now)
        case .year:
            let year = cal.component(.year, from: now)
            start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
            rangeLabel = String(year)
        }

        range = DateInterval(start: start, end: now)
        savePrefs()
        Task { await rebuildMontage() }
    }

    func chooseAll() {
        range = DateInterval(start: .distantPast, end: .distantFuture)
        rangeLabel = "All"
        savePrefs()
        Task { await rebuildMontage() }
    }

    func applyMonthMulti(_ months: Int) {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .month, value: -months, to: now)!
        range = DateInterval(start: start, end: now)
        rangeLabel = "Past \(months) Months"
        savePrefs()
        Task { await rebuildMontage() }
    }

    func applyYearMulti(_ years: Int) {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .year, value: -years, to: now)!
        range = DateInterval(start: start, end: now)
        rangeLabel = years == 1 ? "Past Year" : "Past \(years) Years"
        savePrefs()
        Task { await rebuildMontage() }
    }

    func customLabel(for range: DateInterval) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        return "\(fmt.string(from: range.start)) – \(fmt.string(from: range.end))"
    }
}

// MARK: - Helper Methods

extension MontageView {

    func ensureMontageIsFresh() {
        Task { await rebuildMontage() }
    }

    func presentPaywallFromMontage() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        paywall.present()
    }
}

extension MontageView {

    // MARK: - Delete Timeline Items

    /// Handles deleting selected timeline items
    @MainActor
    func handleDeleteTimelineItems(_ items: Set<TimelineItem>) {
        for item in items {
            handleDeleteTimelineItem(item)
        }
    }

    /// Handles deleting a timeline item (audio or caption)
    @MainActor
    func handleDeleteTimelineItem(_ item: TimelineItem) {
        switch item.type {
        case .audio:
            deleteAudioItem(item)
        case .caption:
            deleteCaptionItem(item)
        case .effect:
            deleteFilterItem(item)
        case .video:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    /// Deletes an audio timeline item
    @MainActor
    private func deleteAudioItem(_ item: TimelineItem) {
        selectedTrack = nil
        isUsingCustomAudio = false
        customMusicURL = nil
        customMusicName = nil
        musicStartTime = 0
        musicDuration = nil
        syncTimelineItems()

        savePrefs()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        beginRebuildWithSpinner()
    }

    /// Deletes a caption timeline item
    @MainActor
    private func deleteCaptionItem(_ item: TimelineItem) {
        if item.isGeneratedDateCaption {
            showDates = false
        } else {
            captionMode = .none
        }
        syncTimelineItems()

        savePrefs()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        beginRebuildWithSpinner()
    }

    @MainActor
    private func deleteFilterItem(_ item: TimelineItem) {
        selectedFilter = .none
        syncTimelineItems()

        savePrefs()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        beginRebuildWithSpinner()
    }
}
