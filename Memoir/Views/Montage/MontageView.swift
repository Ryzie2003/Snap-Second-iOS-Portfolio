import SwiftUI
import AVKit
import AVFoundation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import PhosphorSwift


// MARK: – MontageView
struct MontageView: View {
    let T: Theme
    let project: Project
    let initialComp: AVMutableComposition
    let initialVC:   AVMutableVideoComposition
    let hideRangeFeature: Bool  // NEW: Hide range controls for collections projects
    // Injected from CalendarView
    @State var composition:      AVMutableComposition
    @State var videoComposition: AVVideoComposition
    @State var isExporting  = false
    @State var exportProg   : Float = 0         // 0–1
    @State var exportURL    : URL? = nil        // cached exported file
    @State var shareSheetURL: URL? = nil
    @State var exportErrorAlert: MontageExportAlert? = nil
    @State var exportStatusMessage: String? = nil
    @State var isSavingExport = false
    @State var cancelExportAction: (() -> Void)? = nil

    @State var player: AVPlayer?
    @State var scrubPreviewTime: TimeInterval? = nil

    @EnvironmentObject private var entitlements: Entitlements
    var isPro: Bool { entitlements.isPro }

    @State private var showShareSheet  = false

    @State private var showAddTrack    = false
    @State var selectedTrack: Track?    = nil
    @State var audioMix: AVAudioMix? = nil
    // Custom audio
    @State var isUsingCustomAudio: Bool = false
    @State var customMusicURL: URL? = nil
    @State var customMusicName: String? = nil
    @State private var showAudioImporter: Bool = false

    @State var musicVol = 100.0        // %
    @State var videoVol = 30.0         // %

    // Music timeline positioning (for trim adjustments)
    @State var musicStartTime: TimeInterval = 0
    @State var musicDuration: TimeInterval? = nil  // nil = full duration

    @State var selectedStyle: MontageStyle = .classic
    @State var selectedFilter: MontageFilter = .none

    @State private var showRangeDialog = false
    @State var rangeLabel = "Past Week"
    @State var range: DateInterval
    @State var currentClipCount: Int = 0

    @State var showDates = false

    @State var brandingOn: Bool = true
    // user toggle for watermark


    @State private var showCustomPicker = false

    // Cinematic coming soon
    @State private var showComingSoon = false

    @State var isEmpty = false
    @State var overlayLayer: CALayer? = nil
    @State var overlayKey: Int = 0
    // the latest overlay returned by MontageService (already includes watermark/date-year etc.)
    @State var baseOverlayLayer: CALayer? = nil


    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ClipStore
    @State private var didSeedRange = false
    @EnvironmentObject private var onboard: OnboardState
    @State private var didApplyOnboardSeeds = false


    @State private var showWalkthrough = false
    @State private var wtStep = 0    // 0..3

    @State var speed: Double = 1.0
    @State var orientation: Orientation = .v916   // default portrait

    @State private var selectedTab: ControlTab = .range
    @State private var sheetTab: ControlTab?


    // Fullscreen video preview
    @State private var isVideoFullscreen: Bool = false

    // Enhanced timeline items
    @State var videoTimelineItems: [TimelineItem] = []   // Non-destructive video segments
    @State var audioTimelineItems: [TimelineItem] = []
    @State var captionTimelineItems: [TimelineItem] = []
    @State var effectTimelineItems: [TimelineItem] = []



    @State private var showPaywall = false

    @State var isPlaying = false
    @State private var showNoClipsAlert = false
    @State var rebuildTask: Task<Void, Never>? = nil
    @State var isClipAudioMuted = false


    @EnvironmentObject var paywall: PaywallCoordinator

    @State var exportQuality: ExportQuality = .standard

    @State var captionPos: CaptionPos3 = .bottomLeft
    @State var captionFont: CaptionFontVariant = .system
    @State var captionMode: CaptionKind = .none
    @State var captionsDetent: PresentationDetent = .height(320)
    @State var isRebuildingPreview = false

    // Rich custom-caption state (used by sheet + inline editor)
    @State var customCaptionText: String = "Tap to Add Caption"
    @State var captionColor: Color = .white
    @State var captionOpacity: Double = 1.0
    @State var captionFontSize: Double = 24.0
    @State var captionPosNorm: CGPoint = CGPoint(x: 0.08, y: 0.90)


    @State private var blankingPref: BlankingPref = .none

    @State var backgroundStyle: BackgroundStyle = .black

    // If you want a Fit/Fill toggle under Orientation:
    @State var contentMode: ContentMode = .fit    // from MontageService.swift

    /// Free vs Pro tracks (keep in one place). Everything not listed here is considered Pro.
    private let freeTrackIDs: Set<String> = []

    // MARK: - Range helpers


    init(project: Project,
         T: Theme,
         composition: AVMutableComposition,
         videoComposition: AVMutableVideoComposition,
         interval: DateInterval,
         hideRangeFeature: Bool = false) {
        self.project      = project
        self.T = T
        self.initialComp = composition
        self.initialVC   = videoComposition
        self.hideRangeFeature = hideRangeFeature
        _composition      = State(initialValue: composition)
        _videoComposition = State(initialValue: videoComposition)
        _range            = State(initialValue: interval)
    }

