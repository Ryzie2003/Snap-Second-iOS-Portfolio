//
//  ClipDefaults.swift
//  Memoir
//
//  Centralized defaults for new clip creation and first-time edits.
//

import Foundation
import CoreGraphics

enum ClipDefaults {
    static let durationKey = "clip.default.duration"
    static let orientationKey = "clip.default.orientation"

    static let defaultDuration: Double = 1.5
    static let defaultOrientationRaw: String = "portrait"
    static let durationRange: ClosedRange<Double> = 0.5...5.0

    static var duration: Double {
        let raw = UserDefaults.standard.double(forKey: durationKey)
        let base = raw > 0 ? raw : defaultDuration
        return min(max(base, durationRange.lowerBound), durationRange.upperBound)
    }

    static var orientationRaw: String {
        let raw = UserDefaults.standard.string(forKey: orientationKey) ?? defaultOrientationRaw
        switch raw {
        case "portrait", "landscape", "square":
            return raw
        default:
            return defaultOrientationRaw
        }
    }

    struct MediaConfig {
        let crop: CropPreset
        let mode: ScaleMode
        let renderSize: CGSize
    }

    static func mediaConfig(for orientationRaw: String) -> MediaConfig {
        switch orientationRaw {
        case "landscape":
            return .init(
                crop: .landscape16x9,
                mode: .fit,
                renderSize: CGSize(width: 1920, height: 1080)
            )
        case "square":
            return .init(
                crop: .square1x1,
                mode: .fill,
                renderSize: CGSize(width: 1080, height: 1080)
            )
        default:
            return .init(
                crop: .portrait9x16,
                mode: .fit,
                renderSize: CGSize(width: 1080, height: 1920)
            )
        }
    }

    static var mediaConfig: MediaConfig {
        mediaConfig(for: orientationRaw)
    }
}
