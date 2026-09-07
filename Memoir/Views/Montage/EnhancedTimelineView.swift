//
//  EnhancedTimelineView.swift
//  Memoir
//
//  Timeline for video, audio, captions, and effects
//  Designed to match TikTok/CapCut editing experience with smooth scrolling playhead
//

import SwiftUI
import AVFoundation
import UIKit

// MARK: - Timeline Item Types

enum TimelineItemType: Hashable {
    case video
    case audio
    case caption
    case effect
}

struct TimelineItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let type: TimelineItemType
    var startTime: TimeInterval      // Start position in the montage timeline
    var duration: TimeInterval       // Duration in the montage timeline
    var title: String
    var color: Color
    var lane: Int = 0

    // Video-specific: Reference to source clip (only used for .video type)
    var clipID: UUID?                // The source Clip's ID
    var clipAssetURL: String?        // The source Clip's asset URL
    var clipStartOffset: TimeInterval = 0  // Start offset within the source clip
    var clipDate: Date?              // The clip's date (for ordering/display)
    var isGeneratedDateCaption: Bool = false

    /// Marks that this item was created from a snip operation and should be
    /// rendered as a separate segment from the previous item (not grouped)
    var isSeparatedFromPrevious: Bool = false

    var endTime: TimeInterval {
        startTime + duration
    }

    /// For video items: the end offset within the source clip
    var clipEndOffset: TimeInterval {
        clipStartOffset + duration
    }

    init(id: UUID = UUID(), type: TimelineItemType, startTime: TimeInterval, duration: TimeInterval, title: String, color: Color, lane: Int = 0, clipDate: Date? = nil, isGeneratedDateCaption: Bool = false) {
        self.id = id
        self.type = type
        self.startTime = startTime
        self.duration = duration
        self.title = title
        self.color = color
        self.lane = lane
        self.clipDate = clipDate
        self.isGeneratedDateCaption = isGeneratedDateCaption
    }

    /// Initializer for video timeline items that reference a source clip
    init(id: UUID = UUID(),
         type: TimelineItemType = .video,
         startTime: TimeInterval,
         duration: TimeInterval,
         title: String,
         color: Color,
         lane: Int = 0,
         clipID: UUID,
         clipAssetURL: String,
         clipStartOffset: TimeInterval = 0,
         clipDate: Date? = nil,
         isSeparatedFromPrevious: Bool = false,
         isGeneratedDateCaption: Bool = false) {
        self.id = id
        self.type = type
        self.startTime = startTime
        self.duration = duration
        self.title = title
        self.color = color
        self.lane = lane
        self.clipID = clipID
        self.clipAssetURL = clipAssetURL
        self.clipStartOffset = clipStartOffset
        self.clipDate = clipDate
        self.isSeparatedFromPrevious = isSeparatedFromPrevious
        self.isGeneratedDateCaption = isGeneratedDateCaption
    }

    // Hashable conformance based on id only (for Set membership)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Timeline Configuration

struct TimelineConfiguration {
    var pixelsPerSecond: CGFloat = 50.0  // Default scale
    var minPixelsPerSecond: CGFloat = 20.0
    var maxPixelsPerSecond: CGFloat = 150.0
    var snapThreshold: TimeInterval = 0.1  // Magnetic snap within 0.1s
    var enableSnapping: Bool = true

    /// Metal's max texture size - timeline width should stay under this to avoid rendering errors
    private static let maxTextureWidth: CGFloat = 16384.0

    mutating func zoom(by factor: CGFloat) {
        pixelsPerSecond = min(max(pixelsPerSecond * factor, minPixelsPerSecond), maxPixelsPerSecond)
    }

    /// Clamps pixels per second to ensure timeline width doesn't exceed Metal's max texture size
    mutating func clampForDuration(_ duration: TimeInterval) {
        guard duration > 0 else { return }
        let maxPixelsForDuration = Self.maxTextureWidth / CGFloat(duration)
        if pixelsPerSecond > maxPixelsForDuration {
            pixelsPerSecond = max(minPixelsPerSecond, maxPixelsForDuration)
        }
        // Also adjust max zoom based on duration
        maxPixelsPerSecond = min(150.0, maxPixelsForDuration)
    }
}

// MARK: - Enhanced Timeline View

struct EnhancedTimelineView: View {
    let T: Theme
    let player: AVPlayer?
    let composition: AVComposition
    let videoComposition: AVVideoComposition?

    // Delete action callback - called with the selected items to delete
    var onDelete: ((Set<TimelineItem>) -> Void)? = nil

