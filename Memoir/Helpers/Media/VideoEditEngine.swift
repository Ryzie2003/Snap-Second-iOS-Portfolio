import AVFoundation
import CoreGraphics

public enum QuarterTurns: Int { case t0 = 0, t1, t2, t3 } // kept for API compatibility (ignored)
public enum CropPreset: CaseIterable { case original, square1x1, portrait4x5, portrait9x16, landscape16x9 }
public enum ScaleMode { case fit, fill }

// MARK: - Helpers

@inline(__always) private func aspect(for preset: CropPreset) -> CGFloat? {
    switch preset {
    case .original:       return nil
    case .square1x1:      return 1.0
    case .portrait4x5:    return 4.0/5.0
    case .portrait9x16:   return 9.0/16.0
    case .landscape16x9:  return 16.0/9.0
    }
}

@inline(__always) private func even(_ x: CGFloat) -> CGFloat { floor(x / 2) * 2 }
@inline(__always) private func evenSize(_ s: CGSize) -> CGSize { .init(width: even(s.width), height: even(s.height)) }

private func canvasSize(for preset: CropPreset, orientedBase: CGSize) -> CGSize {
    switch preset {
    case .landscape16x9:  return CGSize(width: 1920, height: 1080)
    case .portrait9x16:   return CGSize(width: 1080, height: 1920)
    case .square1x1:      return CGSize(width: 1080, height: 1080)
    case .portrait4x5:    return CGSize(width: 1080, height: 1350)
    case .original:
        // Choose based on the *oriented* source
        return (orientedBase.width >= orientedBase.height)
             ? CGSize(width: 1920, height: 1080)
             : CGSize(width: 1080, height: 1920)
    }
}

// Return the track’s clean aperture rect if available; else full natural frame.
private func cleanApertureRect(for track: AVAssetTrack) -> CGRect {
    if let fd = (track.formatDescriptions as? [CMFormatDescription])?.first {
        let ca = CMVideoFormatDescriptionGetCleanAperture(fd, originIsAtTopLeft: false)
        if ca.width > 0, ca.height > 0 { return ca.integral }
    }
    let ns = track.naturalSize
    return CGRect(origin: .zero, size: CGSize(width: ns.width, height: ns.height)).integral
}

// Extract only the rotation (no tx/ty) from a preferredTransform
private func rotationOnly(from t: CGAffineTransform) -> CGAffineTransform {
    // Canonical orientations:
    //  0°:  [ 1  0;  0  1]
    // 90°:  [ 0  1; -1  0]
    // 180°: [-1  0;  0 -1]
    // 270°: [ 0 -1;  1  0]
    if abs(t.a - 1) < 0.001, abs(t.b) < 0.001, abs(t.c) < 0.001, abs(t.d - 1) < 0.001 {
        return .identity
    } else if abs(t.a) < 0.001, abs(t.b - 1) < 0.001, abs(t.c + 1) < 0.001, abs(t.d) < 0.001 {
        return CGAffineTransform(rotationAngle: .pi / 2)
    } else if abs(t.a + 1) < 0.001, abs(t.b) < 0.001, abs(t.c) < 0.001, abs(t.d + 1) < 0.001 {
        return CGAffineTransform(rotationAngle: .pi)
    } else if abs(t.a) < 0.001, abs(t.b + 1) < 0.001, abs(t.c - 1) < 0.001, abs(t.d) < 0.001 {
        return CGAffineTransform(rotationAngle: 3 * .pi / 2)
    } else {
        // Fallback to normalized angle
        return CGAffineTransform(rotationAngle: atan2(t.b, t.a))
    }
}

private struct TransformResult {
    let renderSize: CGSize
    let transform: CGAffineTransform
    let scale: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    let videoRectInRender: CGRect
}

