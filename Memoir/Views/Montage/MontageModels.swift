//
//  MontageModels.swift
//  Snap Second
//
//  Data models and enums for Montage functionality
//

import Foundation
import AVFoundation
import SwiftUI

// MARK: - Enums

enum MontageStyle: String, Codable {
    case classic
    case cinematic
    case scrolling
    case timelapse
}

enum MontageFilter: String, Codable, CaseIterable, Identifiable {
    case none
    case warm
    case cool
    case vivid
    case mono
    case fade
    case vintage
    case crisp
    case soft
    case moody

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:     return "Original"
        case .warm:     return "Warm"
        case .cool:     return "Cool"
        case .vivid:    return "Vivid"
        case .mono:     return "Mono"
        case .fade:     return "Fade"
        case .vintage:  return "Vintage"
        case .crisp:    return "Crisp"
        case .soft:     return "Soft"
        case .moody:    return "Moody"
        }
    }

    var subtitle: String? {
        switch self {
        case .none:
            return "No filter"
        case .warm:
            return "Cozy golden tint"
        case .cool:
            return "Calm blue tone"
        case .vivid:
            return "Extra pop and contrast"
        case .mono:
            return "Black & white look"
        case .fade:
            return "Soft, slightly washed"
        case .vintage:
            return "Warm, nostalgic vibe"
        case .crisp:
            return "Clean, punchy details"
        case .soft:
            return "Muted, gentle colors"
        case .moody:
            return "Darker, cinematic feel"
        }
    }
}

// MARK: - Track Model

struct Track: Identifiable, Equatable {
    let id: String             // e.g. "calm"
    let name: String           // human-friendly, e.g. "Calm Breeze"
    let resource: String       // filename in Bundle (without extension)
}

// Production music is licensed separately and intentionally omitted from the
// public portfolio. This procedurally generated demo track keeps the preview
// and bundled-audio paths functional; the editor also supports custom audio.
let bundledTracks: [Track] = [
    Track(id: "moments", name: "Portfolio Demo", resource: "moments")
]

// MARK: - Preferences Model

struct MontagePrefs: Codable {
    var style: String = "classic"

    var trackID: String?
    var musicVol: Double
    var videoVol: Double

    var rangeStart: Date
    var rangeEnd: Date
    var rangeLabel: String

    var orientation: String     // "v916" | "s11" | "h169"
    var contentMode: String     // "fit"  | "fill"

    var captionsMode: String    // "none" | "dateYear" | "custom"
    var customCaption: String?
    var showDates: Bool

    var showBranding: Bool = true

    // LEGACY (quick toggle) — keep for back-compat
    var captionTextColor: String = "white"

    // NEW — rich caption prefs
    var captionRGBA: RGBA = .init(r: 1, g: 1, b: 1, a: 1)
    var captionOpacity: Double = 1.0
    var captionFontSize: Double = 24.0
    var captionFont: String = "system"           // CaptionFontVariant.rawValue
    var captionPos: String = "bottomCenter"      // CaptionPos3.rawValue-like
    var exportQuality: String = "standard" // "standard" | "hd"
    var background: String = "black"

    // Normalized custom-caption position (0...1 in render coordinates)
    var captionNormX: Double = 0.08
    var captionNormY: Double = 0.90

    var filter: String = "none"
    var speed: Double = 1.0
}

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

// MARK: - Helper Extensions

extension Double {
    var clamped01: Double { max(0, min(1, self)) }
}

extension URL: Identifiable {
    public var id: URL { self }
}

extension Double {
    var formattedTime: String {
        guard self.isFinite else { return "0:00" }
        let s = max(0, Int(self.rounded()))
        let m = s / 60, r = s % 60
        return "\(m):" + String(format: "%02d", r)
    }
}

// MARK: - CALayer Extension

extension CALayer {
    func deepClone() -> CALayer? {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
            return try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? CALayer
        } catch {
            return self.copy() as? CALayer
        }
    }
}
