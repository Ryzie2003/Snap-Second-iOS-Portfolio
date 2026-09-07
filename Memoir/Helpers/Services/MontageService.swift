//
//  MontageService.swift
//  Snap Second
//
//  Created by Montage Builder on 14-Jun-2025.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import UIKit

@inline(__always)
private func onMain<T>(_ work: @MainActor () -> T) async -> T {
    await MainActor.run { work() }
}


// MARK: - MontageService

private struct ClipSeg {
    let url: URL
    let asset: AVURLAsset
    let vTrack: AVAssetTrack?        // nil if no video
    let aTrack: AVAssetTrack?        // nil if no audio
    let duration: CMTime
    let naturalSize: CGSize          // .zero when no video
    let preferredTransform: CGAffineTransform
    let rotationDegrees: Double      // user's custom rotation (0, 90, 180, 270)
    let zoomScale: Double            // ✅ zoom level (1.0 = no zoom, 3.0 = max)
    let panOffsetX: Double           // ✅ pan offset X (-1.0 to 1.0)
    let panOffsetY: Double           // ✅ pan offset Y (-1.0 to 1.0)
}

// Font picker helper (maps your CaptionFontVariant to a UIFont)
private func uiFont(for variant: CaptionFontVariant,
                    size: CGFloat,
                    weight: UIFont.Weight = .semibold) -> UIFont {
    switch variant {
    case .system:
        return .systemFont(ofSize: size, weight: weight)

    case .rounded:
        // Build a rounded system font via descriptor
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let roundedDesc = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: roundedDesc, size: size)
        } else {
            return base
        }

    case .serif:
        // Times New Roman fallback if not available
        return UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size, weight: weight)

    case .monospaced:
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

enum ContentMode { case fit, fill }
enum CaptionAnchor3 { case bottomLeft, bottomCenter, bottomRight }
// MARK: - Caption style (shared)
private enum CaptionStyle {
    // insets as % of render size
    static let padX: CGFloat = 0.06
    static let padY: CGFloat = 0.06
    static let montageWideLift: CGFloat = 0.04

    // ✅ NEW: extra bottom padding used only in live preview
    static let previewBottomInset: CGFloat = 0.05

    // CUSTOM size
    static func customPointSize(for renderH: CGFloat) -> CGFloat {
        max(18, renderH * 0.036)
    }

    // DATE–YEAR sizes — smaller baseline
    static func dateTitleSize(for renderH: CGFloat) -> CGFloat {
        max(20, renderH * 0.04)
    }
    static func dateYearSize(for renderH: CGFloat) -> CGFloat {
        dateTitleSize(for: renderH) * 0.85
    }

    // Slightly reduced kerning for a denser look
    static let titleKern: CGFloat = 0.6
    static let yearKern: CGFloat  = 0.7
    static let pillOpacity: CGFloat = 0.16
}



struct MontageService {

    // ───── Dependencies
    private let store = ClipStore.shared
    private let cal   = Calendar.current
    private let project: Project

    init(project: Project) {
        self.project = project
    }

    // MARK: - Clip timing helper (centralized)

    private let timingEpsilon: Double = 0.05  // ~1–2 frames wiggle room

    /// Returns the CMTimeRange (start,duration) to use for this clip's asset:
    /// - If the file is already trimmed to ~clip.duration, treat snippetStart as 0
    /// - Otherwise, trim inside the full asset using snippetStart/duration
    private func effectiveRange(
        for clip: Clip,
        asset: AVAsset,
        timescale: CMTimeScale = 600
    ) -> CMTimeRange {
        let fileSec = max(0.0, CMTimeGetSeconds(asset.duration))
        let wantSec = max(0.01, clip.duration)
        let startSec = max(0.0, clip.snippetStart)

        let treatAsTrimmed = abs(fileSec - wantSec) <= timingEpsilon

        let useStartSec = min(treatAsTrimmed ? 0.0 : startSec, max(0.0, fileSec - 0.01))
        let useLenSec   = min(wantSec, max(0.01, fileSec - useStartSec))

        let start = CMTime(seconds: useStartSec, preferredTimescale: timescale)
        let dur   = CMTime(seconds: useLenSec,   preferredTimescale: timescale)
        return CMTimeRange(start: start, duration: dur)
    }

    // MARK: - Async loaders (one read per clip)
    private func loadSegment(at url: URL, rotationDegrees: Double, zoomScale: Double, panOffsetX: Double, panOffsetY: Double) async throws -> ClipSeg {
        let asset = AVURLAsset(url: url)
        // Load properties concurrently
        async let tracks    = asset.load(.tracks)
        async let duration  = asset.load(.duration)

        let t = try await tracks
        let v = t.first(where: { $0.mediaType == .video })
        let a = t.first(where: { $0.mediaType == .audio })

        var size = CGSize.zero
        var xform = CGAffineTransform.identity

        if let v {
            async let ns = v.load(.naturalSize)
            async let pt = v.load(.preferredTransform)
            (size, xform) = try await (ns, pt)
        }
        return ClipSeg(url: url, asset: asset, vTrack: v, aTrack: a,
                       duration: try await duration,
                       naturalSize: size, preferredTransform: xform,
                       rotationDegrees: rotationDegrees,
                       zoomScale: zoomScale,
                       panOffsetX: panOffsetX,
                       panOffsetY: panOffsetY)
    }

    private func captionDate(for clip: Clip) -> Date? {
        clip.date
    }



    // MARK: Past-week helper -------------------------------------------------

    /// Clips for the past 7 calendar days (inclusive), ordered oldest → newest.
    /// Days without a clip are silently skipped.
    func weekClips(endingOn today: Date = Date()) async -> [Clip] {
        // Start = 6 days ago at local 00:00
        let startOfToday = cal.startOfDay(for: today)
        guard
            let start = cal.date(byAdding: .day, value: -6, to: startOfToday)
        else { return [] }

        // End = tonight 23:59:59.999
        let end = cal.date(byAdding: .day, value: 1, to: startOfToday)!
            .addingTimeInterval(-0.001)

        return await onMain { store.clips(from: start, to: end, in: project) }
    }

    /// Any date-interval → the existing `[Clip]` query
    func clips(in interval: DateInterval) async -> [Clip] {
        await onMain { store.clips(from: interval.start, to: interval.end, in: project) }
    }

    // MARK: – Helpers for URL-based pipeline

