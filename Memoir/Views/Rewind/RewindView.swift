import SwiftUI
import Photos
import AVKit
import PhotosUI
import PhosphorSwift

struct RewindView: View {
    @Binding var selectedTab: Int
    // No more ClipStore dependency
    @State private var entries: [RewindYearEntry] = []
    @State private var activeSession: RewindYearSession? = nil
    @State private var years: [Int] = []
    @State private var daySession: RewindDaySession? = nil

    var onBadgeCountChange: ((Int) -> Void)? = nil

    @State private var currentYearIndex: Int = 0
    private let carouselTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    @Environment(\.colorScheme) private var scheme
    @State private var theme: AppTheme = .sunsetGlow
    private var T: Theme { theme.theme(for: scheme) }

    @State private var lastInteractionDate = Date()

    @State private var hintPing = UUID()

    // Formatter for the "On This Day" date at the top
    private var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: Date())
    }

    var body: some View {
        ZStack {
            T.core.surface
                .ignoresSafeArea()

            VStack(spacing: 24) {
                header



                if entries.isEmpty {
                    emptyState
                } else {
                    carouselCard
                }



                if !entries.isEmpty {
                    yearDots
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .onAppear {
            loadRewindEntries()
            daySession = RewindEngine.buildDaySession()
        }
        // NEW: auto-rotate the visible year card
        .onReceive(carouselTimer) { _ in
            guard entries.count > 1 else { return }

            // Only auto-advance if it's been at least 5 seconds
            let interval = Date().timeIntervalSince(lastInteractionDate)
            guard interval >= 5 else { return }

            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                currentYearIndex = (currentYearIndex + 1) % entries.count
            }

            // 👇 Each time the card rotates, ping the hint animation
            hintPing = UUID()
        }


        .fullScreenCover(item: $activeSession) { session in
            NavigationStack {
                RewindYearFullScreenView(
                    year: session.year,
                    assets: session.assets,
                    allYears: years,
                    onChangeYear: { newYear in
                        switchToYear(newYear)
                    },
                    onAddToProject: { asset in
                        // TODO: integrate with ClipStore
                    },
                    onClose: {
                        activeSession = nil
                    }
                )
            }
        }
    }

    private func updateBadgeCount(from entries: [RewindYearEntry]) {
        let currentYear = Calendar.current.component(.year, from: Date())
        var count = 0

        // For each year before this year, see if we have assets "on this day"
        for entry in entries {
            guard entry.year < currentYear else { continue }
            let assets = RewindEngine.assetsForYearOnThisDay(year: entry.year)
            if !assets.isEmpty {
                count += 1
            }
        }

        // 1) Update the Rewind tab badge (if hooked up)
        onBadgeCountChange?(count)
    }

    private func loadRewindEntries() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        func applyEntries(_ built: [RewindYearEntry]) {
            self.entries = built
            self.years = built.map { $0.year }
            self.currentYearIndex = 0
            // Update the Rewind tab badge whenever we refresh entries
            updateBadgeCount(from: built)
        }

        switch status {
        case .authorized, .limited:
            let built = RewindEngine.buildEntriesFromPhotos()
            applyEntries(built)

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        let built = RewindEngine.buildEntriesFromPhotos()
                        applyEntries(built)
                    } else {
                        self.entries = []
                        self.years = []
                        self.currentYearIndex = 0
                        self.onBadgeCountChange?(0)
                    }
                }
            }

        default:
            entries = []
            years = []
            currentYearIndex = 0
            onBadgeCountChange?(0)
        }
    }



    private func switchToYear(_ year: Int) {
        handleYearTapped(year)
    }


    // MARK: - Header

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Fun rewind icon bubble in accent color
            ZStack {
//                Circle()
//                    .fill(T.core.accent.opacity(0.16))
//                    .frame(width: 32, height: 32)

                Ph.rewind.fill
                    .frame(width: 32, height: 32)
                    .foregroundColor(T.core.accent)

            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Rewind")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(T.core.text)

                Text("On this day")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(T.textSecondary)
            }

            Spacer()

            // Date pill
            Text(todayString.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(T.surfaceAlt)
                )
                .foregroundColor(T.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }







    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(T.surfaceAlt)

                HStack(spacing: 12) {
                    Text("📸")
                        .font(.system(size: 32))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("No rewind memories today")
                            .font(.headline)
                            .foregroundColor(T.core.text)

                        Text("Start capturing today so future you can thank you.")
                            .font(.subheadline)
                            .foregroundColor(T.textSecondary)
                    }

                    Spacer()
                }
                .padding(16)
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }



    private func handleYearTapped(_ year: Int) {
        let assets = RewindEngine.assetsForYearOnThisDay(year: year)

        guard !assets.isEmpty else {
            return
        }

        activeSession = RewindYearSession(
            year: year,
            assets: assets
        )
    }


    // Single visible carousel card for the current year
    private var carouselCard: some View {
        let entry = entries[currentYearIndex]

        return Button {
            lastInteractionDate = Date()          // 👈 reset auto-advance timer
            handleYearTapped(entry.year)
        } label: {
            RewindYearCarouselCard(entry: entry, isActive: true, hintPing: hintPing)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }


    // MARK: - Year Underline Selector (Minimalist + themed)
    private var yearDots: some View {
        HStack(spacing: 26) {
            ForEach(entries.indices, id: \.self) { idx in
                let entry = entries[idx]
                let isActive = idx == currentYearIndex

                VStack(spacing: 4) {
                    Text(String(entry.year))
                        .font(.system(
                            size: isActive ? 15 : 13,
                            weight: isActive ? .semibold : .regular,
                            design: .rounded
                        ))
                        .foregroundColor(isActive ? T.core.text : T.core.text)
                        .animation(.easeInOut(duration: 0.3), value: isActive)

                    Rectangle()
                        .fill(T.core.accent)
                        .frame(height: 3)
                        .frame(width: isActive ? 22 : 0)
                        .opacity(isActive ? 1 : 0)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.82),
                            value: isActive
                        )
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        currentYearIndex = idx
                    }
                    lastInteractionDate = Date()
                    hintPing = UUID()      // 👈 bounce when user switches years too
                }
            }
        }
        .padding(.top, 10)
    }



}

