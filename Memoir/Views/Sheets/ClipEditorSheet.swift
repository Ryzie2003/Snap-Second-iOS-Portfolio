//
//  ClipEditorSheet.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/11/25.
//

import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import PhosphorSwift

// In ClipEditorSheet.swift (add at top-level)
private struct EditorSourceLocalIDKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues { var _editorSourceLocalID: String? {
    get { self[EditorSourceLocalIDKey.self] }
    set { self[EditorSourceLocalIDKey.self] = newValue }
}}

// PreviewFill enum is defined in DayPreviewHelpers.swift

struct ClipEditorSheet: View {
    // Required
    let project: Project
    let date: Date

    // Either pass a source URL (new) OR a clip to edit (existing)
    let initialURL: URL?
    let editingClip: Clip?
    let sourceLocalID: String?

    @State private var previewFill: PreviewFill = .portrait
    @State private var shouldInferPreviewFill = false

    private enum EditorTab: Hashable { case length, orientation, caption }
    private enum PreviewPlayMode: String, CaseIterable, Identifiable {
        case snippet = "Snippet"
        case full = "Full"
        var id: String { rawValue }
    }

    @State private var playMode: PreviewPlayMode = .snippet


    @State private var selectedTab: EditorTab = .length
    @State private var fitFill: Bool = false     // false = Fit (letterbox), true = Fill (crop). Affects preview only.


    // Return (fileURL, thumb, duration, snippetStart, sourceLocalID, rotationDegrees, previewFillRaw, zoomScale, panOffset)
    var onSave: (URL, UIImage, Double, Double, String?, Double, String, Double, CGPoint) -> Void
    var onCancel: () -> Void
    var batchIndex: Int? = nil
    var batchTotal: Int? = nil
    var onPerClipCaptionChange: ((String?) -> Void)? = nil

    @State private var player: AVPlayer?
    @State private var assetURL: URL?
    @State private var assetDuration: Double = 0
    @State private var clipStart: Double = 0

    @State private var crop: CropPreset = .original
    @State private var isExporting = false
    @State private var isSeeding = false

    // Snippet selection via range scrubber
    @State private var clipRange: ClosedRange<Double> = 0...ClipDefaults.duration
    private let minSpan: Double = 0.5
    private let maxSpan: Double = 5.0
    private var defaultSpan: Double { ClipDefaults.duration }
    private let photoEditableDuration: Double = 4.0
    @State private var clipLength: Double = ClipDefaults.duration   // default window size (s)

    private var defaultPreviewFill: PreviewFill {
        PreviewFill(rawValue: ClipDefaults.orientationRaw) ?? .portrait
    }

    @MainActor
    private func applyInferredPreviewFillIfNeeded() {
        guard shouldInferPreviewFill else { return }
        guard sourceAspect.isFinite, sourceAspect > 0 else { return }

        let ar = sourceAspect
        let delta = abs(ar - 1.0)
        if delta <= 0.08 {
            previewFill = .square
        } else {
            previewFill = ar >= 1.0 ? .landscape : .portrait
        }
        shouldInferPreviewFill = false
    }

    private func clampSpan(_ value: Double) -> Double {
        max(minSpan, min(maxSpan, value))
    }

    private func preferredSpan(for clip: Clip?) -> Double {
        let raw = (clip?.duration ?? 0) > 0 ? (clip?.duration ?? defaultSpan) : defaultSpan
        return clampSpan(raw)
    }

    private func preferredStart(for clip: Clip?) -> Double {
        max(0, clip?.snippetStart ?? 0)
    }

    @State private var isPhotoSource: Bool = false
    @State private var photoImage: UIImage? = nil

    @State private var showPlayOverlay = true          // already present; keep using it
    @State private var timeObserver: Any?
    @State private var boundaryObserver: Any?
    @State private var itemEndObserver: NSObjectProtocol?
    @State private var pendingSeek: DispatchWorkItem?

    @State private var sourceAspect: CGFloat = 9.0/16.0

    // Add near your other @State vars
    @State private var currentTime: Double = 0
    @State private var thumbnails: [UIImage] = []

    @State private var showLengthAlert = false
    @State private var lengthAlertText = ""

    @State private var photoBuildTask: Task<Void, Never>? = nil

    // ✅ NEW: Rotation state (in 90° increments)
    @State private var rotationDegrees: Double = 0  // 0, 90, 180, 270

    // ✅ NEW: Zoom/Crop state
    @State private var zoomScale: Double = 1.0  // 1.0 = no zoom, 3.0 = 3x zoom
    @State private var panOffset: CGPoint = .zero  // normalized pan offset (-1...1)
    @State private var dragStartOffset: CGPoint = .zero  // Track offset at drag start
    @State private var lastZoomScale: Double = 1.0  // Track zoom scale at gesture start
    private let minZoom: Double = 1.0
    private let maxZoom: Double = 3.0

    @State private var captionTextDraft: String = ""
    @FocusState private var captionFieldFocused: Bool
    private enum CaptionPos3 { case bottomLeft, bottomCenter, bottomRight }
    @State private var perClipPreviewPos: CaptionPos3 = .bottomLeft

    private var perClipOverlayAlignment: Alignment {
        switch perClipPreviewPos {
        case .bottomLeft:   return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight:  return .bottomTrailing
        }
    }


    private let lengthChipValues: [Double] =
        Array(stride(from: 0.5, through: 5.0, by: 0.5))

    @State private var showZoomIndicator = false
    @State private var zoomIndicatorTask: Task<Void, Never>?
    @State private var showModeBadge = false
    @State private var showZoomHint = false
    @State private var hasShownZoomHint = false
    @State private var zoomHintTask: Task<Void, Never>?

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    // MARK: - Playback controls (full-clip preview + overlay)

    // Helper to clamp pan offset based on current zoom level
    private func clampPanOffset() {
        let maxPan = (zoomScale - 1.0) / zoomScale
        panOffset.x = max(-maxPan, min(maxPan, panOffset.x))
        panOffset.y = max(-maxPan, min(maxPan, panOffset.y))
    }

    private func playAccordingToMode() {
        guard let p = player else { return }

        switch playMode {
        case .snippet:
            // Always start at the selection start
            let start = clipRange.lowerBound
            seek(to: start)
            currentTime = start

            // Install looping boundary at selection end
            installEndObserversForCurrentRange()
            p.play()
            showPlayOverlay = false

        case .full:
            // Full playback: resume, and if at end restart from 0
            if let item = p.currentItem {
                let here = CMTimeGetSeconds(p.currentTime())
                let fullEnd = assetDuration > 0 ? assetDuration : CMTimeGetSeconds(item.duration)
                if here.isNaN || here >= fullEnd - 0.05 {
                    seek(to: 0)
                    currentTime = 0
                }
            }
            // Ensure no snippet boundary observer remains
            installEndObserversForCurrentRange()
            p.play()
            showPlayOverlay = false
        }
    }

