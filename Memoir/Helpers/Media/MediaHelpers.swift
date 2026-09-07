//
//  MediaHelpers.swift
//  Memoir
//
//  Created by Ryan Zheng on 6/6/25.
//

import AVFoundation
import Photos
import UIKit      // for UIImage thumbnails
import CoreVideo


enum MediaError: Error {
    case unableToExport
    case thumbnailFailed
}

enum SilenceError: Error { case writeFailed }

/// Writes a silent .caf file for the requested duration.
/// Uses chunked writing to avoid memory crashes on long durations.
func makeSilenceFileURL(duration: Double,
                        sampleRate: Double = 44100,
                        channels: AVAudioChannelCount = 2) async throws -> URL {
    let totalFrames = AVAudioFrameCount(max(0, duration) * sampleRate)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
        throw SilenceError.writeFailed
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).caf")
    // Clean up if any
    try? FileManager.default.removeItem(at: url)

    let file = try AVAudioFile(forWriting: url, settings: format.settings)

    // Write in chunks to avoid memory exhaustion on long durations
    // 0.5 second chunks = 22050 frames × 2 channels × 4 bytes = ~175KB per chunk
    // Using smaller chunks to reduce memory pressure on long exports
    let chunkSize = AVAudioFrameCount(sampleRate / 2) // 0.5 seconds of audio

    var framesRemaining = totalFrames
    while framesRemaining > 0 {
        // Create buffer inside loop and use autoreleasepool to ensure cleanup
        try autoreleasepool {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
                throw SilenceError.writeFailed
            }
            let framesToWrite = min(chunkSize, framesRemaining)
            buf.frameLength = framesToWrite
            // Buffer is already zeroed = silence
            try file.write(from: buf)
            framesRemaining -= framesToWrite
        }
        // Yield briefly to allow memory cleanup on long durations
        if framesRemaining > 0 {
            await Task.yield()
        }
    }

    // Quick integrity check
    guard FileManager.default.fileExists(atPath: url.path) else { throw SilenceError.writeFailed }
    return url
}

// MARK: - Video trimming helper
struct VideoTrimmer {
  /// Trims the first `targetDuration` of `inputURL`, preserving orientation.
  static func trim(_ inputURL: URL,
                   to targetDuration: CMTime
                  ) async throws -> URL {
    let asset = AVAsset(url: inputURL)

    // 1) Create a composition and insert the first `targetDuration` of the video track
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw NSError(domain: "VideoTrimmer", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No video track"])
    }

    let composition = AVMutableComposition()
    let compTrack = composition.addMutableTrack(
      withMediaType: .video,
      preferredTrackID: kCMPersistentTrackID_Invalid
    )!
    try compTrack.insertTimeRange(
      CMTimeRange(start: .zero, duration: targetDuration),
      of: videoTrack,
      at: .zero
    )

      if let audioTrack = asset.tracks(withMediaType: .audio).first {
          let aComp = composition.addMutableTrack(withMediaType: .audio,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid)!
          try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: targetDuration),
                                    of: audioTrack,
                                    at: .zero)
      }

    // 2) Apply the asset’s preferredTransform so orientation is preserved
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: targetDuration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
    let t = videoTrack.preferredTransform
    layerInstruction.setTransform(t, at: .zero)
    instruction.layerInstructions = [layerInstruction]

    let videoComp = AVMutableVideoComposition()
    videoComp.instructions = [instruction]
    // Render size must account for rotation
    let naturalSize = videoTrack.naturalSize.applying(t)
    videoComp.renderSize = CGSize(width: abs(naturalSize.width),
                                  height: abs(naturalSize.height))
    videoComp.frameDuration = CMTime(value: 1, timescale: 30)

    // 3) Export with the composition
    let outURL = FileManager.default
      .temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
    guard let session = AVAssetExportSession(
      asset: composition,
      presetName: AVAssetExportPresetHighestQuality
    ) else {
      throw NSError(domain: "VideoTrimmer", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Can't create export session"])
    }
    session.outputURL = outURL
    session.outputFileType = .mp4
    session.videoComposition = videoComp
    session.timeRange = CMTimeRange(start: .zero, duration: targetDuration)

    try await withCheckedThrowingContinuation { cont in
      session.exportAsynchronously {
        switch session.status {
        case .completed:   cont.resume(returning: ())
        case .failed:      cont.resume(throwing: session.error!)
        case .cancelled:   cont.resume(throwing: session.error!)
        default:           cont.resume(throwing: NSError(
                              domain: "VideoTrimmer", code: -3,
                              userInfo:[NSLocalizedDescriptionKey:"Unknown status"]))
        }
      }
    }
    return outURL
  }
}