// Build a transform that crops to the clean aperture, rotates (no tx/ty), scales with overscan,
// applies zoom/pan, and centers based on the *actual transformed corners* bbox (orientation-agnostic).
private func buildTransformForExport(
    track: AVAssetTrack,
    crop: CropPreset,
    mode: ScaleMode,
    overscan: CGFloat = 1.004,
    zoomScale: Double = 1.0,
    panOffsetX: Double = 0.0,
    panOffsetY: Double = 0.0
) async throws -> TransformResult {

    let pt  = try await track.load(.preferredTransform)
    let rot = rotationOnly(from: pt) // ignore tx/ty entirely
    let ca  = cleanApertureRect(for: track).integral

    // Oriented base size (w/h swap for 90°/270°)
    let portrait = (abs(rot.b.rounded()) == 1 && abs(rot.c.rounded()) == 1)
    let orientedBase: CGSize = portrait
        ? CGSize(width: ca.height, height: ca.width)
        : CGSize(width: ca.width,  height: ca.height)

    // Target render size from preset (even)
    let render0: CGSize = {
        guard let ar = aspect(for: crop) else { return orientedBase }
        let cur = orientedBase.width / max(orientedBase.height, 0.0001)
        if cur > ar { // too wide → clamp width
            return CGSize(width: orientedBase.height * ar, height: orientedBase.height)
        } else {      // too tall → clamp height
            return CGSize(width: orientedBase.width, height: orientedBase.width / ar)
        }
    }()
    let renderSize = evenSize(canvasSize(for: crop, orientedBase: orientedBase))

    let sx = renderSize.width  / max(orientedBase.width,  0.0001)
    let sy = renderSize.height / max(orientedBase.height, 0.0001)
    let base = (mode == .fill) ? max(sx, sy) : min(sx, sy)
    let s  = base * ((mode == .fill) ? overscan : 1.0)

    var t0 = CGAffineTransform(translationX: -ca.origin.x, y: -ca.origin.y)
    t0 = t0.concatenating(rot)
    t0 = t0.concatenating(CGAffineTransform(scaleX: s, y: s))

    // Apply user zoom (no pan yet) so centering doesn't cancel pan
    if zoomScale > 1.0 {
        t0 = t0.concatenating(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
    }

    // Phase B: compute bbox of transformed source corners, then translate to center
    @inline(__always)
    func map(_ p: CGPoint, by m: CGAffineTransform) -> CGPoint {
        CGPoint(x: m.a * p.x + m.c * p.y + m.tx,
                y: m.b * p.x + m.d * p.y + m.ty)
    }
    let srcW = CGFloat(ca.width), srcH = CGFloat(ca.height)
    let p0 = map(.init(x: 0,    y: 0),    by: t0)
    let p1 = map(.init(x: srcW, y: 0),    by: t0)
    let p2 = map(.init(x: 0,    y: srcH), by: t0)
    let p3 = map(.init(x: srcW, y: srcH), by: t0)

    let minX = min(p0.x, p1.x, p2.x, p3.x)
    let maxX = max(p0.x, p1.x, p2.x, p3.x)
    let minY = min(p0.y, p1.y, p2.y, p3.y)
    let maxY = max(p0.y, p1.y, p2.y, p3.y)
    let bboxW = maxX - minX
    let bboxH = maxY - minY

    let dx = (renderSize.width  - bboxW) / 2 - minX
    let dy = (renderSize.height - bboxH) / 2 - minY
    var t = t0.concatenating(CGAffineTransform(translationX: dx, y: dy))

    // Apply pan after centering so it doesn't get canceled
    var panX: CGFloat = 0
    var panY: CGFloat = 0
    if zoomScale > 1.0 || panOffsetX != 0 || panOffsetY != 0 {
        panX = panOffsetX * renderSize.width * 0.5 * zoomScale
        panY = panOffsetY * renderSize.height * 0.5 * zoomScale
        t = t.concatenating(CGAffineTransform(translationX: panX, y: panY))
    }

    // Final on-canvas rect of the visible video (after centering + pan)
    let videoRect = CGRect(origin: .zero, size: CGSize(width: srcW, height: srcH))
        .applying(t)
        .standardized
        .integral

    return .init(renderSize: renderSize, transform: t, scale: s, dx: dx, dy: dy,
                 videoRectInRender: videoRect)
}

// MARK: - Export

enum VideoEditEngine {
    static func exportEdited(
        inputURL: URL,
        snippetStart: Double,
        snippetDuration: Double,
        rotate: QuarterTurns,      // ignored (rotation UI disabled)
        crop: CropPreset,
        mode: ScaleMode,
        captionText: String? = nil,
        perClipCaptionAnchor: CaptionAnchor3 = .bottomLeft,
        zoomScale: Double = 1.0,
        panOffsetX: Double = 0.0,
        panOffsetY: Double = 0.0
    ) async throws -> URL {

        let asset = AVURLAsset(url: inputURL)
        guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Export", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        // Time window
        let dur = CMTimeGetSeconds(try await asset.load(.duration))
        let start = max(0, min(snippetStart, dur))
        let len   = max(0.01, min(snippetDuration, dur - start))
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: len,   preferredTimescale: 600))

        // Composition
        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(range, of: srcTrack, at: .zero)

        if let aSrc = try await asset.loadTracks(withMediaType: .audio).first,
           let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? a.insertTimeRange(range, of: aSrc, at: .zero)
        }

        // Geometry (shared builder; no user rotation)
        let tr = try await buildTransformForExport(
            track: srcTrack,
            crop: crop,
            mode: mode,
            overscan: 1.004,
            zoomScale: zoomScale,
            panOffsetX: panOffsetX,
            panOffsetY: panOffsetY
        )
        print("ENGINE_REV r5 • render:", tr.renderSize, "s:", tr.scale, "zoom:", zoomScale, "pan:", panOffsetX, panOffsetY, "dx:", tr.dx, "dy:", tr.dy)

        // Apply to layer
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: v)
        layer.setTransform(tr.transform, at: .zero)

        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        inst.layerInstructions = [layer]

        let vc = AVMutableVideoComposition()
        vc.instructions = [inst]
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.renderSize = tr.renderSize

        // Export
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edit-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)

        // Build a Core Animation overlay only if we have caption text
        if let text = captionText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use the same renderSize as your video composition/export
            let renderSize = vc.renderSize

            // Root container (flipped coordinates)
            let overlayRoot = CALayer()
            overlayRoot.frame = CGRect(origin: .zero, size: renderSize)
            overlayRoot.isGeometryFlipped = true

            // Text layer (simple, readable, bottom-center)
            // Text layer (match montage date/year font: plain system, semibold, no stroke)
            let tl = CATextLayer()
            tl.contentsScale = 2.0

            let fSize = max(20, tr.renderSize.height * 0.028)
            // Montage uses UIFont.systemFont(...); stick to that for parity
            let montageFont = UIFont.systemFont(ofSize: fSize, weight: .semibold)  // matches montage style

            let attribs: [NSAttributedString.Key: Any] = [
                .font: montageFont,
                .foregroundColor: UIColor.white
            ]
            let str = NSAttributedString(string: text, attributes: attribs)
            tl.string = str


            // Measure and position
            let maxW = tr.videoRectInRender.width * 0.88
            let size = (text as NSString).boundingRect(
                with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: montageFont],
                context: nil
            ).integral.size
            tl.bounds = CGRect(origin: .zero, size: CGSize(width: min(size.width, maxW), height: size.height))

            let padX = vc.renderSize.width  * 0.06   // match CaptionStyle.padX
            let padY = vc.renderSize.height * 0.06   // match CaptionStyle.padY

            let yCanvas = vc.renderSize.height - padY - tl.bounds.height/2
            let xCanvas: CGFloat = {
                switch perClipCaptionAnchor {
                case .bottomLeft:
                    return padX + tl.bounds.width/2
                case .bottomCenter:
                    return vc.renderSize.width / 2.0
                case .bottomRight:
                    return vc.renderSize.width - padX - tl.bounds.width/2
                }
            }()

            tl.position = CGPoint(x: xCanvas, y: yCanvas)


             overlayRoot.addSublayer(tl)

            // Attach to the pipeline
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: renderSize)

            let videoLayer = CALayer()
            videoLayer.frame = parent.bounds

            parent.addSublayer(videoLayer)
            parent.addSublayer(overlayRoot)

            vc.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parent
            )
        }


        let sess = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        sess.outputURL = out
        sess.outputFileType = .mp4
        sess.videoComposition = vc

        return try await withCheckedThrowingContinuation { c in
            sess.exportAsynchronously {
                if sess.status == .completed { c.resume(returning: out) }
                else { c.resume(throwing: sess.error ?? NSError(domain: "Export", code: -2)) }
            }
        }
    }
}

