//
//  MontageHelpers.swift
//  Snap Second
//
//  Helper functions and computed properties for MontageView
//

import Foundation
import SwiftUI
import AVFoundation
import UIKit

// MARK: - Device Layout Helpers

extension MontageView {

    var isSmallDevice: Bool {
        UIScreen.main.bounds.height < 750  // iPhone SE, 12 mini, 13 mini
    }

    var isMediumDevice: Bool {
        UIScreen.main.bounds.height >= 750 && UIScreen.main.bounds.height < 850  // iPhone 12, 13, 14
    }

    var topPadding: CGFloat {
        if isSmallDevice { return 12 }
        if isMediumDevice { return 50 }
        return 80
    }

    var videoHeightRatio: CGFloat {
        if isSmallDevice { return 0.35 }  // Show more timeline/controls
        return 0.40
    }

    var bottomPanelMaxHeight: CGFloat {
        if isSmallDevice { return 380 }
        if isMediumDevice { return 420 }
        return 460
    }

    var timelineHeight: CGFloat {
        if isSmallDevice { return 180 }
        return 220
    }

    var categoryButtonSize: CGFloat {
        if isSmallDevice { return 38 }
        return 44
    }

    var categoryButtonSpacing: CGFloat {
        if isSmallDevice { return 10 }
        return 14
    }

    var categoryButtonFontSize: CGFloat {
        if isSmallDevice { return 8 }
        return 9
    }
}

// MARK: - Audio Helpers

extension MontageView {

    /// Convert volume percentage to gain using logarithmic scale
    func gainFromPercent(
        _ percent: Double,
        minDb: Double = -36,   // very quiet
        maxDb: Double = -3     // never full-scale
    ) -> Float {
        let p = max(0.0, min(100.0, percent)) / 100.0
        let db = minDb + (maxDb - minDb) * p
        return Float(pow(10.0, db / 20.0))
    }

    var musicFloat: Float {
        gainFromPercent(musicVol)
    }

    var videoFloat: Float {
        if isClipAudioMuted {
            return 0
        }
        return gainFromPercent(videoVol, minDb: -24, maxDb: -6)
    }

    /// Effective music URL: custom imported audio if enabled, otherwise the selected bundled track
    var effectiveMusicURL: URL? {
        if isUsingCustomAudio, let url = customMusicURL {
            return url
        }
        if let track = selectedTrack {
            // Try mp3 first (current format), then m4a as fallback
            if let url = Bundle.main.url(forResource: track.resource, withExtension: "mp3") {
                return url
            }
            return Bundle.main.url(forResource: track.resource, withExtension: "m4a")
        }
        return nil
    }
}

// MARK: - Layout & Styling Helpers

extension MontageView {

    var backgroundUIColor: UIColor {
        switch backgroundStyle {
        case .black: return .black
        case .white: return .white
        case .blur:  return .black   // placeholder; blur path ignores this color
        }
    }

    var forcedAspect: CGFloat {
        switch orientation {
        case .v916: return 9.0/16.0
        case .s11:  return 1.0
        case .h169: return 16.0/9.0
        }
    }

    var exportSize: CGSize {
        let hd = (exportQuality == .hd)
        switch orientation {
        case .v916: return hd ? CGSize(width: 1080, height: 1920) : CGSize(width: 720, height: 1280)
        case .s11:  return hd ? CGSize(width: 1080, height: 1080) : CGSize(width: 720, height: 720)
        case .h169: return hd ? CGSize(width: 1920, height: 1080) : CGSize(width: 1280, height: 720)
        }
    }

    var orientationLabel: String {
        switch orientation {
        case .v916: return "9:16"
        case .s11: return "1:1"
        case .h169: return "16:9"
        }
    }
}

// MARK: - Caption Helpers

extension MontageView {

    var captionAlignment: Alignment {
        switch captionPos {
        case .bottomLeft:   return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight:  return .bottomTrailing
        }
    }

    var bottomRowAnchor: CaptionAnchor3 {
        switch captionPos {
        case .bottomLeft:   return .bottomLeft
        case .bottomCenter: return .bottomCenter
        case .bottomRight:  return .bottomRight
        }
    }

    /// Trimmed custom caption text used for preview; nil when not needed
    var previewCustomCaptionText: String? {
        guard case .custom = captionMode else { return nil }
        let trimmed = customCaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func effectiveCaptionUIColorForCurrentMode() -> UIColor {
        if case .custom = captionMode {
            return UIColor(captionColor)
        }
        return .white
    }
}

// MARK: - Pro Feature Helpers

extension MontageView {

    var isCustomCaptionsOn: Bool {
        if case .custom = captionMode {
            return true
        }
        return false
    }

    var isDateCaptionsOn: Bool {
        if case .dateYear = captionMode {
            return showDates
        }
        return false
    }

    var isInlineCaptionVisible: Bool {
        isCustomCaptionsOn
    }

    var isUsingProMusic: Bool {
        // ONLY custom imported audio is Pro
        return isUsingCustomAudio
    }

    var isUsingProFilter: Bool {
        selectedFilter != .none
    }

    /// Any Pro feature toggled on for this montage?
    var hasProFeatureEnabled: Bool {
        (!brandingOn) || isUsingProMusic || isCustomCaptionsOn || (exportQuality == .hd)
    }
}

// MARK: - Imported Audio Helpers

extension MontageView {

    var importedAudioDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("MontageAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var videoContentDurationForTimeline: TimeInterval {
        if let maxEnd = videoTimelineItems.map(\.endTime).max(), maxEnd > 0 {
            return maxEnd
        }
        return max(0, composition.duration.seconds - (brandingOn ? 2.0 : 0.0))
    }

    func persistedAudioURL(from importedURL: URL) throws -> URL {
        let fm = FileManager.default
        let ext = importedURL.pathExtension.isEmpty ? "m4a" : importedURL.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = importedAudioDirectory.appendingPathComponent(fileName)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: importedURL, to: destination)
        return destination
    }
}
