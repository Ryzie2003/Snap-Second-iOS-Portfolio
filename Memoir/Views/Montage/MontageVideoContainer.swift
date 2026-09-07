//
//  MontageVideoContainer.swift
//  Snap Second
//
//  Video player and overlay components for Montage
//

import SwiftUI
import AVKit
import AVFoundation
import UIKit

// MARK: - Video Container

struct VideoContainer: View {
    // inputs
    var player: AVPlayer?
    var overlay: CALayer?
    var forcedAspect: CGFloat? = nil
    var gravity: AVLayerVideoGravity = .resizeAspect
    var overlayKey: Int = 0
    var theme: Theme
    var bgColor: UIColor
    @Binding var isPlaying: Bool
    var scrubPreviewTime: TimeInterval? = nil
    var dateCaptionItems: [TimelineItem] = []
    var showDateCaptions: Bool = false
    var dateCaptionAnchor: CaptionAnchor3 = .bottomLeft

    // callbacks
    var onTapped: (() -> Void)? = nil

    // custom caption inputs
    @Binding var customCaptionText: String
    var showCustomCaption: Bool
    var customCaptionStartTime: TimeInterval? = nil
    var customCaptionDuration: TimeInterval? = nil
    @Binding var captionPosNorm: CGPoint
    var captionColor: UIColor
    var captionOpacity: Double
    var captionFontVariant: CaptionFontVariant
    @Binding var captionFontSize: Double
    var onCaptionDragEnded: (() -> Void)? = nil

    // End card parameters (to hide caption during end card)
    var showBranding: Bool = true
    var endCardSeconds: Double = 2.0

    // HUD state
    @State private var showHUD: Bool = true
    @State private var isDragging: Bool = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var timeObservers: [ObjectIdentifier: Any] = [:]
    @State private var itemEndObserver: NSObjectProtocol?
    @State private var captionSize: CGSize = CGSize(width: 100, height: 30)  // Reasonable default to prevent positioning issues during layout
    @State private var dragStartCaptionNorm: CGPoint? = nil
    @State private var pinchStartFontSize: Double? = nil
    @State private var isCaptionGestureActive: Bool = false
    @FocusState private var captionFieldFocused: Bool

    @State private var originalCaptionPosBeforeEditing: CGPoint? = nil
    @StateObject private var scrubOutput = VideoScrubOutput()

    // layout
    @State private var aspect: CGFloat = 9.0/16.0
    @State private var realAspect: CGFloat = 9.0/16.0
    var isBlocked: Bool = false