    // Add audio callback - called when user taps "+ Add audio" placeholder
    var onAddAudio: (() -> Void)? = nil

    // Tap callbacks - called when user taps an audio or caption item to edit
    var onTapAudio: (() -> Void)? = nil
    var onTapCaptions: (() -> Void)? = nil
    var onTapEffects: (() -> Void)? = nil

    @StateObject private var thumbnailGenerator = TimelineThumbnailGenerator()
    @State private var isDragging = false
    @State private var currentTime: TimeInterval = 0
    @State private var timelineConfig = TimelineConfiguration()

    // Timeline items
    @Binding var videoItems: [TimelineItem]   // Video segments (non-destructive)
    @Binding var audioItems: [TimelineItem]
    @Binding var captionItems: [TimelineItem]
    @Binding var effectItems: [TimelineItem]

    // Scrub preview time (nil when not scrubbing)
    @Binding var scrubPreviewTime: TimeInterval?

    // Fullscreen toggle
    @Binding var isVideoFullscreen: Bool
    @Binding var isClipAudioMuted: Bool

    @State private var selectedItemID: UUID?

    // Add state to track playing status
    @State private var isPlaying = false
    @State private var timeObserverToken: Any?  // Store observer token
    @State private var hasPendingThumbnailRefresh = false

    // Scroll-based time tracking
    @State private var isUserScrolling = false
    @State private var isSeeking = false
    @State private var suppressScrollUpdates = false
    @State private var pendingScrollTime: TimeInterval?
    @State private var lastStableTime: TimeInterval = 0

    // Track the actual scroll offset for accurate time sync
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollCommandID: Int = 0
    @State private var scrollCommandAnimated: Bool = false

    // Use player item duration as source of truth (synced with video preview scrubber)
    @State private var playerItemDuration: TimeInterval = 0

    private let videoTrackHeight: CGFloat = 60      // Optimal touch target
    private let auxTrackHeight: CGFloat = 44        // Larger for better interaction
    private let trackSpacing: CGFloat = 4
    private let thumbnailWidth: CGFloat = 48        // Match pixels per second
    private let maxThumbnailsPerSegment: Int = 80  // Reduced from 200 for better performance on long montages
    private let videoStartOffsetTolerance: TimeInterval = 0.001

    /// Duration from player item (preferred) or composition (fallback)
    private var duration: TimeInterval {
        // Use player item duration if available and valid, otherwise fall back to composition
        if playerItemDuration > 0 && playerItemDuration.isFinite {
            return playerItemDuration
        }
        return composition.duration.seconds
    }

    /// Duration of actual video content (excludes end card/branding)
    /// This should match the timeline visual width
    private var videoContentDuration: TimeInterval {
        // Use video items as source of truth for content duration
        guard let maxEnd = videoItems.map(\.endTime).max() else {
            return duration
        }
        let rawDuration = maxEnd - videoStartOffset
        // Clamp to player/composition duration so visuals never exceed playback range.
        return max(0, min(rawDuration, duration))
    }

    private func timeFromScrollOffset(_ offset: CGFloat) -> TimeInterval {
        let time = offset / timelineConfig.pixelsPerSecond
        return max(0, min(time, duration))
    }

    private var videoStartOffset: TimeInterval {
        guard let minStart = videoItems.map(\.startTime).min() else { return 0 }
        return minStart > videoStartOffsetTolerance ? minStart : 0
    }

