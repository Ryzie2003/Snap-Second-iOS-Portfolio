import SwiftUI
import Photos
import AVKit

struct RewindDayFullScreenView: View {
    let session: RewindDaySession
    @Binding var isPresented: Bool

    @State private var currentIndex: Int = 0
    @State private var showUI: Bool = true
    @State private var autoHideTimer: Timer? = nil
    @State private var playPausePing = UUID()
    @State private var clipProgress: CGFloat = 0.0

    private let storyTimer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    private var clips: [RewindDayClip] {
        session.clips
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Media content
            RewindDayMediaView(
                asset: clips[currentIndex].asset,
                playPausePing: playPausePing
            )
            .id(clips[currentIndex].asset.localIdentifier)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            tapZones

            if showUI {
                topControls
                bottomControls
            }
        }
        // IG-style auto-advance
        .onReceive(storyTimer) { _ in
            handleStoryTick()
        }
    }


    // MARK: - Controls

    private var topControls: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // 1) Year "stories" bar at the very top
                yearStoriesBar
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                // 2) Current year + how long ago, with X on the right
                HStack {
                    Text(currentYearDescriptor)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))

                    Spacer()

                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.9),
                        Color.black.opacity(0.5),
                        Color.black.opacity(0.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()
        }
        .transition(.opacity)
    }




    private var bottomControls: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formattedDateLabel)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)

                        Text(currentYearClipCounterText)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                    }

                    Spacer()

                    if isCurrentClipVideo {
                        Button {
                            // Ping the media view to toggle play/pause
                            playPausePing = UUID()
                        } label: {
                            Image(systemName: "playpause.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(10)
                                .background(Color.white)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.5),
                        Color.black.opacity(0.9)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
//        .ignoresSafeArea(edges: .bottom)
        .transition(.opacity)
    }


    // MARK: - Year "Story" Bar

    private var yearStoriesBar: some View {
        let years = orderedYears

        return HStack(spacing: 4) {
            ForEach(years, id: \.self) { year in
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .overlay(
                        GeometryReader { geo in
                            let progress = progressForYear(year)
                            Capsule()
                                .fill(Color.white)
                                .frame(width: geo.size.width * progress)
                        }
                    )
            }
        }
        .frame(height: 3)
    }


    // MARK: - Tap Zones (left / right only)

    private var tapZones: some View {
        HStack(spacing: 0) {
            // LEFT: previous
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    previousClip()
                }

            // RIGHT: next
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    nextClip()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Logic

    private var isCurrentClipVideo: Bool {
        guard !clips.isEmpty else { return false }
        return clips[currentIndex].asset.mediaType == .video
    }

    private func nextClip() {
        showUI = true
        clipProgress = 0.0

        if currentIndex < clips.count - 1 {
            currentIndex += 1
        } else {
            currentIndex = 0 // loop behavior
        }
    }

    private func previousClip() {
        showUI = true
        clipProgress = 0.0

        if currentIndex > 0 {
            currentIndex -= 1
        } else {
            // do nothing at the first clip
        }
    }




    private var formattedDateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return "\(formatter.string(from: session.date).uppercased()), \(clips[currentIndex].year)"
    }

    private var currentYearClipCounterText: String {
        guard !clips.isEmpty else { return "" }

        let currentYear = clips[currentIndex].year

        // All indices whose clip belongs to this year
        let indicesForYear = clips.indices.filter { clips[$0].year == currentYear }

        // Find where the currentIndex sits within that sub-sequence
        guard let localIndex = indicesForYear.firstIndex(of: currentIndex) else {
            return ""
        }

        let position = localIndex + 1
        let total = indicesForYear.count

        return "\(position) of \(total)"
    }

    private var currentYearDescriptor: String {
        let year = currentYear
        let calendar = Calendar.current
        let nowYear = calendar.component(.year, from: Date())
        let diff = nowYear - year

        if diff <= 0 {
            return "\(year) · This year"
        } else if diff == 1 {
            return "\(year) · 1 year ago"
        } else {
            return "\(year) · \(diff) years ago"
        }
    }


    // MARK: - Year Progress Helpers

    private var orderedYears: [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for clip in clips {
            if !seen.contains(clip.year) {
                seen.insert(clip.year)
                result.append(clip.year)
            }
        }
        return result
    }

    private var currentYear: Int {
        guard !clips.isEmpty else { return Calendar.current.component(.year, from: session.date) }
        return clips[currentIndex].year
    }

    private func progressForYear(_ year: Int) -> CGFloat {
        let years = orderedYears
        guard let yearIndex = years.firstIndex(of: year),
              let currentYearIndex = years.firstIndex(of: currentYear) else {
            return 0
        }

        // Previous years are fully filled
        if yearIndex < currentYearIndex {
            return 1.0
        }

        // Future years are empty
        if yearIndex > currentYearIndex {
            return 0.0
        }

        // Active year: partial fill based on position within that year
        let indicesForYear = clips.indices.filter { clips[$0].year == year }
        guard !indicesForYear.isEmpty,
              let localIndex = indicesForYear.firstIndex(of: currentIndex) else {
            return 0.0
        }

        let total = indicesForYear.count

        // Clips before the current one are fully filled; current clip uses clipProgress.
        let fullyCompleted = CGFloat(localIndex)
        let progress = (fullyCompleted + clipProgress) / CGFloat(total)

        return min(max(progress, 0.0), 1.0)
    }


    /// Called every 0.03s by `storyTimer` to drive IG-style auto-advance.
    private func handleStoryTick() {
        guard !clips.isEmpty else { return }

        // If you ever re-enable videos in Rewind, you could choose to skip auto-advance for videos:
        if isCurrentClipVideo {
            return
        }

        // Duration per still / Live Photo "story" in seconds
        let duration: CGFloat = 3.0
        let tickInterval: CGFloat = 0.03
        let step = tickInterval / duration

        clipProgress += step

        if clipProgress >= 1.0 {
            clipProgress = 0.0
            nextClip()
        }
    }


}