    private static let dateCaptionMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM d")
        return formatter
    }()

    private static let dateCaptionYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yyyy")
        return formatter
    }()

    /// Returns true if we're currently in the end card portion of the video
    private var isInEndCard: Bool {
        guard showBranding, endCardSeconds > 0, duration > 0 else { return false }
        let endCardStart = duration - endCardSeconds
        return displayedTime >= endCardStart
    }

    private var displayedTime: TimeInterval {
        scrubPreviewTime ?? current
    }

    private var isCustomCaptionActive: Bool {
        guard showCustomCaption else { return false }
        guard let start = customCaptionStartTime, let duration = customCaptionDuration else {
            return showCustomCaption
        }
        let end = start + duration
        let time = displayedTime
        return time >= start && time <= end
    }

    private var activeDateCaptionDate: Date? {
        guard showDateCaptions else { return nil }
        let time = displayedTime
        return dateCaptionItems
            .sorted { $0.startTime < $1.startTime }
            .first { item in
                guard let date = item.clipDate else { return false }
                return time >= item.startTime && time < item.endTime && date.timeIntervalSinceReferenceDate.isFinite
            }?
            .clipDate
    }

    private var captionSwiftUIFont: Font {
        switch captionFontVariant {
        case .system:
            return .system(size: captionFontSize)
        case .rounded:
            return .system(size: captionFontSize, weight: .regular, design: .rounded)
        case .serif:
            return .system(size: captionFontSize, weight: .regular, design: .serif)
        case .monospaced:
            return .system(size: captionFontSize, weight: .regular, design: .monospaced)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let availableHeight = proxy.size.height

            let targetAspect = forcedAspect ?? aspect

            let widthBasedHeight = proxy.size.width / targetAspect
            let heightBasedWidth = proxy.size.height * targetAspect
            let isWidthConstrained = widthBasedHeight <= availableHeight
            let finalWidth  = isWidthConstrained ? availableWidth  : heightBasedWidth
            let finalHeight = isWidthConstrained ? widthBasedHeight : availableHeight

            ZStack {
                Group {
                    if let player = player {
                        let pid = ObjectIdentifier(player)
                        PlayerLayerView(player: player, overlay: overlay, gravity: gravity)
                            .id("\(pid.hashValue)-\(overlayKey)")
                            .onTapGesture(perform: togglePlay)
                            .onAppear { attachObservers(to: player); syncDurFromItem() }
                            .onDisappear { detachObservers(from: player) }
                            .onChange(of: player.currentItem) { _ in
                                syncDurFromItem()
                                scrubOutput.attach(to: player.currentItem)
                            }
                    } else {
                        Color.black.opacity(0.25)
                    }
                }

                if let image = scrubOutput.image, scrubPreviewTime != nil {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: gravity == .resizeAspectFill ? .fill : .fit)
                        .frame(width: finalWidth, height: finalHeight)
                        .clipped()
                        .transition(.opacity)
                }

                if let date = activeDateCaptionDate, !isInEndCard {
                    dateCaptionOverlay(for: date)
                        .allowsHitTesting(false)
                }

                if isCustomCaptionActive && !isInEndCard {
                    GeometryReader { cap in
                        let size = cap.size

                        // Guard against invalid container size during layout transitions
                        if size.width > 1 && size.height > 1 {
                        // Simple percentage-based positioning:
                        // x=0 means left edge, x=0.5 means center, x=1 means right edge
                        // Values outside 0-1 allow off-screen positioning (will be clipped)
                        let centerX = captionPosNorm.x * size.width
                        let centerY = captionPosNorm.y * size.height

                        TextField(
                            "Tap to Add Caption",
                            text: Binding(
                                get: { customCaptionText },
                                set: { newValue in customCaptionText = newValue }
                            )
                        )
                        .focused($captionFieldFocused)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(captionSwiftUIFont)
                        .foregroundColor(Color(captionColor).opacity(captionOpacity))
                        .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(isCaptionGestureActive ? 0.6 : 0), lineWidth: 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(isCaptionGestureActive ? 0.1 : 0))
                                )
                        )
                        .animation(.easeInOut(duration: 0.15), value: isCaptionGestureActive)
                        .background(
                            GeometryReader { textGeo in
                                Color.clear
                                    .allowsHitTesting(false)
                                    .onAppear { captionSize = textGeo.size }
                                    .onChange(of: textGeo.size) { newSize in
                                        captionSize = newSize
                                    }
                            }
                        )
                        .position(x: centerX, y: centerY)
                        .disabled(isBlocked)
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard !captionFieldFocused else { return }

                                    if dragStartCaptionNorm == nil {
                                        dragStartCaptionNorm = captionPosNorm
                                        isCaptionGestureActive = true
                                    }

                                    let start = dragStartCaptionNorm ?? captionPosNorm

                                    // Use direct percentage of container size
                                    let nx = start.x + value.translation.width  / size.width
                                    let ny = start.y + value.translation.height / size.height

                                    // Allow free positioning - caption can go partially off-screen
                                    captionPosNorm = CGPoint(x: nx, y: ny)
                                }
                                .onEnded { _ in
                                    dragStartCaptionNorm = nil
                                    isCaptionGestureActive = false
                                    onCaptionDragEnded?()
                                }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    guard !captionFieldFocused else { return }

                                    if pinchStartFontSize == nil {
                                        pinchStartFontSize = captionFontSize
                                        isCaptionGestureActive = true
                                    }
                                    let base = pinchStartFontSize ?? captionFontSize
                                    let newSize = min(max(base * value, 16), 72)
                                    captionFontSize = newSize
                                }
                                .onEnded { _ in
                                    pinchStartFontSize = nil
                                    isCaptionGestureActive = false
                                    onCaptionDragEnded?()
                                }
                        )
                        .onTapGesture {
                            captionFieldFocused = true
                        }
                        }  // end if size.width > 1 && size.height > 1
                    }
                }

            }
            .frame(width: finalWidth, height: finalHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
                isPlaying = false
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: ObjectIdentifier(player as AnyObject)) {
                if let p = player {
                    attachObservers(to: p)
                    syncDurFromItem()
                    scrubOutput.attach(to: p.currentItem)
                }
            }
            .onAppear {
                syncDurFromItem()
                if let fa = forcedAspect { aspect = fa }
                isPlaying = (player?.timeControlStatus == .playing)
            }
            .onChange(of: scrubPreviewTime) { _, newValue in
                if let time = newValue {
                    scrubOutput.requestFrame(at: time)
                } else {
                    scrubOutput.clear()
                }
            }
            .onChange(of: forcedAspect) { newValue in
                if let fa = newValue {
                    aspect = fa
                } else {
                    aspect = realAspect
                }
            }
            .onChange(of: captionFieldFocused) { isFocused in
                if isFocused {
                    let lowThreshold: CGFloat = 0.6
                    let editY: CGFloat = 0.35

                    if captionPosNorm.y > lowThreshold {
                        originalCaptionPosBeforeEditing = captionPosNorm
                        withAnimation(.easeOut(duration: 0.25)) {
                            captionPosNorm.y = editY
                        }
                    }
                } else {
                    if let original = originalCaptionPosBeforeEditing {
                        withAnimation(.easeOut(duration: 0.25)) {
                            captionPosNorm = original
                        }
                        originalCaptionPosBeforeEditing = nil
                    }
                }
            }
        }
    }

    // MARK: HUD pieces

    private var scrubberTrackColor    : Color { theme.border.opacity(0.35) }
    private var scrubberProgressColor : Color { theme.core.primary }
    private var scrubberThumbFill     : Color { theme.core.primary }
    private var scrubberThumbStroke   : Color { .white }

    private var scrubber: some View {
        VStack(spacing: 6) {
            HStack {
                Text(current.formattedTime).font(.system(.caption, design: .rounded).monospacedDigit())
                Spacer()
                Text(duration.formattedTime).font(.system(.caption, design: .rounded).monospacedDigit())
            }
            .foregroundColor(.white)

            GeometryReader { g in
                let trackH: CGFloat = 4
                let knob:   CGFloat = 16
                let x = max(0, CGFloat(progress) * g.size.width)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(scrubberTrackColor)
                        .frame(height: trackH)

                    Capsule()
                        .fill(scrubberProgressColor)
                        .frame(width: x, height: trackH)

                    Circle()
                        .fill(scrubberThumbFill)
                        .overlay(Circle().stroke(scrubberThumbStroke, lineWidth: 2))
                        .frame(width: knob, height: knob)
                        .offset(x: max(0, x - knob/2), y: -(knob - trackH)/2)
                        .shadow(radius: 2, y: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            showHUD = true
                            isDragging = true
                            let p = max(0, min(1, val.location.x / g.size.width))
                            seek(to: p)
                        }
                        .onEnded { _ in
                            isDragging = false
                            autoHideHUD()
                        }
                )
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onTapGesture { /* absorb taps so HUD stays up */ }
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return current / duration
    }

    private func dateCaptionOverlay(for date: Date) -> some View {
        let monthDay = Self.dateCaptionMonthDayFormatter
            .string(from: date)
            .uppercased(with: Locale.current)
        let year = Self.dateCaptionYearFormatter.string(from: date)

        return VStack(alignment: dateCaptionTextAlignment, spacing: 0) {
            Text(monthDay)
                .font(.system(size: dateCaptionTitleSize, weight: .semibold))
            Text(year)
                .font(.system(size: dateCaptionYearSize, weight: .regular))
                .opacity(0.92)
        }
        .foregroundStyle(Color(captionColor))
        .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dateCaptionAlignment)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    private var dateCaptionTextAlignment: HorizontalAlignment {
        switch dateCaptionAnchor {
        case .bottomLeft: return .leading
        case .bottomCenter: return .center
        case .bottomRight: return .trailing
        }
    }

    private var dateCaptionAlignment: Alignment {
        switch dateCaptionAnchor {
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    private var dateCaptionTitleSize: CGFloat {
        max(18, min(34, captionFontSize * 1.25))
    }

    private var dateCaptionYearSize: CGFloat {
        max(13, min(24, captionFontSize * 0.82))
    }

    // MARK: playback / observers

    private func togglePlay() {
        guard let p = player else { return }
        showHUD = true
        autoHideHUD()
        if p.timeControlStatus == .playing {
            p.pause()
            isPlaying = false
        } else {
            if let it = p.currentItem, current >= it.duration.seconds - 0.05 {
                p.seek(to: .zero)
            }
            p.play()
            isPlaying = true
        }
        onTapped?()
    }

    private func seek(to p: Double) {
        guard let it = player?.currentItem, p.isFinite, duration > 0 else { return }
        let t = CMTime(seconds: duration * p, preferredTimescale: 600)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        current = t.seconds
    }

    private func autoHideHUD() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !isDragging {
                withAnimation(.easeOut(duration: 0.2)) {
                    showHUD = false
                }
            }
        }
    }

    private func attachObservers(to player: AVPlayer) {
        let id = ObjectIdentifier(player)

        if timeObservers[id] == nil {
            let token = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                queue: .main
            ) { t in
                if !isDragging { current = t.seconds }

                if duration == 0,
                   let d = player.currentItem?.duration.seconds,
                   d.isFinite, d > 0 {
                    duration = d
                }
            }
            timeObservers[id] = token
        }

        if itemEndObserver == nil {
            itemEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { _ in showHUD = true }
        }
    }

    private func detachObservers(from player: AVPlayer) {
        let id = ObjectIdentifier(player)
        if let token = timeObservers.removeValue(forKey: id) {
            player.removeTimeObserver(token)
        }
        if timeObservers.isEmpty, let obs = itemEndObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndObserver = nil
        }
    }

    private func syncDurFromItem() {
        guard let item = player?.currentItem else { duration = 0; current = 0; return }
        let sec = item.duration.seconds
        if sec.isFinite, sec > 0 {
            duration = sec
        } else {
            Task {
                if let loaded = try? await item.asset.load(.duration).seconds,
                   loaded.isFinite, loaded > 0 {
                    await MainActor.run { duration = loaded }
                }
            }
        }
    }
}