private struct RewindYearCarouselCard: View {
    let entry: RewindYearEntry
    let isActive: Bool
    let hintPing: UUID

    // This is the ONE true size for all cards
    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 560
    @State private var hintOffset: CGFloat = 0
    @State private var hintAnimating: Bool = false



    private var formattedDayMonth: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f.string(from: Date())   // today's month + day
    }


    var body: some View {
        ZStack(alignment: .bottomLeading) {

            // FULL card background + thumbnail
            YearThumbnailView(year: entry.year)
                .id(entry.year)
                .frame(width: cardWidth, height: cardHeight)
                .scaledToFill()
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            // DATE OVERLAY (bottom-left)
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDayMonth)   // Example: "November 15"
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)

                Text(String(entry.year))  // Example: "2024"
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .frame(width: cardWidth, height: cardHeight, alignment: .bottomLeading)


            // --- EXPAND HINT (bottom-right corner, DOUBLE-BOUNCE + REST) ---
            HStack {
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(10)
                    .background(Color.black.opacity(0.25))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                    .offset(y: hintOffset)   // <-- animated offset
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
            }
            .frame(width: cardWidth, height: cardHeight, alignment: .bottomTrailing)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(
            color: Color.black.opacity(isActive ? 0.18 : 0.08),
            radius: isActive ? 18 : 8,
            x: 0,
            y: isActive ? 10 : 4
        )
        .scaleEffect(isActive ? 1.0 : 0.96)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: isActive)
        .onAppear {
            // Optional: play once when the card first appears
            runHintSequence()
        }
        .onChange(of: hintPing) { _ in
            // Each time the parent pings, play the bounce once
            runHintSequence()
        }
    }

    private func runHintSequence() {
        // Avoid overlapping bounces
        if hintAnimating { return }
        hintAnimating = true

        // Reset to baseline
        hintOffset = 0

        // Bounce 1
        withAnimation(.easeOut(duration: 0.30)) {
            hintOffset = -12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.easeIn(duration: 0.20)) {
                hintOffset = 0
            }

            // Bounce 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeOut(duration: 0.30)) {
                    hintOffset = -8
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    withAnimation(.easeIn(duration: 0.20)) {
                        hintOffset = 0
                        // Done – allow future bounces
                        hintAnimating = false
                    }
                }
            }
        }
    }
}