// MARK: - Headless helpers (Quick Add)

import UIKit

extension VideoEditEngine {

    /// Still → video clip. Centers the image on an exact-pixel rect to avoid single-pixel seams.
    /// - Parameters:
    ///   - image: Uprighted still image.
    ///   - duration: Clip duration in seconds (e.g. 1.5).
    ///   - renderSize: Output canvas (defaults to 1080×1920 portrait to match quick paths).
    /// - Returns: MP4 file URL.
    public static func exportStill(
        _ image: UIImage,
        duration: Double,
        renderSize: CGSize = .init(width: 1080, height: 1920)
    ) async throws -> URL {

        // --- 1) Output URL
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)

        // --- 2) Writer @ 30fps
        let fps: Int32 = 30
        let totalFrames = max(1, Int(ceil(duration * Double(fps))))
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(even(renderSize.width)),
            AVVideoHeightKey: Int(even(renderSize.height))
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey  as String: Int(even(renderSize.width)),
                kCVPixelBufferHeightKey as String: Int(even(renderSize.height))
            ])

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoEditEngine", code: -30,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
        }
        writer.add(input)

        func makeBuffer() -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(even(renderSize.width)),
                                Int(even(renderSize.height)),
                                kCVPixelFormatType_32ARGB,
                                nil,
                                &pb)
            return pb!
        }

        // Upright & compute an integral draw rect (prevents 1-px black bar)
        let src = upright(image)
        guard let cg = src.cgImage else {
            throw NSError(domain: "VideoEditEngine", code: -31,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid CGImage"])
        }

        let imgW = CGFloat(cg.width), imgH = CGFloat(cg.height)
        let imgAR = imgW / max(imgH, 0.0001)
        let canW  = even(renderSize.width), canH = even(renderSize.height)
        let canAR = canW / max(canH, 0.0001)

        @inline(__always)
        func integral(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x.rounded(),
                   y: r.origin.y.rounded(),
                   width: r.size.width.rounded(),
                   height: r.size.height.rounded())
        }

        let drawRect: CGRect = {
            if imgAR > canAR {
                // Wider → fit width, center vertically
                let w = canW
                let h = (w / imgAR).rounded()
                let y = ((canH - h) / 2).rounded()
                return integral(CGRect(x: 0, y: y, width: w, height: h))
            } else {
                // Taller → fit height, center horizontally
                let h = canH
                let w = (h * imgAR).rounded()
                let x = ((canW - w) / 2).rounded()
                return integral(CGRect(x: x, y: 0, width: w, height: h))
            }
        }()

        // --- 3) Write identical frame N times
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var t = CMTime.zero
        let step = CMTime(value: 1, timescale: fps)

        for _ in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { usleep(2_000) }

            let pb = makeBuffer()
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                   width: Int(canW),
                                   height: Int(canH),
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                // Clear once – prevents uninitialized pixels from showing as seams
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: canW, height: canH))
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: drawRect)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: t)
            t = t + step
        }

        input.markAsFinished()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed { cont.resume(returning: ()) }
                else { cont.resume(throwing: writer.error ?? NSError(
                    domain: "VideoEditEngine", code: -32,
                    userInfo: [NSLocalizedDescriptionKey: "Writer failed"]))
                }
            }
        }
        return out
    }

    // MARK: - Still → Video (Ken Burns)

    public static func exportStillKenBurns(
        _ image: UIImage,
        duration: Double,
        renderSize: CGSize = .init(width: 1080, height: 1920),
        fps: Int32 = 30,
        zoomStart: CGFloat = 0.95,
        zoomEnd:   CGFloat = 1.07,
        panStart:  CGPoint = CGPoint(x: 0.5, y: 0.45), // normalized (0..1) in source image
        panEnd:    CGPoint = CGPoint(x: 0.5, y: 0.55)  // subtle downward pan
    ) async throws -> URL {

        // --- 1) Output
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-kb-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)

        // --- 2) Writer
        let totalFrames = max(1, Int(ceil(duration * Double(fps))))
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(even(renderSize.width)),
            AVVideoHeightKey: Int(even(renderSize.height))
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey  as String: Int(even(renderSize.width)),
                kCVPixelBufferHeightKey as String: Int(even(renderSize.height))
            ])

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoEditEngine", code: -40,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
        }
        writer.add(input)

        // Upright image + geometry you already use in exportStill(...)
        let src = upright(image)
        guard let cg = src.cgImage else {
            throw NSError(domain: "VideoEditEngine", code: -41,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid CGImage"])
        }
        let imgW = CGFloat(cg.width), imgH = CGFloat(cg.height)
        let canW = even(renderSize.width), canH = even(renderSize.height)
        let imgAR = imgW / max(imgH, 0.0001)
        let canAR = canW / max(canH, 0.0001)

        @inline(__always) func ease(_ t: CGFloat) -> CGFloat { t*t*(3 - 2*t) } // smoothstep

        func makeBuffer() -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(canW), Int(canH),
                                kCVPixelFormatType_32ARGB,
                                nil, &pb)
            return pb!
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var time = CMTime.zero
        let step = CMTime(value: 1, timescale: fps)

        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { usleep(2_000) }

            let u = ease(CGFloat(i) / CGFloat(max(1, totalFrames - 1)))
            let zoom = zoomStart + (zoomEnd - zoomStart) * u
            let cx = panStart.x + (panEnd.x - panStart.x) * u
            let cy = panStart.y + (panEnd.y - panStart.y) * u

            // Compute the image rect we will draw into the canvas this frame.
            // Start with "fit" in canvas, then apply zoom & center based on (cx, cy).
            // We keep letterboxing (no crop) like your existing exportStill(...).
            let baseDrawRect: CGRect = {
                if imgAR > canAR {
                    // fit width
                    let w = canW
                    let h = (w / imgAR).rounded()
                    let y = ((canH - h) / 2).rounded()
                    return CGRect(x: 0, y: y, width: w, height: h)
                } else {
                    // fit height
                    let h = canH
                    let w = (h * imgAR).rounded()
                    let x = ((canW - w) / 2).rounded()
                    return CGRect(x: x, y: 0, width: w, height: h)
                }
            }()

            // Apply zoom around the (cx, cy) point in image-space mapped to base rect.
            let zW = baseDrawRect.width  * zoom
            let zH = baseDrawRect.height * zoom
            let px = baseDrawRect.minX + cx * (baseDrawRect.width)  - zW * 0.5
            let py = baseDrawRect.minY + cy * (baseDrawRect.height) - zH * 0.5
            let drawRect = CGRect(x: px.rounded(), y: py.rounded(),
                                  width: zW.rounded(), height: zH.rounded())

            var pb = makeBuffer()
            CVPixelBufferLockBaseAddress(pb, [])

            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                   width: Int(canW),
                                   height: Int(canH),
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {

                // Clear + draw
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: canW, height: canH))
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: drawRect)
            }

            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: time)
            time = CMTimeAdd(time, step)
        }

        input.markAsFinished()

        return try await withCheckedThrowingContinuation { cont in
            writer.finishWriting {
                if writer.status == .completed { cont.resume(returning: out) }
                else { cont.resume(throwing: writer.error ?? NSError(domain: "VideoEditEngine", code: -42)) }
            }
        }
    }


    /// Video/Live-Photo → (optionally) trimmed clip using the same export pipeline as the editor.
    /// - Parameters:
    ///   - inputURL: Source movie (regular video or Live Photo paired .mov).
    ///   - trimTo: If provided, exports the **first N seconds**. If nil, exports full duration.
    ///   - crop: Geometry preset (defaults to `.original`). Uses the same clean-aperture/centering.
    /// - Returns: MP4 file URL.
    public static func exportVideo(
        from inputURL: URL,
        trimTo seconds: Double? = nil,
        crop: CropPreset = .original,
        mode: ScaleMode = .fill
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let full = CMTimeGetSeconds(try await asset.load(.duration))
        let len  = max(0.01, min(seconds ?? full, full))
        // Reuse the exact editor pipeline for geometry/transform/clean aperture.
        return try await exportEdited(
            inputURL: inputURL,
            snippetStart: 0,
            snippetDuration: len,
            rotate: .t0,
            crop: crop,
            mode: mode
        )
    }

    // Upright helper (local copy; mirrors MediaHelpers.upright)
    @inline(__always)
    private static func upright(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        img.draw(in: CGRect(origin: .zero, size: img.size))
        let fixed = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return fixed
    }
}