// MARK: - Scrub Output

final class VideoScrubOutput: ObservableObject {
    @Published var image: UIImage? = nil

    private let queue = DispatchQueue(label: "montage.scrub.output")
    private let context = CIContext(options: nil)
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var fallbackGenerator: AVAssetImageGenerator?
    private var fallbackAssetID: ObjectIdentifier?
    private var isRendering = false
    private var pendingTime: TimeInterval?

    func attach(to item: AVPlayerItem?) {
        queue.async {
            if item === self.item {
                return
            }
            if let currentItem = self.item, let output = self.output {
                currentItem.remove(output)
            }
            self.item = item
            guard let item else {
                self.output = nil
                self.fallbackGenerator = nil
                self.fallbackAssetID = nil
                DispatchQueue.main.async { self.image = nil }
                return
            }

            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
            output.suppressesPlayerRendering = false
            item.add(output)
            self.output = output
            self.updateFallbackGenerator(for: item)
        }
    }

    func requestFrame(at time: TimeInterval) {
        queue.async {
            self.pendingTime = time
            self.renderNextFrameIfNeeded()
        }
    }

    func clear() {
        queue.async {
            self.pendingTime = nil
            DispatchQueue.main.async { self.image = nil }
        }
    }

    private func renderNextFrameIfNeeded() {
        guard !isRendering else { return }
        guard let output else { return }
        guard let time = pendingTime else { return }

        pendingTime = nil
        isRendering = true

        var displayTime = CMTime.zero
        let itemTime = CMTime(seconds: time, preferredTimescale: 600)
        if let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let extent = ciImage.extent
            if let cgImage = context.createCGImage(ciImage, from: extent) {
                let image = UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
                DispatchQueue.main.async {
                    self.image = image
                }
                isRendering = false
                renderNextFrameIfNeeded()
                return
            }
        }