// MARK: - Thumbnail generation helper
struct ThumbnailGenerator {
    /// Generates a square thumbnail (up to `maxLength` pixels) from the first 0.1s of `url`.
    static func make(
        from url: URL,
        maxLength: CGFloat = 300
    ) throws -> UIImage {

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxLength, height: maxLength)

        // Grab the frame at 0.1 seconds
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        var image = UIImage(cgImage: cgImage)

        // If not square, center-crop to square
        if image.size.width != image.size.height {
            let length = min(image.size.width, image.size.height)
            let cropRect = CGRect(
                x: (image.size.width  - length) / 2,
                y: (image.size.height - length) / 2,
                width: length,
                height: length
            )
            if let cropped = image.cgImage?.cropping(to: cropRect) {
                image = UIImage(cgImage: cropped)
            }
        }

        return image
    }
}

// 1) Extract the MOV component of a Live Photo and trim to maxDuration:

struct LivePhotoProcessor {
  /// Extracts the MOV component from a Live Photo PHAsset, trims it to `maxDuration` seconds, and returns the file URL.
    static func extractLivePhotoVideo(
      from asset: PHAsset,
      maxDuration: TimeInterval
    ) async throws -> URL {
      let resources = PHAssetResource.assetResources(for: asset)
      guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
        throw NSError(domain: "LivePhotoProcessor", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "No pairedVideo"])
      }

      let tempDir = FileManager.default.temporaryDirectory
      let targetURL = tempDir.appendingPathComponent(videoResource.originalFilename)
      try? FileManager.default.removeItem(at: targetURL)

      let requestOptions = PHAssetResourceRequestOptions()
      requestOptions.isNetworkAccessAllowed = true

      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        PHAssetResourceManager.default().writeData(
          for: videoResource,
          toFile: targetURL,
          options: requestOptions
        ) { error in
          if let err = error {
            continuation.resume(throwing: err)
          } else {
            continuation.resume(returning: ())
          }
        }
      }
      print("[LivePhoto] wrote MOV to \(targetURL)")

      let trimmedURL = try await VideoTrimmer.trim(
        targetURL,
        to: CMTime(seconds: maxDuration, preferredTimescale: 600)
      )
      print("[LivePhoto] trimmed to \(maxDuration)s: \(trimmedURL)")

      return trimmedURL
    }

}

// 2) Render a still UIImage into a 1s video:
struct ImageToVideoConverter {
  /// Renders `image` into a video of `duration` seconds and returns the file URL.
    static func makeVideo(
      from image: UIImage,
      duration: TimeInterval
    ) async throws -> URL {

      // --- 1.  output URL --------------------------------------------------
      let outURL = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("mp4")
      try? FileManager.default.removeItem(at: outURL)

      // --- 2.  target canvas 1080×1920 portrait ----------------------------
      let canvas = CGSize(width: 1080, height: 1920)
      let fps: Int32 = 30
      let totalFrames = Int(duration * Double(fps))

      // --- 3.  asset-writer -------------------------------------------------
      let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
      let videoSettings: [String: Any] = [
          AVVideoCodecKey:  AVVideoCodecType.h264,
          AVVideoWidthKey:  Int(canvas.width),
          AVVideoHeightKey: Int(canvas.height)
      ]
      let input = AVAssetWriterInput(mediaType: .video,
                                     outputSettings: videoSettings)
      input.expectsMediaDataInRealTime = false

      // upscale / downscale pixel-buffer to canvas size
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
          assetWriterInput: input,
          sourcePixelBufferAttributes: [
              kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
              kCVPixelBufferWidthKey  as String: Int(canvas.width),
              kCVPixelBufferHeightKey as String: Int(canvas.height)
          ])