    /// Extra tail duration from end-card branding (if present).
    private var endCardOffset: TimeInterval {
        let maxVideoEnd = videoContentDuration + videoStartOffset
        return max(0, duration - maxVideoEnd)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// Returns true if there are selected items that can be deleted (audio, caption, or video items)
    private var canDeleteSelectedItems: Bool {
        guard onDelete != nil else { return false }
        return selectedItem != nil
    }

    private var selectedItem: TimelineItem? {
        guard let selectedItemID else { return nil }
        return (audioItems + captionItems + effectItems).first { $0.id == selectedItemID }
    }

    var body: some View {
        GeometryReader { geometry in
            let playheadX = geometry.size.width / 2  // Calculate exact center
            let contentRevision = timelineContentRevision(playheadX: playheadX)

            VStack(spacing: 0) {
                // Top toolbar - CapCut style with time display, play button, and controls
                ZStack {
                    // Left: Fullscreen toggle
                    HStack {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.easeOut(duration: 0.2)) {
                                isVideoFullscreen.toggle()
                            }
                        } label: {
                            Image(systemName: isVideoFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44)
                        Spacer()
                    }

                    // Center: Play button (absolutely centered over playhead)
                    playButton

                    // Right: Delete, Undo, Redo
                    HStack {
                        Spacer()
                        HStack(spacing: 16) {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                if let selectedItem {
                                    onDelete?(Set([selectedItem]))
                                    selectedItemID = nil
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(canDeleteSelectedItems ? Color.red : .white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canDeleteSelectedItems)
                            .accessibilityLabel("Delete selected items")

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Time display row - CapCut style
                HStack {
                    // Show full composition duration (includes end card when watermark is enabled)
                    Text(formatTimeDisplay(currentTime) + " / " + formatTimeDisplay(duration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                // Scrollable timeline container
                ZStack {
                    TimelineScrollView(
                        player: player,
                        isPlaying: isPlaying,
                        pixelsPerSecond: timelineConfig.pixelsPerSecond,
                        contentWidth: duration * timelineConfig.pixelsPerSecond,
                        contentHeight: totalTimelineHeight,
                        leadingPadding: playheadX,
                        trailingPadding: playheadX,
                        contentRevision: contentRevision,
                        scrollOffset: $scrollOffset,
                        scrollCommandID: $scrollCommandID,
                        scrollCommandAnimated: $scrollCommandAnimated,
                        isUserScrolling: $isUserScrolling,
                        onOffsetChange: { newOffset in
                            handleScrollOffsetChange(newOffset: newOffset)
                        },
                        onScrollEnd: { finalOffset in
                            finalizeUserScroll(at: finalOffset)
                        }
                    ) {
                        HStack(spacing: 0) {
                            // Leading padding (half screen width)
                            Color.clear
                                .frame(width: playheadX)

                            ZStack(alignment: .topLeading) {
                                // Main timeline content
                                VStack(alignment: .leading, spacing: 0) {
                                    // Time ruler
                                    timeRuler
                                        .padding(.bottom, 6)

                                    VStack(alignment: .leading, spacing: trackSpacing) {
                                        // Video track (main) with + button
                                        HStack(spacing: 0) {
                                            videoTrack
                                            Spacer(minLength: 0)
                                        }
                                        .overlay(alignment: .trailing) {
                                            // + button on right side - outside scrollable area
                                            // This will be positioned in a fixed overlay later
                                        }
                                        .padding(.bottom, 2)

                                        // "+ Add audio" placeholder when no audio
                                        if audioItems.isEmpty {
                                            addAudioPlaceholder
                                        } else {
                                            multiLaneTrackRow(items: audioItems, baseHeight: auxTrackHeight, color: T.core.accent.opacity(0.8))
                                        }

                                        // Captions track - only show when there are captions
                                        if !captionItems.isEmpty {
                                            multiLaneTrackRow(items: captionItems, baseHeight: auxTrackHeight, color: Color.orange)
                                        }

                                        // Effects track - only show when there are effects
                                        if !effectItems.isEmpty {
                                            multiLaneTrackRow(items: effectItems, baseHeight: auxTrackHeight, color: Color.purple.opacity(0.8))
                                        }
                                    }
                                    .padding(.bottom, 6)
                                }
                            }

                            // Trailing padding (half screen width)
                            Color.clear
                                .frame(width: playheadX)
                        }
                        .simultaneousGesture(
                            // Pinch to zoom gesture
                            MagnificationGesture()
                                .onChanged { scale in
                                    withAnimation(.interactiveSpring()) {
                                        timelineConfig.zoom(by: scale)
                                    }
                                }
                        )
                    }

                    // Full-height playhead indicator (fixed at screen center, not scrolling)
                    playheadIndicator(centerX: playheadX, totalHeight: totalTimelineHeight)

                    // Mute clip audio button - positioned on left, aligned with video track center
                    VStack {
                        // Offset to align with video track center: ruler (18) + padding (6) + half video track (30) = 54
                        Spacer()
                            .frame(height: 18 + 6 + (videoTrackHeight / 2) - 11) // 11 = half button height

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            isClipAudioMuted.toggle()
                        } label: {
                            Image(systemName: isClipAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(isClipAudioMuted ? 0.9 : 0.6))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isClipAudioMuted ? "Unmute clip audio" : "Mute clip audio")

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                }
                .frame(height: totalTimelineHeight)
            }
        }
        .onAppear {
            // Clamp zoom level to prevent Metal texture size overflow on long montages
            timelineConfig.clampForDuration(duration)
            requestThumbnailRefresh()
            startTimeObserver()
            updatePlayingStatus()
            scrollToTime(currentTime, animated: false)
        }
        .onDisappear {
            thumbnailGenerator.cancel()
            hasPendingThumbnailRefresh = false
            stopTimeObserver()
        }
        .onChange(of: composition) { oldValue, newValue in
            // Reset player duration to force use of composition duration until player syncs
            playerItemDuration = 0
            // Clamp zoom level for new duration to prevent Metal texture overflow
            timelineConfig.clampForDuration(newValue.duration.seconds)
            requestThumbnailRefresh()
            isUserScrolling = false
            pendingScrollTime = timeFromScrollOffset(scrollOffset)
        }
        .onChange(of: videoItems) { _, _ in
            requestThumbnailRefresh()
            isUserScrolling = false
            pendingScrollTime = timeFromScrollOffset(scrollOffset)
        }
        .onChange(of: player?.timeControlStatus) { oldValue, newValue in
            updatePlayingStatus()
            handlePlaybackStateForThumbnails()
        }
        .onChange(of: player) { oldPlayer, newPlayer in
            startTimeObserver()
        }
        .onChange(of: player?.currentItem) { oldItem, newItem in
            // Sync duration when player item changes
            syncDurationFromPlayer()
        }
        .onChange(of: currentTime) { oldValue, newValue in
            // Auto-scroll only when not playing (playback handled by display link)
            if !isPlaying {
                handleTimeUpdate(oldTime: oldValue, newTime: newValue)
            }
        }
        .onChange(of: timelineConfig.pixelsPerSecond) { _, _ in
            // Maintain current time position when zooming
            scrollToTime(currentTime, animated: true)
        }
        .onChange(of: pendingScrollTime) { _, newValue in
            guard let targetTime = newValue else { return }
            let targetOffset = targetTime * timelineConfig.pixelsPerSecond
            suppressScrollUpdates = true
            scrollOffset = targetOffset
            scrollToTime(targetTime, animated: false)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                scrollToTime(targetTime, animated: false)
                suppressScrollUpdates = false
            }
            pendingScrollTime = nil
        }
    }

    // MARK: - Smooth Scrolling Handler

    private func handleTimeUpdate(oldTime: TimeInterval, newTime: TimeInterval) {
        // Don't programmatically scroll while user is manually scrolling
        // This prevents the jitter from competing scroll sources
        guard !isUserScrolling else { return }

        // Calculate how much time has elapsed
        let timeDelta = abs(newTime - oldTime)

        // During playback, follow the player position exactly to avoid lag.
        if isPlaying {
            scrollToTime(newTime, animated: false)
        } else if timeDelta < 0.5 {
            scrollToTime(newTime, animated: true)
        } else {
            // For larger jumps (seek, etc.), scroll immediately
            scrollToTime(newTime, animated: false)
        }
    }

    private func scrollToTime(_ time: TimeInterval, animated: Bool) {
        let targetOffset = CGFloat(time) * timelineConfig.pixelsPerSecond
        scrollOffset = targetOffset
        scrollCommandAnimated = animated
        scrollCommandID &+= 1
    }

    // MARK: - Play Button

    private var playButton: some View {
        Button {
            togglePlayPause()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Time Display Formatter

    private func formatTimeDisplay(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Playhead Indicator (Full Height)

    private func playheadIndicator(centerX: CGFloat, totalHeight: CGFloat) -> some View {
        // Simple thin white line - CapCut style
        Rectangle()
            .fill(Color.white)
            .frame(width: 1.5)
            .frame(height: totalHeight)
            .position(x: centerX, y: totalHeight / 2)
            .zIndex(1000)
            .allowsHitTesting(false)
    }

    private var totalTimelineHeight: CGFloat {
        let baseHeight: CGFloat = 18 + 6 + videoTrackHeight + 2 // ruler + padding + video
        // Always show audio row (either placeholder or items)
        let audioHeight = CGFloat(max(audioLaneCount, 1)) * auxTrackHeight + trackSpacing
        let captionHeight = !captionItems.isEmpty ? CGFloat(max(captionLaneCount, 1)) * auxTrackHeight + trackSpacing : 0
        let effectHeight = !effectItems.isEmpty ? CGFloat(max(effectLaneCount, 1)) * auxTrackHeight + trackSpacing : 0
        return baseHeight + audioHeight + captionHeight + effectHeight + 6
    }

    // MARK: - Helper Methods

    private func togglePlayPause() {
        guard let player = player else { return }

        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            isUserScrolling = false
            isSeeking = false
            scrubPreviewTime = nil
            // Always seek to currentTime before playing to ensure player matches timeline position
            // currentTime is set either by the time observer (during playback) or by scroll tracking (when paused)
            let targetTime = currentTime

            // Check if we're at the end and should restart
            if let item = player.currentItem {
                let end = item.duration.seconds
                if end.isFinite && end > 0 && targetTime >= end - 0.1 {
                    // At the end - restart from beginning
                    let seekTime = CMTime.zero
                    player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                        player?.play()
                    }
                    currentTime = 0
                    isPlaying = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    return
                }
            }

            // Seek to the current timeline position before playing
            let seekTime = CMTime(seconds: targetTime, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                player?.play()
            }
            isPlaying = true
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func updatePlayingStatus() {
        if let player = player {
            let isRatePlaying = player.rate > 0
            isPlaying = player.timeControlStatus == .playing || isRatePlaying
        }
    }

    private func stopTimeObserver() {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    // MARK: - Time Ruler

    private var timeRuler: some View {
        // Adaptive marker interval based on duration to reduce view count for long montages
        let markerInterval: Int = {
            if duration > 300 { return 10 }      // > 5 min: every 10 seconds
            else if duration > 120 { return 5 } // > 2 min: every 5 seconds
            else if duration > 60 { return 2 }  // > 1 min: every 2 seconds
            else { return 1 }                    // <= 1 min: every second
        }()
        let markerCount = Int(ceil(duration)) / markerInterval + 1

        return ZStack(alignment: .leading) {
            // Background for the ruler - use full composition duration
            Color.clear
                .frame(width: duration * timelineConfig.pixelsPerSecond, height: 18)

            // Time markers at adaptive intervals
            ForEach(0..<markerCount, id: \.self) { index in
                let second = index * markerInterval
                let xPos = Double(second) * timelineConfig.pixelsPerSecond

                // Time label
                Text(formatTimeCode(Double(second)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .offset(x: xPos)

                // Mid-interval dot marker (only show if interval allows)
                if markerInterval <= 2, Double(second) + Double(markerInterval) / 2.0 <= duration {
                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 3, height: 3)
                        .offset(x: xPos + timelineConfig.pixelsPerSecond * Double(markerInterval) / 2.0, y: 4)
                }
            }
        }
        .frame(height: 18)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: timelineConfig.pixelsPerSecond)
    }

    private func formatTimeCode(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Video Track

    private var videoTrack: some View {
        // Simple continuous filmstrip without segment grouping
        let totalWidth = videoContentDuration * timelineConfig.pixelsPerSecond
        let thumbnailCount = max(1, min(Int(ceil(totalWidth / thumbnailWidth)), maxThumbnailsPerSegment))
        let adjustedThumbnailWidth = totalWidth / CGFloat(thumbnailCount)

        return HStack(spacing: 0) {
            ForEach(0..<thumbnailCount, id: \.self) { index in
                let timeForThumbnail: Double = {
                    if thumbnailCount <= 1 {
                        return videoContentDuration / 2
                    } else {
                        return Double(index) / Double(thumbnailCount - 1) * videoContentDuration
                    }
                }()

                if let closestTime = findClosestThumbnailTime(to: timeForThumbnail),
                   let thumbnail = thumbnailGenerator.thumbnails[closestTime] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: adjustedThumbnailWidth, height: videoTrackHeight)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: adjustedThumbnailWidth, height: videoTrackHeight)
                }
            }
        }
        .frame(width: totalWidth, height: videoTrackHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: timelineConfig.pixelsPerSecond)
    }

    /// Finds the closest available thumbnail time to the target time
    private func findClosestThumbnailTime(to targetTime: TimeInterval) -> TimeInterval? {
        let times = sortedThumbnailTimes
        guard !times.isEmpty else { return nil }

        var low = 0
        var high = times.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = times[mid]
            if value == targetTime {
                return value
            } else if value < targetTime {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if low >= times.count {
            return times.last
        }
        if high < 0 {
            return times.first
        }

        let lowTime = times[low]
        let highTime = times[high]
        return abs(lowTime - targetTime) < abs(highTime - targetTime) ? lowTime : highTime
    }

    // MARK: - Add Audio Placeholder

    private var addAudioPlaceholder: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onAddAudio?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Text("Add audio")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: auxTrackHeight)
            .padding(.leading, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Track Row (Audio, Captions, Effects)

    private var audioLaneCount: Int { max((audioItems.map(\.lane).max() ?? 0) + 1, audioItems.isEmpty ? 0 : 1) }
    private var captionLaneCount: Int { max((captionItems.map(\.lane).max() ?? 0) + 1, captionItems.isEmpty ? 0 : 1) }
    private var effectLaneCount: Int { max((effectItems.map(\.lane).max() ?? 0) + 1, effectItems.isEmpty ? 0 : 1) }

    private func multiLaneTrackRow(items: [TimelineItem], baseHeight: CGFloat, color: Color) -> some View {
        let laneCount = max((items.map(\.lane).max() ?? 0) + 1, 1)
        return VStack(alignment: .leading, spacing: trackSpacing) {
            ForEach(0..<laneCount, id: \.self) { lane in
                ZStack(alignment: .leading) {
                    ForEach(items.filter { $0.lane == lane }) { item in
                        timelineItemView(item: item, height: baseHeight, trackColor: color)
                    }
                }
                .frame(height: baseHeight)
                .frame(width: videoContentDuration * timelineConfig.pixelsPerSecond, alignment: .leading)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: timelineConfig.pixelsPerSecond)
    }

    // MARK: - Timeline Item View

    private func timelineItemView(item: TimelineItem, height: CGFloat, trackColor: Color? = nil) -> some View {
        let isVideoItem = item.type == .video
        let normalizedStartTime = isVideoItem ? max(0, item.startTime - videoStartOffset) : item.startTime
        let startXPos = normalizedStartTime * timelineConfig.pixelsPerSecond
        let itemWidth = item.duration * timelineConfig.pixelsPerSecond
        let isSelected = selectedItemID == item.id
        let color = trackColor ?? item.color
        let isSelectable = !isVideoItem && !item.isGeneratedDateCaption

        return ZStack {
            // Simple colored bar - CapCut style
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            isSelected ? Color.white : Color.clear,
                            lineWidth: isSelected ? 2 : 0
                        )
                )

            // Content area - just the title, left aligned
            HStack(spacing: 0) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.leading, 8)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .frame(width: max(itemWidth, 50), height: height - 8)
        .offset(x: startXPos)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: timelineConfig.pixelsPerSecond)
        .onTapGesture {
            guard isSelectable else { return }
            selectItem(item)
        }
    }

    // MARK: - Gesture Handlers

    private func handleScrollOffsetChange(newOffset: CGFloat) {
        if suppressScrollUpdates {
            return
        }
        // Don't update during playback
        guard !isPlaying else { return }
        // Ignore layout-driven scroll changes unless user is actively scrolling
        guard isUserScrolling else { return }

        scrollOffset = newOffset

        // Update currentTime during scroll
        if isUserScrolling {
            let timeFromScroll = max(0, min(newOffset / timelineConfig.pixelsPerSecond, duration))
            if abs(timeFromScroll - currentTime) > 0.01 {
                currentTime = timeFromScroll
                lastStableTime = timeFromScroll
                scrubPreviewTime = timeFromScroll
            }
        }
    }

    private func finalizeUserScroll(at finalOffset: CGFloat) {
        guard !isPlaying else { return }
        // Use the offset passed directly from the scroll view to avoid state timing issues
        let finalTime = max(0, min(finalOffset / timelineConfig.pixelsPerSecond, duration))
        currentTime = finalTime
        scrollOffset = finalOffset  // Ensure state is in sync
        let cmTime = CMTime(seconds: finalTime, preferredTimescale: 600)
        isSeeking = true
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                self.isSeeking = false
            }
        }
        scrubPreviewTime = nil
    }

    private func selectItem(_ item: TimelineItem) {
        selectedItemID = item.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Open the appropriate sheet when tapping audio/caption items
        switch item.type {
        case .audio:
            onTapAudio?()
        case .caption:
            onTapCaptions?()
        case .effect:
            onTapEffects?()
        default:
            break
        }
    }

    /// Clears all selections
    private func clearAllSelections() {
        selectedItemID = nil
    }

    // MARK: - Helpers

    private var sortedThumbnailTimes: [TimeInterval] {
        thumbnailGenerator.sortedTimes
    }

    private func timelineContentRevision(playheadX: CGFloat) -> Int {
        var hasher = Hasher()
        hasher.combine(quantized(duration))
        hasher.combine(quantized(videoContentDuration))
        hasher.combine(quantized(Double(timelineConfig.pixelsPerSecond)))
        hasher.combine(quantized(Double(playheadX)))
        hasher.combine(thumbnailGenerator.sortedTimes.count)
        hasher.combine(quantized(thumbnailGenerator.sortedTimes.first ?? -1))
        hasher.combine(quantized(thumbnailGenerator.sortedTimes.last ?? -1))
        hasher.combine(selectedItemID)
        combineTimelineItems(videoItems, into: &hasher)
        combineTimelineItems(audioItems, into: &hasher)
        combineTimelineItems(captionItems, into: &hasher)
        combineTimelineItems(effectItems, into: &hasher)
        return hasher.finalize()
    }

    private func combineTimelineItems(_ items: [TimelineItem], into hasher: inout Hasher) {
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.type)
            hasher.combine(quantized(item.startTime))
            hasher.combine(quantized(item.duration))
            hasher.combine(item.title)
            hasher.combine(item.clipID)
            hasher.combine(item.clipAssetURL)
            hasher.combine(quantized(item.clipStartOffset))
            hasher.combine(item.clipDate?.timeIntervalSinceReferenceDate)
            hasher.combine(item.isSeparatedFromPrevious)
            hasher.combine(item.isGeneratedDateCaption)
        }
    }

    private func quantized(_ value: TimeInterval) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 1_000).rounded())
    }