        if let fallbackImage = renderFallbackFrame(at: itemTime) {
            DispatchQueue.main.async {
                self.image = fallbackImage
            }
        }

        isRendering = false
        renderNextFrameIfNeeded()
    }

    private func updateFallbackGenerator(for item: AVPlayerItem) {
        let asset = item.asset
        let assetID = ObjectIdentifier(asset)
        if fallbackAssetID == assetID {
            return
        }
        fallbackAssetID = assetID
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let videoComposition = item.videoComposition {
            generator.videoComposition = videoComposition
        }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        fallbackGenerator = generator
    }

    private func renderFallbackFrame(at time: CMTime) -> UIImage? {
        guard let generator = fallbackGenerator else { return nil }
        guard time.isValid, time.isNumeric else { return nil }
        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
        } catch {
            return nil
        }
    }
}

// MARK: - Player Layer View

struct PlayerLayerView: UIViewRepresentable {
    let player:  AVPlayer
    let overlay: CALayer?
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> UIView {
        let v = PlayerView()
        v.playerLayer.videoGravity = gravity
        v.playerLayer.player       = player
        v.overlayGravity          = gravity

        ensureOverlayAttached(v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let view = uiView as! PlayerView
        view.playerLayer.player       = player
        view.playerLayer.videoGravity = gravity
        view.overlayGravity          = gravity

        if needsReattach(view) {
            ensureOverlayAttached(view)
        } else {
            Self.rescaleOverlay(in: view, gravity: view.overlayGravity)
        }
    }

    // MARK: - Idempotent attach

    private func needsReattach(_ host: PlayerView) -> Bool {
        guard let item = player.currentItem else { return false }
        let newItemID = ObjectIdentifier(item)
        let newOvID   = overlay.map(ObjectIdentifier.init)

        return host.attachedItemID != newItemID || host.attachedOverlayID != newOvID
    }

    private func ensureOverlayAttached(_ host: PlayerView) {
        host.layer.sublayers?
            .filter { $0 is AVSynchronizedLayer }
            .forEach { $0.removeFromSuperlayer() }

        guard let item = player.currentItem, let overlay else { return }

        let overlaySize = overlay.bounds.size
        let render = item.videoComposition?.renderSize
            ?? (overlaySize.width > 0 && overlaySize.height > 0
                ? overlaySize
                : CGSize(width: 1080, height: 1920))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        overlay.bounds      = CGRect(origin: .zero, size: render)
        overlay.anchorPoint = .zero
        overlay.position    = .zero

        overlay.actions = [
            "opacity": NSNull(), "position": NSNull(),
            "bounds": NSNull(),  "transform": NSNull(),
            "sublayers": NSNull(), "contents": NSNull()
        ]

        setContentsScaleRecursively(overlay, scale: UIScreen.main.scale)

        let sync = AVSynchronizedLayer(playerItem: item)
        sync.frame  = host.bounds
        sync.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]

        sync.addSublayer(overlay)
        host.layer.addSublayer(sync)

        overlay.beginTime = AVCoreAnimationBeginTimeAtZero

        host.attachedItemID   = ObjectIdentifier(item)
        host.attachedOverlayID = ObjectIdentifier(overlay)

        Self.rescaleOverlay(in: host, gravity: host.overlayGravity)

        CATransaction.commit()
    }

