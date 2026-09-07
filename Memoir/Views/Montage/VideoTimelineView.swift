//
//  VideoTimelineView.swift
//  Memoir
//
//  Created on 1/5/26.
//

import SwiftUI
import AVFoundation

/// CapCut/TikTok-style video timeline with film strip thumbnails
struct VideoTimelineView: View {
    let T: Theme
    let player: AVPlayer?
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    @Binding var currentTime: TimeInterval
    @Binding var isPlaying: Bool

    @StateObject private var thumbnailGenerator = TimelineThumbnailGenerator()
    @State private var isDragging = false
    @State private var timelineWidth: CGFloat = 0
    @State private var playheadOffset: CGFloat = 0
    @State private var updateTimer: Timer?

    // CapCut-style sizing
    private let stripHeight: CGFloat = 56
    private let cornerRadius: CGFloat = 8

    private var duration: TimeInterval {
        composition.duration.seconds
    }

    var body: some View {
        VStack(spacing: 8) {
            // Timeline controls
            HStack(spacing: 16) {
                // Play/Pause button
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(T.core.primary)
                        )
                }
                .buttonStyle(.plain)

                // Time display
                HStack(spacing: 4) {
                    Text(formatTime(currentTime))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)

                    Text("/")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))

                    Text(formatTime(duration))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                )

                Spacer()
            }
            .padding(.horizontal, 16)

            // CapCut-style film strip timeline
            GeometryReader { geo in
                let usable = max(1, geo.size.width)

                ZStack(alignment: .leading) {
                    // Tightly packed filmstrip (no gaps)
                    if !sortedThumbnailTimes.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(sortedThumbnailTimes, id: \.self) { time in
                                if let thumbnail = thumbnailGenerator.thumbnails[time] {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: max(1, usable / CGFloat(sortedThumbnailTimes.count)), height: stripHeight)
                                        .clipped()
                                } else {
                                    Rectangle()
                                        .fill(Color(white: 0.15))
                                        .frame(width: max(1, usable / CGFloat(sortedThumbnailTimes.count)), height: stripHeight)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .opacity(thumbnailGenerator.isGenerating ? 0.6 : 1.0)
                    } else {
                        // Placeholder when loading
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(white: 0.15))
                            .frame(height: stripHeight)
                    }

                    // Playhead (CapCut style - thin white line with caps)
                    TimelinePlayheadView(height: stripHeight)
                        .offset(x: playheadOffset - 1)
                }
                .frame(height: stripHeight)
                .preference(key: TimelineWidthKey.self, value: usable)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDragChanged(value)
                        }
                        .onEnded { _ in
                            handleDragEnded()
                        }
                )
            }
            .frame(height: stripHeight)
            .onPreferenceChange(TimelineWidthKey.self) { width in
                timelineWidth = width
            }
            .padding(.horizontal, 16)

            // Loading indicator
            if thumbnailGenerator.isGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading timeline...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
        .background(
            Color.black.opacity(0.8)
                .ignoresSafeArea(edges: .bottom)
        )
        .onAppear {
            generateThumbnails()
            startTimelineUpdates()
        }
        .onDisappear {
            updateTimer?.invalidate()
            updateTimer = nil
            thumbnailGenerator.cancel()
        }
        .onChange(of: composition) { _, _ in
            generateThumbnails()
        }
    }

    // MARK: - Helpers

    private var sortedThumbnailTimes: [TimeInterval] {
        thumbnailGenerator.thumbnails.keys.sorted()
    }

    private func generateThumbnails() {
        thumbnailGenerator.generateThumbnails(
            from: composition,
            videoComposition: videoComposition,
            count: 20
        )
    }

    private func startTimelineUpdates() {
        // Invalidate any existing timer before creating a new one
        updateTimer?.invalidate()

        // Update playhead position based on current time
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
            guard !isDragging, let player = player else { return }

            let current = player.currentTime().seconds
            currentTime = current
            updatePlayheadOffset(for: current)
        }
    }

    private func updatePlayheadOffset(for time: TimeInterval) {
        guard duration > 0 else { return }
        let progress = min(max(time / duration, 0), 1)
        playheadOffset = timelineWidth * progress
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        isDragging = true

        // Pause during scrubbing
        if isPlaying {
            player?.pause()
        }

        // Calculate new time based on drag position
        let position = value.location.x
        let progress = min(max(position / timelineWidth, 0), 1)
        let newTime = duration * progress

        currentTime = newTime
        playheadOffset = position

        // Seek player
        let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func handleDragEnded() {
        isDragging = false

        // Resume playback if it was playing before
        if isPlaying {
            player?.play()
        }
    }

    private func togglePlayback() {
        guard let player = player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // If at the end, restart from beginning
            if currentTime >= duration - 0.1 {
                let cmTime = CMTime(seconds: 0, preferredTimescale: 600)
                player.seek(to: cmTime)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preference Key

private struct TimelineWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Timeline Playhead (CapCut Style)

private struct TimelinePlayheadView: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            // Shadow/glow for visibility
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.5))
                .frame(width: 4, height: height + 8)
                .blur(radius: 2)

            // Main line
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white)
                .frame(width: 2, height: height + 4)

            // Top/bottom caps
            VStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

                Spacer()

                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .frame(height: height + 8)
        }
        .offset(y: -2)
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var currentTime: TimeInterval = 0
        @State private var isPlaying = false

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack {
                    Spacer()

                    // Mock video preview area
                    Rectangle()
                        .fill(Color.gray)
                        .aspectRatio(9/16, contentMode: .fit)
                        .overlay(
                            Text("Video Preview")
                                .foregroundColor(.white)
                        )

                    // Timeline
                    VideoTimelineView(
                        T: Theme(core: ThemeCore(
                            primary: .blue,
                            accent: .orange,
                            surface: .white,
                            text: .black
                        )),
                        player: nil,
                        composition: mockComposition(),
                        videoComposition: nil,
                        currentTime: $currentTime,
                        isPlaying: $isPlaying
                    )
                }
            }
        }

        private func mockComposition() -> AVMutableComposition {
            let comp = AVMutableComposition()
            // This is just for preview - real usage will have actual video
            return comp
        }
    }

    return PreviewWrapper()
}