    private func requestThumbnailRefresh() {
        if isPlaying || (player?.rate ?? 0) > 0 {
            thumbnailGenerator.cancel()
            hasPendingThumbnailRefresh = true
            return
        }

        hasPendingThumbnailRefresh = false
        generateThumbnails()
    }

    private func handlePlaybackStateForThumbnails() {
        if isPlaying || (player?.rate ?? 0) > 0 {
            thumbnailGenerator.cancel()
            return
        }

        guard hasPendingThumbnailRefresh else { return }
        hasPendingThumbnailRefresh = false
        generateThumbnails()
    }

    private func generateThumbnails() {
        // Use video content duration (excludes end card) for thumbnail generation
        let contentDur = videoContentDuration

        // Generate enough thumbnails to cover the timeline at max zoom
        // At max zoom (150px/s), we want a thumbnail roughly every 48px (thumbnailWidth)
        // So we need duration * 150 / 48 thumbnails for full coverage
        let maxThumbnails = Int(ceil(contentDur * timelineConfig.maxPixelsPerSecond / thumbnailWidth))
        // Cap at reasonable number for performance (but ensure minimum coverage)
        let count = min(max(maxThumbnails, 20), 100)

        thumbnailGenerator.generateThumbnails(
            from: composition,
            videoComposition: videoComposition,
            count: count,
            contentDuration: contentDur
        )
    }

