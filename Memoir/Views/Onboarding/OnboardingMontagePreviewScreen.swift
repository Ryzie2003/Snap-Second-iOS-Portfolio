import SwiftUI
import Photos
import AVFoundation
import AVKit

struct OnboardingMontagePreviewScreen: View {
    private enum PreviewState {
        case loading
        case unavailable(String)
        case ready
    }

    @EnvironmentObject private var onboard: OnboardState
    let project: Project

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    @State private var player: AVPlayer?
    @State private var composition: AVMutableComposition?
    @State private var videoComp: AVMutableVideoComposition?
    @State private var overlay: CALayer?
    @State private var interval: DateInterval?

    @State private var toEditor = false
    @State private var toCalendar = false

    @State private var isPlaying = false
    @State private var showPlayOverlay = true
    @State private var previewState: PreviewState = .loading

    @State private var selectedStyle: MontageStyle = .classic

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    header
                    playerArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationDestination(isPresented: $toEditor) {
                if let comp = composition, let vc = videoComp, let iv = interval {
                    MontageView(project: project, T: T, composition: comp, videoComposition: vc, interval: iv)
                } else {
                    MontageView(project: project, T: T)
                }
            }
            .navigationDestination(isPresented: $toCalendar) {
                CalendarView(project: project)
            }
            .onAppear(perform: buildPreview)
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
                player?.seek(to: .zero)
                isPlaying = false
                showPlayOverlay = true
            }
            .background(T.core.surface.ignoresSafeArea())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your life in seconds")
                .font(
                    .system(
                        size: OnboardingTypography.scaled(24),
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .foregroundStyle(T.core.text)

            Text("Tap to play. You can edit or add more moments anytime.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(T.textSecondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var playerArea: some View {
        ZStack {
            if let p = player {
                PlayerLayerView(player: p, overlay: overlay, gravity: .resizeAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.border, lineWidth: 1))
                    .shadow(
                        color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.10),
                        radius: 8,
                        y: 4
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
            } else {
                placeholderCard
            }

            if player != nil && showPlayOverlay {
                Button(action: { togglePlay() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black.opacity(0.9))
                        .padding(24)
                        .background(.white, in: Circle())
                        .shadow(radius: 10, y: 4)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showPlayOverlay)
    }

    @ViewBuilder
    private var placeholderCard: some View {
        switch previewState {
        case .loading:
            T.surfaceAlt
                .overlay(ProgressView("Preparing montage…").padding())
                .clipShape(RoundedRectangle(cornerRadius: 14))

        case .unavailable(let message):
            VStack(spacing: 14) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(T.core.accent)

                Text("No preview yet")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(T.core.text)

                Text(message)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(.horizontal, 28)
            .background(T.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.border, lineWidth: 1))

        case .ready:
            T.surfaceAlt
                .overlay(ProgressView("Preparing montage…").padding())
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            showPlayOverlay = true
        } else {
            if let item = p.currentItem {
                let end = item.duration.seconds
                if end.isFinite, p.currentTime().seconds >= end - 0.05 {
                    p.seek(to: .zero)
                }
            }
            p.play()
            isPlaying = true
            withAnimation { showPlayOverlay = false }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                OnboardingAnalytics.trackMontagePreviewContinueTapped(variant: onboard.sessionVariant)
                onboard.advance()
            } label: {
                Text("Continue")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func buildPreview() {
        previewState = .loading
        showPlayOverlay = false
        isPlaying = false

        guard !onboard.lastImportLocalIDs.isEmpty else {
            previewState = .unavailable("You skipped adding media here. You can continue now and add moments later from your project.")
            return
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: onboard.lastImportLocalIDs, options: nil)
        var list: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in list.append(asset) }
        guard let minD = list.compactMap(\.creationDate).min(),
              let maxD = list.compactMap(\.creationDate).max() else {
            previewState = .unavailable("We couldn't find imported moments for this preview. You can continue and add them later.")
            return
        }

        let cal = Calendar.current
        let start = cal.startOfDay(for: minD)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: maxD))!
        let iv = DateInterval(start: start, end: end)
        interval = iv

        onboard.seedShowDates = true
        onboard.seedTrackID = "moments"

        let svc = MontageService(project: project)
        Task {
            do {
                let previewMusicURL = Bundle.main.url(forResource: "moments", withExtension: "m4a")

                let (comp, vc, _) = try await svc.makeVideo(
                    for: iv,
                    backgroundMusicURL: previewMusicURL,
                    musicVol: 1.0,
                    videoVol: 0.3,
                    showCaptions: true,
                    customCaption: nil,
                    dateCaptionAnchor: .bottomLeft,
                    showBranding: true,
                    endCardSeconds: 2.0,
                    mode: .preview,
                    targetSize: CGSize(width: 1080, height: 1920),
                    contentMode: .fit,
                    captionColor: .white
                )

                let clipsForOverlay = await svc.clips(in: iv)
                let overlayLayer = await svc.makePreviewOverlay(
                    renderSize: vc.renderSize,
                    clips: clipsForOverlay,
                    showCaptions: true,
                    customCaption: nil,
                    dateCaptionAnchor: .bottomLeft,
                    showBranding: true,
                    endCardSeconds: 2.0,
                    compositionDuration: comp.duration,
                    filter: .none,
                    captionColor: .white,
                    playbackSpeed: 1.0
                )

                await MainActor.run {
                    composition = comp
                    videoComp = vc
                    overlay = overlayLayer

                    let item = AVPlayerItem(asset: comp)
                    item.videoComposition = vc
                    if player == nil {
                        player = AVPlayer(playerItem: item)
                    } else {
                        player?.replaceCurrentItem(with: item)
                    }
                    previewState = .ready
                    showPlayOverlay = true
                }
            } catch {
                print("Preview build failed: \(error)")
                await MainActor.run {
                    player = nil
                    composition = nil
                    videoComp = nil
                    overlay = nil
                    interval = nil
                    previewState = .unavailable("We couldn't prepare your montage preview right now. You can continue and edit later.")
                    showPlayOverlay = false
                    isPlaying = false
                }
            }
        }
    }

    private func recursivelySetContentsScale(_ layer: CALayer, scale: CGFloat) {
        layer.contentsScale = scale
        if let txt = layer as? CATextLayer {
            txt.contentsScale = scale
        }
        layer.sublayers?.forEach { recursivelySetContentsScale($0, scale: scale) }
    }
}