    /// Convenience init for the “no clips yet” case.
    /// Creates a 1080×1920 blank composition so the view can load.
    /// Convenience init used when we don't have a prebuilt composition.
    /// From ProjectsView this should default to showing *all* clips.
    init(project: Project, T: Theme, hideRangeFeature: Bool = false) {
        self.project = project
        self.T = T
        self.hideRangeFeature = hideRangeFeature

        // Blank base comp so the UI can come up immediately
        let comp = AVMutableComposition()
        let vc   = AVMutableVideoComposition()
        vc.renderSize    = CGSize(width: 1080, height: 1920)
        vc.frameDuration = CMTime(value: 1, timescale: 30)

        self.initialComp  = comp
        self.initialVC    = vc
        _composition      = State(initialValue: comp)
        _videoComposition = State(initialValue: vc)

        // inside init(project: Project, T: Theme)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        let pastWeekStart = cal.date(byAdding: .day, value: -6, to: todayStart)!  // inclusive of today
        let fallback = DateInterval(start: pastWeekStart, end: .now)

        // Prefer a true "All clips" span when there are any clips
        let effectiveRange: DateInterval
        let label: String

        // Same semantics as chooseAll(): .distantPast ... .distantFuture
        let anyClips = ClipStore.shared.clips(
            from: .distantPast,
            to: .distantFuture,
            in: project
        )

        if anyClips.isEmpty {
            effectiveRange = fallback
            label = "Past Week"
        } else {
            effectiveRange = DateInterval(start: .distantPast, end: .distantFuture)
            label = "All"
        }

        _range      = State(initialValue: effectiveRange)
        _rangeLabel = State(initialValue: label)

        _isEmpty = State(initialValue: false)
        _showNoClipsAlert = State(initialValue: false)

    }



        var body: some View {
            montageLifecycleView
                .alert(
                    "No clips yet",
                    isPresented: $showNoClipsAlert,
                    actions: {
                        Button("OK", role: .cancel) { }
                    },
                    message: {
                        Text("Add your first memory to build a montage. Once you add clips, come back here to see them.")
                    }
                )
        }