    private func togglePlayPause() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing {
            p.pause()
            showPlayOverlay = true
        } else {
            playAccordingToMode()
        }
    }

    private func seek(to seconds: Double) {
        guard let p = player else { return }
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - End handling (no looping)
    // Selection no longer controls playback end – we only stop when the clip ends.
    // Keep this as a small cleanup helper so existing calls remain safe.
    private func installEndObserversForCurrentRange() {
        guard let p = player else { return }

        // Remove any existing boundary observer
        if let token = boundaryObserver {
            p.removeTimeObserver(token)
            boundaryObserver = nil
        }

        // Only install a boundary time observer in Snippet mode (to loop)
        guard playMode == .snippet else { return }

        let end = clipRange.upperBound
        guard end.isFinite, end > 0 else { return }

        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        boundaryObserver = p.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak p] in
            guard let p else { return }
            let start = self.clipRange.lowerBound
            self.seek(to: start)
            self.currentTime = start
            p.play()
            self.showPlayOverlay = false
        }
    }



    @MainActor
    private func installItemEndNotification() {
        // Remove any previous observer tied to an older item
        if let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
        guard let item = player?.currentItem else { return }

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            // No looping in ClipEditor: when item ends, reveal the play button
            showPlayOverlay = true
        }
    }

    @MainActor
    private func stopPlayback() {
        player?.pause()
        showPlayOverlay = true
    }

    private var editorPreview: some View {
        // Compute display container AR + gravity
        let orientedAR = max(sourceAspect, .leastNonzeroMagnitude)
        var cfg = displayConfig(mode: previewFill, sourceAR: sourceAspect, quarterTurns: .t0)

        // Let user force Fit/Fill for portrait/landscape; square stays Fill (crop)
        if previewFill != .square {
            cfg = (containerAR: cfg.containerAR,
                   gravity:     (fitFill ? .resizeAspectFill : .resizeAspect))
        }

        let radius: CGFloat = 12

        return ZStack {
            if let p = player {
                // Fixed-size container that doesn't change
                GeometryReader { geo in
                    let size = geo.size
                    let panX = panOffset.x * (size.width / 2) * zoomScale
                    let panY = panOffset.y * (size.height / 2) * zoomScale
                    PlayerFillView(player: p, gravity: cfg.gravity)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoomScale)  // ✅ Apply zoom (scales content, not container)
                        .offset(
                            x: panX,
                            y: panY
                        )  // ✅ Apply pan
                        .rotationEffect(.degrees(rotationDegrees))  // ✅ Apply rotation
                        .gesture(
                            // Pinch to zoom gesture
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = lastZoomScale * value
                                    zoomScale = max(minZoom, min(maxZoom, newScale))

                                    // Clamp pan offset as zoom changes to prevent out-of-bounds
                                    clampPanOffset()

                                    // Auto-recenter when returning to 1x
                                    if zoomScale <= 1.0 {
                                        zoomScale = 1.0
                                        panOffset = .zero
                                        dragStartOffset = .zero
                                    }

                                    // Show zoom indicator
                                    showZoomIndicator = true
                                    zoomIndicatorTask?.cancel()
                                    showZoomHint = false
                                    zoomHintTask?.cancel()
                                    hasShownZoomHint = true
                                }
                                .onEnded { value in
                                    lastZoomScale = zoomScale
                                    clampPanOffset()

                                    if zoomScale <= 1.0 {
                                        zoomScale = 1.0
                                        panOffset = .zero
                                        dragStartOffset = .zero
                                    }

                                    // Hide zoom indicator after a delay
                                    zoomIndicatorTask?.cancel()
                                    zoomIndicatorTask = Task {
                                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                                        await MainActor.run {
                                            showZoomIndicator = false
                                        }
                                    }
                                }
                        )
                        .simultaneousGesture(
                            // Drag to pan gesture
                            DragGesture()
                                .onChanged { value in
                                    // Only allow panning when zoomed in
                                    guard zoomScale > 1.0 else { return }

                                    let denomX = max(1, (size.width / 2) * zoomScale)
                                    let denomY = max(1, (size.height / 2) * zoomScale)
                                    let newX = dragStartOffset.x + value.translation.width / denomX
                                    let newY = dragStartOffset.y + value.translation.height / denomY

                                    // Calculate maximum pan offset based on zoom level
                                    // At 1.0x zoom, no pan is possible (max = 0)
                                    // At 3.0x zoom, you can pan more but still limited
                                    let maxPan = (zoomScale - 1.0) / zoomScale

                                    panOffset.x = max(-maxPan, min(maxPan, newX))
                                    panOffset.y = max(-maxPan, min(maxPan, newY))
                                    showZoomHint = false
                                    zoomHintTask?.cancel()
                                    hasShownZoomHint = true
                                }
                                .onEnded { _ in
                                    dragStartOffset = panOffset
                                }
                        )
                        .onAppear {
                            lastZoomScale = zoomScale
                            dragStartOffset = panOffset
                            if !hasShownZoomHint {
                                showZoomHint = true
                                zoomHintTask?.cancel()
                                zoomHintTask = Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    await MainActor.run {
                                        showZoomHint = false
                                    }
                                }
                                hasShownZoomHint = true
                            }
                        }
                        .highPriorityGesture(
                            TapGesture().onEnded { togglePlayPause() }
                        )
                }
                .aspectRatio(cfg.containerAR, contentMode: .fit)
                .background(T.core.surface)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(T.border, lineWidth: 1)
                )
            } else {
                Color(T.core.surface)
                    .aspectRatio(cfg.containerAR, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .overlay(
                      RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(T.border, lineWidth: 1)
                    )
            }

            // Zoom indicator overlay
            if showZoomIndicator {
                VStack(spacing: 4) {
                    Image(systemName: zoomScale > lastZoomScale ? "plus.magnifyingglass" : "minus.magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(String(format: "%.1f", zoomScale))×")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(radius: 8, y: 2)
                .transition(.scale.combined(with: .opacity))
            }

            // Subtle hint overlay (gestures only)
            if showZoomHint {
                Text("Pinch to zoom · Drag to reposition")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 8, y: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if showPlayOverlay, player != nil {
                Button {
                    playAccordingToMode()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(T.core.accent)
                        .shadow(radius: 4, y: 2)
                        .accessibilityLabel("Play")
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showZoomIndicator)
        .animation(.easeInOut(duration: 0.2), value: showZoomHint)
        .overlay(alignment: perClipOverlayAlignment) {
            Text(captionTextDraft)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .padding(.leading, 4)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // Show zoom/pan active indicator
            if zoomScale > 1.0 || panOffset != .zero {
                HStack(spacing: 4) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Zoom Active")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.leading, 16)
                .padding(.top, 12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if zoomScale > 1.0 || panOffset != .zero {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        zoomScale = 1.0
                        panOffset = .zero
                        lastZoomScale = 1.0
                        dragStartOffset = .zero
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.top, 12)
            }
        }
    }


    @ViewBuilder
    private var optionsShelf: some View {
        switch selectedTab {
        case .length:
            lengthShelf
        case .orientation:
            orientationShelf
        case .caption:
            captionShelf
        }
    }

    private var lengthShelf: some View {
        VStack(spacing: 10) {
            Picker("", selection: $playMode) {
                ForEach(PreviewPlayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .tint(T.core.accent)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(maxWidth: 220)
            .padding(.horizontal, 12)
            .onChange(of: playMode) { _ in
                // If user toggles while playing, restart playback in the new mode
                if player?.timeControlStatus == .playing {
                    playAccordingToMode()
                } else {
                    // Keep the paused frame sensible in Snippet mode
                    if playMode == .snippet {
                        seek(to: clipRange.lowerBound)
                        currentTime = clipRange.lowerBound
                        showPlayOverlay = true
                    }
                    // Ensure observers match the mode
                    installEndObserversForCurrentRange()
                }
            }

            FixedWindowScrubber(
                start: Binding(
                    get: { clipRange.lowerBound },
                    set: { newStart in
                        let clamped = max(0, min(newStart, max(0, assetDuration - clipLength)))
                        clipRange = clamped...(min(assetDuration, clamped + clipLength))
                    }
                ),
                length: clipLength,
                total: max(0.001, assetDuration),
                thumbnails: thumbnails,
                current: currentTime
            )
            .frame(height: 56)
            .padding(.horizontal, 12)
            .disabled(assetDuration <= 0)

            // Helper hint
            Text("Pick a length, then drag the box to your moment. Tap preview to play/pause (loops selection).")
              .font(.system(size: 13, weight: .regular, design: .rounded))
              .foregroundStyle(T.textSecondary)
              .padding(.horizontal, 12)

            // Length chips (your exact logic, just lifted here)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(lengthChipValues, id: \.self) { len in
                        let invalid = (!isPhotoSource) && assetDuration > 0 && len > assetDuration
                        Button {
                            if invalid {
                                lengthAlertText = "This media is \(timeString(assetDuration)) long. Choose ≤ \(String(format: "%.1f", assetDuration))s."
                                showLengthAlert = true
                                return
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if isPhotoSource {
                                clipLength = len
                                clipRange  = 0...len
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                    clipLength = len
                                    let maxStart = max(0, assetDuration - clipLength)
                                    let newStart = min(clipRange.lowerBound, maxStart)
                                    clipRange    = newStart...(min(assetDuration, newStart + clipLength))
                                }
                            }
                        } label: {
                            let isActive = abs(clipLength - len) < 0.001
                            Text("\(len, specifier: "%.1f")s")
                              .font(.system(size: 15, weight: .semibold, design: .rounded))
                              .monospacedDigit()
                              .padding(.vertical, 8).padding(.horizontal, 12)
                              .background(
                                Capsule().fill(
                                  invalid ? T.border.opacity(0.20)
                                  : (isActive ? T.core.accent : T.core.text.opacity(0.08))
                                )
                              )
                              .foregroundStyle(invalid ? T.textSecondary : (isActive ? .white : T.core.text))
                              .overlay(invalid ? Capsule().stroke(T.border, lineWidth: 1) : nil)
                          }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .alert("Length too long", isPresented: $showLengthAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(lengthAlertText) }
            .onChange(of: clipRange) { _ in
                if player?.timeControlStatus == .playing {
                    if playMode == .snippet {
                        installEndObserversForCurrentRange() // update loop end
                    }
                    return
                }

                // If paused: debounce seek so the frozen frame matches the start of the selection.
                pendingSeek?.cancel()
                let work = DispatchWorkItem { [clipStart = clipRange.lowerBound] in
                    seek(to: clipStart)
                    currentTime = clipStart
                    showPlayOverlay = true  // still paused → overlay stays visible
                }
                pendingSeek = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }

        .onChange(of: clipLength) { newLen in
            guard isPhotoSource, let img = photoImage else { return }
            photoBuildTask?.cancel()
            isSeeding = true
            photoBuildTask = Task {
                let out = try? await makeVideo(from: img, duration: newLen, fps: 20)
                if Task.isCancelled { return }
                if let out {
                    await setPlayer(url: out, start: 0)
                    await MainActor.run {
                        clipRange = 0...newLen
                        isSeeding = false
                    }
                } else {
                    await MainActor.run { isSeeding = false }
                }
            }
        }
    }


    private var orientationShelf: some View {
        VStack(spacing: 10) {
            Picker("Frame", selection: $previewFill) {
                ForEach(PreviewFill.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
              .tint(T.core.accent)
              .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)

            // Fit / Fill toggle for portrait/landscape
            if previewFill != .square {
                Picker("", selection: $fitFill) {
                    Text("Fit").tag(false)
                    Text("Fill").tag(true)
                }
                .pickerStyle(.segmented)
                  .tint(T.core.accent)
                  .font(.system(size: 14, weight: .semibold, design: .rounded))
                  .labelsHidden()
                  .frame(maxWidth: 240, minHeight: 32)
            }

            // ✅ NEW: Rotation controls
            VStack(spacing: 8) {
                Text("Rotate")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    // Rotate CCW (counter-clockwise)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            rotationDegrees -= 90
                            if rotationDegrees < 0 { rotationDegrees += 360 }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Ph.arrowCounterClockwise.regular
                                .frame(width: 20, height: 20)
                            Text("CCW")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(T.core.text)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(T.core.text.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)

                    // Reset to 0°
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            rotationDegrees = 0
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(Int(rotationDegrees))°")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("Reset")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(rotationDegrees == 0 ? T.textSecondary : T.core.accent)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(rotationDegrees == 0 ? T.core.text.opacity(0.04) : T.core.accent.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(rotationDegrees == 0)

                    // Rotate CW (clockwise)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            rotationDegrees += 90
                            if rotationDegrees >= 360 { rotationDegrees -= 360 }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Ph.arrowClockwise.regular
                                .frame(width: 20, height: 20)
                            Text("CW")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(T.core.text)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(T.core.text.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .onChange(of: previewFill) { _ in
            if !isSeeding { shouldInferPreviewFill = false }
            // Show a small badge like you had
            showModeBadge = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { showModeBadge = false }
        }
    }

    private var captionShelf: some View {
        VStack(spacing: 10) {
            // Input row styled like chips/shelves
            HStack(spacing: 10) {
                Ph.textAa.regular
                    .frame(width: 32, height: 32)
                    .foregroundStyle(T.core.text)

                TextField("Add caption…", text: $captionTextDraft)
                    .lineLimit(1)
                    .textInputAutocapitalization(.sentences)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .focused($captionFieldFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        captionFieldFocused = false
                        hideKeyboard()
                    }


                if !captionTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        captionTextDraft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(T.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onChange(of: captionTextDraft) { new in
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    onPerClipCaptionChange?(trimmed.isEmpty ? nil : trimmed)
                }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(T.core.text.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(T.border, lineWidth: 1)
            )
            .padding(.horizontal, 12)
        }
        .onChange(of: captionTextDraft) { new in
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            onPerClipCaptionChange?(trimmed.isEmpty ? nil : trimmed)
        }
    }

    private var cropShelf: some View {
        VStack(spacing: 16) {
            // Current zoom level indicator
            HStack {
                Text("Zoom Level")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(T.core.text)
                Spacer()
                Text("\(String(format: "%.1f", zoomScale))x")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(T.core.accent)
            }
            .padding(.horizontal, 12)

            // Instructions
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "hand.pinch")
                        .font(.system(size: 20))
                        .foregroundStyle(T.core.accent)
                        .frame(width: 32)

                    Text("Pinch on the preview to zoom in and out")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(T.core.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if zoomScale > 1.0 {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.drag")
                            .font(.system(size: 20))
                            .foregroundStyle(T.core.accent)
                            .frame(width: 32)

                        Text("Drag the preview to reposition")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(T.core.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(T.core.text.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(T.border.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 12)

            // Reset button
            if zoomScale != 1.0 || panOffset != .zero {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        zoomScale = 1.0
                        panOffset = .zero
                        lastZoomScale = 1.0
                        dragStartOffset = .zero
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Reset Zoom & Position")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(T.core.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
    }


    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Length = scissors / trim vibe
            barItem(.length, Ph.timer.regular, "Length")

            // Orientation = crop
            barItem(.orientation, Ph.crop.regular, "Orientation")

            // Caption = same textAa icon you use in the caption shelf
            barItem(.caption, Ph.textAa.regular, "Caption")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func barItem<Icon: View>(_ tab: EditorTab, _ icon: Icon, _ title: String) -> some View {
        let isSel = (selectedTab == tab)
        Button { selectedTab = tab } label: {
            VStack(spacing: 4) {
                icon
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(isSel ? T.core.primary : T.core.text)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSel ? T.core.primary.opacity(0.12) : T.core.text.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSel ? T.core.primary : T.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSel)
    }



    var body: some View {

        NavigationStack {
            VStack(spacing: 12) {
                // TOP: Always-visible preview
                editorPreview
            }
            // Bottom controls like Montage
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    optionsShelf                      // ⬅️ active shelf content
                        .padding(.top, 8)
                    bottomBar
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            .onChange(of: selectedTab) { tab in
                captionFieldFocused = (tab == .caption)   // focus only on caption shelf
            }
            .navigationTitle(batchIndex != nil && batchTotal != nil
                    ? "Edit Clip (\(batchIndex! + 1) of \(batchTotal!))"
                    : "Edit Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { await stopPlayback() }
                        onCancel()
                    }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await exportAndSave() } } label: {
                      Text(isExporting ? "Saving…" : "Save")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .disabled(player == nil || isExporting)
                }
                ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            captionFieldFocused = false
                            hideKeyboard()
                        }
                    }
            }
            .overlay(alignment: .center) {
                if isExporting || isSeeding {
                    ZStack {
                        T.core.surface.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 12) {
                          ProgressView()
                          Text(isExporting ? "Exporting…" : "Loading…")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(T.textSecondary)
                        }
                        .padding(16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .task { await seedEditor() }
            .onDisappear {
                player?.pause()
                if let token = timeObserver, let p = player { p.removeTimeObserver(token); timeObserver = nil }
                if let token = boundaryObserver, let p = player { p.removeTimeObserver(token); boundaryObserver = nil }
            }
        }
        .background(T.core.surface)
        .ignoresSafeArea()                         // ← add this
        .tint(T.core.text)
        .toolbarBackground(T.core.surface, for: .navigationBar)
        .toolbarBackground(.visible,          for: .navigationBar)
    }


    private func exportAndSave() async {
        await stopPlayback()
        let url: URL
        do { url = try await resolveSourceURL() } catch { print(error); return }

        isExporting = true
        defer { isExporting = false }

        do {
            let start    = clipRange.lowerBound
            let duration = max(minSpan, min(maxSpan, clipRange.upperBound - clipRange.lowerBound))

            let selectedCrop: CropPreset = {
                switch previewFill {
                case .portrait:  return .portrait9x16
                case .landscape: return .landscape16x9
                case .square:    return .square1x1
                }
            }()

            // Keep square always Fill to match preview behavior (no letterboxing)
            let mode: ScaleMode = (previewFill == .square) ? .fill : (fitFill ? .fill : .fit)

            // ✅ Convert rotation degrees to QuarterTurns enum
            let rotationQuarterTurns: QuarterTurns = {
                let normalized = Int(rotationDegrees) % 360
                switch normalized {
                case 90:  return .t1  // 90° clockwise
                case 180: return .t2  // 180°
                case 270: return .t3  // 270° clockwise (90° counter-clockwise)
                default:  return .t0  // 0° or any other value
                }
            }()

            // Export with zoom/pan applied
            let out = try await VideoEditEngine.exportEdited(
                inputURL: url,
                snippetStart: start,
                snippetDuration: duration,
                rotate: rotationQuarterTurns,
                crop: selectedCrop,
                mode: mode,
                captionText: captionTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : captionTextDraft,
                perClipCaptionAnchor: {
                    switch perClipPreviewPos {
                    case .bottomLeft:   return .bottomLeft
                    case .bottomCenter: return .bottomCenter
                    case .bottomRight:  return .bottomRight
                    }
                }(),
                zoomScale: zoomScale,
                panOffsetX: panOffset.x,
                panOffsetY: panOffset.y
            )


            let av = AVURLAsset(url: out)
            let exportedDur = CMTimeGetSeconds(av.duration)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            let cg = try? gen.copyCGImage(at: CMTime(seconds: min(0.25, max(0.2, duration/2)), preferredTimescale: 600), actualTime: nil)
            let thumb = cg.map { UIImage(cgImage: $0) } ?? UIImage()

            // Try to carry the Photos localID if known (when initialURL came from Suggestions/Library)

            onSave(out, thumb, exportedDur, clipRange.lowerBound, sourceLocalID, rotationDegrees, previewFill.rawValue, zoomScale, panOffset)
        } catch {
            print("[ClipEditorSheet] export error:", error)
        }
    }

    // This var is just a placeholder; DayPreviewView will pass a binding via initializer
    private var _tempSourceLocalID: String? { nil }

    // MARK: - Seeding (video or photo)
    private func seedEditor() async {
        await MainActor.run { isSeeding = true }
        defer { Task { await MainActor.run { isSeeding = false } } }
        let desiredSpan = preferredSpan(for: editingClip)
        let desiredStart = preferredStart(for: editingClip)

        await MainActor.run {
            if let editingClip {
                shouldInferPreviewFill = (editingClip.previewFillRaw == nil)
                if editingClip.previewFillRaw != nil {
                    previewFill = editingClip.previewFillValue
                } else {
                    previewFill = .portrait
                }
            } else {
                shouldInferPreviewFill = false
                previewFill = defaultPreviewFill
            }
            clipLength = desiredSpan
        }

        // ✅ 1) EDITING FLOW: prefer original Photos asset if available
        if let editingClip, player == nil {

            // Seed caption draft from the existing clip (text-only per-clip caption)
            await MainActor.run {
                captionTextDraft = editingClip.captionText ?? ""
                rotationDegrees = editingClip.rotationDegrees  // ✅ Load saved rotation

                // ✅ Load saved zoom/crop values (0 treated as 1.0 - Core Data default issue)
                zoomScale = editingClip.zoomScale > 0 ? editingClip.zoomScale : 1.0
                panOffset = CGPoint(x: editingClip.panOffsetX, y: editingClip.panOffsetY)
                dragStartOffset = panOffset

                print("📐 Loaded zoom/crop: scale=\(zoomScale), pan=\(panOffset)")
            }

            if let id = editingClip.sourceLocalID,                    // <-- prefer original
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {

                if asset.mediaType == .video {
                    let opts = PHVideoRequestOptions()
                    opts.deliveryMode = .highQualityFormat
                    opts.isNetworkAccessAllowed = true
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                            guard let av = avAsset else { cont.resume(); return }
                            Task { @MainActor in
                                isPhotoSource = false
                                photoImage = nil
                                await setPlayer(asset: av, start: desiredStart)
                                cont.resume()
                            }
                        }
                    }
                    return
                } else {
                    // Live Photo or still → treat like your existing "localIdentifier path"
                    if isLivePhoto(asset) {
                        do {
                            let url = try await exportPairedVideo(for: asset)
                            await MainActor.run {
                                isPhotoSource = false
                                photoImage = nil
                            }
                            await setPlayer(url: url, start: desiredStart)
                            return
                        } catch {
                            print("[ClipEditorSheet] Failed to extract Live Photo video: \(error)")
                        }
                    }
                    // As a still photo, rebuild a temp video for preview as you already do elsewhere
                    let opts = PHImageRequestOptions()
                    opts.deliveryMode = .highQualityFormat
                    opts.isSynchronous = false
                    opts.isNetworkAccessAllowed = true
                    PHImageManager.default().requestImageDataAndOrientation(
                        for: asset, options: opts
                    ) { data, _, _, _ in
                        Task {
                            if let data, let raw = UIImage(data: data) {
                                let img = uprightImage(raw)
                                if let out = try? await makeVideo(from: img, duration: clipLength) {
                                    await setPlayer(url: out, start: desiredStart)
                                    await MainActor.run {
                                        isPhotoSource = true
                                        photoImage = img
                                        clipRange = 0...clipLength
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            }

            // ❇️ Fallback: no sourceLocalID → use exported/trimmed file on disk (existing behavior)
            let url = ClipStore.shared.urlForClip(editingClip)
            await setPlayer(url: url, start: 0)
            await MainActor.run {
                isPhotoSource = false
                photoImage = nil
                // When editing the baked file (no source asset), avoid double-zoom
                zoomScale = 1.0
                panOffset = .zero
                lastZoomScale = 1.0
                dragStartOffset = .zero
                clipLength = preferredSpan(for: editingClip)
                clipRange  = 0...clipLength
            }
            return
        }

        // 2) Prepared media URL from LibraryPickerView / Suggestions.
        // This must win before sourceLocalID so iCloud assets are not downloaded twice.
        if let url = initialURL, player == nil {
            if let ut = UTType(filenameExtension: url.pathExtension), ut.conforms(to: .image) {
                // Photo -> build temp video at current clipLength.
                if let raw = UIImage(contentsOfFile: url.path) {
                    let img = uprightImage(raw)
                    isPhotoSource = true
                    photoImage = img
                    if let out = try? await makeVideo(from: img, duration: clipLength) {
                        await setPlayer(url: out, start: 0)
                        await MainActor.run { clipRange = 0...clipLength }
                    }
                }
            } else {
                // Video URL, including Live Photo paired video.
                isPhotoSource = false
                photoImage = nil
                await setPlayer(url: url, start: 0)
            }
            return
        }

        // 3) Photos localIdentifier (custom LibraryPickerView path)
        if let id = sourceLocalID, player == nil {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                if asset.mediaType == .video {
                    // (unchanged) resolve AVAsset and seed player
                    let opts = PHVideoRequestOptions()
                    opts.deliveryMode = .highQualityFormat
                    opts.isNetworkAccessAllowed = true
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                            guard let av = avAsset else { cont.resume(); return }
                            Task { @MainActor in
                                isPhotoSource = false
                                photoImage = nil
                                await setPlayer(asset: av, start: desiredStart)
                                cont.resume()
                            }
                        }
                    }
                } else {
                    // ⬇️ NEW: treat Live Photo as video; otherwise treat as still photo
                    if isLivePhoto(asset) {
                        do {
                            let url = try await exportPairedVideo(for: asset)
                            await MainActor.run {
                                isPhotoSource = false   // it's a real video now
                                photoImage = nil
                            }
                            await setPlayer(url: url, start: desiredStart)
                        } catch {
                            // Fallback: if paired video fails, use still-photo path
                            await handleStillPhoto(asset)
                        }
                    } else {
                        await handleStillPhoto(asset)   // regular still photo
                    }
                }
            }
        }
    }

    @MainActor
    private func handleStillPhoto(_ asset: PHAsset) async {
        do {
            let data = try await requestImageData(for: asset)
            if let raw = UIImage(data: data) {
                let img = uprightImage(raw)
                isPhotoSource = true
                photoImage = img
                if let out = try? await makeVideo(from: img, duration: clipLength) {
                    await setPlayer(url: out, start: 0)
                    clipRange = 0...clipLength
                }
            }
        } catch {
            print("[ClipEditorSheet] image data error:", error)
        }
    }




    @MainActor
    private func setPlayer(asset: AVAsset, start: Double) {
        if let u = (asset as? AVURLAsset)?.url { assetURL = u } else { assetURL = nil }

        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let n = try? await track.load(.naturalSize),
               let t = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: n).applying(t)
                let w = max(1, abs(r.width)), h = max(1, abs(r.height))
                await MainActor.run {
                    sourceAspect = w / h
                    applyInferredPreviewFillIfNeeded()
                }
            }
        }

        let old = player
        if let token = timeObserver, let old { old.removeTimeObserver(token); timeObserver = nil }
        if let token = boundaryObserver, let old { old.removeTimeObserver(token); boundaryObserver = nil }

        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        newPlayer.actionAtItemEnd = .pause
        installItemEndNotification()
        // Selection no longer controls playback; no selection-based boundary observer here.
        installEndObserversForCurrentRange()

        // Track URL if available
        if let urlAsset = asset as? AVURLAsset { assetURL = urlAsset.url } else { assetURL = nil }

        assetDuration = CMTimeGetSeconds(asset.duration)
        // If not ready yet, load duration asynchronously and correct the range once known
        if !assetDuration.isFinite || assetDuration <= 0 {
            Task {
                if let dur = try? await asset.load(.duration) {
                    await MainActor.run {
                        assetDuration = CMTimeGetSeconds(dur)
                        let maxStart = max(0, assetDuration - clipLength)
                        let newLower = min(start, maxStart)
                        clipRange = newLower...(min(assetDuration, newLower + clipLength))
                    }
                }
            }
        }
        // keep whatever clipLength the user picked, just clamp it and range
        let clampedLen = min(maxSpan, max(minSpan, clipLength))
        clipLength = clampedLen
        let lower = min(start, max(0, assetDuration - clampedLen))
        clipRange = lower...(min(assetDuration, lower + clampedLen))

        isSeeding = false
        showPlayOverlay = true
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
            currentTime = CMTimeGetSeconds(t)
        }
        if isPhotoSource, let img = photoImage {
            // Avoid expensive generator; repeat the still
            self.thumbnails = Array(repeating: img, count: 8)
        } else {
            Task { await generateThumbnails(from: asset) }
        }

    }

    // Normalize UIImage orientation so exported videos / thumbnails are upright
    private func uprightImage(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        img.draw(in: CGRect(origin: .zero, size: img.size))
        let fixed = UIGraphicsGetImageFromCurrentImageContext() ?? img
        UIGraphicsEndImageContext()
        return fixed
    }


    @MainActor
    private func setPlayer(url: URL, start: Double) async {
        let av = AVURLAsset(url: url)

        if let track = try? await av.loadTracks(withMediaType: .video).first,
           let n = try? await track.load(.naturalSize),
           let t = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: n).applying(t)
            let w = max(1, abs(r.width)), h = max(1, abs(r.height))
            sourceAspect = w / h
            applyInferredPreviewFillIfNeeded()
        }

        setPlayer(asset: av, start: start)     // this one can stay non-async
    }


    private func displayConfig(
        mode: PreviewFill,
        sourceAR: CGFloat,
        quarterTurns: QuarterTurns
    ) -> (containerAR: CGFloat, gravity: AVLayerVideoGravity) {

        // Apply 90°/270° to the source aspect
        let ar = (quarterTurns == .t1 || quarterTurns == .t3) ? 1.0 / max(sourceAR, .leastNonzeroMagnitude)
                                                              : max(sourceAR, .leastNonzeroMagnitude)

        switch mode {
        case .portrait:
            // If the media is portrait already: match its exact aspect and FIT (zero crop)
            // If landscape media: use 9:16 box and FIT (letterbox only)
            return (ar < 1 ? ar : 9.0/16.0, .resizeAspect)

        case .landscape:
            // If the media is landscape already: match exact aspect and FIT (zero crop)
            // If portrait media: use 16:9 box and FIT (letterbox only)
            return (ar > 1 ? ar : 16.0/9.0, .resizeAspect)

        case .square:
            // Square: center-crop minimally so the box is filled
            return (1.0, .resizeAspectFill)
        }
    }



    // Resolve a usable file URL for export.
    // 1) If we already captured a URL, use it.
    // 2) Else, if the player's asset is AVURLAsset, use its url.
    // 3) Else, export the current asset to a temp .mov with orientation properly baked in.
    private func resolveSourceURL() async throws -> URL {
        if let url = assetURL { return url }

        guard let asset = player?.currentItem?.asset else {
            throw NSError(domain: "Editor", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "No asset to export"])
        }
        if let urlAsset = asset as? AVURLAsset {
            return urlAsset.url
        }

        // For non-URL assets (e.g., AVComposition from PHImageManager), we need to export
        // with a video composition that bakes in the preferredTransform to avoid double-rotation
        // issues where the export preserves orientation metadata that VideoEditEngine then re-applies.

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("source-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: tmp)

        // Get the video track and its orientation info
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Editor", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)

        // Calculate the render size after applying the transform
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )

        // Create a composition to hold the video
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "Editor", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create composition track"])
        }

        let duration = try await asset.load(.duration)
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )

        // Also copy audio if present
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }

        // Create video composition to apply the preferredTransform
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Editor", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
        }
        session.outputURL = tmp
        session.outputFileType = .mov
        session.videoComposition = videoComposition  // ✅ Apply orientation transform

        try await withCheckedThrowingContinuation { cont in
            session.exportAsynchronously {
                if session.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: session.error ?? NSError(
                        domain: "Editor", code: -12,
                        userInfo: [NSLocalizedDescriptionKey: "Export failed with status \(session.status)"]
                    ))
                }
            }
        }
        return tmp
    }






    // MARK: - Helpers (Photos & Conversion)
    private func requestImageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.isNetworkAccessAllowed = true
            // NB: requestImageDataAndOrientation returns (data, uti, orientation, infoDict)
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, info in
                // Handle cancellations
                if let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue, cancelled {
                    cont.resume(throwing: NSError(domain: "Photos", code: -999,
                                                  userInfo: [NSLocalizedDescriptionKey: "Request cancelled"]))
                    return
                }
                // Ignore degraded (low-res) pass; we'll get called again with full quality
                if let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue, degraded {
                    return
                }
                // Surface Photos errors properly
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err)
                    return
                }
                // Success
                if let data = data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: NSError(domain: "Photos", code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey: "No image data"]))
                }
            }
        }
    }


      private func exportTemp(from av: AVAsset) async throws -> URL {
          let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pick-\(UUID().uuidString).mp4")
          try? FileManager.default.removeItem(at: out)
          guard let exporter = AVAssetExportSession(asset: av, presetName: AVAssetExportPresetHighestQuality) else {
              throw NSError(domain: "Export", code: -1)
          }
          exporter.outputURL = out
          exporter.outputFileType = .mp4
          exporter.shouldOptimizeForNetworkUse = true
          return try await withCheckedThrowingContinuation { cont in
              exporter.exportAsynchronously {
                  if exporter.status == .completed { cont.resume(returning: out) }
                  else { cont.resume(throwing: exporter.error ?? NSError(domain: "Export", code: -2)) }
              }
          }
      }

    // Image → mp4 with a gentle zoom-in over `duration` (runs off-main)
    private func makeVideo(from image: UIImage, duration: Double, fps: Int32 = 20) async throws -> URL {
        // Normalize orientation using Core Image (no UIKit drawing on background threads)
        func exif(_ o: UIImage.Orientation) -> Int32 {
            switch o {
            case .up:  return 1
            case .down: return 3
            case .left: return 8
            case .right: return 6
            case .upMirrored: return 2
            case .downMirrored: return 4
            case .leftMirrored: return 5
            case .rightMirrored: return 7
            @unknown default: return 1
            }
        }
        let ciBase: CIImage
        if let cg = image.cgImage {
            ciBase = CIImage(cgImage: cg).oriented(forExifOrientation: exif(image.imageOrientation))
        } else if let ci = CIImage(image: image) {
            ciBase = ci.oriented(forExifOrientation: exif(image.imageOrientation))
        } else {
            throw NSError(domain: "Writer", code: -6, userInfo: [NSLocalizedDescriptionKey: "Cannot normalize image"])
        }
        let ciCtx = CIContext(options: nil)
        guard let baseCG = ciCtx.createCGImage(ciBase, from: ciBase.extent) else {
            throw NSError(domain: "Writer", code: -7, userInfo: [NSLocalizedDescriptionKey: "CIContext CGImage create failed"])
        }

        // Render size (cap at ~720p longer side, even)
        let maxSide: CGFloat = 720
        let aspect = ciBase.extent.width / max(ciBase.extent.height, 1)
        let render: CGSize = {
            if aspect >= 1 {
                let w = min(ciBase.extent.width, maxSide)
                let h = w / max(aspect, 0.0001)
                return CGSize(width: max(2, Int(w)) & ~1, height: max(2, Int(h)) & ~1)
            } else {
                let h = min(ciBase.extent.height, maxSide)
                let w = h * max(aspect, 0.0001)
                return CGSize(width: max(2, Int(w)) & ~1, height: max(2, Int(h)) & ~1)
            }
        }()

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imgvid-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(render.width),
            AVVideoHeightKey: Int(render.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000] // slightly reduced bitrate for speed
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(render.width),
            kCVPixelBufferHeightKey as String: Int(render.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(duration * Double(fps)))
        let frameDuration = CMTime(value: 1, timescale: fps)

        var t = CMTime.zero
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "Writer", code: -3)
        }

        // Ken Burns: zoom from 0.95x → 1.07x (a tiny bit lighter than before)
        let startZoom: CGFloat = 0.95
        let endZoom:   CGFloat = 1.07

        for i in 0..<totalFrames {
            if Task.isCancelled { break }
            let p = CGFloat(i) / CGFloat(max(1, totalFrames - 1))
            let z = startZoom + (endZoom - startZoom) * p
            if let buf = pixelBuffer(from: baseCG, pool: pool, canvas: render, zoom: z) {
                while !input.isReadyForMoreMediaData {
                    if Task.isCancelled { break }
                    Thread.sleep(forTimeInterval: 0.001) // brief back-off to keep CPU smooth
                }
                adaptor.append(buf, withPresentationTime: t)
                t = t + frameDuration
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .completed { return url }
        throw writer.error ?? NSError(domain: "Writer", code: -4)
    }


    // Draw CGImage into CVPixelBuffer with UIKit coordinates (upright), with optional zoom.
    private func pixelBuffer(from cg: CGImage, pool: CVPixelBufferPool, canvas: CGSize, zoom: CGFloat) -> CVPixelBuffer? {
        var px: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &px) == kCVReturnSuccess, let px else { return nil }
        CVPixelBufferLockBaseAddress(px, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(px),
            width: Int(canvas.width), height: Int(canvas.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(px),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue   // matches kCVPixelFormatType_32ARGB
        ) {
            let scaledW = canvas.width * zoom
            let scaledH = canvas.height * zoom
            let dx = (scaledW - canvas.width) / 2
            let dy = (scaledH - canvas.height) / 2
            ctx.draw(cg, in: CGRect(x: -dx, y: -dy, width: scaledW, height: scaledH))
        }
        CVPixelBufferUnlockBaseAddress(px, [])
        return px
    }


    private func clampRangeIfNeeded() {
        guard assetDuration.isFinite, assetDuration > 0 else {
            clipRange = 0...0
            return
        }
        // Clamp endpoints into [0, assetDuration]
        var lower = max(0, min(clipRange.lowerBound, assetDuration))
        var upper = max(0, min(clipRange.upperBound, assetDuration))

        // Normalize ordering
        if lower > upper { swap(&lower, &upper) }

        // Enforce span limits
        let span = upper - lower
        let desired = min(maxSpan, max(minSpan, span))

        // Keep range inside [0, assetDuration]
        lower = min(lower, max(0, assetDuration - desired))
        upper = lower + desired

        clipRange = lower...upper
    }


    // Is this Photos asset a Live Photo?
    private func isLivePhoto(_ asset: PHAsset) -> Bool {
        if asset.mediaSubtypes.contains(.photoLive) { return true }
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .pairedVideo }
    }

    // Export the Live Photo's paired video to a temp .mov and return its URL
    private func exportPairedVideo(for asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let paired = resources.first(where: { $0.type == .pairedVideo }) else {
            throw NSError(domain: "Photos", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "No Live Photo video resource"])
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: out)

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: paired, toFile: out, options: opts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return out
    }




    // Thumbnails for the scrubber
    private func generateThumbnails(from asset: AVAsset) async {
        guard assetDuration > 0 else { return }
        let count = 8
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)

        let times = (0..<count).map {
            NSValue(time: CMTime(seconds: (Double($0)+0.5) * (assetDuration / Double(count)),
                                 preferredTimescale: 600))
        }

        var imgs: [UIImage] = []
        for t in times {
            if let cg = try? gen.copyCGImage(at: t.timeValue, actualTime: nil) {
                imgs.append(UIImage(cgImage: cg))
            }
        }
        await MainActor.run { self.thumbnails = imgs }
    }

    // Small helper: seconds → "m:ss"
    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let m = s / 60
        let r = s % 60
        return "\(m):" + String(format: "%02d", r)
    }


}