    private func addBackgroundMusic(
        to composition: AVMutableComposition,
        musicURL: URL,
        duration: CMTime,
        musicVol: Float,   // 0…1
        videoVol: Float
    ) throws -> (AVMutableComposition, AVAudioMix) {
        let comp = composition
        let asset = AVURLAsset(url: musicURL)
        guard let aSrc = asset.tracks(withMediaType: .audio).first else {
            return (comp, AVAudioMix())
        }

        // 1) Insert the music
        guard let bgTrack = comp.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return (comp, AVAudioMix())
        }
        try bgTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: aSrc,
            at: .zero
        )

        // 2) Lower the original and boost music
        var audioParams: [AVMutableAudioMixInputParameters] = []

        // Only add original track params if it exists
        if let origTrack = comp.tracks(withMediaType: .audio).first {
            let pOrig = AVMutableAudioMixInputParameters(track: origTrack)
            pOrig.setVolume(videoVol, at: .zero)
            audioParams.append(pOrig)
        }

        let pMusic = AVMutableAudioMixInputParameters(track: bgTrack)
        pMusic.setVolume(musicVol, at: .zero)
        audioParams.append(pMusic)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParams
        return (comp, audioMix)
    }

    // MARK: - Watermark (shared builder)
    private func buildWatermarkGroup(renderSize: CGSize,
                                     insetX: CGFloat = 0.06,
                                     insetY: CGFloat = 0.01,
                                     isPreview: Bool) -> CALayer {
        // Full canvas (flipped for UI-style coordinates)
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.isGeometryFlipped = true

        // Sizing
        let padX  = renderSize.width  * insetX
        let padY  = renderSize.height * insetY
        let markH = max(40, renderSize.height * 0.14)

        // Branded mark (already includes text)
        let mark = CALayer()
        mark.contents = UIImage(named: "WatermarkLogo")?.cgImage  // <-- your new asset name
        mark.contentsGravity = .resizeAspect
        mark.frame = CGRect(x: 0, y: 0, width: markH, height: markH)
        mark.shadowOpacity = 0.35
        mark.shadowRadius  = 2
        mark.shadowOffset  = .init(width: 0, height: 1)

        // Position as a single element
        let stack = CALayer()
        stack.frame = CGRect(x: renderSize.width - padX - markH,
                             y: padY,
                             width: markH,
                             height: markH)
        // center inside stack
        mark.frame.origin.x = (stack.bounds.width - markH) / 2
        stack.addSublayer(mark)

        container.addSublayer(stack)
        return container
    }


    // MARK: - Preview & Export adapters

    func previewWatermarkLayer(renderSize: CGSize) -> CALayer {
        buildWatermarkGroup(renderSize: renderSize, isPreview: true)
    }

    private func makeWatermarkLayer(renderSize: CGSize,
                                    insetX: CGFloat = 0.04,
                                    insetY: CGFloat = 0.015) -> CALayer {
        buildWatermarkGroup(renderSize: renderSize, insetX: insetX, insetY: insetY, isPreview: false)
    }

    // MARK: - Filter overlays (global tint)

    // MARK: - Filter overlays (cinematic tints)

    private func makeFilterOverlayLayer(
        renderSize: CGSize,
        filter: MontageFilter,
        isPreview: Bool
    ) -> CALayer? {
        guard filter != .none else { return nil }

        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.isGeometryFlipped = true
        layer.masksToBounds = false

        // Stronger for export, slightly softer in preview – but still noticeable
        let baseAlpha: CGFloat = isPreview ? 0.30 : 0.40

        switch filter {

        case .none:
            return nil

        // WARM – rich, golden “sunset” feel
        case .warm:
            layer.backgroundColor = UIColor(
                red: 1.00,
                green: 0.70,
                blue: 0.40,
                alpha: baseAlpha * 1.05
            ).cgColor

        // COOL – teal / blue, clean “arctic” feel
        case .cool:
            layer.backgroundColor = UIColor(
                red: 0.25,
                green: 0.70,
                blue: 1.00,
                alpha: baseAlpha * 1.05
            ).cgColor

        // VIVID – deeper contrast, like turning lights down
        case .vivid:
            layer.backgroundColor = UIColor(
                white: 0.0,
                alpha: baseAlpha * 0.95
            ).cgColor

        // MONO – strong neutral gray wash (B&W-ish look)
        // (This isn’t true grayscale yet, but it reads as a distinct B&W mood.)
        case .mono:
            layer.backgroundColor = UIColor(
                white: 0.15,
                alpha: baseAlpha * 1.15
            ).cgColor

        // FADE – lifted blacks + creamy highlights
        case .fade:
            layer.backgroundColor = UIColor(
                red: 1.00,
                green: 0.96,
                blue: 0.90,
                alpha: baseAlpha * 1.20
            ).cgColor

        // VINTAGE – warm sepia, nostalgic
        case .vintage:
            layer.backgroundColor = UIColor(
                red: 0.90,
                green: 0.75,
                blue: 0.55,
                alpha: baseAlpha * 1.20
            ).cgColor

        // CRISP – cool, punchy contrast
        case .crisp:
            layer.backgroundColor = UIColor(
                red: 0.05,
                green: 0.18,
                blue: 0.30,
                alpha: baseAlpha * 1.10
            ).cgColor

        // SOFT – bright matte, pastel feel
        case .soft:
            layer.backgroundColor = UIColor(
                red: 0.97,
                green: 0.97,
                blue: 1.00,
                alpha: baseAlpha * 1.10
            ).cgColor

        // MOODY – deep navy, cinematic night
        case .moody:
            layer.backgroundColor = UIColor(
                red: 0.02,
                green: 0.05,
                blue: 0.12,
                alpha: baseAlpha * 1.30
            ).cgColor
        }

        return layer
    }



    // MARK: - End card branding

    private func makeEndCardBrandingGroup(
        renderSize: CGSize,
        startAt: Double,
        logoName: String = "SplashLogo",
        badgeName: String = "AppStoreBadge",
        endCardSeconds: Double = 2.0,
        isPreview: Bool = false
    ) -> CALayer {

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        // Always use flipped coordinate system (Y=0 at top) for consistent layout
        parent.isGeometryFlipped = true
        parent.opacity = 0            // ← invisible until we fade it in

        // Sizing - logo and badges
        let logoSize = max(70, renderSize.height * 0.165)  // 10% larger logo
        let badgeW = renderSize.width * 0.342  // 10% smaller badges
        let badgeSpacing: CGFloat = renderSize.width * 0.025
        let logoToBadgeGap: CGFloat = renderSize.height * 0.025

        // Load images
        let appStoreImg = UIImage(named: badgeName)?.cgImage
        let googlePlayImg = UIImage(named: "GooglePlayBadge")?.cgImage

        // Calculate badge heights
        var badgesH: CGFloat = 0
        var badgesTotalW: CGFloat = 0
        if let appStoreImg = appStoreImg, let googlePlayImg = googlePlayImg {
            let appStoreAspect = CGFloat(appStoreImg.width) / CGFloat(appStoreImg.height)
            let googlePlayAspect = CGFloat(googlePlayImg.width) / CGFloat(googlePlayImg.height)
            let appStoreH = badgeW / max(appStoreAspect, 0.01)
            let googlePlayH = badgeW / max(googlePlayAspect, 0.01)
            badgesH = max(appStoreH, googlePlayH)
            badgesTotalW = badgeW * 2 + badgeSpacing
        } else if let appStoreImg = appStoreImg {
            let aspect = CGFloat(appStoreImg.width) / CGFloat(appStoreImg.height)
            badgesH = badgeW / max(aspect, 0.01)
            badgesTotalW = badgeW
        }

        // Total content height: logo + gap + badges
        let totalContentH = logoSize + logoToBadgeGap + badgesH

        // Center everything vertically
        // Layout: Logo on top, badges below
        let contentCenterY = renderSize.height / 2
        let contentStartY = contentCenterY - (totalContentH / 2)

        // Badges first (at top of content area), then logo below
        // This appears inverted but renders correctly due to layer compositing
        let badgesY = contentStartY
        let logoY = contentStartY + badgesH + logoToBadgeGap

        // Logo (centered)
        let mark = CALayer()
        mark.contents = UIImage(named: "WatermarkLogo")?.cgImage
        mark.contentsGravity = .resizeAspect

        // Stack for logo (for pop animation)
        let stack = CALayer()
        stack.isGeometryFlipped = true
        stack.frame = CGRect(
            x: (renderSize.width - logoSize) / 2,
            y: logoY,
            width: logoSize,
            height: logoSize
        )
        mark.frame = CGRect(x: 0, y: 0, width: logoSize, height: logoSize)
        stack.addSublayer(mark)
        parent.addSublayer(stack)

        // Badges (centered, under the logo)
        let badgesStartX = (renderSize.width - badgesTotalW) / 2

        if let appStoreImg = appStoreImg, let googlePlayImg = googlePlayImg {
            let appStoreAspect = CGFloat(appStoreImg.width) / CGFloat(appStoreImg.height)
            let googlePlayAspect = CGFloat(googlePlayImg.width) / CGFloat(googlePlayImg.height)
            let appStoreH = badgeW / max(appStoreAspect, 0.01)
            let googlePlayH = badgeW / max(googlePlayAspect, 0.01)
            let maxH = max(appStoreH, googlePlayH)

            // App Store badge (left)
            let appStoreBadge = CALayer()
            appStoreBadge.contents = appStoreImg
            appStoreBadge.contentsGravity = .resizeAspect
            appStoreBadge.frame = CGRect(
                x: badgesStartX,
                y: badgesY + (maxH - appStoreH) / 2,
                width: badgeW,
                height: appStoreH
            )
            parent.addSublayer(appStoreBadge)

            // Google Play badge (right)
            let googlePlayBadge = CALayer()
            googlePlayBadge.contents = googlePlayImg
            googlePlayBadge.contentsGravity = .resizeAspect
            googlePlayBadge.frame = CGRect(
                x: badgesStartX + badgeW + badgeSpacing,
                y: badgesY + (maxH - googlePlayH) / 2,
                width: badgeW,
                height: googlePlayH
            )
            parent.addSublayer(googlePlayBadge)
        } else if let appStoreImg = appStoreImg {
            let aspect = CGFloat(appStoreImg.width) / CGFloat(appStoreImg.height)
            let targetH = badgeW / max(aspect, 0.01)

            let badge = CALayer()
            badge.contents = appStoreImg
            badge.contentsGravity = .resizeAspect
            badge.frame = CGRect(
                x: (renderSize.width - badgeW) / 2,
                y: badgesY,
                width: badgeW,
                height: targetH
            )
            parent.addSublayer(badge)
        }


        // ── animations (tied to end-card start)
        let t0  = AVCoreAnimationBeginTimeAtZero + startAt
        let dur: CFTimeInterval = 0.24

        // MODEL STATES AT FINAL VALUES (so they persist after the fade)
        parent.opacity = 1
        stack.setAffineTransform(.identity)   // final scale = 1

        // 0) HOLD INVISIBLE UNTIL t0  (prevents early visibility even though model is 1)
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.fromValue = 0
        hold.toValue   = 0
        hold.beginTime = AVCoreAnimationBeginTimeAtZero
        hold.duration  = t0
        hold.fillMode  = .forwards
        hold.isRemovedOnCompletion = false
        parent.add(hold, forKey: "end.hold")

        // 1) FADE IN at t0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue   = 1
        fade.beginTime = t0
        fade.duration  = dur
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode  = .forwards
        fade.isRemovedOnCompletion = false
        parent.add(fade, forKey: "end.fade")

        // 2) POP SCALE (stack only)
        let holdScale = CABasicAnimation(keyPath: "transform.scale")
        holdScale.fromValue = 0.86
        holdScale.toValue   = 0.86
        holdScale.beginTime = AVCoreAnimationBeginTimeAtZero
        holdScale.duration  = t0
        holdScale.fillMode  = .forwards
        holdScale.isRemovedOnCompletion = false
        stack.add(holdScale, forKey: "end.hold.scale")

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.86
        scale.toValue   = 1.0
        scale.beginTime = t0
        scale.duration  = dur
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scale.fillMode  = .forwards
        scale.isRemovedOnCompletion = false
        stack.add(scale, forKey: "end.pop")


        return parent
    }


    // Contrast helpers
    private static func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        // sRGB relative luminance
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
        let L = 0.2126*lin(r) + 0.7152*lin(g) + 0.0722*lin(b)
        return L
    }
    private static func autoOutlineColor(for fill: UIColor) -> UIColor {
        // If fill is light → dark outline, else light outline.
        return luminance(fill) > 0.55 ? UIColor.black : UIColor.white
    }

    private static func cgImageFromText(_ text: String,
                                        font: UIFont,
                                        color: UIColor,
                                        size: CGSize,
                                        alignment: NSTextAlignment = .left,
                                        outlineWidth: CGFloat = 2.0,
                                        outlineColor: UIColor? = nil,
                                        shadowRadius: CGFloat = 2.0,
                                        shadowOffset: CGSize = .init(width: 0, height: 1),
                                        shadowOpacity: CGFloat = 0.35) -> CGImage? {
        let scale: CGFloat = 2.0
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let img = renderer.image { rctx in
            let cg = rctx.cgContext
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)
            cg.interpolationQuality = .high

            UIColor.clear.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)

            // 1) Outline pass: positive stroke width → stroke ONLY
            if outlineWidth > 0 {
                let strokeAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .paragraphStyle: paragraph,
                    .strokeColor: (outlineColor ?? Self.autoOutlineColor(for: color)),
                    .strokeWidth: outlineWidth * 1.05,   // tiny bump smooths joins
                    .foregroundColor: UIColor.clear      // ensure no fill on this pass
                ]
                // slight feather to hide miter spikes on conjunctions (E/B)
                // (keep very small to avoid glow)
                (text as NSString).draw(in: rect, withAttributes: strokeAttrs)
            }

            // 2) Fill pass: clean text, optional soft shadow
            var fillAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: color
            ]
            if shadowRadius > 0, shadowOpacity > 0 {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = shadowRadius
                shadow.shadowOffset = shadowOffset
                shadow.shadowColor = UIColor.black.withAlphaComponent(shadowOpacity)
                fillAttrs[.shadow] = shadow
            }
            (text as NSString).draw(in: rect, withAttributes: fillAttrs)
        }
        return img.cgImage
    }




    enum RenderMode { case preview, export }

    // Change signature to async
    func makeVideo(for interval: DateInterval,
                   backgroundMusicURL: URL?,
                   musicVol: Float,
                   videoVol: Float,
                   musicStartTime: TimeInterval = 0,
                   musicDuration: TimeInterval? = nil,
                   showCaptions: Bool,
                   customCaption: (text: String, anchor: CaptionAnchor3)? = nil,
                   dateCaptionAnchor: CaptionAnchor3 = .bottomLeft,
                   showBranding: Bool,
                   endCardSeconds: Double = 2.0,
                   mode: RenderMode,
                   targetSize: CGSize,
                   contentMode: ContentMode,
                   captionColor: UIColor,
                   captionFontVariant: CaptionFontVariant = .system,
                   captionPointSize: CGFloat = 24,
                   filter: MontageFilter = .none,
                   style: MontageStyle = .classic,
                   timelapseSecondsPerClip: Double = 0.5,
                   backgroundColor: UIColor = .black,
                   customCaptionNorm: CGPoint? = nil,
                   playbackSpeed: Double = 1.0) async throws
    -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?)

 {

    // 1) Resolve clips
     var segs: [(seg: ClipSeg, startOffset: TimeInterval, segmentDuration: TimeInterval, clipDate: Date?)] = []

     let clips = await onMain { store.clips(from: interval.start, to: interval.end, in: project) }
     let urls = await onMain { clips.map { store.urlForClip($0) } }

     for (index, u) in urls.enumerated() {
         try Task.checkCancellation()

         guard FileManager.default.fileExists(atPath: u.path) else {
             continue
         }

         do {
             let clip = clips[index]
             let rotation = clip.rotationDegrees

             let s = try await loadSegment(
                 at: u,
                 rotationDegrees: rotation,
                 zoomScale: clip.zoomScale,
                 panOffsetX: clip.panOffsetX,
                 panOffsetY: clip.panOffsetY
             )

             if let clipDate = clip.date {
                 let cal = Calendar.current
                 let clipDay = cal.startOfDay(for: clipDate)
                 let startDay = cal.startOfDay(for: interval.start)
                 let endDay = cal.startOfDay(for: interval.end)

                 if clipDay >= startDay && clipDay <= endDay {
                     // Use effectiveRange to handle already-trimmed files correctly
                     let range = effectiveRange(for: clip, asset: s.asset)
                     segs.append((seg: s, startOffset: range.start.seconds, segmentDuration: range.duration.seconds, clipDate: captionDate(for: clip)))
                 }
             }
         } catch {
             continue
         }
     }


     let comp  = AVMutableComposition()
     let vcomp = AVMutableVideoComposition()

     let vTrackComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
     let hasOriginalAudio = segs.contains { $0.seg.aTrack != nil }
     let aTrackComp = hasOriginalAudio
        ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        : nil

     var cursor = CMTime.zero
     var instructions: [AVVideoCompositionInstructionProtocol] = []
     var audioParams: [AVAudioMixInputParameters] = []
     var captionTimeline: [(date: Date?, duration: CMTime)] = []
     var insertedOriginalAudio = false

     for segTuple in segs {
         try Task.checkCancellation()
         autoreleasepool {
             let s = segTuple.seg
             let startOffset = segTuple.startOffset
             let segmentDuration = segTuple.segmentDuration
             let clipDate = segTuple.clipDate

             // Clamp speed to your supported range (0.5…5.0) to avoid weird edge cases.
             let sp = max(0.5, min(5.0, playbackSpeed))

             // Use the segment's startOffset and duration for non-destructive editing
             // This allows snipped segments to use specific portions of the source clip
             let segStart = CMTime(seconds: startOffset, preferredTimescale: 600)
             let segDur = CMTime(seconds: segmentDuration, preferredTimescale: 600)
             let segRange = CMTimeRange(start: segStart, duration: segDur)

             // Output duration after speed: 2.0x => half time, 0.5x => double time
             let outDurSeconds = max(0.01, segRange.duration.seconds / sp)
             let outDur = CMTime(seconds: outDurSeconds, preferredTimescale: 600)

             let insertedRange = CMTimeRange(start: cursor, duration: segRange.duration)
             let scaledRange   = CMTimeRange(start: cursor, duration: outDur)

             // Insert + scale VIDEO
             if let vt = s.vTrack, let vTrackComp {
                 try? vTrackComp.insertTimeRange(segRange, of: vt, at: cursor)
                 vTrackComp.scaleTimeRange(insertedRange, toDuration: outDur)   // ✅ speed applies to video

                 let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrackComp)
                 let renderSize = targetSize
                 let userRotationDegrees = s.rotationDegrees

                 // 🔍 DEBUG: Log clip info

                 // Build transform step by step
                 // 1. Start with preferred transform (camera orientation)
                 var xform = s.preferredTransform

                 // Calculate video size after preferred transform
                 let afterPreferred = CGRect(origin: .zero, size: s.naturalSize)
                     .applying(xform)
                     .standardized


                 // 2. Apply user rotation if needed - CORRECTED
                 var rotatedSize = afterPreferred.size
                 if userRotationDegrees != 0 {
                     let radians = userRotationDegrees * .pi / 180.0

                     // For user rotation, we need to:
                     // a) Move center of video to origin
                     // b) Rotate around origin
                     // c) Move back
                     let centerX = afterPreferred.size.width / 2.0
                     let centerY = afterPreferred.size.height / 2.0

                     let t1 = CGAffineTransform(translationX: centerX, y: centerY)
                     let r = CGAffineTransform(rotationAngle: radians)
                     let t2 = CGAffineTransform(translationX: -centerX, y: -centerY)

                     // Compose: move to origin, rotate, move back, then apply to existing transform
                     xform = xform.concatenating(t2).concatenating(r).concatenating(t1)

                     // Recalculate size after rotation
                     let afterRotation = CGRect(origin: .zero, size: s.naturalSize)
                         .applying(xform)
                         .standardized
                     rotatedSize = afterRotation.size

                 }

                 // 3. Calculate scale to fit/fill the rotated size
                 let scale: CGFloat = (contentMode == .fill)
                     ? max(renderSize.width / rotatedSize.width, renderSize.height / rotatedSize.height)
                     : min(renderSize.width / rotatedSize.width, renderSize.height / rotatedSize.height)


                 // 4. Apply scale
                 xform = xform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

                 // 5. Calculate translation to center the scaled, rotated video
                 // After scaling, we need to recalculate the bounding box
                 let scaledBounds = CGRect(origin: .zero, size: s.naturalSize)
                     .applying(xform)
                     .standardized

                 // Center it in the render frame
                 let tx = (renderSize.width - scaledBounds.width) / 2.0 - scaledBounds.origin.x
                 let ty = (renderSize.height - scaledBounds.height) / 2.0 - scaledBounds.origin.y


                 // Apply final centering translation
                 xform = xform.concatenating(CGAffineTransform(translationX: tx, y: ty))


                 layer.setTransform(xform, at: cursor)

                 // Create instruction for this clip
                 let instr = AVMutableVideoCompositionInstruction()
                 instr.timeRange = scaledRange
                 instr.layerInstructions = [layer]
                 instr.backgroundColor = backgroundColor.cgColor
                 instructions.append(instr)
             }

             // Insert + scale ORIGINAL AUDIO (don’t mute it)
             if let at = s.aTrack, let aTrackComp {
                 do {
                     try aTrackComp.insertTimeRange(segRange, of: at, at: cursor)
                     aTrackComp.scaleTimeRange(insertedRange, toDuration: outDur)  // ✅ speed applies to clip audio
                     insertedOriginalAudio = true
                 } catch {
                     print("[MontageService] original audio insert failed:", error)
                 }
             }

             captionTimeline.append((date: clipDate, duration: outDur))

             cursor = cursor + outDur                                         // ✅ cursor advances by output duration
         }
     }

     if insertedOriginalAudio, let aTrackComp {
         let ip = AVMutableAudioMixInputParameters(track: aTrackComp)
         ip.setVolume(videoVol, at: .zero)
         audioParams.append(ip)
     }

     // Extend timeline for end card (black) **only** when branding is ON
     let tailDur = CMTime(seconds: endCardSeconds, preferredTimescale: 600)
     let endCardStart = cursor

     let shouldShowEndCard = (showBranding && endCardSeconds > 0)

     if shouldShowEndCard {
         comp.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: tailDur))
         cursor = cursor + tailDur
     }

     // 5) Finalize video composition (one pass, using the instructions we built)
     // Ensure the tail has its own instruction so the renderer doesn't hold the last frame
     // 5) Finalize video composition (one pass, using the instructions we built)
     if shouldShowEndCard {
         let tailInstr = AVMutableVideoCompositionInstruction()
         tailInstr.timeRange = CMTimeRange(start: endCardStart, duration: tailDur)
         tailInstr.backgroundColor = UIColor.black.cgColor
         tailInstr.layerInstructions = []   // no video layers during end card
         instructions.append(tailInstr)
     }

     vcomp.instructions = instructions
     vcomp.frameDuration = CMTime(value: 1, timescale: 30)
     vcomp.renderSize    = targetSize


     for (idx, ins) in instructions.enumerated() {
         if let mi = ins as? AVMutableVideoCompositionInstruction {
             mi.backgroundColor = backgroundColor.cgColor
             if let cg = mi.backgroundColor {
                 let comps = UIColor(cgColor: cg).cgColor.components ?? []
             }
         }
     }

     // If you want the end-card to stay black, re-assert it after:
     if shouldShowEndCard, let tail = instructions.last as? AVMutableVideoCompositionInstruction {
         tail.backgroundColor = UIColor.black.cgColor
     }


     // 2. mutate comp if music is requested
     if let musicURL = backgroundMusicURL {
         let musicAsset = AVURLAsset(url: musicURL)

         async let tracksAsync   = musicAsset.load(.tracks)
         async let durationAsync = musicAsset.load(.duration)

         if let mTrack = try? await tracksAsync.first(where: { $0.mediaType == .audio }) {
             let assetDuration = (try? await durationAsync) ?? .zero
             let totalDuration = cursor

             let effectiveMusicStart = CMTime(seconds: musicStartTime, preferredTimescale: 600)
             let effectiveMusicDuration: CMTime
             if let customDuration = musicDuration {
                 effectiveMusicDuration = CMTime(seconds: customDuration, preferredTimescale: 600)
             } else {
                 effectiveMusicDuration = totalDuration - effectiveMusicStart
             }

             if let mComp = comp.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
             ) {
                 if assetDuration > .zero, effectiveMusicDuration > .zero {
                     var insertAt = effectiveMusicStart
                     let musicEndTime = effectiveMusicStart + effectiveMusicDuration

                     while insertAt < musicEndTime {
                         let remaining = musicEndTime - insertAt
                         let chunk = CMTimeMinimum(assetDuration, remaining)
                         let range = CMTimeRange(start: .zero, duration: chunk)

                         do {
                             try mComp.insertTimeRange(range, of: mTrack, at: insertAt)
                         } catch {
                             break
                         }

                         insertAt = insertAt + chunk
                     }

                     let mp = AVMutableAudioMixInputParameters(track: mComp)
                     if musicStartTime > 0 {
                         mp.setVolume(0, at: .zero)
                         mp.setVolume(musicVol, at: effectiveMusicStart)
                     } else {
                         mp.setVolume(musicVol, at: .zero)
                     }
                     audioParams.append(mp)
                 }
             }
         }
     }



     let vc = vcomp


     if mode == .export {
         let parent = CALayer()
         parent.frame = CGRect(origin: .zero, size: vc.renderSize)
         parent.isGeometryFlipped = true
         parent.masksToBounds = false
         parent.beginTime  = AVCoreAnimationBeginTimeAtZero
         parent.speed      = 1
         parent.timeOffset = 0

         // NEW: explicit background so CA render isn’t “transparent → black”
         parent.backgroundColor = backgroundColor.cgColor // harmless redundancy
         parent.isOpaque = true

         let bgLayer = CALayer()
         bgLayer.frame = parent.bounds
         bgLayer.backgroundColor = backgroundColor.cgColor
         bgLayer.isOpaque = true
         parent.addSublayer(bgLayer)  // add first so it sits behind

         // 1) Base video layer
         let videoLayer = CALayer()
         videoLayer.frame = parent.bounds
         videoLayer.masksToBounds = false
         videoLayer.zPosition = 0
         videoLayer.beginTime  = AVCoreAnimationBeginTimeAtZero
         videoLayer.speed      = 1
         videoLayer.timeOffset = 0
         parent.addSublayer(videoLayer)

         // 2) Overlays container (above video)
         let contentGroup = CALayer()
         contentGroup.frame = parent.bounds
         contentGroup.isGeometryFlipped = true
         contentGroup.masksToBounds = false
         contentGroup.zPosition = 100
         contentGroup.beginTime  = AVCoreAnimationBeginTimeAtZero
         contentGroup.speed      = 1
         contentGroup.timeOffset = 0
         parent.addSublayer(contentGroup)

         // 2.5) Black cover that fades up at the start of the tail
         if shouldShowEndCard {
             let blackCover = CALayer()
             blackCover.frame = parent.bounds
             blackCover.backgroundColor = UIColor.black.cgColor
             blackCover.opacity = 0
             blackCover.zPosition = 90   // below branding, above base video
             parent.addSublayer(blackCover)

             let endCardStartSec = CMTimeGetSeconds(endCardStart)
             let fadeUp = CABasicAnimation(keyPath: "opacity")
             fadeUp.fromValue = 0
             fadeUp.toValue   = 1
             fadeUp.beginTime = AVCoreAnimationBeginTimeAtZero + endCardStartSec
             fadeUp.duration  = 0.12
             fadeUp.fillMode  = .forwards
             fadeUp.isRemovedOnCompletion = false
             blackCover.add(fadeUp, forKey: "tail.black.fadeUp")
         }

         // 3) Filter overlay (global tint over video; sits under captions & watermark)
         if let filterLayer = makeFilterOverlayLayer(
            renderSize: vc.renderSize,
            filter: filter,
            isPreview: false
         ) {
             filterLayer.zPosition = 50
             contentGroup.addSublayer(filterLayer)
         }

         // 4) Captions (mutually exclusive)
         if showCaptions {
             if let custom = customCaption,
                !custom.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 let customLayer = exportCustomCaptionLayer(
                     renderSize: vc.renderSize,
                     text: custom.text,
                     anchor: custom.anchor,
                     fontVariant: captionFontVariant,
                     fontSize: captionPointSize,
                     captionColor: captionColor,
                     normalizedPosition: customCaptionNorm     // ⬅️ dragged position
                 )
                 customLayer.zPosition = 200
                 contentGroup.addSublayer(customLayer)
            } else {
                let dateLayer = Self.exportCaptionLayer(
                    for: captionTimeline,
                    renderSize: vc.renderSize,
                    anchor: dateCaptionAnchor,
                    captionColor: captionColor
                )
                 dateLayer.zPosition = 200
                 contentGroup.addSublayer(dateLayer)
             }
         }


         // 5) Watermark (text ABOVE logo inside the returned container)
         if showBranding {
             let wm = makeWatermarkLayer(renderSize: vc.renderSize)
             wm.zPosition = 300
             contentGroup.addSublayer(wm)
         }

         // 5.5) Fade OUT overlays for the end-card and show the centered logo
         if shouldShowEndCard {
             let endCardStartSec = CMTimeGetSeconds(endCardStart)

             // Fade the whole overlay group (captions + watermark) right at tail start
             let fade = CABasicAnimation(keyPath: "opacity")
             fade.fromValue = 1
             fade.toValue   = 0
             fade.beginTime = AVCoreAnimationBeginTimeAtZero + endCardStartSec
             fade.duration  = 0.12
             fade.fillMode  = .forwards
             fade.isRemovedOnCompletion = false
             contentGroup.add(fade, forKey: "fade.out.tail")

             // NEW: add branding group (logo + Snap Second + bottom badge)
             let branding = makeEndCardBrandingGroup(
                renderSize: vc.renderSize,
                startAt: comp.duration.seconds - endCardSeconds,
                 logoName: "SplashLogo",
                 badgeName: "AppStoreBadge",
                 endCardSeconds: endCardSeconds
             )
             branding.zPosition = 1000
             parent.addSublayer(branding)
         }

         // 6) Attach Core Animation overlay to the export
         vc.animationTool = AVVideoCompositionCoreAnimationTool(
             postProcessingAsVideoLayer: videoLayer,
             in: parent
         )
     }
     let finalMix: AVMutableAudioMix?
     if audioParams.isEmpty {
         finalMix = nil
     } else {
         let mix = AVMutableAudioMix()
         mix.inputParameters = audioParams
         finalMix = mix
     }

        return (comp, vc, finalMix)
    }

    // Build the preview overlay tree (to be attached with AVSynchronizedLayer)
    func makePreviewOverlay(renderSize: CGSize,
                            clips: [Clip],
                            showCaptions: Bool,
                            customCaption: (text: String, anchor: CaptionAnchor3)?,
                            dateCaptionAnchor: CaptionAnchor3,
                            showBranding: Bool,
                            endCardSeconds: Double,
                            compositionDuration: CMTime,
                            filter: MontageFilter,
                            captionColor: UIColor,
                            captionFontVariant: CaptionFontVariant = .system,
                            captionPointSize: CGFloat = 24,
                            playbackSpeed: Double = 1.0) async -> CALayer
    {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = false

        // Everything that should disappear on the tail goes in here:
        let contentGroup = CALayer()
        contentGroup.frame = parent.bounds
        contentGroup.isGeometryFlipped = true
        contentGroup.masksToBounds = false
        contentGroup.zPosition = 100
        contentGroup.beginTime = AVCoreAnimationBeginTimeAtZero
        contentGroup.speed = 1
        contentGroup.timeOffset = 0
        parent.addSublayer(contentGroup)

        // Global filter tint (same look as export, but preview-safe alpha)
        if let filterLayer = makeFilterOverlayLayer(
            renderSize: renderSize,
            filter: filter,
            isPreview: true
        ) {
            filterLayer.zPosition = 50
            contentGroup.addSublayer(filterLayer)
        }


        if showCaptions {
            if let custom = customCaption,
               !custom.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let customLayer = exportCustomCaptionLayer(
                    renderSize: renderSize,
                    text: custom.text,
                    anchor: custom.anchor,
                    fontVariant: captionFontVariant,
                    fontSize: captionPointSize,
                    captionColor: captionColor
                )
                // Anchor the child to media time; parent stays at default timing.
                customLayer.beginTime = AVCoreAnimationBeginTimeAtZero
                customLayer.speed     = 1
                customLayer.zPosition = 200
                contentGroup.addSublayer(customLayer)
            } else {
                let dateLayer = await exportCaptionLayer(
                    for: clips,
                    renderSize: renderSize,
                    anchor: dateCaptionAnchor,
                    captionColor: captionColor,
                    playbackSpeed: playbackSpeed
                )
                dateLayer.beginTime = AVCoreAnimationBeginTimeAtZero
                dateLayer.speed     = 1
                dateLayer.zPosition = 200
                contentGroup.addSublayer(dateLayer)
            }
        }



        // Watermark
        if showBranding {
            let wm = previewWatermarkLayer(renderSize: renderSize)
            contentGroup.addSublayer(wm)
        }

        let shouldShowEndCard = (showBranding && endCardSeconds > 0)

        // Fade OUT content at the start of the tail
        if shouldShowEndCard {
            let t0 = AVCoreAnimationBeginTimeAtZero + (compositionDuration.seconds - endCardSeconds)

            // Fade out contentGroup (captions + watermark) at tail start
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.beginTime = t0
            fadeOut.duration = 0.12
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            contentGroup.add(fadeOut, forKey: "fade.out.tail")

            // Black cover that cross-fades up right at the start of the tail
            let blackCover = CALayer()
            blackCover.frame = CGRect(origin: .zero, size: renderSize)
            blackCover.backgroundColor = UIColor.black.cgColor
            blackCover.opacity = 0
            blackCover.zPosition = 500  // above contentGroup (100), below branding (1000)
            parent.addSublayer(blackCover)

            let fadeUp = CABasicAnimation(keyPath: "opacity")
            fadeUp.fromValue = 0
            fadeUp.toValue = 1
            fadeUp.beginTime = t0
            fadeUp.duration = 0.12
            fadeUp.fillMode = .forwards
            fadeUp.isRemovedOnCompletion = false
            blackCover.add(fadeUp, forKey: "fadeUpTail")

            // Branding group (logo + store badges)
            let branding = makeEndCardBrandingGroup(
                renderSize: renderSize,
                startAt: compositionDuration.seconds - endCardSeconds,
                logoName: "SplashLogo",
                badgeName: "AppStoreBadge",
                endCardSeconds: endCardSeconds,
                isPreview: true
            )
            branding.zPosition = 1000
            parent.addSublayer(branding)
        }

        return parent
    }



    func exportCaptionLayer(for clips: [Clip],
                            renderSize: CGSize,
                            anchor: CaptionAnchor3,
                            captionColor: UIColor,
                            playbackSpeed: Double = 1.0) async -> CALayer {
        // Build per-clip timeline (start/duration) accounting for playback speed
        var timeline: [(date: Date?, duration: CMTime)] = []
        let sp = max(0.5, min(5.0, playbackSpeed))

        for clip in clips {
            let url = await onMain { store.urlForClip(clip) }

            // Validate file exists - skip if missing (matches makeVideo behavior)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            // Use clip.duration (stored duration) NOT effectiveRange duration.
            // This matches makeVideo() behavior where clip.duration is used for composition,
            // even when the actual video file is shorter (video gets scaled/held to fill).
            let scaledDuration = CMTime(seconds: max(0.01, clip.duration) / sp,
                                       preferredTimescale: 600)

            timeline.append((date: captionDate(for: clip), duration: scaledDuration))
        }

        return Self.exportCaptionLayer(
            for: timeline,
            renderSize: renderSize,
            anchor: anchor,
            captionColor: captionColor
        )
    }

    private static func exportCaptionLayer(
        for timeline: [(date: Date?, duration: CMTime)],
        renderSize: CGSize,
        anchor: CaptionAnchor3,
        captionColor: UIColor
    ) -> CALayer {
        var t = CMTime.zero
        let totalCaptionSeconds = max(
            0.01,
            timeline.reduce(0.0) { $0 + max(0.0, $1.duration.seconds) }
        )

        // Flipped export space
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true

        // Sizing & insets
        let padX = renderSize.width  * CaptionStyle.padX
        let padY = renderSize.height * CaptionStyle.padY
        let titleSize = CaptionStyle.dateTitleSize(for: renderSize.height)
        let yearSize  = CaptionStyle.dateYearSize(for: renderSize.height)

        // Slightly tighter per-line boxes (still safe for ascenders/descenders)
        let lineH1    = titleSize * 1.02
        let lineH2    = yearSize * 1.02

        // Reduce interline gap (and clamp so it never gets too big)
        let gap       = max(2, min(4, titleSize * 0.04))

        let width     = renderSize.width - padX * 2
        let height    = lineH1 + gap + lineH2

        let extraBottom = renderSize.height * CaptionStyle.previewBottomInset
        let y = renderSize.height - padY - height - extraBottom

        // NEW: let alignment do the horizontal work inside the padded width
        let textAlign: NSTextAlignment = {
            switch anchor {
            case .bottomLeft:   return .left
            case .bottomCenter: return .center
            case .bottomRight:  return .right
            }
        }()

        // (optional) keep x at padX for all anchors – alignment handles placement
        let x: CGFloat = padX

        let df1 = DateFormatter(); df1.setLocalizedDateFormatFromTemplate("MMMM d")
        let df2 = DateFormatter(); df2.setLocalizedDateFormatFromTemplate("yyyy")

        for entry in timeline {
            let seg = (start: t, duration: entry.duration)
            t = t + entry.duration
            guard let d = entry.date else { continue }

            let origin = Self.bottomRowOrigin(
                for: .init(width: width, height: height),
                anchor: anchor,
                renderSize: renderSize,
                extraLiftPercent: CaptionStyle.montageWideLift
            )

            let group = CALayer()
            group.frame = CGRect(origin: origin, size: .init(width: width, height: height))
            group.opacity = 0

            // Line 1: MONTH DAY (semibold, uppercase)
            let titleFont = UIFont.systemFont(ofSize: titleSize, weight: .semibold)
            if let cg1 = cgImageFromText(
                df1.string(from: d).uppercased(),
                font: titleFont,
                color: captionColor,                              // full opacity for the date title
                size: CGSize(width: width, height: lineH1),
                alignment: textAlign,
                outlineWidth: 2.0,                                // NEW
                outlineColor: nil,                                // auto (black for light text, white for dark)
                shadowRadius: 2.0, shadowOffset: .init(width: 0, height: 1), shadowOpacity: 0.35
            ) {
                let l1 = CALayer()
                l1.contents = cg1
                l1.contentsScale = 2.0
                l1.frame = CGRect(x: 0, y: 0, width: width, height: lineH1)
                group.addSublayer(l1)
            }

            // Line 2: YEAR (regular)
            let yearFont = UIFont.systemFont(ofSize: yearSize, weight: .regular)
            if let cg2 = cgImageFromText(
                df2.string(from: d),
                font: yearFont,
                color: captionColor.withAlphaComponent(0.92),     // retain your subtlety
                size: CGSize(width: width, height: lineH2),
                alignment: textAlign,
                outlineWidth: 1.6,                                // NEW
                outlineColor: nil,
                shadowRadius: 2.0, shadowOffset: .init(width: 0, height: 1), shadowOpacity: 0.35
            ) {
                let l2 = CALayer()
                l2.contents = cg2
                l2.contentsScale = 2.0
                l2.frame = CGRect(x: 0, y: lineH1 + gap, width: width, height: lineH2)
                group.addSublayer(l2)
            }

            group.add(
                Self.captionOpacityAnimation(
                    start: seg.start.seconds,
                    duration: seg.duration.seconds,
                    totalDuration: totalCaptionSeconds
                ),
                forKey: "timeline"
            )

            parent.addSublayer(group)
        }

        return parent
    }

    private static func captionOpacityAnimation(
        start: Double,
        duration: Double,
        totalDuration: Double
    ) -> CAKeyframeAnimation {
        let clampedStart = max(0.0, start)
        let clampedDuration = max(0.01, duration)
        let end = clampedStart + clampedDuration
        let total = max(0.01, totalDuration, end)
        let fade = min(0.12, clampedDuration * 0.12)
        let fadeInEnd = min(end, clampedStart + fade)
        let fadeOutStart = max(fadeInEnd, end - fade)

        var points: [(time: Double, opacity: Double)] = []
        func append(_ time: Double, _ opacity: Double) {
            let normalized = min(max(time / total, 0), 1)
            if let last = points.last, abs(last.time - normalized) < 0.0001 {
                points[points.count - 1] = (normalized, opacity)
            } else if normalized > (points.last?.time ?? -1) {
                points.append((normalized, opacity))
            }
        }

        if clampedStart <= 0.0001 {
            append(0, 1)
        } else {
            append(0, 0)
            append(clampedStart, 0)
            append(fadeInEnd, 1)
        }
        append(fadeOutStart, 1)
        append(end, 0)
        append(total, 0)

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = points.map { NSNumber(value: $0.opacity) }
        animation.keyTimes = points.map { NSNumber(value: $0.time) }
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = total
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    // MARK: - Custom caption export layer
    private func exportCustomCaptionLayer(renderSize: CGSize,
                                          text: String,
                                          anchor: CaptionAnchor3,
                                          fontVariant: CaptionFontVariant,
                                          fontSize: CGFloat,
                                          captionColor: UIColor,
                                          normalizedPosition: CGPoint? = nil) -> CALayer {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true
        parent.masksToBounds = true  // Clip caption at render boundaries (match preview behavior)
        parent.beginTime  = AVCoreAnimationBeginTimeAtZero
        parent.speed      = 1
        parent.timeOffset = 0

        // Match VideoContainer's proportional inset: 16px on a ~350px preview height
        // Scale proportionally based on render height to match the preview appearance
        let referencePreviewHeight: CGFloat = 350.0
        let baseInset: CGFloat = (renderSize.height / referencePreviewHeight) * 16.0

        // Use the same ".regular + design" logic as SwiftUI
        let uiFont = uiFont(for: fontVariant, size: fontSize, weight: .regular)

        // Layout box for the text in *render* space
        let layoutWidth  = max(renderSize.width  - baseInset * 2, 1)
        let layoutHeight = max(fontSize * 1.35, 1)

        // Center alignment to match TextField’s .multilineTextAlignment(.center)
        let alignment: NSTextAlignment = .center

        // 1️⃣ Measure the actual text width so we don't treat it as full safe width
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment

        let measureAttrs: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .paragraphStyle: paragraph
        ]

        let measuredRect = (text as NSString).boundingRect(
            with: CGSize(width: layoutWidth, height: layoutHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: measureAttrs,
            context: nil
        ).integral

        let textWidth  = max(1, min(measuredRect.width, layoutWidth))
        let textHeight = layoutHeight

        // 2️⃣ Render into a snug image of that width
        // Scale shadow properties to match preview appearance (3px radius, 1px offset on ~350px preview)
        let scale = renderSize.height / referencePreviewHeight
        let scaledShadowRadius: CGFloat = 3.0 * scale
        let scaledShadowOffset = CGSize(width: 0, height: 1.0 * scale)

        guard let cg = Self.cgImageFromText(
            text,
            font: uiFont,
            color: captionColor,
            size: CGSize(width: textWidth, height: textHeight),
            alignment: alignment,
            outlineWidth: 0,          // keep matching preview
            outlineColor: nil,
            shadowRadius: scaledShadowRadius,
            shadowOffset: scaledShadowOffset,
            shadowOpacity: 0.7
        ) else {
            return parent
        }

        // --- Positioning: simple percentage-based (matches VideoContainer) ---
        // x=0 means left edge, x=0.5 means center, x=1 means right edge
        // Values outside 0-1 allow off-screen positioning (will be clipped by masksToBounds)

        var centerX: CGFloat
        var centerY: CGFloat

        if let norm = normalizedPosition {
            // Direct percentage of render size - same as preview
            centerX = norm.x * renderSize.width
            centerY = norm.y * renderSize.height
        } else {
            // Fallback for anchor-based positioning
            let fallback = Self.bottomRowOrigin(
                for: CGSize(width: textWidth, height: textHeight),
                anchor: anchor,
                renderSize: renderSize,
                extraLiftPercent: CaptionStyle.montageWideLift
            )
            centerX = fallback.x + textWidth  / 2
            centerY = fallback.y + textHeight / 2
        }

        let origin = CGPoint(x: centerX - textWidth / 2,
                             y: centerY - textHeight / 2)

        let layer = CALayer()
        layer.contents = cg
        layer.contentsScale = UIScreen.main.scale
        layer.frame = CGRect(origin: origin,
                             size: CGSize(width: textWidth, height: textHeight))

        parent.addSublayer(layer)
        return parent
    }


    private func captionOverlay(
        clips: [Clip],
        timeline: [(start: CMTime, duration: CMTime)],
        renderSize: CGSize,
        includeVideoLayer: Bool = true,
        anchor: CaptionAnchor3 = .bottomLeft,
        extraBottom: CGFloat = 0          // ✅ NEW
    ) -> (CALayer, CALayer) {

        // parent holds video layer + every CATextLayer
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true

        let videoLayer = CALayer()
        if includeVideoLayer {
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)          // ← only when exporting
        }          // sits behind text

        let df1 = DateFormatter() // line 1: “AUGUST 21”
        df1.setLocalizedDateFormatFromTemplate("MMMM d")

        let df2 = DateFormatter() // line 2: “2025”
        df2.setLocalizedDateFormatFromTemplate("yyyy")

        let totalCaptionSeconds = max(
            0.01,
            timeline.reduce(0.0) { partial, segment in
                max(partial, segment.start.seconds + segment.duration.seconds)
            }
        )
        for (idx, clip) in clips.enumerated() {
            guard idx < timeline.count else { continue }
            // Skip clips without a valid date to prevent crashes
            guard let clipDate = captionDate(for: clip) else {
                continue
            }
            let seg = timeline[idx]

            let padX: CGFloat = renderSize.width  * CaptionStyle.padX
            let padY: CGFloat = renderSize.height * CaptionStyle.padY

            let titleSize = CaptionStyle.dateTitleSize(for: renderSize.height)
            let yearSize  = CaptionStyle.dateYearSize(for: renderSize.height)

            let pointSize: CGFloat = 76
            let font = UIFont.systemFont(ofSize: pointSize, weight: .regular)

            // ── 2️⃣ build attributed two-line string ───────────────
            let paragraph = NSMutableParagraphStyle()
            switch anchor {
            case .bottomLeft:   paragraph.alignment = .left
            case .bottomCenter: paragraph.alignment = .center
            case .bottomRight:  paragraph.alignment = .right
            }            // negative pulls lines together

            paragraph.lineSpacing = -min(8, titleSize * 0.22)

            let fullString = "\(df1.string(from: clipDate))\n\(df2.string(from: clipDate))"

            let locale = Locale.current
            let monthDay = df1.string(from: clipDate).uppercased(with: locale)
            let year     = df2.string(from: clipDate)

            // at top (already added above): import CoreText

            // Replace titleAttrs / yearAttrs dictionaries:
            let titleUIFont = UIFont.systemFont(ofSize: titleSize, weight: .semibold)
            let yearUIFont  = UIFont.systemFont(ofSize: yearSize,  weight: .regular)
            let ctTitleFont = CTFontCreateWithName(titleUIFont.fontName as CFString, titleUIFont.pointSize, nil)
            let ctYearFont  = CTFontCreateWithName(yearUIFont.fontName  as CFString, yearUIFont.pointSize,  nil)

            var ctAlignment: CTTextAlignment
            switch anchor {
            case .bottomLeft:   ctAlignment = .left
            case .bottomCenter: ctAlignment = .center
            case .bottomRight:  ctAlignment = .right
            }
            var settings = [
              CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &ctAlignment),
            ]
            let ctParagraph = CTParagraphStyleCreate(settings, settings.count)

            let titleAttrs: [NSAttributedString.Key: Any] = [
              kCTFontAttributeName as NSAttributedString.Key: ctTitleFont,
              kCTForegroundColorAttributeName as NSAttributedString.Key: UIColor.white.withAlphaComponent(0.96).cgColor,
              kCTKernAttributeName as NSAttributedString.Key: CaptionStyle.titleKern,
              kCTParagraphStyleAttributeName as NSAttributedString.Key: ctParagraph
            ]

            let yearAttrs: [NSAttributedString.Key: Any] = [
              kCTFontAttributeName as NSAttributedString.Key: ctYearFont,
              kCTForegroundColorAttributeName as NSAttributedString.Key: UIColor.white.withAlphaComponent(0.92).cgColor,
              kCTKernAttributeName as NSAttributedString.Key: CaptionStyle.yearKern,
              kCTParagraphStyleAttributeName as NSAttributedString.Key: ctParagraph
            ]

            let composed = NSMutableAttributedString(string: monthDay + "\n", attributes: titleAttrs)
            composed.append(NSAttributedString(string: year, attributes: yearAttrs))

            let txt = CATextLayer()
            txt.string = composed
            txt.isWrapped = true
            txt.alignmentMode = {
                switch anchor {
                case .bottomLeft:   return .left
                case .bottomCenter: return .center
                case .bottomRight:  return .right
                }
            }()
            txt.shadowOpacity = 0.85
            txt.shadowRadius  = 3.5
            txt.shadowOffset  = CGSize(width: 0, height: 1)

            // frame: bottom-row, left/center/right with safe insets
            let width  = renderSize.width - padX * 2
            let height = titleSize + yearSize + 6 // matches lineSpacing choice
            let y = renderSize.height - padY - height - extraBottom
            let x: CGFloat = {
                switch anchor {
                case .bottomLeft:   return padX
                case .bottomCenter: return (renderSize.width - width) / 2
                case .bottomRight:  return renderSize.width - padX - width
                }
            }()
            txt.frame = CGRect(x: x, y: y, width: width, height: height)
            txt.shadowOpacity = 0.85
            txt.shadowRadius  = 4
            txt.contentsScale = 2.0
            txt.string = composed


            txt.opacity = 0

            txt.add(
                Self.captionOpacityAnimation(
                    start: seg.start.seconds,
                    duration: seg.duration.seconds,
                    totalDuration: totalCaptionSeconds
                ),
                forKey: "timeline"
            )


            parent.addSublayer(txt)

        }


        return (parent, videoLayer)
    }

    @inline(__always)
    private static func bottomRowOrigin(
        for box: CGSize,
        anchor: CaptionAnchor3,
        renderSize: CGSize,
        padXPercent: CGFloat = CaptionStyle.padX,
        padYPercent: CGFloat = CaptionStyle.padY,
        extraLiftPercent: CGFloat = 0.0
    ) -> CGPoint {
        let padX = renderSize.width  * padXPercent
        let padY = renderSize.height * padYPercent
        let lift = renderSize.height * extraLiftPercent   // NEW

        let x: CGFloat = {
            switch anchor {
            case .bottomLeft:   return padX
            case .bottomCenter: return (renderSize.width - box.width) / 2.0
            case .bottomRight:  return renderSize.width - padX - box.width
            }
        }()
        let y = renderSize.height - padY - box.height - lift   // NEW
        return CGPoint(x: x, y: y)
    }
}