    private var montageLifecycleView: some View {
        montagePresentationView
            .onDisappear {
                rebuildTask?.cancel()
                rebuildTask = nil
                player?.pause()
                savePrefs()
            }
            .onAppear {
                // Track montage view for review prompt
                ReviewManager.shared.recordMontageView()

                if !didApplyOnboardSeeds {
                    if let id = onboard.seedTrackID,
                       selectedTrack == nil,
                       let preset = bundledTracks.first(where: { $0.id == id }) {
                        selectedTrack = preset
                    }
                    if onboard.seedShowDates {
                        showDates = true
                        captionMode = .dateYear
                    }
                    didApplyOnboardSeeds = true
                }

                loadPrefsIfAny()
                syncTimelineItems()

                let totalClips = store.countByProject[project.id] ?? 0
                if totalClips > 0 {
                    let inRange = ClipStore.shared.clips(
                        from: range.start,
                        to: range.end,
                        in: project
                    )

                    if inRange.isEmpty {
                        range = DateInterval(start: .distantPast, end: .distantFuture)
                        rangeLabel = "All"
                    }
                }

                guard !didSeedRange else { return }
                didSeedRange = true

                let hasAnyClips = (store.countByProject[project.id] ?? 0) > 0
                if !hasAnyClips {
                    showNoClipsAlert = true
                    isEmpty = true
                    player = nil
                    overlayLayer = nil
                    overlayKey &+= 1
                    return
                }

                rebuildTask?.cancel()
                rebuildTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    await rebuildMontage()
                }
            }
            .onReceive(store.$clips) { _ in
                ensureMontageIsFresh()
            }
            .onChange(of: range) { _ in
                videoTimelineItems = []
                audioTimelineItems = []
                captionTimelineItems = []
                effectTimelineItems = []
                beginRebuildWithSpinner()
            }
            .onChange(of: musicVol) { _ in
                handleMusicVolumeChange()
            }
            .onChange(of: videoVol) { _ in
                savePrefs()
                beginRebuildWithSpinner()
            }
            .onChange(of: isClipAudioMuted) { _ in
                beginRebuildWithSpinner()
            }
            .onChange(of: range) { _ in savePrefs() }
            .onChange(of: rangeLabel) { _ in savePrefs() }
            .onChange(of: orientation) { _ in savePrefs() }
            .onChange(of: contentMode) { _ in savePrefs() }
            .onChange(of: captionMode) {
                savePrefs()
                captionsDetent = .height(420)
            }
            .onChange(of: sheetTab) { tab in
                if tab == .captions {
                    captionsDetent = .height(420)
                }
            }
            .onChange(of: showDates) { _ in
                savePrefs()
                syncTimelineItems()
                beginRebuildWithSpinner()
            }
            .onChange(of: brandingOn) { _ in savePrefs() }
            .onChange(of: captionPos) { _ in
                switch captionPos {
                case .bottomLeft:
                    captionPosNorm = CGPoint(x: 0.18, y: 0.90)
                case .bottomCenter:
                    captionPosNorm = CGPoint(x: 0.50, y: 0.90)
                case .bottomRight:
                    captionPosNorm = CGPoint(x: 0.82, y: 0.90)
                }
            }
    }

    private var montagePresentationView: some View {
        montageBaseView
            .coordinateSpace(name: "montage")
            .tint(T.core.accent)
            .sheet(isPresented: $showShareSheet) { Text("Share sheet").padding() }
            .sheet(isPresented: $showAddTrack) { Text("Add track").padding() }
            .sheet(item: $shareSheetURL) { url in
                ActivityView(activityItems: [url])
            }
            .alert(item: $exportErrorAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $paywall.isPresented) {
                PaywallSheet()
            }
            .sheet(isPresented: $showCustomPicker) {
                DateRangePicker(T: T, range: $range) {
                    rangeLabel = customLabel(for: range)
                    Task { await rebuildMontage() }
                    showCustomPicker = false
                }
                .presentationDetents([.fraction(0.4), .medium])
                .presentationDragIndicator(.visible)
            }
            .fileImporter(
                isPresented: $showAudioImporter,
                allowedContentTypes: [UTType.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let pickedURL = urls.first else { return }

                    let allowed = pickedURL.startAccessingSecurityScopedResource()
                    defer {
                        if allowed {
                            pickedURL.stopAccessingSecurityScopedResource()
                        }
                    }

                    do {
                        customMusicURL = try persistedAudioURL(from: pickedURL)
                        customMusicName = pickedURL.lastPathComponent
                        selectedTrack = nil
                        isUsingCustomAudio = true
                        musicStartTime = 0
                        musicDuration = nil
                        syncTimelineItems()
                        savePrefs()
                        beginRebuildWithSpinner()
                    } catch { }

                case .failure(let error):
                    print("🔴 audio import failed:", error.localizedDescription)
                }
            }
            .sheet(item: $sheetTab, content: montageSheetContent)
    }

    private var montageBaseView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                if !isPro && hasProFeatureEnabled {
                    ProPreviewBanner(accent: T.core.accent) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let hadOpenSheet = sheetTab != nil || showCustomPicker || showShareSheet || showAddTrack || shareSheetURL != nil
                        if hadOpenSheet {
                            sheetTab = nil
                            showCustomPicker = false
                            showShareSheet = false
                            showAddTrack = false
                            shareSheetURL = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                paywall.present()
                            }
                        } else {
                            presentPaywallFromMontage()
                        }
                    }
                    .padding(.top, isSmallDevice ? 44 : 44)
                }

                videoSection
                    .frame(maxWidth: .infinity)
                    .frame(height: isVideoFullscreen ? nil : UIScreen.main.bounds.height * videoHeightRatio)
                    .frame(maxHeight: isVideoFullscreen ? .infinity : UIScreen.main.bounds.height * videoHeightRatio)

                bottomEditingPanel
                    .opacity(isVideoFullscreen ? 0 : 1)
                    .allowsHitTesting(!isVideoFullscreen)
                    .frame(height: isVideoFullscreen ? 0 : nil)
            }
            .ignoresSafeArea(edges: [.bottom])
            .padding(.top, topPadding)

            VStack {
                topOverlayBar
                    .padding(.top, isSmallDevice ? 12 : 50)
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
            .zIndex(100)

            if showsExportOverlay {
                exportProgressAlert
                    .zIndex(200)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }

    @ViewBuilder
    private func montageSheetContent(_ tab: ControlTab) -> some View {
        switch tab {
        case .range:
            SheetScaffold(title: "Range", T: T, detents: [.medium], useScroll: true) {
                RangeShelfVertical(
                    T: T,
                    rangeLabel: $rangeLabel,
                    clipCount: currentClipCount,
                    onChoosePreset: { p in
                        choosePreset(p)
                        sheetTab = nil
                    },
                    onChooseAll: {
                        chooseAll()
                        sheetTab = nil
                    },
                    showCustomPicker: $showCustomPicker,
                    onChooseMonths: { months in
                        applyMonthMulti(months)
                        sheetTab = nil
                    },
                    onChooseYears: { years in
                        applyYearMulti(years)
                        sheetTab = nil
                    }
                )
            }

        case .music:
            musicSheet

        case .captions:
            SheetScaffold(
                title: "Captions",
                T: T,
                detents: [.height(420), .medium, .large],
                useScroll: true,
                selectedDetent: $captionsDetent
            ) {
                CaptionsShelfVertical(
                    T: T,
                    captionMode: $captionMode,
                    isCustomCaptionsOn: isCustomCaptionsOn,
                    customCaptionText: $customCaptionText,
                    showDates: $showDates,
                    onChange: {
                        savePrefs()
                        syncTimelineItems()
                        beginRebuildWithSpinner()
                    },
                    captionColor: $captionColor,
                    captionOpacity: $captionOpacity,
                    captionFontSize: $captionFontSize,
                    captionFont: $captionFont,
                    captionPos: $captionPos
                )
            }

        case .orientation:
            SheetScaffold(
                title: "Orientation",
                T: T,
                detents: [.height(200)],
                useScroll: false
            ) {
                OrientationShelfVertical(
                    T: T,
                    orientation: $orientation,
                    contentMode: $contentMode,
                    onChange: { Task { await rebuildMontage() } }
                )
            }

        case .quality:
            SheetScaffold(
                title: "Export Quality",
                T: T,
                detents: [.height(180)],
                useScroll: false
            ) {
                ExportQualityShelfVertical(
                    T: T,
                    exportQuality: $exportQuality,
                    onChange: {
                        savePrefs()
                    }
                )
            }

        case .watermark:
            SheetScaffold(
                title: "Watermark",
                T: T,
                detents: [.height(160)],
                useScroll: false
            ) {
                WatermarkShelfVertical(
                    T: T,
                    brandingOn: $brandingOn,
                    onChange: {
                        savePrefs()
                        Task { await rebuildMontage() }
                    }
                )
            }

        case .filters:
            SheetScaffold(
                title: "Filters",
                T: T,
                detents: [.height(260)],
                useScroll: true
            ) {
                FiltersShelfVertical(
                    T: T,
                    selectedFilter: $selectedFilter,
                    onChange: {
                        savePrefs()
                        beginRebuildWithSpinner()
                    }
                )
            }

        case .speed:
            SheetScaffold(
                title: "Speed",
                T: T,
                detents: [.height(260)],
                useScroll: true
            ) {
                SpeedShelfVertical(
                    speed: $speed,
                    onChange: {
                        savePrefs()
                        beginRebuildWithSpinner()
                    }
                )
            }
        }
    }

    private var showsExportOverlay: Bool {
        isExporting || exportURL != nil || isSavingExport
    }

    private var exportIsReady: Bool {
        exportURL != nil && !isExporting
    }

    private var exportSharePrompt: String {
        "Keep Snap Second open while we render your video."
    }

    private var exportProgressStatus: String {
        switch exportProg {
        case ..<0.15:
            return "Preparing clips and audio"
        case ..<0.7:
            return "Rendering your montage"
        default:
            return "Finalizing export"
        }
    }

    private var exportProgressAlert: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard exportIsReady, !isSavingExport else { return }
                    dismissExportOverlay()
                }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exportIsReady ? "Your montage is ready" : "Preparing your montage")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(T.core.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }

                    Spacer(minLength: 12)

                    Button {
                        handleExportOverlayCloseTapped()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(T.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(T.border.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                if exportIsReady {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            exportUtilityButton(
                                title: "Share",
                                systemImage: "square.and.arrow.up",
                                isLoading: false
                            ) {
                                startExportShare()
                            }

                            exportUtilityButton(
                                title: "Save",
                                systemImage: "arrow.down.to.line",
                                isLoading: isSavingExport
                            ) {
                                startExportSave()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        Text("Share with #snapsecond or tag @snapsecond for a chance to be featured.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if let exportStatusMessage {
                            Text(exportStatusMessage)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(exportStatusMessage == "Saved to gallery" ? T.core.accent : .red)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(exportProgressStatus)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(T.core.text)

                            Spacer(minLength: 12)

                            Text("\(Int((exportProg * 100).rounded()))%")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(T.core.text)
                        }

                        ProgressView(value: Double(exportProg), total: 1)
                            .tint(T.core.accent)
                            .scaleEffect(x: 1, y: 1.2, anchor: .center)

                        Text(exportSharePrompt)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(T.core.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(T.border.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            .padding(.horizontal, 24)
        }
        .allowsHitTesting(true)
        .animation(.easeInOut(duration: 0.2), value: exportProg)
        .animation(.easeInOut(duration: 0.2), value: exportIsReady)
    }

    private var musicSheet: some View {
        SheetScaffold(title: "Music", T: T, detents: [.height(360)], useScroll: true) {
            MusicShelfVertical(
                T: T,
                tracks: bundledTracks,
                freeTrackIDs: freeTrackIDs,
                selectedTrack: $selectedTrack,
                isUsingCustomAudio: $isUsingCustomAudio,
                musicVol: $musicVol,
                videoVol: $videoVol,
                onChange: handleMusicVolumeChange,
                onPickCustomAudio: handleCustomAudioPick
            )
        }
    }

    private func handleMusicVolumeChange() {
        if selectedTrack == nil && !isUsingCustomAudio {
            musicStartTime = 0
            musicDuration = nil
        }
        syncTimelineItems()
        savePrefs()
        beginRebuildWithSpinner()
    }

    private func handleCustomAudioPick() {
        sheetTab = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showAudioImporter = true
        }
    }

    private func exportUtilityButton(
        title: String,
        systemImage: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(T.core.accent)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 54, height: 54)
                .background(T.border.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(T.textSecondary)
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
        .foregroundStyle(T.core.text)
    }

    private func startExportShare() {
        guard let exportURL else { return }
        exportStatusMessage = nil
        dismissExportOverlay()
        shareSheetURL = exportURL
    }

    private func startExportSave() {
        guard let exportURL, !isSavingExport else { return }

        isSavingExport = true
        exportStatusMessage = nil

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportURL)
        }) { success, error in
            Task { @MainActor in
                isSavingExport = false
                exportStatusMessage = success
                    ? "Saved to gallery"
                    : (error?.localizedDescription ?? "Couldn’t save the export.")
            }
        }
    }

    func dismissExportOverlay() {
        exportURL = nil
        exportStatusMessage = nil
    }

    private func handleExportOverlayCloseTapped() {
        if isExporting {
            cancelExportAction?()
        } else if exportIsReady && !isSavingExport {
            dismissExportOverlay()
        }
    }

    private func uiColor(from color: Color, alpha: Double) -> UIColor {
        UIColor(color).withAlphaComponent(CGFloat(alpha))
    }

    // MARK: - Timeline Item Sync

    /// Updates timeline items to reflect current clips, music, and caption state
    func syncTimelineItems() {
        let totalDuration = composition.duration.seconds
        guard totalDuration > 0, totalDuration.isFinite else { return }

        syncVideoTimelineItems()

        let videoContentDuration = max(0.1, videoContentDurationForTimeline)
        if selectedTrack != nil || isUsingCustomAudio {
            let trackName = customMusicName ?? selectedTrack?.name ?? "Music"
            let effectiveDuration = musicDuration ?? videoContentDuration
            audioTimelineItems = [
                TimelineItem(
                    type: .audio,
                    startTime: musicStartTime,
                    duration: min(effectiveDuration, max(0.1, videoContentDuration - musicStartTime)),
                    title: trackName,
                    color: T.core.accent.opacity(0.7)
                )
            ]
        } else {
            audioTimelineItems = []
            musicStartTime = 0
            musicDuration = nil
        }

        var captionItems = isDateCaptionsOn ? makeDateCaptionTimelineItems() : []
        if let customText = previewCustomCaptionText {
            captionItems.append(
                TimelineItem(
                    type: .caption,
                    startTime: 0,
                    duration: videoContentDuration,
                    title: String(customText.prefix(18)),
                    color: Color.orange.opacity(0.85),
                    lane: captionItems.isEmpty ? 0 : 1
                )
            )
        }
        captionTimelineItems = captionItems
        effectTimelineItems = []
    }

    /// Syncs video timeline items from clips.
    private func syncVideoTimelineItems() {
        guard videoTimelineItems.isEmpty else {
            let totalDuration = composition.duration.seconds
            for i in videoTimelineItems.indices {
                if videoTimelineItems[i].startTime + videoTimelineItems[i].duration > totalDuration {
                    videoTimelineItems[i].duration = max(0.1, totalDuration - videoTimelineItems[i].startTime)
                }
            }
            return
        }

        let clips = ClipStore.shared.clips(from: range.start, to: range.end, in: project)
        guard !clips.isEmpty else { return }

        let effectiveSpeed = max(0.5, min(5.0, speed))
        var cursor: TimeInterval = 0
        var newItems: [TimelineItem] = []

        for clip in clips {
            let clipDuration = clip.duration / effectiveSpeed  // Adjusted for playback speed

            let item = TimelineItem(
                type: .video,
                startTime: cursor,
                duration: clipDuration,
                title: formatClipTitle(clip),
                color: Color.gray.opacity(0.6),
                lane: 0,
                clipID: clip.id ?? UUID(),
                clipAssetURL: clip.assetURL ?? "",
                clipStartOffset: clip.snippetStart,  // Use existing snippet start
                clipDate: captionDate(for: clip)
            )
            newItems.append(item)
            cursor += clipDuration
        }

        videoTimelineItems = newItems
    }

    /// Formats a clip title for display in timeline
    private func formatClipTitle(_ clip: Clip) -> String {
        if let date = captionDate(for: clip) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
        return "Clip"
    }

    /// Resets video timeline items to rebuild from clips on next sync
    func resetVideoTimelineItems() {
        videoTimelineItems = []
        syncVideoTimelineItems()
    }

    private func makeDateCaptionTimelineItems() -> [TimelineItem] {
        guard !videoTimelineItems.isEmpty else { return [] }
        return [
            TimelineItem(
                type: .caption,
                startTime: 0,
                duration: max(0.1, videoContentDurationForTimeline),
                title: "Date Captions",
                color: Color.orange.opacity(0.45),
                lane: 0,
                isGeneratedDateCaption: true
            )
        ]
    }

    private func makeDateCaptionPlaybackItems() -> [TimelineItem] {
        videoTimelineItems.compactMap { item in
            guard let date = item.clipDate else { return nil }
            return TimelineItem(
                id: item.id,
                type: .caption,
                startTime: item.startTime,
                duration: item.duration,
                title: "Date: \(dateCaptionTimelineTitle(for: date))",
                color: Color.orange.opacity(0.45),
                lane: 0,
                clipDate: date,
                isGeneratedDateCaption: true
            )
        }
    }

    private func captionDate(for clip: Clip) -> Date? {
        clip.date
    }

    private func dateCaptionTimelineTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    @MainActor
    private func renderCaptionOverlay(text: String) {
        beginRebuildWithSpinner()   // deprecated fast path → rebuild
    }

    // Decides whether to update overlay instantly or rebuild
    @MainActor
    private func updateCaptionPreview() {
        beginRebuildWithSpinner()
    }


    // Allow taps on the draggable caption to play/pause the preview
    @MainActor
    private func togglePlayFromCaption() {
        guard let p = player else { return }

        if p.timeControlStatus == .playing {
            p.pause()
            isPlaying = false
        } else {
            // If we're at (or very near) the end, rewind first
            if let item = p.currentItem {
                let end = item.duration.seconds
                if end.isFinite, p.currentTime().seconds >= end - 0.05 {
                    p.seek(to: .zero)
                }
            }
            p.play()
            isPlaying = true
        }
    }



    @MainActor
    private func applyMonthMulti(_ months: Set<Int>) {
        guard !months.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now)

        // Build start of each selected month in the CURRENT year
        let starts: [Date] = months.compactMap { m in
            cal.date(from: DateComponents(year: currentYear, month: m))
        }
        guard !starts.isEmpty else { return }

        // End = start of the month AFTER the max-selected month
        let start = starts.min()!
        let lastStart = starts.max()!
        let end = cal.date(byAdding: .month, value: 1, to: lastStart)!

        range = DateInterval(start: start, end: end)
        let names = months.sorted().map { DateFormatter().shortMonthSymbols[$0-1] }
        rangeLabel = names.joined(separator: ", ")
        Task { await rebuildMontage() }
    }

    @MainActor
    private func applyYearMulti(_ years: Set<Int>) {
        guard !years.isEmpty else { return }
        let cal = Calendar.current
        // Start = Jan 1 of min year, End = Jan 1 of (max year + 1)
        let minY = years.min()!
        let maxY = years.max()!
        guard
          let start = cal.date(from: DateComponents(year: minY, month: 1, day: 1)),
          let end   = cal.date(from: DateComponents(year: maxY + 1, month: 1, day: 1))
        else { return }

        range = DateInterval(start: start, end: end)
        rangeLabel = years.sorted().map(String.init).joined(separator: ", ")
        Task { await rebuildMontage() }
    }

    // MARK: - Paywall helper



    @ViewBuilder
    private var videoSection: some View {
        if isEmpty {
            // Full replacement screen instead of the player
            EmptyRangeScreen(
                T: T,
                label: rangeLabel,
                onPickRange: { showCustomPicker = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, isSmallDevice ? 0 : 12)
            .transition(.opacity)
        } else {
//            let _ = {
//                print("🧩 videoSection: isEmpty=\(isEmpty)",
//                      "captionMode=\(captionMode)",
//                      "isInlineCaptionVisible=\(isInlineCaptionVisible)",
//                      "customCaptionText='\(customCaptionText)'",
//                      "captionPosNorm=\(captionPosNorm)",
//                      "fontSize=\(captionFontSize)")
//                return ()
//            }()

            // Normal player path
            ZStack {
                VideoContainer(
                    player: player,
                    overlay: overlayLayer,
                    forcedAspect: forcedAspect,
                    gravity: (contentMode == .fit ? .resizeAspect : .resizeAspectFill),
                    overlayKey: overlayKey,
                    theme: T,
                    bgColor: backgroundUIColor,
                    isPlaying: $isPlaying,
                    scrubPreviewTime: scrubPreviewTime,
                    dateCaptionItems: [],
                    showDateCaptions: false,
                    dateCaptionAnchor: bottomRowAnchor,
                    onTapped: nil,
                    customCaptionText: $customCaptionText,
                    showCustomCaption: isInlineCaptionVisible,
                    captionPosNorm: $captionPosNorm,
                    captionColor: effectiveCaptionUIColorForCurrentMode(),
                    captionOpacity: captionOpacity,
                    captionFontVariant: captionFont,
                    captionFontSize: $captionFontSize,
                    onCaptionDragEnded: {
                        savePrefs()
                        beginRebuildWithSpinner()
                    },
                    showBranding: brandingOn,
                    endCardSeconds: 2.0,
                    isBlocked: isRebuildingPreview
                )
                .id(backgroundStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("\(rangeLabel)-\(range.start.timeIntervalSince1970)-\(range.end.timeIntervalSince1970)")
                .padding(.top, isSmallDevice ? 0 : 12)
                .task {
                    guard player == nil else { return }
                    let item = AVPlayerItem(asset: composition)
                    item.videoComposition = videoComposition
                    player = AVPlayer(playerItem: item)
                }
                .shadow(radius: 4, y: 2)

                if isRebuildingPreview {
                    // ✨ cover just the player rect and absorb taps
                    Color.black.opacity(0.18)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            VStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(1.15)
                                Text("Rebuilding preview…")
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(12)
                            .background(.ultraThinMaterial, in: Capsule())
                        )
                        .transition(.opacity)
                        .zIndex(1)
                }

            }
        }
    }

    private var topOverlayBar: some View {
        HStack(spacing: isSmallDevice ? 8 : 12) {
            // Left: Close button (X) - exits fullscreen if in fullscreen, otherwise dismisses view
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if isVideoFullscreen {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVideoFullscreen = false
                    }
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: isVideoFullscreen ? "chevron.down" : "xmark")
                    .font(.system(size: isSmallDevice ? 18 : 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(isSmallDevice ? 6 : 8)
            }
            .fixedSize()

            Spacer(minLength: 0)

            // Center: Range pill (hidden for collections projects)
            if !hideRangeFeature {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedTab = .range
                    sheetTab = nil
                    DispatchQueue.main.async {
                        sheetTab = .range
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: isSmallDevice ? 10 : 12, weight: .semibold))
                        Text(rangeLabel)
                            .font(.system(size: isSmallDevice ? 12 : 14, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, isSmallDevice ? 8 : 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.14))
                    .foregroundStyle(Color.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            // Right: Export button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if !isPro && hasProFeatureEnabled {
                    presentPaywallFromMontage()
                } else {
                    Task { await exportAndShare() }
                }
            } label: {
                if isExporting {
                    HStack(spacing: isSmallDevice ? 4 : 6) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("\(Int(exportProg * 100))%")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, isSmallDevice ? 8 : 10)
                    .padding(.vertical, isSmallDevice ? 4 : 6)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: isSmallDevice ? 17 : 19, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(isSmallDevice ? 6 : 8)
                }
            }
            .fixedSize()
            .disabled(isExporting || isRebuildingPreview)
            .opacity((isExporting || isRebuildingPreview) ? 0.5 : 1)
            .accessibilityLabel("Share / Export")
        }
        .padding(.top, isSmallDevice ? 48 : 4)  // Raised higher
        .padding(.horizontal, isSmallDevice ? 12 : 16)
        .padding(.vertical, isSmallDevice ? 8 : 12)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.7),
                    Color.black.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Video Fullscreen (removed snapshot management)



    // MARK: - Bottom controls bar (horizontally scrollable)
    private var bottomCategoryToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isSmallDevice ? 20 : 28) {
                ForEach(allControls, id: \.self) { control in
                    controlButton(control)
                }
            }
            .padding(.horizontal, isSmallDevice ? 16 : 20)
        }
        .padding(.top, isSmallDevice ? 8 : 12)
        .padding(.bottom, isSmallDevice ? 24 : 32)
        .background(Color.black.opacity(0.95))
    }

    private var allControls: [ControlTab] {
        [.range, .music, .speed, .filters, .captions, .orientation, .quality, .watermark]
    }

    private func controlButton(_ control: ControlTab) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedTab = control
            // Defer sheet presentation slightly to allow haptic and button animation to complete first
            // This prevents the sheet creation from blocking the UI response
            DispatchQueue.main.async {
                sheetTab = control
            }
        } label: {
            VStack(spacing: isSmallDevice ? 4 : 6) {
                Image(systemName: controlIcon(for: control))
                    .font(.system(size: isSmallDevice ? 22 : 24, weight: .regular))
                    .foregroundStyle(.white)
                Text(control.label)
                    .font(.system(size: isSmallDevice ? 10 : 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func controlIcon(for control: ControlTab) -> String {
        switch control {
        case .range:       return "calendar"
        case .music:       return "music.note"
        case .captions:    return "captions.bubble"
        case .orientation: return "crop.rotate"
        case .quality:     return "square.and.arrow.up.on.square"
        case .watermark:   return "seal"
        case .filters:     return "camera.filters"
        case .speed:       return "speedometer"
        }
    }

    @ViewBuilder
    private func phosphorControlIcon(for symbol: String,
                                     selected: Bool) -> some View {
        let icon = selected ? "fill" : "regular"

        switch symbol {

        case "calendar":
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))

        case "music.note":
            (icon == "fill" ? Ph.musicNote.fill : Ph.musicNote.regular)

        case "captions.bubble":
            (icon == "fill" ? Ph.textAa.fill : Ph.textAa.regular)

        case "crop.rotate":
            (icon == "fill" ? Ph.crop.fill : Ph.crop.regular)

        case "square.stack.3d.up":
            (icon == "fill" ? Ph.magicWand.fill : Ph.magicWand.regular)

        case "sliders":
            (icon == "fill" ? Ph.slidersHorizontal.fill : Ph.slidersHorizontal.regular)

        case "speed":
            // pick an icon you like; this is a reasonable “speed” metaphor
            (icon == "fill" ? Ph.gauge.fill : Ph.gauge.regular)

        case "a.square":
            (icon == "fill" ? Ph.seal.fill : Ph.seal.regular)

        // New CapCut-style category icons
        case "wand.and.stars":
            (icon == "fill" ? Ph.magicWand.fill : Ph.magicWand.regular)

        case "slider.horizontal.3":
            (icon == "fill" ? Ph.slidersHorizontal.fill : Ph.slidersHorizontal.regular)

        case "ellipsis":
            (icon == "fill" ? Ph.dotsThree.fill : Ph.dotsThree.regular)

        default:
            Ph.circle.regular
        }
    }



    // MARK: - Bottom editing panel
    private var bottomEditingPanel: some View {
        VStack(spacing: 0) {
            // Timeline area
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // Timeline
                    // Use id() to prevent recreation when unrelated state changes (like sheetTab)
                    if !isEmpty {
                        EnhancedTimelineView(
                            T: T,
                            player: player,
                            composition: composition,
                            videoComposition: videoComposition,
                            onDelete: { items in
                                handleDeleteTimelineItems(items)
                            },
                            onAddAudio: {
                                selectedTab = .music
                                sheetTab = .music
                            },
                            onTapAudio: {
                                selectedTab = .music
                                sheetTab = .music
                            },
                            onTapCaptions: {
                                selectedTab = .captions
                                sheetTab = .captions
                            },
                            onTapEffects: {
                                selectedTab = .filters
                                sheetTab = .filters
                            },
                            videoItems: $videoTimelineItems,
                            audioItems: $audioTimelineItems,
                            captionItems: $captionTimelineItems,
                            effectItems: $effectTimelineItems,
                            scrubPreviewTime: $scrubPreviewTime,
                            isVideoFullscreen: $isVideoFullscreen,
                            isClipAudioMuted: $isClipAudioMuted
                        )
                        // Stable identity prevents recreation when sheets open/close
                        .id("timeline-\(composition.duration.seconds)")
                        .frame(maxHeight: timelineHeight)
                        .padding(.horizontal, isSmallDevice ? 8 : 12)
                        .padding(.top, isSmallDevice ? 12 : 16)
                    }
                }
            }
            .frame(maxHeight: bottomPanelMaxHeight)

            // Bottom bar (categories or controls with back button)
            bottomCategoryToolbar
        }
        .background(
            Color.black.opacity(0.95)
                .ignoresSafeArea(edges: .bottom)
        )
    }

}