      guard writer.canAdd(input) else { throw MediaError.unableToExport }
      writer.add(input)

      // --- 4.  start session -----------------------------------------------
      writer.startWriting()
      writer.startSession(atSourceTime: .zero)

      // helpers
      func makeBuffer() -> CVPixelBuffer {
          var pb: CVPixelBuffer?
          CVPixelBufferCreate(kCFAllocatorDefault,
                              Int(canvas.width), Int(canvas.height),
                              kCVPixelFormatType_32ARGB,
                              nil, &pb)
          return pb!
      }

        let srcImage = upright(image)

      let cgImage = srcImage.cgImage!                         // force-unwrap ok after guard
      let imgAR   = CGFloat(cgImage.width) / CGFloat(cgImage.height)
      let canAR   = canvas.width / canvas.height
      let drawRect: CGRect = {
          if imgAR > canAR {   // image is wider → pillar-box
              let w = canvas.width
              let h = w / imgAR
              return CGRect(x: 0, y: (canvas.height-h)/2, width: w, height: h)
          } else {            // image is taller → letter-box
              let h = canvas.height                  // ✅ fit to height
            let w = h * imgAR
              return CGRect(x: (canvas.width-w)/2, y: 0, width: w, height: h)
          }
      }()

      // --- 5.  draw frames with Ken Burns zoom effect (0.95x → 1.07x) ----
      var frameTime = CMTime.zero
      let frameDur  = CMTime(value: 1, timescale: fps)

      // Ken Burns: zoom from 0.95x → 1.07x (same as ClipEditorSheet)
      let startZoom: CGFloat = 0.95
      let endZoom:   CGFloat = 1.07

      for i in 0..<totalFrames {
          while !input.isReadyForMoreMediaData { usleep(2_000) }

          // Calculate zoom factor for this frame
          let progress = CGFloat(i) / CGFloat(max(1, totalFrames - 1))
          let zoom = startZoom + (endZoom - startZoom) * progress

          let pb = makeBuffer()
          CVPixelBufferLockBaseAddress(pb, [])
          if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                 width: Int(canvas.width),
                                 height: Int(canvas.height),
                                 bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
              // Apply zoom by scaling the draw rect
              let scaledW = drawRect.width * zoom
              let scaledH = drawRect.height * zoom
              let dx = (scaledW - drawRect.width) / 2
              let dy = (scaledH - drawRect.height) / 2
              let zoomedRect = CGRect(x: drawRect.origin.x - dx,
                                     y: drawRect.origin.y - dy,
                                     width: scaledW,
                                     height: scaledH)
              ctx.draw(cgImage, in: zoomedRect)
          }
          CVPixelBufferUnlockBaseAddress(pb, [])

          adaptor.append(pb, withPresentationTime: frameTime)
          frameTime = frameTime + frameDur
      }

      input.markAsFinished()
      try await withCheckedThrowingContinuation { cont in
          writer.finishWriting {
              writer.status == .completed
              ? cont.resume(returning: ())
              : cont.resume(throwing: writer.error ?? MediaError.unableToExport)
          }
      }
      print("[ImageToVideo] output portrait 1080×1920 at \(outURL)")
      return outURL
    }

    private static func upright(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }

        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        img.draw(in: CGRect(origin: .zero, size: img.size))
        let fixed = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return fixed
    }


}