// MARK: Public helper ─ preview overlay
extension MontageService {
    static func onboardingPreviewCaptionLayer(
        for timeline: [OnboardingPreviewTimelineEntry],
        renderSize: CGSize,
        anchor: CaptionAnchor3 = .bottomLeft,
        captionColor: UIColor = .white
    ) -> CALayer {
        Self.exportCaptionLayer(
            for: timeline.map {
                (
                    date: Optional($0.date),
                    duration: CMTime(seconds: $0.duration, preferredTimescale: 600)
                )
            },
            renderSize: renderSize,
            anchor: anchor,
            captionColor: captionColor
        )
    }

    /// Build a CALayer tree that drives date captions during *playback*
    /// (no Core-Animation tool; safe for AVPlayer).
    func previewCaptionLayer(for clips: [Clip],
                              renderSize: CGSize,
                             anchor: CaptionAnchor3,
                             playbackSpeed: Double = 1.0) async -> CALayer {
        // Build timeline exactly the same way you do for export
        var timeline: [(start: CMTime, duration: CMTime)] = []
        var t = CMTime.zero
        let sp = max(0.5, min(5.0, playbackSpeed))

        for clip in clips {
            let url   = await onMain { store.urlForClip(clip) }
            let asset = AVURLAsset(url: url)
            let seg = effectiveRange(for: clip, asset: asset)

            // Apply speed adjustment
            let scaledDuration = CMTime(seconds: seg.duration.seconds / sp,
                                       preferredTimescale: seg.duration.timescale)

            timeline.append((t, scaledDuration))
            t = t + scaledDuration
        }

        // extension MontageService { func previewCaptionLayer(...) }
        let (parent, _) = captionOverlay(
          clips: clips,
          timeline: timeline,
          renderSize: renderSize,
          includeVideoLayer: false,
          anchor: anchor,
          extraBottom: 0
        )

        return parent
    }