// ─── DEBUG helper: prints model and presentation opacity ───
func logOpacity(_ txt: CATextLayer, label: String) {
}

func trackOpacity(_ txt: CATextLayer, every sec: Double) {
    var t: Double = 0
    Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { timer in
        guard let pres = txt.presentation() else { return }

        t += sec
        if t > 2.0 { timer.invalidate() }   // stop after 2 sec
    }
}






private struct WalkthroughOverlay: View {
    let frames: [WTarget: CGRect]
    let step: Int                 // 0:play, 1:scrub, 2:actions, 3:export
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let rect = targetRect(in: proxy.size)

            ZStack(alignment: .topLeading) {
                // Dim everything with a "cutout" around the target rect
                Color.black.opacity(0.55)
                    .mask(
                        Rectangle()
                            .overlay(
                                RoundedRectangle(cornerRadius: corner(for: step))
                                    .frame(width: rect.width + 12, height: rect.height + 12)
                                    .position(x: rect.midX, y: rect.midY)
                                    .blendMode(.destinationOut)
                            )
                    )
                    .compositingGroup()
                    .ignoresSafeArea()

                // Outline ring exactly over the control
                RoundedRectangle(cornerRadius: corner(for: step))
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 3)
                    .frame(width: rect.width + 8, height: rect.height + 8)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: .black.opacity(0.5), radius: 8)

                // Tip card positioned just above or below the rect
                VStack(spacing: 10) {
                    Spacer().frame(height: max(0, rect.minY - 90))
                    tipCard
                        .frame(maxWidth: 320)
                        .position(x: rect.midX, y: rect.minY - 40)
                    Spacer()
                }

                // Controls (bottom)
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Button("Skip")   { onSkip() }.buttonStyle(.bordered)
                        Button(step < 3 ? "Next" : "Finish") { onNext() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .transition(.opacity)
        .animation(.easeInOut, value: step)
        .ignoresSafeArea()
        .allowsHitTesting(true)     // block touches to underlying controls during walkthrough
    }

    // Choose which rect to highlight for each step
    private func targetRect(in size: CGSize) -> CGRect {
        switch step {
        case 0: return frames[.play]    ?? fallback(size)
        case 1: return frames[.scrub]   ?? fallback(size)
        case 2: return frames[.actions] ?? fallback(size)
        default: return frames[.export] ?? fallback(size)
        }
    }

    private func corner(for step: Int) -> CGFloat {
        // circular for play, rounded for bars/buttons
        return (step == 0) ? 44 : 12
    }

    private var tipCard: some View {
        Group {
            switch step {
            case 0: TipCard(title: "Play / Pause", text: "Tap here to start or pause playback.")
            case 1: TipCard(title: "Scrub", text: "Drag the bar to jump to any moment.")
            case 2: TipCard(title: "Quick Edits", text: "Music, Captions, and Ratio live here.")
            default: TipCard(title: "Export", text: "Share or save your montage from here.")
            }
        }
    }

    private func fallback(_ size: CGSize) -> CGRect {
        CGRect(x: size.width/2 - 60, y: size.height/2 - 30, width: 120, height: 60)
    }
}

private struct TipCard: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundColor(.white)
            Text(text).font(.subheadline).foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}


private enum WTarget: Hashable { case play, scrub, actions, export }

private struct TargetFramesKey: PreferenceKey {
    static var defaultValue: [WTarget: CGRect] = [:]
    static func reduce(value: inout [WTarget: CGRect], nextValue: () -> [WTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private extension View {
    func reportFrame(_ target: WTarget) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TargetFramesKey.self,
                    value: [target: geo.frame(in: .named("montage"))]
                )
            }
        )
    }
}




private struct DismissButton: View {
  @Environment(\.dismiss) var dismiss
  let T: Theme
  var body: some View {
    Button("Done") { dismiss() }
      .font(.system(.callout, design: .rounded).weight(.semibold))
      .foregroundStyle(T.core.accent)
  }
}

// Small helper to keep availability clean
private extension View {
  @ViewBuilder
  func ifAvailable_iOS16_4<Wrapped: View>(
    _ transform: (Self) -> Wrapped
  ) -> some View {
    if #available(iOS 16.4, *) {
      transform(self)
    } else {
      self
    }
  }
}