// MARK: - Thumbnail for the first clip of the year

private struct YearThumbnailView: View {
    let year: Int

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            loadThumbnailIfNeeded()
        }
    }

    private func loadThumbnailIfNeeded() {
        guard image == nil else { return }

        // Use your existing Photos-based helper:
        let assets = RewindEngine.assetsForYearOnThisDay(year: year)
        guard let first = assets.first else { return }

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast   // or .exact if you want, but .fast is usually fine

        // Ask for a thumbnail roughly matching / exceeding the card size
        // Card is ~320x560; multiply by screen scale to avoid upscaling.
        let scale = UIScreen.main.scale
        let targetSize = CGSize(
            width: 320 * scale * 1.3,
            height: 560 * scale * 1.3
        )

        manager.requestImage(
            for: first,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result {
                DispatchQueue.main.async {
                    self.image = result
                }
            }
        }
    }
}


// MARK: - Full-screen year view

struct RewindYearFullScreenView: View {
    let year: Int
    let assets: [PHAsset]
    let allYears: [Int]
    let onChangeYear: (Int) -> Void
    let onAddToProject: (PHAsset) -> Void
    let onClose: () -> Void



    @State private var currentIndex: Int = 0

    // Auto-play timer: advance every 5 seconds
    private let autoPlayTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var todayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f.string(from: Date()).uppercased()
    }

    private var fullDateLabel: String {
        "\(todayLabel), \(year)"
    }

    private var dateTitleText: String {
        // "NOVEMBER 3"
        todayLabel.uppercased()
    }

    private var dateYearText: String {
        // "2025"
        String(year)
    }


    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if assets.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Text("No clips for this day in \(year).")
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button(action: onClose) {
                        Text("Close")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .cornerRadius(20)
                    }
                }
            } else {
                ZStack {
                    // Paged assets
                    TabView(selection: $currentIndex) {
                        ForEach(assets.indices, id: \.self) { idx in
                            RewindAssetView(asset: assets[idx])
                                .tag(idx)
                                .ignoresSafeArea()
                        }
                    }

                    // Arrow navigation overlay
                    if assets.count > 1 {
                        HStack {
                            Button(action: goToPrevious) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white)
                                    .shadow(radius: 4)
                            }
                            .opacity(currentIndex > 0 ? 0.95 : 0.35)
                            .disabled(currentIndex == 0)

                            Spacer()

                            Button(action: goToNext) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white)
                                    .shadow(radius: 4)
                            }
                            .opacity(currentIndex < assets.count - 1 ? 0.95 : 0.35)
                            .disabled(currentIndex >= assets.count - 1)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }

            // Top header overlay
            VStack {
                header
                Spacer()
            }

            // Bottom controls overlay
            VStack {
                Spacer()
                controls
            }
        }
        .onReceive(autoPlayTimer) { _ in
            let asset = assets[currentIndex]

            // If it's a video, do NOT auto-advance early.
            if asset.mediaType == .video { return }

            autoAdvance()
        }

    }


    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                if !assets.isEmpty {
                    Text("\(currentIndex + 1) of \(assets.count)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }


        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }



    private var controls: some View {
        VStack(spacing: 14) {
            // DATE — styled like Montage date overlay
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateTitleText)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.9), radius: 2, x: 0, y: 1)
                        .shadow(color: Color.black.opacity(0.7), radius: 4, x: 0, y: 3)

                    Text(dateYearText)
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                        .shadow(color: Color.black.opacity(0.8), radius: 1, x: 0, y: 1)
                        .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 2)

                }

                Spacer()
            }

            // CUSTOM PAGE DOTS — the only dots now
            if assets.count > 1 {
                HStack(spacing: 8) {
                    ForEach(assets.indices, id: \.self) { idx in
                        Circle()
                            .frame(width: idx == currentIndex ? 8 : 6,
                                   height: idx == currentIndex ? 8 : 6)
                            .foregroundColor(
                                idx == currentIndex
                                ? Color.white
                                : Color.white.opacity(0.45)
                            )
                            .shadow(radius: idx == currentIndex ? 2 : 0)
                    }
                }
                .padding(.top, 4)
            }