    private func startTimeObserver() {
        guard let player = player else {
            return
        }

        // Remove existing observer if any
        stopTimeObserver()

        // Sync duration from player item
        syncDurationFromPlayer()


        // Playback scrolling is driven imperatively by CADisplayLink below. Keep SwiftUI
        // state updates lower-frequency so the timeline does not rebuild every frame.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            let timeSeconds = time.seconds

            // Also update duration if it wasn't available before
            if self.playerItemDuration == 0 {
                self.syncDurationFromPlayer()
            }

            // Don't override currentTime while user is dragging or seeking.
            // Allow updates during playback even if scrolling flag is stale.
            let isActuallyPlaying = (self.player?.rate ?? 0) > 0
            if !self.isDragging && !self.isSeeking && (!self.isUserScrolling || self.isPlaying || isActuallyPlaying) {
                if !self.suppressScrollUpdates {
                    self.currentTime = timeSeconds
                    self.lastStableTime = timeSeconds
                }
            }
        }

    }

    /// Sync duration from player item to match video preview scrubber
    private func syncDurationFromPlayer() {
        guard let item = player?.currentItem else { return }
        let dur = item.duration.seconds
        if dur.isFinite && dur > 0 {
            playerItemDuration = dur
        } else {
            // Try async load if not immediately available
            Task {
                if let loaded = try? await item.asset.load(.duration).seconds,
                   loaded.isFinite, loaded > 0 {
                    await MainActor.run {
                        playerItemDuration = loaded
                    }
                }
            }
        }
    }
}