    func previewCustomCaptionLayer(renderSize: CGSize,
                                   text: String,
                                   anchor: CaptionAnchor3,
                                   fontVariant: CaptionFontVariant,
                                   fontSize: CGFloat,
                                   captionColor: UIColor) -> CALayer {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true

        parent.beginTime  = AVCoreAnimationBeginTimeAtZero
         parent.speed      = 1
         parent.timeOffset = 0
         parent.removeAllAnimations()

        let padX = renderSize.width  * CaptionStyle.padX
        let padY = renderSize.height * CaptionStyle.padY
        let extra = renderSize.height * CaptionStyle.previewBottomInset   // ✅ NEW

        let lineH    = fontSize * 1.35
        let width    = renderSize.width - padX * 2

        let originX: CGFloat = padX
        let originY: CGFloat = renderSize.height - padY - lineH - extra

        let bg = CALayer()
        bg.frame  = CGRect(x: originX - 10, y: originY - 6, width: width + 20, height: lineH + 12)

        let uiFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold) // ignore variant for custom

        let attr = NSAttributedString(
          string: text,
          attributes: [
            .font: uiFont,
            .foregroundColor: captionColor,
            .kern: 0.3
          ]
        )

        let txt = CATextLayer()
        txt.contentsScale = UIScreen.main.scale
        txt.string = attr
        txt.isWrapped = false
        txt.truncationMode = .end
        txt.alignmentMode = {
            switch anchor {
            case .bottomLeft:   return .left
            case .bottomCenter: return .center
            case .bottomRight:  return .right
            }
        }()
        txt.shadowOpacity = 0.8
        txt.shadowRadius  = 2
        txt.shadowOffset  = CGSize(width: 0, height: 1)
        txt.frame = CGRect(x: originX,       y: originY,     width: width,       height: lineH)

        parent.addSublayer(bg)
        parent.addSublayer(txt)
        return parent
    }


}