    private static func rescaleOverlay(in host: UIView, gravity: AVLayerVideoGravity) {
        guard
            let sync = host.layer.sublayers?.first(where: { $0 is AVSynchronizedLayer }) as? AVSynchronizedLayer,
            let overlay = sync.sublayers?.first
        else { return }

        let render = overlay.bounds.size
        guard render.width > 0, render.height > 0 else { return }

        let sx = host.bounds.width  / render.width
        let sy = host.bounds.height / render.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sync.frame           = host.bounds

        switch gravity {
        case .resizeAspectFill:
            let s = max(sx, sy)
            let w = render.width * s
            let h = render.height * s
            let x = (host.bounds.width - w) * 0.5
            let y = (host.bounds.height - h) * 0.5
            overlay.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
            overlay.position = CGPoint(x: x, y: y)

        case .resize:
            overlay.setAffineTransform(CGAffineTransform(scaleX: sx, y: sy))
            overlay.position = .zero

        default:
            let s = min(sx, sy)
            let w = render.width * s
            let h = render.height * s
            let x = (host.bounds.width - w) * 0.5
            let y = (host.bounds.height - h) * 0.5
            overlay.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
            overlay.position = CGPoint(x: x, y: y)
        }

        CATransaction.commit()
    }

    private func setContentsScaleRecursively(_ layer: CALayer, scale: CGFloat) {
        layer.contentsScale = scale
        layer.sublayers?.forEach { setContentsScaleRecursively($0, scale: scale) }
    }

    private class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var attachedItemID: ObjectIdentifier?
        var attachedOverlayID: ObjectIdentifier?
        var overlayGravity: AVLayerVideoGravity = .resizeAspect

        override func layoutSubviews() {
            super.layoutSubviews()
            PlayerLayerView.rescaleOverlay(in: self, gravity: overlayGravity)
        }
    }
}