// MARK: - Timeline Scroll View

private struct TimelineScrollView<Content: View>: UIViewRepresentable {
    let player: AVPlayer?
    let isPlaying: Bool
    let pixelsPerSecond: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let contentRevision: Int
    @Binding var scrollOffset: CGFloat
    @Binding var scrollCommandID: Int
    @Binding var scrollCommandAnimated: Bool
    @Binding var isUserScrolling: Bool
    let onOffsetChange: (CGFloat) -> Void
    let onScrollEnd: (CGFloat) -> Void  // Now passes final offset directly
    let content: Content

    init(player: AVPlayer?,
         isPlaying: Bool,
         pixelsPerSecond: CGFloat,
         contentWidth: CGFloat,
         contentHeight: CGFloat,
         leadingPadding: CGFloat,
         trailingPadding: CGFloat,
         contentRevision: Int,
         scrollOffset: Binding<CGFloat>,
         scrollCommandID: Binding<Int>,
         scrollCommandAnimated: Binding<Bool>,
         isUserScrolling: Binding<Bool>,
         onOffsetChange: @escaping (CGFloat) -> Void,
         onScrollEnd: @escaping (CGFloat) -> Void,
         @ViewBuilder content: () -> Content) {
        self.player = player
        self.isPlaying = isPlaying
        self.pixelsPerSecond = pixelsPerSecond
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.contentRevision = contentRevision
        self._scrollOffset = scrollOffset
        self._scrollCommandID = scrollCommandID
        self._scrollCommandAnimated = scrollCommandAnimated
        self._isUserScrolling = isUserScrolling
        self.onOffsetChange = onOffsetChange
        self.onScrollEnd = onScrollEnd
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.bounces = true
        scrollView.delegate = context.coordinator

        let host = context.coordinator.hostingController
        host.view.backgroundColor = .clear
        scrollView.addSubview(host.view)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let totalWidth = leadingPadding + contentWidth + trailingPadding
        let host = context.coordinator.hostingController
        context.coordinator.parent = self
        if context.coordinator.lastContentRevision != contentRevision {
            context.coordinator.lastContentRevision = contentRevision
            host.rootView = content
        }
        let contentSize = CGSize(width: totalWidth, height: contentHeight)
        if context.coordinator.lastContentSize != contentSize {
            context.coordinator.lastContentSize = contentSize
            host.view.frame = CGRect(origin: .zero, size: contentSize)
            scrollView.contentSize = contentSize
        }

        context.coordinator.updatePlayback(
            player: player,
            isPlaying: isPlaying,
            pixelsPerSecond: pixelsPerSecond
        )

        if context.coordinator.lastScrollCommandID != scrollCommandID {
            context.coordinator.lastScrollCommandID = scrollCommandID
            context.coordinator.isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: scrollOffset, y: 0), animated: scrollCommandAnimated)
            DispatchQueue.main.async {
                context.coordinator.isProgrammaticScroll = false
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        var parent: TimelineScrollView
        var isProgrammaticScroll = false
        var lastScrollCommandID: Int = 0
        var lastContentRevision: Int?
        var lastContentSize: CGSize = .zero
        weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private weak var player: AVPlayer?
        private var isPlaying: Bool = false
        private var pixelsPerSecond: CGFloat = 0
        private var lastOffset: CGFloat = 0

        init(parent: TimelineScrollView) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
        }