struct OnboardingPreviewPlaybackScreen: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showPlayOverlay = true

    private var previewUnavailableMessage: String {
        onboard.previewErrorMessage
            ?? "We couldn't build the preview right now, but you can keep going and My First Project will still be ready."
    }

    var body: some View {
        OnboardingStepScreen(
            step: .montageWalkthrough,
            title: onboard.previewBundle == nil ? "You can still keep going" : "This is your life, zoomed out",
            subtitle: onboard.previewBundle == nil
                ? "Your project will still be set up after onboarding."
                : "A first pass from your recent moments, paired with preset music."
        ) {
            VStack(spacing: 18) {
                previewCard

                if onboard.previewBundle != nil {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        OnboardingStatCard(
                            value: "\(max(onboard.onboardingClipsCount, 1))",
                            label: "Moments used"
                        )
                        OnboardingStatCard(
                            value: "30 sec",
                            label: "Preview length"
                        )
                    }

                    OnboardingMiniFeatureRow(
                        icon: "wand.and.stars",
                        title: "Built automatically",
                        body: "No manual setup first. Just a fast reveal."
                    )

                    OnboardingMiniFeatureRow(
                        icon: "music.note",
                        title: "Preset soundtrack",
                        body: "Music is already in place for the first pass."
                    )
                }
            }
        } footer: {
            VStack(spacing: 12) {
                if onboard.previewBundle == nil {
                    OnboardingSecondaryButton(title: "Try again") {
                        onboard.retryPreviewGeneration()
                    }
                }

                OnboardingPrimaryButton(title: "Continue") {
                    OnboardingAnalytics.trackMontagePreviewContinueTapped(variant: onboard.sessionVariant)
                    onboard.advance()
                }
            }
        }
        .onAppear(perform: configurePlayerIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            player?.seek(to: .zero)
            player?.pause()
            isPlaying = false
            showPlayOverlay = true
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        if let player {
            ZStack {
                PlayerLayerView(player: player, overlay: nil, gravity: .resizeAspectFill)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(T.border, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: togglePlayback)

                if showPlayOverlay {
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.black.opacity(0.88))
                            .padding(26)
                            .background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(T.core.accent)

                Text("Preview unavailable")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(T.core.text)

                Text(previewUnavailableMessage)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
            .padding(.horizontal, 26)
            .background(T.surfaceAlt, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private func configurePlayerIfNeeded() {
        guard let bundle = onboard.previewBundle,
              let composition = bundle.composition,
              let videoComposition = bundle.videoComposition else {
            player = nil
            return
        }
        guard player == nil else { return }

        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = bundle.audioMix
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        self.player = player
        self.isPlaying = false
        self.showPlayOverlay = true
    }

    private func togglePlayback() {
        guard let player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            showPlayOverlay = true
            return
        }

        if let item = player.currentItem {
            let endSeconds = item.duration.seconds
            if endSeconds.isFinite, player.currentTime().seconds >= endSeconds - 0.05 {
                player.seek(to: .zero)
            }
        }

        player.play()
        isPlaying = true
        withAnimation(.easeInOut(duration: 0.18)) {
            showPlayOverlay = false
        }
    }
}

struct OnboardingPreviewRevealScreen: View {
    private enum PreviewExportIntent {
        case share
        case save
    }

    private static let slideshowImageManager = PHCachingImageManager()
    private static let slideshowRenderedImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 36
        return cache
    }()
    private static let captionMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM d")
        return formatter
    }()
    private static let captionYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yyyy")
        return formatter
    }()

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private let previewService = OnboardingPreviewService()
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    @State private var configuredPreviewSignature: String?
    @State private var shareURL: URL?
    @State private var exportedURL: URL?
    @State private var exportIntent: PreviewExportIntent?
    @State private var isExporting = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var hasTrackedPreviewView = false
    @State private var player: AVPlayer?
    @State private var slideshowAssets: [PHAsset] = []
    @State private var currentSlideIndex = 0
    @State private var currentTimelineIndex = 0
    @State private var currentSlideImage: UIImage?
    @State private var slideshowTask: Task<Void, Never>?
    @State private var slideshowAudioPlayer: AVAudioPlayer?
    @State private var activeSlideshowRequestID: PHImageRequestID?
    @State private var slideshowPreloadRequestIDs: [String: PHImageRequestID] = [:]
    @State private var activeSlideRequestToken = UUID()
    @State private var playerTimeObserver: Any?
    @State private var observedPlayer: AVPlayer?
    @State private var isSlideshowPlaying = true

    private var isReady: Bool {
        switch onboard.previewStage {
        case .slidesReady, .videoReady:
            return true
        default:
            return false
        }
    }
    private var isLoading: Bool {
        switch onboard.previewStage {
        case .idle, .loading:
            return onboard.previewErrorMessage == nil
        default:
            return false
        }
    }
    private var isVideoReady: Bool {
        onboard.previewStage == .videoReady && (onboard.previewBundle?.hasPlayableVideo ?? false)
    }
    private var hasSeedPreview: Bool {
        !isReady && onboard.previewSeedSlide != nil && onboard.previewErrorMessage == nil
    }
    private var canTogglePreviewPlayback: Bool {
        isReady && (player != nil || !slideshowAssets.isEmpty)
    }
    private var canBuildExport: Bool { isReady && onboard.previewBundle != nil }
    private var isWorking: Bool { isExporting || isSaving }
    private var previewSlides: [OnboardingPreviewSlide] { onboard.previewBundle?.slides ?? [] }
    private var currentSlide: OnboardingPreviewSlide? {
        guard previewSlides.indices.contains(currentSlideIndex) else { return nil }
        return previewSlides[currentSlideIndex]
    }
    private var activeCaptionDate: Date? {
        if let player,
           player.currentItem != nil,
           let timeline = onboard.previewBundle?.timeline,
           !timeline.isEmpty {
            let clampedIndex = min(max(currentTimelineIndex, 0), timeline.count - 1)
            return timeline[clampedIndex].date
        }
        return currentSlide?.date ?? onboard.previewSeedSlide?.date
    }
    private var previewCardWidth: CGFloat {
        if isCondensedLayout {
            return 182
        }
        return min(max(UIScreen.main.bounds.width - 128, 208), 228)
    }
    private var previewCardHeight: CGFloat { previewCardWidth * (16.0 / 9.0) }
    private var previewSectionMinHeight: CGFloat {
        isCondensedLayout ? max(previewCardHeight + 48, 300) : previewCardHeight + 76
    }
    private var previewTopInset: CGFloat { isCondensedLayout ? 14 : 20 }
    private var previewCornerRadius: CGFloat { isCondensedLayout ? 28 : 32 }
    private var previewCaptionOverlayHeight: CGFloat { isCondensedLayout ? 116 : 132 }
    private var previewCaptionInset: CGFloat { isCondensedLayout ? 14 : 16 }
    private var previewMonthDayFontSize: CGFloat { isCondensedLayout ? 16 : 18 }
    private var previewYearFontSize: CGFloat { isCondensedLayout ? 13 : 14 }
    private var previewControlDiameter: CGFloat { isCondensedLayout ? 36 : 40 }
    private var previewControlFontSize: CGFloat { isCondensedLayout ? 14 : 16 }
    private var slideshowTargetSize: CGSize {
        let scale = UIScreen.main.scale
        return CGSize(
            width: previewCardWidth * scale,
            height: previewCardHeight * scale
        )
    }
    private var previewDisplaySignature: String {
        if let bundle = onboard.previewBundle {
            let identifiers = bundle.sourceLocalIDs
            let first = identifiers.first ?? "empty"
            let last = identifiers.last ?? "empty"
            return "\(bundle.assetCount)-\(first)-\(last)-\(bundle.hasPlayableVideo ? "video" : "slides")"
        }
        if let seedSlide = onboard.previewSeedSlide {
            return "seed-\(seedSlide.localIdentifier)"
        }
        return "none"
    }
    private var slideshowPreheatBehindCount: Int { 4 }
    private var slideshowPreheatAheadCount: Int { 18 }

    private var titleText: String {
        if isReady || hasSeedPreview {
            return "This is your life"
        }
        if onboard.previewErrorMessage != nil {
            return "Preview unavailable"
        }
        return "Preparing preview"
    }

    var body: some View {
        OnboardingStepScreen(
            step: .previewGenerating,
            title: titleText,
            subtitle: ""
        ) {
            previewStage
        } footer: {
            footer
        }
        .onAppear {
            exportedURL = onboard.previewBundle?.exportURL
            onboard.preparePreviewIfNeeded()
            configurePreviewIfNeeded()
            trackPreviewViewIfNeeded()
        }
        .onChange(of: previewDisplaySignature) { _, _ in
            exportedURL = onboard.previewBundle?.exportURL
            statusMessage = nil
            configurePreviewIfNeeded()
            trackPreviewViewIfNeeded()
        }
        .onChange(of: onboard.previewErrorMessage) { _, _ in
            trackPreviewViewIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            guard let player else { return }
            player.seek(to: .zero)
            currentTimelineIndex = 0
            if isSlideshowPlaying {
                player.play()
            }
        }
        .onDisappear {
            player?.pause()
            detachPlayerTimeObserver()
            stopSlideshow()
            teardownSlideshowSoundtrack()
        }
        .sheet(item: $shareURL) { url in
            ActivityView(activityItems: [url])
        }
    }

    @ViewBuilder
    private var previewStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: previewTopInset)

            if isReady {
                readyContent
            } else if hasSeedPreview {
                seedContent
            } else if let error = onboard.previewErrorMessage {
                errorContent(message: error)
            } else {
                loadingContent
            }

            Spacer(minLength: previewTopInset)
        }
        .frame(maxWidth: .infinity, minHeight: previewSectionMinHeight, maxHeight: .infinity)
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                    .fill(T.core.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                            .stroke(T.border, lineWidth: 1)
                    )
                    .shadow(
                        color: scheme == .dark ? .black.opacity(0.30) : .black.opacity(0.10),
                        radius: 18,
                        y: 6
                    )

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(T.primaryMuted.opacity(0.45))
                            .frame(width: isCondensedLayout ? 66 : 74, height: isCondensedLayout ? 66 : 74)

                        ProgressView()
                            .controlSize(.regular)
                            .tint(T.core.accent)
                            .scaleEffect(1.1)
                    }

                    VStack(spacing: 6) {
                        Text("Creating preview")
                            .font(OnboardingTypography.preferred(.title3, weight: .semibold))
                            .foregroundStyle(T.core.text)

                        Text("\(Int((onboard.previewProgress.clamped01 * 100).rounded()))%")
                            .font(OnboardingTypography.fixed(isCondensedLayout ? 26 : 30, weight: .bold))
                            .foregroundStyle(T.core.accent)
                    }

                    Text("Finding local photos from your last 5 years.")
                        .font(OnboardingTypography.preferred(.callout, weight: .regular))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, isCondensedLayout ? 18 : 22)
            }
            .frame(width: previewCardWidth, height: previewCardHeight)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var readyContent: some View {
        VStack(spacing: 10) {
            previewCard

            HStack(spacing: 18) {
                PreviewUtilityButton(
                    title: "Share",
                    systemImage: "square.and.arrow.up",
                    isLoading: isExporting && exportIntent == .share
                ) {
                    startShare()
                }
                .disabled(isWorking || !canBuildExport)

                PreviewUtilityButton(
                    title: "Save",
                    systemImage: "arrow.down.to.line",
                    isLoading: (isExporting && exportIntent == .save) || isSaving
                ) {
                    startSave()
                }
                .disabled(isWorking || !canBuildExport)
            }
            .frame(maxWidth: previewCardWidth)
            .padding(.top, 6)
            .opacity(canBuildExport ? 1 : 0.45)

            if let statusMessage {
                Text(statusMessage)
                    .font(OnboardingTypography.preferred(.footnote, weight: .regular))
                    .foregroundStyle(statusMessage == "Saved to Photos" ? T.core.accent : .red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var seedContent: some View {
        VStack(spacing: 0) {
            previewCard
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "film.slash.fill")
                .font(.system(size: isCondensedLayout ? 30 : 34, weight: .semibold))
                .foregroundStyle(T.core.accent)

            Text(message)
                .font(OnboardingTypography.preferred(.body, weight: .regular))
                .foregroundStyle(T.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: previewCardWidth, minHeight: isCondensedLayout ? 320 : 360)
        .padding(.horizontal, 24)
        .background(T.core.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
        .shadow(
            color: scheme == .dark ? .black.opacity(0.28) : .black.opacity(0.08),
            radius: 16,
            y: 6
        )
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if onboard.previewErrorMessage != nil {
                OnboardingSecondaryButton(title: "Try again") {
                    onboard.retryPreviewGeneration()
                }
            }

            if !isLoading {
                OnboardingPrimaryButton(title: "Continue") {
                    OnboardingAnalytics.trackMontagePreviewContinueTapped(variant: onboard.sessionVariant)
                    onboard.advance()
                }
            }
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        ZStack {
            Group {
                if let player {
                    PlayerLayerView(
                        player: player,
                        overlay: nil,
                        gravity: .resizeAspectFill
                    )
                } else if let currentSlideImage {
                    Image(uiImage: currentSlideImage)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    T.core.surface
                        .overlay {
                            ProgressView()
                                .controlSize(.large)
                                .tint(T.core.accent)
                        }
                }
            }
            .frame(width: previewCardWidth, height: previewCardHeight)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                guard canTogglePreviewPlayback else { return }
                toggleSlideshowPlayback()
            }

            if let captionDate = activeCaptionDate {
                previewCaptionOverlay(for: captionDate)
            }

            if canTogglePreviewPlayback {
                Button(action: toggleSlideshowPlayback) {
                    Image(systemName: isSlideshowPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: previewControlFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: previewControlDiameter, height: previewControlDiameter)
                        .background(.black.opacity(0.28), in: Circle())
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
        .background(T.core.surface, in: RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
        .shadow(
            color: scheme == .dark ? .black.opacity(0.30) : .black.opacity(0.10),
            radius: 18,
            y: 6
        )
        .frame(width: previewCardWidth, height: previewCardHeight)
    }

    private func previewCaptionOverlay(for date: Date) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, .black.opacity(0.12), .black.opacity(0.44)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: previewCaptionOverlayHeight)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: -2) {
                    Text(captionMonthDay(for: date))
                        .font(OnboardingTypography.fixed(previewMonthDayFontSize, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.96))
                    Text(captionYear(for: date))
                        .font(OnboardingTypography.fixed(previewYearFontSize, weight: .regular))
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.horizontal, previewCaptionInset)
                .padding(.bottom, previewCaptionInset)
            }
        }
        .frame(width: previewCardWidth, height: previewCardHeight, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func configurePreviewIfNeeded() {
        guard let bundle = onboard.previewBundle else {
            if let seedSlide = onboard.previewSeedSlide {
                let seedSignature = previewDisplaySignature
                guard configuredPreviewSignature != seedSignature else { return }

                configuredPreviewSignature = seedSignature
                player?.pause()
                detachPlayerTimeObserver()
                player = nil
                stopSlideshow()
                teardownSlideshowSoundtrack()
                currentTimelineIndex = 0
                statusMessage = nil
                isSlideshowPlaying = false
                configureSeedPreview(slide: seedSlide)
                return
            }

            configuredPreviewSignature = nil
            player?.pause()
            detachPlayerTimeObserver()
            player = nil
            currentSlideImage = nil
            slideshowAssets = []
            currentTimelineIndex = 0
            stopSlideshow()
            teardownSlideshowSoundtrack()
            return
        }

        guard configuredPreviewSignature != previewDisplaySignature else {
            return
        }

        configuredPreviewSignature = previewDisplaySignature
        currentSlideIndex = 0
        currentTimelineIndex = 0
        statusMessage = nil
        isSlideshowPlaying = true

        if let composition = bundle.composition,
           let videoComposition = bundle.videoComposition,
           bundle.hasPlayableVideo {
            stopSlideshow()
            teardownSlideshowSoundtrack()
            slideshowAssets = []
            currentSlideImage = nil
            configureVideoPreview(
                composition: composition,
                videoComposition: videoComposition,
                audioMix: bundle.audioMix
            )
            player?.seek(to: .zero)
            player?.play()
            return
        }

        player?.pause()
        detachPlayerTimeObserver()
        player = nil
        slideshowAssets = loadAssets(for: bundle.slides)
        currentSlideImage = cachedSlideshowImage(for: slideshowAssets.first)
        configureSlideshowSoundtrack(trackID: bundle.trackID)
        startSlideshow()
    }

    private func configureSeedPreview(slide: OnboardingPreviewSlide) {
        let asset = loadAssets(for: [slide]).first
        slideshowAssets = asset.map { [$0] } ?? []
        currentSlideIndex = 0

        guard let asset else {
            currentSlideImage = nil
            return
        }

        if let cachedImage = cachedSlideshowImage(for: asset) {
            currentSlideImage = cachedImage
            return
        }

        let requestToken = UUID()
        activeSlideRequestToken = requestToken
        requestCurrentSlideFallbackImage(
            for: asset,
            at: 0,
            requestToken: requestToken
        )
    }

    private func startSlideshow() {
        stopSlideshow()
        guard !slideshowAssets.isEmpty else { return }
        playSlideshowSoundtrack()

        let assets = slideshowAssets
        let slideInterval = OnboardingPreviewService.timelapseSecondsPerAsset(assetCount: assets.count)
        let slideIntervalNanoseconds = UInt64(slideInterval * 1_000_000_000)
        slideshowTask = Task {
            var nextIndex = min(max(currentSlideIndex, 0), max(assets.count - 1, 0))

            while !Task.isCancelled {
                await MainActor.run {
                    presentSlide(at: nextIndex, in: assets)
                }

                do {
                    try await Task.sleep(nanoseconds: slideIntervalNanoseconds)
                } catch {
                    return
                }

                nextIndex = (nextIndex + 1) % assets.count
            }
        }
    }

    private func stopSlideshow() {
        slideshowTask?.cancel()
        slideshowTask = nil
        cancelActiveSlideshowRequest()
        cancelAllSlideshowPreloadRequests()
        activeSlideRequestToken = UUID()
        slideshowAudioPlayer?.pause()
    }

    private func toggleSlideshowPlayback() {
        if let player {
            if isSlideshowPlaying {
                player.pause()
                isSlideshowPlaying = false
                return
            }

            if let item = player.currentItem {
                let endSeconds = item.duration.seconds
                if endSeconds.isFinite, player.currentTime().seconds >= endSeconds - 0.05 {
                    player.seek(to: .zero)
                }
            }

            player.play()
            isSlideshowPlaying = true
            return
        }

        guard !slideshowAssets.isEmpty else { return }

        if isSlideshowPlaying {
            isSlideshowPlaying = false
            stopSlideshow()
            return
        }

        isSlideshowPlaying = true
        startSlideshow()
    }

    private func configureSlideshowSoundtrack(trackID: String) {
        guard let trackURL = try? OnboardingPreviewService.previewTrackURL(for: trackID) else {
            teardownSlideshowSoundtrack()
            return
        }

        if let slideshowAudioPlayer, slideshowAudioPlayer.url == trackURL {
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: trackURL)
            audioPlayer.numberOfLoops = -1
            audioPlayer.prepareToPlay()
            slideshowAudioPlayer = audioPlayer
        } catch {
            teardownSlideshowSoundtrack()
        }
    }

    private func playSlideshowSoundtrack() {
        guard player == nil else { return }
        if slideshowAudioPlayer == nil, let trackID = onboard.previewBundle?.trackID {
            configureSlideshowSoundtrack(trackID: trackID)
        }
        slideshowAudioPlayer?.play()
    }

    private func teardownSlideshowSoundtrack() {
        slideshowAudioPlayer?.stop()
        slideshowAudioPlayer = nil
    }

    private func configureVideoPreview(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVAudioMix?
    ) {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix

        if let player {
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .none
            attachPlayerTimeObserver(to: player)
            return
        }

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        self.player = player
        attachPlayerTimeObserver(to: player)
    }

    private func attachPlayerTimeObserver(to player: AVPlayer) {
        detachPlayerTimeObserver()

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            syncCurrentTimelineIndex(for: time)
        }

        playerTimeObserver = token
        observedPlayer = player
        syncCurrentTimelineIndex(for: player.currentTime())
    }

    private func detachPlayerTimeObserver() {
        guard let playerTimeObserver, let observedPlayer else { return }
        observedPlayer.removeTimeObserver(playerTimeObserver)
        self.playerTimeObserver = nil
        self.observedPlayer = nil
    }

    private func syncCurrentTimelineIndex(for time: CMTime) {
        guard let timeline = onboard.previewBundle?.timeline, !timeline.isEmpty else {
            currentTimelineIndex = 0
            return
        }

        let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
        var elapsed: TimeInterval = 0

        for (index, entry) in timeline.enumerated() {
            elapsed += entry.duration
            if seconds < elapsed || index == timeline.count - 1 {
                currentTimelineIndex = index
                return
            }
        }

        currentTimelineIndex = max(timeline.count - 1, 0)
    }

    private func captionMonthDay(for date: Date) -> String {
        OnboardingPreviewRevealScreen.captionMonthDayFormatter
            .string(from: date)
            .uppercased(with: .current)
    }

    private func captionYear(for date: Date) -> String {
        OnboardingPreviewRevealScreen.captionYearFormatter.string(from: date)
    }

    private func loadAssets(for slides: [OnboardingPreviewSlide]) -> [PHAsset] {
        let identifiers = slides.map(\.localIdentifier)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }
        return identifiers.compactMap { assetsByIdentifier[$0] }
    }

    private var slideshowFallbackImageRequestOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.version = .current
        return options
    }

    private var slideshowPreloadImageRequestOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.version = .current
        return options
    }

    private func slideshowCacheKey(for asset: PHAsset?) -> NSString? {
        guard let asset else { return nil }
        return "\(asset.localIdentifier)-\(Int(slideshowTargetSize.width.rounded()))x\(Int(slideshowTargetSize.height.rounded()))" as NSString
    }

    private func cachedSlideshowImage(for asset: PHAsset?) -> UIImage? {
        guard let key = slideshowCacheKey(for: asset) else { return nil }
        return OnboardingPreviewRevealScreen.slideshowRenderedImageCache.object(forKey: key)
    }

    private func slideshowPreheatAssets(around index: Int, in assets: [PHAsset]) -> [PHAsset] {
        guard !assets.isEmpty else { return [] }

        let clampedIndex = min(max(index, 0), assets.count - 1)
        var orderedIndices: [Int] = []
        orderedIndices.reserveCapacity(slideshowPreheatBehindCount + slideshowPreheatAheadCount + 1)
        var seen = Set<Int>()

        for offset in (-slideshowPreheatBehindCount)...slideshowPreheatAheadCount {
            let wrappedIndex = (clampedIndex + offset + assets.count) % assets.count
            guard seen.insert(wrappedIndex).inserted else { continue }
            orderedIndices.append(wrappedIndex)
        }

        return orderedIndices.map { assets[$0] }
    }

    private func presentSlide(at index: Int, in assets: [PHAsset]) {
        guard assets.indices.contains(index) else { return }

        let asset = assets[index]
        let requestToken = UUID()
        activeSlideRequestToken = requestToken
        currentSlideIndex = index

        preloadSlideshowImages(around: index, in: assets)

        if let cachedImage = cachedSlideshowImage(for: asset) {
            cancelActiveSlideshowRequest()
            withAnimation(.easeInOut(duration: 0.12)) {
                currentSlideImage = cachedImage
            }
            return
        }

        requestCurrentSlideFallbackImage(for: asset, at: index, requestToken: requestToken)
    }

    private func cancelActiveSlideshowRequest() {
        guard let requestID = activeSlideshowRequestID else { return }
        OnboardingPreviewRevealScreen.slideshowImageManager.cancelImageRequest(requestID)
        activeSlideshowRequestID = nil
    }

    private func cancelAllSlideshowPreloadRequests() {
        for requestID in slideshowPreloadRequestIDs.values {
            OnboardingPreviewRevealScreen.slideshowImageManager.cancelImageRequest(requestID)
        }
        slideshowPreloadRequestIDs.removeAll()
    }

    private func preloadSlideshowImages(around index: Int, in assets: [PHAsset]) {
        let desiredAssets = slideshowPreheatAssets(around: index, in: assets)
        let desiredIdentifiers = Set(desiredAssets.map(\.localIdentifier))

        for (localIdentifier, requestID) in slideshowPreloadRequestIDs where !desiredIdentifiers.contains(localIdentifier) {
            OnboardingPreviewRevealScreen.slideshowImageManager.cancelImageRequest(requestID)
            slideshowPreloadRequestIDs[localIdentifier] = nil
        }

        for asset in desiredAssets {
            guard let cacheKey = slideshowCacheKey(for: asset) else { continue }
            if OnboardingPreviewRevealScreen.slideshowRenderedImageCache.object(forKey: cacheKey) != nil {
                continue
            }
            if slideshowPreloadRequestIDs[asset.localIdentifier] != nil {
                continue
            }

            let localIdentifier = asset.localIdentifier
            let requestID = OnboardingPreviewRevealScreen.slideshowImageManager.requestImage(
                for: asset,
                targetSize: slideshowTargetSize,
                contentMode: .aspectFill,
                options: slideshowPreloadImageRequestOptions
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if isDegraded {
                    return
                }

                let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                let error = info?[PHImageErrorKey] as? Error

                Task { @MainActor in
                    slideshowPreloadRequestIDs[localIdentifier] = nil

                    guard !cancelled, error == nil, let image else { return }

                    let fixedImage = image.fixedOrientation()
                    OnboardingPreviewRevealScreen.slideshowRenderedImageCache.setObject(
                        fixedImage,
                        forKey: cacheKey
                    )

                    if currentSlide?.localIdentifier == localIdentifier {
                        cancelActiveSlideshowRequest()
                        withAnimation(.easeInOut(duration: 0.12)) {
                            currentSlideImage = fixedImage
                        }
                    }
                }
            }

            slideshowPreloadRequestIDs[localIdentifier] = requestID
        }
    }

    private func requestCurrentSlideFallbackImage(
        for asset: PHAsset,
        at index: Int,
        requestToken: UUID
    ) {
        cancelActiveSlideshowRequest()

        activeSlideshowRequestID = OnboardingPreviewRevealScreen.slideshowImageManager.requestImage(
            for: asset,
            targetSize: slideshowTargetSize,
            contentMode: .aspectFill,
            options: slideshowFallbackImageRequestOptions
        ) { image, info in
            let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
            if cancelled {
                Task { @MainActor in
                    if activeSlideRequestToken == requestToken {
                        activeSlideshowRequestID = nil
                    }
                }
                return
            }

            let error = info?[PHImageErrorKey] as? Error
            guard error == nil, let image else {
                Task { @MainActor in
                    if activeSlideRequestToken == requestToken {
                        activeSlideshowRequestID = nil
                    }
                }
                return
            }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
            let fixedImage = image.fixedOrientation()

            Task { @MainActor in
                guard activeSlideRequestToken == requestToken else { return }

                currentSlideIndex = index
                withAnimation(.easeInOut(duration: isDegraded ? 0.08 : 0.12)) {
                    currentSlideImage = fixedImage
                }

                if !isDegraded, let cacheKey = slideshowCacheKey(for: asset) {
                    OnboardingPreviewRevealScreen.slideshowRenderedImageCache.setObject(
                        fixedImage,
                        forKey: cacheKey
                    )
                }

                if !isDegraded {
                    activeSlideshowRequestID = nil
                }
            }
        }
    }

    private func startShare() {
        guard !isWorking else { return }

        Task {
            do {
                statusMessage = nil
                shareURL = try await ensureExportURL(for: .share)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func startSave() {
        guard !isWorking else { return }

        Task {
            do {
                statusMessage = nil
                let exportURL = try await ensureExportURL(for: .save)
                savePreviewToPhotos(from: exportURL)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func ensureExportURL(for intent: PreviewExportIntent) async throws -> URL {
        if let exportedURL {
            return exportedURL
        }

        guard let bundle = onboard.previewBundle else {
            throw OnboardingPreviewServiceError.exportFailed
        }

        isExporting = true
        exportIntent = intent
        defer {
            isExporting = false
            exportIntent = nil
        }

        let url = try await previewService.exportPreviewAsset(for: bundle)
        cacheExportURL(url, from: bundle)
        return url
    }

    private func cacheExportURL(_ url: URL, from bundle: OnboardingPreviewBundle) {
        exportedURL = url
        onboard.previewBundle = OnboardingPreviewBundle(
            composition: bundle.composition,
            videoComposition: bundle.videoComposition,
            audioMix: bundle.audioMix,
            exportURL: url,
            preparedClips: bundle.preparedClips,
            slides: bundle.slides,
            timeline: bundle.timeline,
            trackID: bundle.trackID
        )
    }

    private func savePreviewToPhotos(from exportURL: URL) {
        guard !isSaving else { return }

        isSaving = true
        statusMessage = nil

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: exportURL)
        }) { success, error in
            Task { @MainActor in
                isSaving = false
                statusMessage = success
                    ? "Saved to Photos"
                    : (error?.localizedDescription ?? "Couldn’t save the preview.")
            }
        }
    }

    private func trackPreviewViewIfNeeded() {
        guard !hasTrackedPreviewView else { return }
        guard onboard.previewBundle != nil || onboard.previewErrorMessage != nil else { return }

        hasTrackedPreviewView = true
        OnboardingAnalytics.trackMontagePreviewViewed(
            clipsCount: onboard.onboardingClipsCount,
            variant: onboard.sessionVariant
        )
    }
}

private struct PreviewUtilityButton: View {
    let title: String
    let systemImage: String
    let isLoading: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
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
                .frame(width: 52, height: 52)

                Text(title)
                    .font(OnboardingTypography.preferred(.footnote, weight: .medium))
                    .foregroundStyle(T.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(T.core.text)
        .accessibilityLabel(title)
    }
}
