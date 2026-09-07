//
//  TimelineThumbnailGenerator.swift
//  Memoir
//
//  Created on 1/5/26.
//

import AVFoundation
import UIKit
import SwiftUI

/// Generates thumbnail images from video compositions for timeline display
/// Uses parallel async generation for fast loading on long projects
@MainActor
final class TimelineThumbnailGenerator: ObservableObject {

    @Published private(set) var thumbnails: [TimeInterval: UIImage] = [:]
    @Published private(set) var sortedTimes: [TimeInterval] = []
    @Published private(set) var isGenerating = false

    private var imageGenerator: AVAssetImageGenerator?
    private var isCancelled = false
    private var generationID = 0

    /// Generate thumbnails at regular intervals for timeline display
    /// Uses batch async generation for significantly faster loading
    /// - Parameters:
    ///   - composition: The video composition to generate thumbnails from
    ///   - videoComposition: The video composition with effects/transforms
    ///   - count: Number of thumbnails to generate (evenly spaced across duration)
    ///   - contentDuration: Optional duration to use instead of composition duration (excludes end card)
    func generateThumbnails(
        from composition: AVComposition,
        videoComposition: AVVideoComposition?,
        count: Int = 20,
        contentDuration: TimeInterval? = nil
    ) {
        // Cancel any existing generation
        cancel()
        isCancelled = false
        generationID &+= 1
        let currentGenerationID = generationID

        // Use provided content duration or fall back to composition duration
        let duration = contentDuration ?? composition.duration.seconds
        guard duration > 0, count > 0 else {
            return
        }

        isGenerating = true

        // Clear existing thumbnails for fresh generation
        thumbnails = [:]
        sortedTimes = []

        // Configure image generator
        let generator = AVAssetImageGenerator(asset: composition)
        generator.appliesPreferredTrackTransform = true
        // Allow small tolerance to handle edge frames that may not exist at exact times
        let frameTolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance
        generator.maximumSize = CGSize(width: 120, height: 200) // Small thumbnails for timeline

        if let videoComposition = videoComposition {
            generator.videoComposition = videoComposition
        }

        self.imageGenerator = generator

        // Calculate time points - ensure we cover both start (0) and end (duration)
        // Use count-1 intervals to map indices 0..count-1 to times 0..duration
        var times: [NSValue] = []
        var timeMapping: [CMTime: TimeInterval] = [:] // Map CMTime to original seconds for dictionary key

        for i in 0..<count {
            // Map index to time: 0 -> 0, count-1 -> near end (but not exact duration)
            // Avoid exact duration as video compositions often don't have a valid frame there
            let timeSeconds: Double
            if count <= 1 {
                timeSeconds = duration / 2  // Single thumbnail at center
            } else {
                let progress = Double(i) / Double(count - 1)  // 0.0 to 1.0
                // Map to 0...duration with the last frame slightly before the end
                let safeEndTime = max(0, duration - 0.05)  // 50ms before end
                timeSeconds = progress * safeEndTime
            }
            let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)
            times.append(NSValue(time: time))
            timeMapping[time] = timeSeconds
        }

        // Track completion
        var completedCount = 0
        let totalCount = count
        let publishBatchSize = 8
        var generated: [TimeInterval: UIImage] = [:]
        var publishedCount = 0

        func publishBatchIfNeeded(force: Bool) {
            guard force || generated.count - publishedCount >= publishBatchSize else { return }
            thumbnails = generated
            sortedTimes = generated.keys.sorted()
            publishedCount = generated.count
        }

        // Use async batch generation - this runs in parallel on background threads
        // and progressively calls back for each thumbnail as it becomes ready
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requestedTime, cgImage, actualTime, result, error in
            let image: UIImage? = {
                guard let cgImage, result == .succeeded else { return nil }
                return UIImage(cgImage: cgImage)
            }()
            let timeSeconds = timeMapping[requestedTime] ?? requestedTime.seconds

            // Dispatch to main thread for UI updates
            DispatchQueue.main.async {
                guard let self = self,
                      !self.isCancelled,
                      self.generationID == currentGenerationID else { return }

                completedCount += 1

                if let image {
                    generated[timeSeconds] = image
                }

                // Check if all thumbnails are done
                if completedCount >= totalCount {
                    publishBatchIfNeeded(force: true)
                    self.isGenerating = false
                    print("✅ Generated \(self.thumbnails.count) thumbnails for \(duration)s video")
                    if let first = self.sortedTimes.first, let last = self.sortedTimes.last {
                        print("   Range: \(String(format: "%.2f", first))s to \(String(format: "%.2f", last))s")
                    }
                } else {
                    publishBatchIfNeeded(force: false)
                }
            }
        }
    }

    /// Cancel any ongoing thumbnail generation
    func cancel() {
        isCancelled = true
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        isGenerating = false
    }

    deinit {
        imageGenerator?.cancelAllCGImageGeneration()
    }
}