//            // ADD TO PROJECT BUTTON
//            Button {
//                guard assets.indices.contains(currentIndex) else { return }
//                let asset = assets[currentIndex]
//                onAddToProject(asset)
//            } label: {
//                HStack {
//                    Image(systemName: "square.and.arrow.down")
//                    Text("Add to Project")
//                        .fontWeight(.semibold)
//                }
//                .font(.system(size: 16, weight: .semibold, design: .rounded))
//                .frame(maxWidth: .infinity)
//                .padding(.vertical, 14)
//                .background(Color.white)
//                .foregroundColor(.black)
//                .cornerRadius(18)
//            }

            Text("Swipe or use the arrows to see all clips from this day.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }




    // MARK: - Paging helpers

    private func goToPrevious() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut) {
            currentIndex -= 1
        }
    }

    private func goToNext() {
        guard currentIndex < assets.count - 1 else { return }
        withAnimation(.easeInOut) {
            currentIndex += 1
        }
    }

    private func autoAdvance() {
        guard assets.count > 1 else { return }

        withAnimation(.easeInOut) {
            if currentIndex < assets.count - 1 {
                currentIndex += 1
            } else {
                // Loop back to the first asset when reaching the end
                currentIndex = 0
            }
        }
    }

    private var yearIndex: Int? {
        allYears.firstIndex(of: year)
    }

    private var hasPreviousYear: Bool {
        guard let idx = yearIndex else { return false }
        // allYears is newest → oldest, so "previous" means older
        return idx < allYears.count - 1
    }

    private var hasNextYear: Bool {
        guard let idx = yearIndex else { return false }
        // "next" means newer
        return idx > 0
    }

    private func goToPreviousYear() {
        guard let idx = yearIndex,
              idx < allYears.count - 1 else { return }
        let newYear = allYears[idx + 1]   // older year
        onChangeYear(newYear)
    }

    private func goToNextYear() {
        guard let idx = yearIndex,
              idx > 0 else { return }
        let newYear = allYears[idx - 1]   // newer year
        onChangeYear(newYear)
    }

}

struct RewindAssetView: View {
    let asset: PHAsset

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        ZStack {
            // Always black behind everything
            Color.black.ignoresSafeArea()

            if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Downloading from iCloud…")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

            } else if asset.mediaSubtypes.contains(.photoLive) {
                if let livePhoto {
                    LivePhotoView(livePhoto: livePhoto)
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                // Normal photo
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .onAppear { loadAsset() }
    }

    private func loadAsset() {
        let screenSize = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let manager = PHImageManager.default()

        if asset.mediaType == .video {
            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil) { avAsset, _, _ in
                if let urlAsset = avAsset as? AVURLAsset {
                    DispatchQueue.main.async {
                        self.player = AVPlayer(url: urlAsset.url)
                        self.player?.isMuted = false
                        self.player?.play()
                    }
                }
            }
            return
        }

        if asset.mediaSubtypes.contains(.photoLive) {
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true

            let screenSize = UIScreen.main.bounds.size
            let scale = UIScreen.main.scale
            let liveTargetSize = CGSize(width: screenSize.width * scale,
                                        height: screenSize.height * scale)

            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: liveTargetSize,
                contentMode: .aspectFill,
                options: options
            ) { live, _ in
                DispatchQueue.main.async {
                    self.livePhoto = live
                }
            }

            return
        }

        // Normal photo
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        let photoTargetSize = CGSize(width: screenSize.width * scale,
                                     height: screenSize.height * scale)

        manager.requestImage(
            for: asset,
            targetSize: photoTargetSize,
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            DispatchQueue.main.async {
                self.image = result
            }
        }

    }
}

struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.livePhoto = livePhoto
        view.contentMode = .scaleAspectFill
        view.startPlayback(with: .full)
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        uiView.livePhoto = livePhoto
        uiView.startPlayback(with: .full)
    }
}