// MARK: - FixedWindowScrubber (CapCut/TikTok Style - UIKit Gesture)
private struct FixedWindowScrubber: UIViewRepresentable {
    @Binding var start: Double
    let length: Double
    let total: Double
    let thumbnails: [UIImage]
    let current: Double

    func makeUIView(context: Context) -> ScrubberUIView {
        let view = ScrubberUIView()
        view.onStartChanged = { newStart in
            start = newStart
        }
        return view
    }

    func updateUIView(_ uiView: ScrubberUIView, context: Context) {
        uiView.update(start: start, length: length, total: total, thumbnails: thumbnails, current: current)
    }
}

private class ScrubberUIView: UIView {
    var onStartChanged: ((Double) -> Void)?

    private var _start: Double = 0
    private var _length: Double = 1.5
    private var _total: Double = 10
    private var _thumbnails: [UIImage] = []
    private var _current: Double = 0

    private let stripHeight: CGFloat = 56
    private let handleWidth: CGFloat = 14
    private let corner: CGFloat = 8

    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartValue: Double = 0

    // Layers for efficient rendering
    private let thumbnailLayer = CALayer()
    private let leftDimLayer = CALayer()
    private let rightDimLayer = CALayer()
    private let frameLayer = CAShapeLayer()
    private let leftHandleLayer = CALayer()
    private let rightHandleLayer = CALayer()
    private let playheadLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor(white: 0.15, alpha: 1)
        clipsToBounds = true
        layer.cornerRadius = corner
        layer.masksToBounds = true