        func updatePlayback(player: AVPlayer?, isPlaying: Bool, pixelsPerSecond: CGFloat) {
            self.player = player
            self.isPlaying = isPlaying
            self.pixelsPerSecond = pixelsPerSecond

            if isPlaying {
                startDisplayLinkIfNeeded()
            } else {
                stopDisplayLink()
            }
        }

        private func startDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func handleDisplayLink() {
            guard let scrollView = scrollView else { return }
            guard isPlaying, let player = player else { return }
            guard !parent.isUserScrolling else { return }

            let timeSeconds = player.currentTime().seconds
            if !timeSeconds.isFinite { return }

            let targetOffset = CGFloat(timeSeconds) * pixelsPerSecond
            if abs(targetOffset - lastOffset) < 0.25 {
                return
            }

            lastOffset = targetOffset
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: targetOffset, y: 0), animated: false)
            isProgrammaticScroll = false
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // Defer state modification to avoid "Modifying state during view update" error
            DispatchQueue.main.async {
                self.parent.isUserScrolling = true
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            let offset = scrollView.contentOffset.x
            // Defer state modification to avoid "Modifying state during view update" error
            DispatchQueue.main.async {
                self.parent.scrollOffset = offset
                self.parent.onOffsetChange(offset)
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                let finalOffset = scrollView.contentOffset.x
                // Defer state modification to avoid "Modifying state during view update" error
                DispatchQueue.main.async {
                    self.parent.scrollOffset = finalOffset
                    self.parent.isUserScrolling = false
                    self.parent.onScrollEnd(finalOffset)  // Pass final offset directly
                }
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            let finalOffset = scrollView.contentOffset.x
            // Defer state modification to avoid "Modifying state during view update" error
            DispatchQueue.main.async {
                self.parent.scrollOffset = finalOffset
                self.parent.isUserScrolling = false
                self.parent.onScrollEnd(finalOffset)  // Pass final offset directly
            }
        }

        deinit {
            stopDisplayLink()
        }
    }
}