        // Setup layers - all need masksToBounds
        thumbnailLayer.masksToBounds = true
        thumbnailLayer.cornerRadius = corner
        layer.addSublayer(thumbnailLayer)

        leftDimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.5).cgColor
        layer.addSublayer(leftDimLayer)

        rightDimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.5).cgColor
        layer.addSublayer(rightDimLayer)

        frameLayer.fillColor = nil
        frameLayer.strokeColor = UIColor.white.cgColor
        frameLayer.lineWidth = 3
        layer.addSublayer(frameLayer)

        leftHandleLayer.backgroundColor = UIColor.white.cgColor
        leftHandleLayer.cornerRadius = corner
        leftHandleLayer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer.addSublayer(leftHandleLayer)

        rightHandleLayer.backgroundColor = UIColor.white.cgColor
        rightHandleLayer.cornerRadius = corner
        rightHandleLayer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        layer.addSublayer(rightHandleLayer)

        playheadLayer.backgroundColor = UIColor.white.cgColor
        playheadLayer.cornerRadius = 1
        layer.addSublayer(playheadLayer)

        // Pan gesture
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    func update(start: Double, length: Double, total: Double, thumbnails: [UIImage], current: Double) {
        _start = start
        _length = length
        _total = total
        _current = current

        if thumbnails != _thumbnails {
            _thumbnails = thumbnails
            updateThumbnails()
        }

        if !isDragging {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutLayers()
            CATransaction.commit()
        }
    }

    private func updateThumbnails() {
        thumbnailLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let w = bounds.width
        guard w > 0 else { return }

        guard !_thumbnails.isEmpty else {
            thumbnailLayer.backgroundColor = UIColor(white: 0.15, alpha: 1).cgColor
            return
        }

        thumbnailLayer.backgroundColor = nil
        let thumbWidth = ceil(w / CGFloat(_thumbnails.count)) + 1 // Slight overlap to avoid gaps

        for (i, img) in _thumbnails.enumerated() {
            let imgLayer = CALayer()
            imgLayer.contents = img.cgImage
            imgLayer.contentsGravity = .resizeAspectFill
            imgLayer.masksToBounds = true
            imgLayer.frame = CGRect(
                x: floor(CGFloat(i) * (w / CGFloat(_thumbnails.count))),
                y: 0,
                width: thumbWidth,
                height: stripHeight
            )
            thumbnailLayer.addSublayer(imgLayer)
        }
    }

    private func layoutLayers() {
        let w = bounds.width
        guard w > 0, _total > 0 else { return }

        let pps = w / _total
        let winW = _length * pps
        let maxX = max(0, w - winW)
        let dispX = min(max(0, _start * pps), maxX)
        let headX = min(max(0, _current), _total) * pps

        thumbnailLayer.frame = bounds

        leftDimLayer.frame = CGRect(x: 0, y: 0, width: dispX, height: stripHeight)
        rightDimLayer.frame = CGRect(x: dispX + winW, y: 0, width: w - dispX - winW, height: stripHeight)

        // Frame path (top and bottom borders)
        let framePath = UIBezierPath()
        framePath.move(to: CGPoint(x: dispX + handleWidth, y: 1.5))
        framePath.addLine(to: CGPoint(x: dispX + winW - handleWidth, y: 1.5))
        framePath.move(to: CGPoint(x: dispX + handleWidth, y: stripHeight - 1.5))
        framePath.addLine(to: CGPoint(x: dispX + winW - handleWidth, y: stripHeight - 1.5))
        frameLayer.path = framePath.cgPath

        leftHandleLayer.frame = CGRect(x: dispX, y: 0, width: handleWidth, height: stripHeight)
        rightHandleLayer.frame = CGRect(x: dispX + winW - handleWidth, y: 0, width: handleWidth, height: stripHeight)

        playheadLayer.frame = CGRect(x: headX - 1, y: 0, width: 2, height: stripHeight)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: stripHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateThumbnails()
        layoutLayers()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let w = bounds.width
        guard w > 0, _total > 0 else { return }

        let pps = w / _total
        let winW = _length * pps
        let maxX = max(0, w - winW)

        switch gesture.state {
        case .began:
            isDragging = true
            dragStartX = gesture.location(in: self).x
            dragStartValue = _start

        case .changed:
            let currentX = gesture.location(in: self).x
            let deltaX = currentX - dragStartX
            let newStartX = min(max(0, dragStartValue * pps + deltaX), maxX)
            let newStart = newStartX / pps

            _start = newStart

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutLayers()
            CATransaction.commit()

        case .ended, .cancelled:
            isDragging = false
            onStartChanged?(_start)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        default:
            break
        }
    }
}

extension ScrubberUIView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        // Only handle horizontal pans
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }
}

// Mini timeline that highlights the selected range and shows progress
private struct MiniTimelineOverlay: View {
    let duration: Double
    let range: ClosedRange<Double>
    let current: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let startX = CGFloat(range.lowerBound / max(duration, .leastNonzeroMagnitude)) * w
            let endX   = CGFloat(range.upperBound / max(duration, .leastNonzeroMagnitude)) * w
            let progX  = CGFloat(min(max(0, current / max(duration, .leastNonzeroMagnitude)), 1)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.35)).frame(height: 4).padding(.horizontal, 12)
                Capsule().fill(Color.accentColor).frame(width: max(2, endX - startX), height: 4)
                    .offset(x: startX).padding(.horizontal, 12)
                Circle().fill(.white).frame(width: 8, height: 8)
                    .offset(x: progX - 4).padding(.horizontal, 12)
            }
            .padding(.bottom, 8)
            .allowsHitTesting(false)
        }
        .frame(height: 16)
    }
}


// Little pill that appears briefly on mode change
private struct ModeBadge: View {
    let text: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption.bold())
            Text(text).font(.caption.bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 6)
    }
}
